#!/usr/bin/env julia
# project-scaffold — generates a new Julia package with PkgTemplates and completes it to the
# conventions of this workbench: an activation script in every environment, test, docs and
# bench environments that take the package by path, an optional DrWatson pipeline layer,
# and GitHub workflows, Dependabot and citation metadata that stay dormant until the
# launch. It writes only below --dir and needs the network for the registry and for
# git ls-remote.
#
#   julia run.jl project-scaffold NAME --dir DIR --user USER --authors "Name One, Name Two"
#                                 [--julia X.Y] [--no-pipeline] [--no-commit] [--no-hook]
#                                 [--config PATH]
#   julia run.jl project-scaffold --help
#
# Return values: 0 when the package was generated, 2 for invalid arguments or an invalid
# configuration, 1 when the generation itself fails.

using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)

using Dates: Dates
using Pkg: Pkg
using PkgTemplates:
    Dependabot,
    Documenter,
    Formatter,
    Git,
    GitHubActions,
    License,
    ProjectFile,
    Readme,
    TagBot,
    Template,
    Tests
using TOML: TOML

const TOOLBOX_ROOT = normpath(joinpath(@__DIR__, ".."))
const TEMPLATE_DIR = joinpath(@__DIR__, "templates")

# `\z` and not `$`, which also matches before a final newline
const JULIA_VERSION = r"^\d+\.\d+\z"
const PACKAGE_NAME = r"^[A-Z][A-Za-z0-9]*\z"
const GITHUB_USER = r"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z"
const BRANCH_NAME = r"^[A-Za-z0-9][A-Za-z0-9._/-]*\z"
# Lowest compat floor of a generated package: the oldest Julia on which the entries
# written for its test environment resolve (JET 0.9 needs Julia 1.10).
const MINIMUM_FLOOR = v"1.10"
const PLACEHOLDER = r"<<([^<>]+)>>"
const PIN_PLACEHOLDER = r"<<PIN ([^<>]+)>>"
const LS_REMOTE_LINE = r"^([0-9a-f]{40})\trefs/tags/(.+?)(\^\{\})?$"
const RELEASE_TAG = r"^v(\d+)\.(\d+)\.(\d+)$"
const MANIFEST_NAME = r"^(?:Julia)?Manifest(?:-v\d+\.\d+)?\.toml$"
const BARE_KEY = r"^[A-Za-z0-9_-]+$"

# --- settings --------------------------------------------------------------------------

"""
    Settings(julia, license, style, branch, actions, host, compat_extra)

Validated configuration: the compat floor of the generated package (`MAJOR.MINOR`), the
licence name, the JuliaFormatter style, the default branch, the release series (major
version) of every action the workflow templates pin, the host the action repositories
are read from, and the earlier release series added to the `[compat]` entry of a
dependency (package name => series).
"""
struct Settings
    julia::String
    license::String
    style::String
    branch::String
    actions::Dict{String, Int}
    host::String
    compat_extra::Dict{String, Vector{String}}
end

const SECTIONS = ("package", "actions", "remote", "compat_extra")
const PACKAGE_KEYS = ("julia", "license", "style", "branch")
const REMOTE_KEYS = ("host",)
const STYLES = ("blue", "sciml", "yas", "nostyle")
const DEFAULT_PACKAGE = (julia = "1.10", license = "MIT", style = "blue", branch = "main")
const DEFAULT_ACTIONS = (
    "actions/checkout" => 7,
    "julia-actions/setup-julia" => 3,
    "julia-actions/cache" => 3,
    "julia-actions/julia-buildpkg" => 1,
    "julia-actions/julia-runtest" => 1,
    "julia-actions/julia-processcoverage" => 1,
    "julia-actions/julia-docdeploy" => 1,
    "codecov/codecov-action" => 6,
)
const DEFAULT_HOST = "https://github.com"
const DEFAULT_COMPAT_EXTRA = ("JET" => ("0.9",),)

"""
    section_table(raw::AbstractDict, section::AbstractString) -> AbstractDict

The table `[section]` of the configuration, empty when absent. Throws an `ArgumentError`
when the value is not a table.
"""
function section_table(raw::AbstractDict, section::AbstractString)
    table = get(raw, section, Dict{String, Any}())
    table isa AbstractDict || throw(ArgumentError("[$section] must be a table"))
    return table
end

"""
    check_keys(table::AbstractDict, section::AbstractString, known)

Throw an `ArgumentError` naming `[section].key` for the first key of `table` not in
`known`.
"""
function check_keys(table::AbstractDict, section::AbstractString, known)
    for key in keys(table)
        key in known || throw(
            ArgumentError("unknown key [$section].$key; allowed: $(join(known, ", "))"),
        )
    end
    return nothing
end

"""
    string_setting(table, section, key, default) -> String

Value of `key` in `table` (`default` when absent) as a non-empty string. Throws an
`ArgumentError` naming `[section].key` otherwise.
"""
function string_setting(
    table::AbstractDict,
    section::AbstractString,
    key::AbstractString,
    default::AbstractString,
)
    value = get(table, key, default)
    (value isa AbstractString && !isempty(value)) || throw(
        ArgumentError("[$section].$key must be a non-empty string, got $(repr(value))"),
    )
    return String(value)
end

"""
    series_list(value, section, key) -> Vector{String}

`value` as a vector of non-empty strings. Throws an `ArgumentError` naming
`[section].key` otherwise.
"""
function series_list(value, section::AbstractString, key::AbstractString)
    valid = value isa AbstractVector && all(x -> x isa AbstractString && !isempty(x), value)
    valid || throw(
        ArgumentError(
            "[$section].$key must be a list of non-empty strings, got $(repr(value))",
        ),
    )
    return String[String(x) for x in value]
end

"""
    template_actions() -> Vector{String}

The actions that occur as `<<PIN action>>` in the templates, sorted and without repeats.
"""
function template_actions()
    actions = String[]
    for file in sort!(readdir(TEMPLATE_DIR))
        endswith(file, ".tpl") || continue
        for m in eachmatch(PIN_PLACEHOLDER, read(joinpath(TEMPLATE_DIR, file), String))
            action = String(m.captures[1])
            action in actions || push!(actions, action)
        end
    end
    return sort!(actions)
end

"""
    validate_settings(raw::AbstractDict) -> Settings

Enforce the schema of the configuration tables `[package]`, `[actions]`, `[remote]` and
`[compat_extra]`; absent keys take the defaults of the shipped `config.toml`. An
`[actions]` table replaces the default table as a whole and must list every action the
templates pin; the keys of `[compat_extra]` are merged into the default table. Fails with
an `ArgumentError` naming the offending section or key.
"""
function validate_settings(raw::AbstractDict)
    for key in keys(raw)
        key in SECTIONS || throw(
            ArgumentError(
                "unknown section [$key]; allowed: " *
                join(("[$name]" for name in SECTIONS), ", "),
            ),
        )
    end
    package = section_table(raw, "package")
    check_keys(package, "package", PACKAGE_KEYS)
    julia = check_floor(
        string_setting(package, "package", "julia", DEFAULT_PACKAGE.julia),
        "[package].julia",
    )
    license = string_setting(package, "package", "license", DEFAULT_PACKAGE.license)
    style = string_setting(package, "package", "style", DEFAULT_PACKAGE.style)
    style in STYLES || throw(
        ArgumentError(
            "[package].style must be one of $(join(STYLES, ", ")), got $(repr(style))",
        ),
    )
    branch = string_setting(package, "package", "branch", DEFAULT_PACKAGE.branch)
    # it is written into YAML, into Julia string literals and onto a git command line
    (occursin(BRANCH_NAME, branch) && !occursin("..", branch)) || throw(
        ArgumentError(
            "[package].branch must be a plain branch name (letters, digits, '.', '_', " *
            "'/', '-'), got $(repr(branch))",
        ),
    )

    remote = section_table(raw, "remote")
    check_keys(remote, "remote", REMOTE_KEYS)
    host = string_setting(remote, "remote", "host", DEFAULT_HOST)

    actions = Dict{String, Int}(DEFAULT_ACTIONS)
    if haskey(raw, "actions")
        actions = Dict{String, Int}()
        for (action, major) in section_table(raw, "actions")
            (major isa Integer && !(major isa Bool) && major >= 0) || throw(
                ArgumentError(
                    "[actions].$action must be an integer >= 0, got $(repr(major))",
                ),
            )
            actions[String(action)] = Int(major)
        end
        for action in template_actions()
            haskey(actions, action) || throw(
                ArgumentError(
                    "[actions].$action is missing; the workflow templates pin it",
                ),
            )
        end
    end

    compat_extra = Dict{String, Vector{String}}(
        name => collect(String, series) for (name, series) in DEFAULT_COMPAT_EXTRA
    )
    for (name, series) in section_table(raw, "compat_extra")
        compat_extra[String(name)] = series_list(series, "compat_extra", name)
    end
    return Settings(julia, license, style, branch, actions, host, compat_extra)
end

"""
    load_settings(path::AbstractString) -> Settings

Parse and validate a configuration file. Throws an `ArgumentError` when the file is
missing or is not valid TOML.
"""
function load_settings(path::AbstractString)
    isfile(path) || throw(ArgumentError("configuration file not found: $path"))
    text = try
        read(path, String)
    catch err
        err isa Union{SystemError, Base.IOError} || rethrow()
        throw(ArgumentError("configuration file not readable: $path"))
    end
    raw = TOML.tryparse(text)
    raw isa TOML.ParserError &&
        throw(ArgumentError("$path: not valid TOML: $(sprint(showerror, raw))"))
    return validate_settings(raw)
end

# --- request ---------------------------------------------------------------------------

"""
    Request(name, directory, user, authors, julia, pipeline, commit, hook)

What to generate: the package name without `.jl`, the absolute path of the existing
parent directory, the GitHub user or organisation, the author names, the compat floor
(`MAJOR.MINOR`), whether to add the DrWatson pipeline layer (`scripts/`, `configs/`,
DrWatson and TOML as dependencies), whether to make a git repository with a first
commit, and whether to install the commit-guard hook in it.
"""
struct Request
    name::String
    directory::String
    user::String
    authors::Vector{String}
    julia::String
    pipeline::Bool
    commit::Bool
    hook::Bool
end

"""
    package_name(text::AbstractString) -> String

`text` without one trailing `.jl`. Throws an `ArgumentError` unless the rest starts with
an upper-case letter followed by letters and digits only.

```julia
package_name("Spectra.jl") == "Spectra"
```
"""
function package_name(text::AbstractString)
    name = String(chopsuffix(text, ".jl"))
    occursin(PACKAGE_NAME, name) || throw(
        ArgumentError(
            "package name must be an upper-case letter followed by letters and digits, " *
            "got '$text'",
        ),
    )
    return name
end

"""
    check_floor(text::AbstractString, source::AbstractString) -> String

The compat floor `text` of a generated package when it has the form `MAJOR.MINOR` and
lies between `MINIMUM_FLOOR` and the Julia release that runs the tool. Throws an
`ArgumentError` naming `source` otherwise: below the minimum the test environment does
not resolve, and above the running release the tool cannot resolve for it.
"""
function check_floor(text::AbstractString, source::AbstractString)
    occursin(JULIA_VERSION, text) ||
        throw(ArgumentError("$source must have the form MAJOR.MINOR, got $(repr(text))"))
    floor = VersionNumber(text)
    floor >= MINIMUM_FLOOR || throw(
        ArgumentError(
            "$source must be at least $(MINIMUM_FLOOR.major).$(MINIMUM_FLOOR.minor), got " *
            "$text: the [compat] entries of the generated test environment do not " *
            "resolve on an older Julia",
        ),
    )
    running = VersionNumber(VERSION.major, VERSION.minor)
    floor <= running || throw(
        ArgumentError(
            "$source is $text, above the Julia $(VERSION.major).$(VERSION.minor) that " *
            "runs the tool: the dependencies are resolved on this release",
        ),
    )
    return String(text)
end

"""
    parse_authors(text::AbstractString) -> Vector{String}

The comma-separated author names of `text`, stripped. Throws `ArgumentError` when there
is none, when one is empty, when one holds `@`, `<` or `>` (the licence holder line
carries names only), or a character that cannot stand in the files the names are written
into: a double quote, a backslash, a dollar sign or a control character.
"""
function parse_authors(text::AbstractString)
    isempty(strip(text)) && throw(ArgumentError("no author given"))
    authors = String[String(strip(name)) for name in split(text, ',')]
    for author in authors
        isempty(author) && throw(ArgumentError("empty author name in '$text'"))
        any(c -> c in ('@', '<', '>'), author) && throw(
            ArgumentError("author '$author' holds an e-mail address; give names only"),
        )
        # the names enter Julia string literals, YAML and BibTeX as they are
        any(c -> c in ('"', '\\', '$') || iscntrl(c), author) && throw(
            ArgumentError(
                "author $(repr(author)) holds a quotation mark, a backslash, a dollar " *
                "sign or a control character",
            ),
        )
    end
    return authors
end

"""
    check_destination(request::Request) -> String

The package directory `joinpath(request.directory, request.name)`. Throws an
`ArgumentError` when `request.directory` is not an existing directory or the package
directory exists already.
"""
function check_destination(request::Request)
    isdir(request.directory) ||
        throw(ArgumentError("not an existing directory: $(request.directory)"))
    package = joinpath(request.directory, request.name)
    (ispath(package) || islink(package)) && throw(ArgumentError("$package exists already"))
    return package
end

# --- child processes -------------------------------------------------------------------

"""
    exit_status(command::Cmd; output = devnull) -> Int

Exit status of `command`, run with standard input and error detached and standard output
sent to `output`; a process killed by a signal reports 128 plus the signal number, as a
shell does.
"""
function exit_status(command::Cmd; output = devnull, errors = devnull)
    detached =
        pipeline(ignorestatus(command); stdin = devnull, stdout = output, stderr = errors)
    process = run(detached)
    process.termsignal > 0 && return 128 + process.termsignal
    return process.exitcode
end

# --- action pins -----------------------------------------------------------------------

"""
    select_pin(listing::AbstractString, major::Integer)
        -> Union{Tuple{String, String}, Nothing}

The highest release tag `vMAJOR.MINOR.PATCH` of the series `major` in the output of
`git ls-remote --tags`, as `(sha, tag)`. The SHA is that of the peeled line
`refs/tags/<tag>^{}` of an annotated tag, the commit, else that of the plain line.
`nothing` when no tag qualifies; lines of another form are ignored.
"""
function select_pin(listing::AbstractString, major::Integer)
    plain = Dict{String, String}()
    peeled = Dict{String, String}()
    best = nothing
    for line in split(listing, '\n')
        m = match(LS_REMOTE_LINE, rstrip(line))
        m === nothing && continue
        sha, tag, suffix = String(m.captures[1]), String(m.captures[2]), m.captures[3]
        release = match(RELEASE_TAG, tag)
        release === nothing && continue
        parts = tryparse.(UInt32, release.captures)
        any(isnothing, parts) && continue
        version = VersionNumber(parts...)
        version.major == major || continue
        (suffix === nothing ? plain : peeled)[tag] = sha
        (best === nothing || version > first(best)) && (best = (version, tag))
    end
    best === nothing && return nothing
    tag = last(best)
    return (get(peeled, tag, get(plain, tag, "")), tag)
end

"""
    resolve_pins(settings::Settings) -> Dict{String, String}

For every action of `settings.actions`, the release of its major series to pin, read with
`git ls-remote --tags <host>/<action>`, as `"<action>@<sha> # <tag>"`. Throws an
`ArgumentError` naming the action and the major when git fails or no tag qualifies.
"""
function resolve_pins(settings::Settings)
    Sys.which("git") === nothing &&
        throw(ArgumentError("git is not on PATH; the action pins are read with git"))
    pins = Dict{String, String}()
    for action in sort!(collect(keys(settings.actions)))
        major = settings.actions[action]
        url = "$(settings.host)/$action"
        # a repository that does not exist must fail, not ask for credentials
        # `--` ends the options: a host that opens with a dash stays a repository
        command = addenv(`git ls-remote --tags -- $url`, "GIT_TERMINAL_PROMPT" => "0")
        out = IOBuffer()
        status = exit_status(command; output = out)
        status == 0 || throw(
            ArgumentError(
                "git ls-remote --tags $url failed with status $status " *
                "($action, major $major)",
            ),
        )
        pin = select_pin(String(take!(out)), major)
        pin === nothing && throw(
            ArgumentError("$action has no release tag v$major.y.z (major $major) at $url"),
        )
        sha, tag = pin
        pins[action] = "$action@$sha # $tag"
    end
    return pins
end

# --- rendering -------------------------------------------------------------------------

"""
    formatter_version() -> String

The exact JuliaFormatter version of the workbench: the `[compat].JuliaFormatter` entry of
`formatter/Project.toml`, without its leading `=`. Throws an `ArgumentError` when the
file or the entry is missing.
"""
function formatter_version()
    path = joinpath(TOOLBOX_ROOT, "formatter", "Project.toml")
    isfile(path) || throw(ArgumentError("formatter project not found: $path"))
    project = TOML.tryparse(read(path, String))
    project isa TOML.ParserError && throw(ArgumentError("$path: not valid TOML"))
    compat = get(project, "compat", nothing)
    entry = compat isa AbstractDict ? get(compat, "JuliaFormatter", nothing) : nothing
    entry isa AbstractString ||
        throw(ArgumentError("$path has no [compat].JuliaFormatter entry"))
    version = strip(chopprefix(strip(entry), "="))
    isempty(version) && throw(ArgumentError("$path: [compat].JuliaFormatter is empty"))
    return String(version)
end

"""
    compat_entry(version::VersionNumber, extra::Vector{String} = String[]) -> String

The `[compat]` entry of the release series of `version`: `"<major>"` when the major is
positive, `"0.<minor>"` when the minor is, else `"0.0.<patch>"`. The series of `extra`
precede it, joined by `", "`, and no series is repeated.

```julia
compat_entry(v"0.13.5", ["0.9"]) == "0.9, 0.13"
```
"""
function compat_entry(version::VersionNumber, extra::Vector{String} = String[])
    derived =
        version.major > 0 ? "$(version.major)" :
        version.minor > 0 ? "0.$(version.minor)" : "0.0.$(version.patch)"
    series = String[]
    for entry in [extra; derived]
        entry in series || push!(series, entry)
    end
    return join(series, ", ")
end

"""
    render(template::AbstractString, values::AbstractDict) -> String

`template` with every placeholder `<<KEY>>` replaced by `values["KEY"]`. The values are
inserted verbatim and not scanned again. Throws an `ArgumentError` naming a placeholder
without a value.
"""
function render(template::AbstractString, values::AbstractDict)
    for m in eachmatch(PLACEHOLDER, template)
        key = String(m.captures[1])
        haskey(values, key) || throw(ArgumentError("no value for the placeholder <<$key>>"))
    end
    return replace(
        template,
        PLACEHOLDER =>
            placeholder -> string(values[String(chop(placeholder; head = 2, tail = 2))]),
    )
end

"""
    yaml_quote(text::AbstractString) -> String

`text` as a double-quoted YAML scalar.
"""
yaml_quote(text::AbstractString) =
    "\"" * replace(text, "\\" => "\\\\", "\"" => "\\\"") * "\""

"""
    cff_authors(authors::Vector{String}) -> String

The `authors` list of `CITATION.cff`, one item per author, indented by two spaces: the
last word of a name of several words is the family name and the words before it the
given names; a single word is a `name`.

```julia
cff_authors(["Ada Lovelace"]) == "  - family-names: \\"Lovelace\\"\\n    given-names: \\"Ada\\""
```
"""
function cff_authors(authors::Vector{String})
    items = String[]
    for author in authors
        words = split(author)
        if length(words) > 1
            given = join(words[1:(end - 1)], " ")
            push!(
                items,
                "  - family-names: $(yaml_quote(last(words)))\n" *
                "    given-names: $(yaml_quote(given))",
            )
        else
            push!(items, "  - name: $(yaml_quote(strip(author)))")
        end
    end
    return join(items, "\n")
end

"""
    template_values(request::Request, settings::Settings, pins::AbstractDict;
                    stable::VersionNumber = VERSION) -> Dict{String, String}

The value of every placeholder of the templates: package, user, compat floor, branch,
licence, year, formatter version, the stable release series (`MAJOR.MINOR` of `stable`)
from which the tests run JET, the authors in BibTeX, plain and CFF form, the pin of every
action (`"PIN <action>"`), the Dependabot directories of the Julia environments, and the
README and `.gitignore` lines of the pipeline layer, empty without it.
"""
function template_values(
    request::Request,
    settings::Settings,
    pins::AbstractDict;
    stable::VersionNumber = VERSION,
)
    with_pipeline = request.pipeline
    directories =
        ("      - \"/\"", "      - \"/test\"", "      - \"/docs\"", "      - \"/bench\"")
    values = Dict{String, String}(
        "PKG" => request.name,
        "USER" => request.user,
        "JULIA" => request.julia,
        "BRANCH" => settings.branch,
        "LICENSE" => settings.license,
        "YEAR" => string(Dates.year(Dates.today())),
        "FORMATTER" => formatter_version(),
        "STABLE" => "$(stable.major).$(stable.minor)",
        "AUTHORS_BIBTEX" => join(request.authors, " and "),
        "AUTHORS_TEXT" => join(request.authors, ", "),
        "AUTHORS_CFF" => cff_authors(request.authors),
        "JULIA_DIRECTORIES" => join(directories, "\n"),
        "TREE_SCRIPTS" =>
            with_pipeline ?
            "├── scripts/            # pipeline entry points; each activates the project " *
            "itself\n├── configs/            # run configurations\n" : "",
        "ENTRY_SCRIPTS" =>
            with_pipeline ?
            "julia scripts/run.jl                        # the pipeline on its smallest " *
            "configuration\n" : "",
        "FULL_TREE_CONFIGS" =>
            with_pipeline ?
            "├── configs/\n│   └── minimal.toml        # smallest configuration, for " *
            "verification\n" : "",
        "FULL_TREE_SCRIPTS" =>
            with_pipeline ?
            "├── scripts/\n│   └── run.jl              # pipeline entry point\n" : "",
        # anchored at the root: fixtures under test/data are not run outputs
        "IGNORE_RUNS" => with_pipeline ? "\n# run outputs\n/data/\n/plots/\n" : "",
    )
    for (action, pin) in pins
        values["PIN $action"] = string(pin)
    end
    return values
end

"""
    template_targets(request::Request) -> Vector{Pair{String, Vector{String}}}

Every template with the paths, relative to the package directory and `/`-separated, it is
rendered to; the pipeline templates only with `request.pipeline`.
"""
function template_targets(request::Request)
    targets = Pair{String, Vector{String}}[
        "CI.yml.tpl" => [".github/workflows/CI.yml"],
        "Format.yml.tpl" => [".github/workflows/Format.yml"],
        "dependabot.yml.tpl" => [".github/dependabot.yml"],
        "gitignore.tpl" => [".gitignore"],
        "README.md.tpl" => ["README.md"],
        "CITATION.cff.tpl" => ["CITATION.cff"],
        "activate.jl.tpl" => ["activate.jl"],
        "activate_sub.jl.tpl" => [
            "test/activate.jl",
            "docs/activate.jl",
            "bench/activate.jl",
        ],
        "runtests.jl.tpl" => ["test/runtests.jl"],
        "make.jl.tpl" => ["docs/make.jl"],
        "benchmarks.jl.tpl" => ["bench/benchmarks.jl"],
    ]
    if request.pipeline
        push!(
            targets,
            "run.jl.tpl" => ["scripts/run.jl"],
            "minimal.toml.tpl" => ["configs/minimal.toml"],
            "module.jl.tpl" => ["src/$(request.name).jl"],
        )
    end
    return targets
end

# --- project files ---------------------------------------------------------------------

"""
    resolve_packages(names::Vector{String}) -> Dict{String, Tuple{String, VersionNumber}}

The UUID and the resolved version of every registered package or standard library of
`names`, found by adding them to a temporary environment without precompiling them. The
project active before the call is active again afterwards, also when an error is thrown.
"""
function resolve_packages(names::Vector{String})
    previous = Base.active_project()
    try
        # only the resolution is needed: precompiling the packages would cost minutes
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            Pkg.activate(mktempdir(); io = devnull)
            Pkg.add(names; io = devnull)
        end
        found = Dict{String, Tuple{String, VersionNumber}}()
        for (uuid, info) in Pkg.dependencies()
            (info.is_direct_dep && info.name in names) || continue
            info.version isa VersionNumber ||
                error("no version was resolved for $(info.name)")
            found[info.name] = (string(uuid), info.version)
        end
        for name in names
            haskey(found, name) || error("$name was not resolved")
        end
        return found
    finally
        if previous === nothing
            Pkg.activate(; io = devnull)
        else
            Pkg.activate(dirname(previous); io = devnull)
        end
    end
end

"""
    toml_string(text::AbstractString) -> String

`text` as a TOML basic string, with quotes, backslashes and control characters escaped.
"""
function toml_string(text::AbstractString)
    io = IOBuffer()
    print(io, '"')
    for c in text
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\t'
            print(io, "\\t")
        elseif c == '\r'
            print(io, "\\r")
        elseif iscntrl(c)
            print(io, "\\u", string(UInt32(c); base = 16, pad = 4))
        else
            print(io, c)
        end
    end
    print(io, '"')
    return String(take!(io))
end

"""
    toml_key(key::AbstractString) -> String

`key` bare when TOML allows it, else as a basic string.
"""
toml_key(key::AbstractString) = occursin(BARE_KEY, key) ? String(key) : toml_string(key)

"""
    toml_value(value) -> String

The TOML form of a project-file value: a basic string, a Boolean, an integer, an array,
or an inline table with its keys sorted. Throws an `ArgumentError` for other values.
"""
toml_value(value::AbstractString) = toml_string(value)
toml_value(value::Bool) = value ? "true" : "false"
toml_value(value::Integer) = string(value)
toml_value(value::AbstractVector) = "[" * join((toml_value(x) for x in value), ", ") * "]"
function toml_value(value::AbstractDict)
    entries = sort!([string(k) => v for (k, v) in value]; by = first)
    return "{" *
           join(("$(toml_key(k)) = $(toml_value(v))" for (k, v) in entries), ", ") *
           "}"
end
toml_value(value) = throw(ArgumentError("no TOML form for $(repr(value))"))

const PROJECT_SCALARS = ("name", "uuid", "authors", "version")
const PROJECT_TABLES = ("deps", "weakdeps", "sources", "extensions", "compat")

"""
    project_text(project::AbstractDict) -> String

A `Project.toml` text in the order Pkg writes it: the keys `name`, `uuid`, `authors` and
`version` that are present, then the non-empty tables `deps`, `weakdeps`, `sources`,
`extensions` and `compat`, each with its keys sorted, separated by one blank line. A
`sources` entry that is a table is written inline. The text ends with one newline and
parses back to an equal dictionary. Throws an `ArgumentError` for another top-level key.

```julia
project_text(Dict("name" => "A", "compat" => Dict("julia" => "1.10")))
# "name = \\"A\\"\\n\\n[compat]\\njulia = \\"1.10\\"\\n"
```
"""
function project_text(project::AbstractDict)
    for key in keys(project)
        (key in PROJECT_SCALARS || key in PROJECT_TABLES) ||
            throw(ArgumentError("project_text: unsupported top-level key '$key'"))
    end
    blocks = String[]
    scalars = [
        "$key = $(toml_value(project[key]))" for
        key in PROJECT_SCALARS if haskey(project, key)
    ]
    isempty(scalars) || push!(blocks, join(scalars, "\n"))
    for table in PROJECT_TABLES
        entries = get(project, table, nothing)
        entries === nothing && continue
        entries isa AbstractDict ||
            throw(ArgumentError("project_text: [$table] must be a table"))
        isempty(entries) && continue
        lines = ["[$table]"]
        for (key, value) in sort!([string(k) => v for (k, v) in entries]; by = first)
            push!(lines, "$(toml_key(key)) = $(toml_value(value))")
        end
        push!(blocks, join(lines, "\n"))
    end
    return join(blocks, "\n\n") * "\n"
end

"""
    dependency_compat(name, versions, settings) -> String

The `[compat]` entry of the dependency `name` from its resolved version and the earlier
series of `settings.compat_extra`.
"""
dependency_compat(name::AbstractString, versions::AbstractDict, settings::Settings) =
    compat_entry(versions[name][2], get(settings.compat_extra, name, String[]))

"""
    environment_project(package, uuid, names, versions, settings, julia_floor)
        -> Dict{String, Any}

The project of an auxiliary environment: the dependencies `names` and the package itself,
taken by path from the parent directory, with `[compat]` entries for `names` and `julia`.
"""
function environment_project(
    package::AbstractString,
    uuid::AbstractString,
    names,
    versions::AbstractDict,
    settings::Settings,
    julia_floor::AbstractString,
)
    deps = Dict{String, Any}(name => versions[name][1] for name in names)
    deps[package] = uuid
    compat = Dict{String, Any}(
        name => dependency_compat(name, versions, settings) for name in names
    )
    compat["julia"] = julia_floor
    sources = Dict{String, Any}(package => Dict{String, Any}("path" => ".."))
    return Dict{String, Any}("deps" => deps, "sources" => sources, "compat" => compat)
end

"""
    write_file(path::AbstractString, text::AbstractString)

Write `text` to `path`, creating its directory when needed.
"""
function write_file(path::AbstractString, text::AbstractString)
    mkpath(dirname(path))
    write(path, text)
    return nothing
end

"""
    package_path(package::AbstractString, relative::AbstractString) -> String

The path of the `/`-separated `relative` below the package directory `package`.
"""
package_path(package::AbstractString, relative::AbstractString) =
    joinpath(package, split(relative, '/')...)

# --- generation ------------------------------------------------------------------------

"""
    scaffold(request::Request, settings::Settings;
             pins::AbstractDict = resolve_pins(settings), io::IO = stdout) -> String

Generate the package of `request` and return its directory
`joinpath(request.directory, request.name)`. The compat floor and the destination are
checked, every template rendered and the versions of the dependencies resolved before
anything is written, and the pins are resolved before that. PkgTemplates makes the
skeleton; the project files of the root, `test/`, `docs/` and `bench/` are then written
with `[compat]` entries from the resolved versions, the templates rendered over the
skeleton, the manifests removed and the tree formatted with the pinned formatter of the
workbench ([`complete_package`](@ref)). When one of these steps fails, the directory is
removed again, so that a second attempt is not refused. With `request.commit` a git
repository with a first commit is made, and with `request.hook` the commit-guard hook
installed in it ([`finish_package`](@ref)). A commit that is not made for want of a
configured identity and a hook that is not installed are reported as notes on `io`; the
next steps are printed there at the end.

Throws an `ArgumentError` for a compat floor out of bounds, a missing parent directory
or an existing package directory, and an `ErrorException` when formatting, `git init` or
`git add` fails.
"""
function scaffold(
    request::Request,
    settings::Settings;
    pins::AbstractDict = resolve_pins(settings),
    io::IO = stdout,
)
    # 1. request, destination and rendered templates, before anything is written
    check_floor(request.julia, "the compat floor")
    package = check_destination(request)
    values = template_values(request, settings, pins)
    rendered = Pair{String, String}[]
    for (file, destinations) in template_targets(request)
        text = render(read(joinpath(TEMPLATE_DIR, file), String), values)
        for destination in destinations
            push!(rendered, destination => text)
        end
    end

    # 2. versions of the dependencies, still before anything is written
    names = ["Aqua", "JET", "Test", "Documenter", "BenchmarkTools"]
    request.pipeline && append!(names, ["DrWatson", "TOML"])
    versions = resolve_packages(names)

    # 3. skeleton
    skeleton = Template(;
        user = request.user,
        authors = request.authors,
        dir = request.directory,
        julia = VersionNumber(request.julia),
        plugins = [
            ProjectFile(; version = v"0.1.0"),
            Tests(; project = true),
            License(; name = settings.license),
            Formatter(; style = settings.style),
            Documenter{GitHubActions}(; devbranch = settings.branch),
            !Git,
            !Readme,
            !TagBot,
            !Dependabot,
        ],
    )
    skeleton(request.name)
    # from here on a failure removes the directory again: left in place, a partial
    # package would be refused as existing by the next attempt
    complete = false
    try
        complete_package(package, request, settings, versions, rendered)
        complete = true
    finally
        complete || rm(package; recursive = true, force = true)
    end
    finish_package(package, request, settings, io)
    return package
end

"""
    complete_package(package, request, settings, versions, rendered) -> Nothing

Steps 4 to 7 of [`scaffold`](@ref) on the skeleton in `package`: the project files, the
rendered templates, the removal of manifests and the formatting. Throws an
`ErrorException` when PkgTemplates left no project file or the formatter fails; the
message of the latter ends with what the formatter printed.
"""
function complete_package(
    package::AbstractString,
    request::Request,
    settings::Settings,
    versions::AbstractDict,
    rendered::Vector{Pair{String, String}},
)
    root_file = joinpath(package, "Project.toml")
    isfile(root_file) || error("PkgTemplates wrote no Project.toml in $package")

    # 4. project files
    julia_floor = request.julia
    written = TOML.parsefile(root_file)
    uuid = get(written, "uuid", nothing)
    uuid isa AbstractString || error("the Project.toml of PkgTemplates has no uuid")
    root = Dict{String, Any}(
        key => written[key] for key in PROJECT_SCALARS if haskey(written, key)
    )
    root_deps = Dict{String, Any}()
    root_compat = Dict{String, Any}("julia" => julia_floor)
    if request.pipeline
        for name in ("DrWatson", "TOML")
            root_deps[name] = versions[name][1]
            root_compat[name] = dependency_compat(name, versions, settings)
        end
    end
    root["deps"] = root_deps
    root["compat"] = root_compat
    write_file(root_file, project_text(root))
    environments = (
        "test" => ("Aqua", "JET", "Test"),
        "docs" => ("Documenter",),
        "bench" => ("BenchmarkTools",),
    )
    for (directory, dependencies) in environments
        project = environment_project(
            request.name,
            uuid,
            dependencies,
            versions,
            settings,
            julia_floor,
        )
        write_file(joinpath(package, directory, "Project.toml"), project_text(project))
    end

    # 5. rendered templates, over what PkgTemplates wrote
    for (destination, text) in rendered
        write_file(package_path(package, destination), text)
    end
    # the formatter also takes a file without extension that starts with a Julia
    # shebang, and it descends into .git: it would rewrite the commit-guard hook
    style_file = joinpath(package, ".JuliaFormatter.toml")
    isfile(style_file) || error("PkgTemplates wrote no .JuliaFormatter.toml in $package")
    open(style_file, "a") do file
        println(file, "# the hooks under .git are scripts, not sources of the package")
        println(file, "ignore = [\".git\"]")
    end

    # 6. no manifest
    for (directory, _, files) in walkdir(package)
        for file in files
            occursin(MANIFEST_NAME, file) && rm(joinpath(directory, file))
        end
    end

    # 7. formatting with the pinned formatter, against the package's own style file
    formatter = joinpath(TOOLBOX_ROOT, "formatter", "format.jl")
    printed = IOBuffer()
    command = `$(Base.julia_cmd()) --startup-file=no $formatter $package`
    status = exit_status(command; output = printed, errors = printed)
    status == 0 || error(
        "formatting the generated package failed with status $status:\n" *
        String(take!(printed)),
    )
    return nothing
end

"""
    finish_package(package, request, settings, io) -> Nothing

Steps 8 to 10 of [`scaffold`](@ref) on the complete package: the repository with its
first commit, the commit-guard hook and the next steps printed to `io`. The commit is
made only under an identity that git is configured with (`user.useConfigOnly`), never
under one it would guess from the host. Throws an `ErrorException` when git is missing
or `git init` or `git add` fails; the package stays in place then.
"""
function finish_package(
    package::AbstractString,
    request::Request,
    settings::Settings,
    io::IO,
)
    # 8. repository and first commit
    if request.commit
        Sys.which("git") === nothing && error("git is not on PATH; no repository was made")
        branch = settings.branch
        status = exit_status(Cmd(`git init --initial-branch=$branch`; dir = package))
        status == 0 || error("git init failed with status $status in $package")
        status = exit_status(Cmd(`git add -A`; dir = package))
        status == 0 || error("git add failed with status $status in $package")
        message = "chore: scaffold of $(request.name).jl"
        commit = `git -c user.useConfigOnly=true commit -m $message`
        status = exit_status(Cmd(commit; dir = package))
        status == 0 || println(
            io,
            "note: the first commit was not made; set user.name and user.email, " *
            "then commit",
        )
    end

    # 9. commit-guard hook
    if request.hook && request.commit
        guard = joinpath(TOOLBOX_ROOT, "standalone", "commit-guard.jl")
        julia = Base.julia_cmd()
        status = exit_status(`$julia --startup-file=no $guard install $package`)
        status == 0 || println(
            io,
            "note: the commit-guard hook was not installed (status $status); " *
            "see commit-guard install",
        )
    end

    # 10. next steps
    println(io, "Created $package")
    println(io, "Next steps:")
    println(io, "  julia run.jl workspace-audit $(request.directory) --scaffold")
    println(io, "      lays out the workspace around the package")
    println(
        io,
        "  gh api -X PUT repos/$(request.user)/$(request.name).jl/actions/permissions " *
        "-F enabled=false",
    )
    println(
        io,
        "      switches Actions off once a private remote exists; the workflow jobs are " *
        "skipped in a private repository in any case",
    )
    println(io, "  julia run.jl launch-check $package")
    println(
        io,
        "      the launch check; it fails on changelog, badges and dependabot until " *
        "the launch work is done",
    )
    return nothing
end

# --- command line ----------------------------------------------------------------------

"""
    usage(io::IO = stdout)

Print the command-line help.
"""
function usage(io::IO = stdout)
    print(
        io,
        """
        project-scaffold — a new Julia package, completed to the workbench conventions

        Usage:
          julia run.jl project-scaffold NAME --dir DIR --user USER --authors LIST
                                        [--julia X.Y] [--no-pipeline] [--no-commit]
                                        [--no-hook] [--config PATH]
          julia run.jl project-scaffold --help

          NAME              package name, with or without .jl
          --dir DIR         existing directory the package directory is created in
          --user USER       GitHub user or organisation
          --authors LIST    comma-separated author names, without e-mail addresses,
                            e.g. "Name One, Name Two"
          --julia X.Y       compat floor (default: [package].julia of the configuration)
          --no-pipeline     no DrWatson layer (scripts/, configs/, DrWatson and TOML)
          --no-commit       no git repository and no first commit
          --no-hook         no commit-guard hook
          --config PATH     configuration file (default: config.toml next to the tool)

        Exit status: 0 on success, 2 for invalid arguments or configuration, 1 when the
        generation fails.
        """,
    )
    return nothing
end

"""
    main(args::Vector{String} = ARGS; io::IO = stdout) -> Union{String, Nothing}

Parse the command line, validate `NAME`, `--dir`, `--user` and `--authors`, load the
configuration and check the destination before anything is fetched or written, then
generate the package with [`scaffold`](@ref). Returns the package directory, or
`nothing` after `--help`. Throws an `ArgumentError` for an invalid command line.
"""
function main(args::Vector{String} = ARGS; io::IO = stdout)
    config_path = joinpath(@__DIR__, "config.toml")
    name = nothing
    dir = nothing
    user = nothing
    authors = nothing
    julia = nothing
    with_pipeline = true
    commit = true
    hook = true
    i = 1
    function value_of(flag)
        i < length(args) || throw(ArgumentError("$flag requires a value"))
        i += 1
        return args[i]
    end
    while i <= length(args)
        argument = args[i]
        if argument in ("-h", "--help")
            usage(io)
            return nothing
        elseif argument == "--dir"
            dir = value_of(argument)
        elseif argument == "--user"
            user = value_of(argument)
        elseif argument == "--authors"
            authors = value_of(argument)
        elseif argument == "--julia"
            julia = value_of(argument)
        elseif argument == "--config"
            config_path = value_of(argument)
        elseif argument == "--no-pipeline"
            with_pipeline = false
        elseif argument == "--no-commit"
            commit = false
        elseif argument == "--no-hook"
            hook = false
        elseif startswith(argument, "-")
            throw(ArgumentError("unknown command-line argument '$argument'; see --help"))
        else
            name === nothing ||
                throw(ArgumentError("more than one NAME given: '$name' and '$argument'"))
            name = argument
        end
        i += 1
    end

    name === nothing && throw(ArgumentError("NAME is required; see --help"))
    dir === nothing && throw(ArgumentError("--dir is required; see --help"))
    user === nothing && throw(ArgumentError("--user is required; see --help"))
    authors === nothing && throw(ArgumentError("--authors is required; see --help"))
    package = package_name(name)
    isempty(dir) && throw(ArgumentError("--dir requires a non-empty value"))
    directory = abspath(dir)
    occursin(GITHUB_USER, user) || throw(
        ArgumentError("--user must be a GitHub user or organisation name, got '$user'"),
    )
    author_list = parse_authors(authors)

    settings = load_settings(config_path)
    julia_floor = julia === nothing ? settings.julia : check_floor(julia, "--julia")
    request = Request(
        package,
        directory,
        user,
        author_list,
        julia_floor,
        with_pipeline,
        commit,
        hook,
    )
    check_destination(request)
    return scaffold(request, settings; io)
end

if abspath(PROGRAM_FILE) == @__FILE__
    try
        main(ARGS)
    catch err
        if err isa ArgumentError
            println(stderr, "project-scaffold: ", err.msg)
            exit(2)
        end
        showerror(stderr, err, catch_backtrace())
        println(stderr)
        exit(1)
    end
    exit(0)
end
