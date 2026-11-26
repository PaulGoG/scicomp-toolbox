#!/usr/bin/env julia
# launch-check — checks a Julia repository against the conventions of a public launch:
# licence holder, citation metadata, untracked manifests, bounded [compat] entries,
# Dependabot, workflows pinned by commit SHA with declared permissions and cancelling
# concurrency, a CI matrix over named Julia channels, formatter, changelog, README file
# tree and badge row, documentation, coverage, self-containment and commit history. It
# also generates the README badge row. The repository is only read.
#
#   julia run.jl launch-check [PATH] [--only ID,...] [--waive ID,...] [--verbose] [OPTIONS]
#   julia run.jl launch-check badges [PATH] [OPTIONS]
#   julia run.jl launch-check --list
#   OPTIONS: --repository USER/REPO  --branch NAME  --project-file FILE  --platform TEXT
#            --platform-logo SLUG  --config PATH
#
# Return values: 0 when no check fails, 1 when one does, 2 for invalid arguments or an
# invalid configuration, 3 when the tool itself fails.

using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)

using Printf: @sprintf
using TOML: TOML
using YAML: YAML

const TOOLBOX_ROOT = normpath(joinpath(@__DIR__, ".."))
const OPTIONS_FILE = ".launch-check.toml"
const LICENSE_FILES = ("LICENSE", "LICENSE.md", "LICENSE.txt")
const DEPENDABOT_FILES = (".github/dependabot.yml", ".github/dependabot.yaml")
const PROJECT_NAMES = ("Project.toml", "JuliaProject.toml")

const WORKFLOW_PATH = r"^\.github/workflows/[^/]+\.ya?ml$"
const MANIFEST_NAME = r"^(?:Julia)?Manifest(?:-v\d+\.\d+)?\.toml$"
const HOLDER_LINE = r"^\s*copyright\b"i
const EMAIL = r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+"
const CITE_HEADING = r"^#{1,6}\s+.*\bcit(?:e|es|ed|ations?|ing)\b"i
const HEADING = r"^(#{1,6})\s"
const BIBTEX_ENTRY = r"^\s*@\w+\s*\{"
# a fence: its run of backticks or tildes, then the info string
const FENCE = r"^ {0,3}(`{3,}|~{3,})(.*)$"
const COMMENT_OPEN = r"^\s*<!--"
const SETEXT_UNDERLINE = r"^=+\s*$"
# placeholders of the Apache, GPL and MIT licence templates
const TEMPLATE_HOLDER =
    r"\[(?:yyyy|year|fullname|name[^\]]*)\]|<(?:year|name[^>]*|copyright holders?)>"i
const COMMIT_SHA = r"^[0-9a-f]{40}$"
const IMAGE_DIGEST = r"@sha256:[0-9a-f]{64}$"
const RELEASE_COMMENT = r"^v?\d"
const SLUG = r"^[\w.-]+/[\w.-]+$"
const REMOTE_URL = r"github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$"
const RELEASE_TAG = r"^v\d+\.\d+\.\d+$"
const ARXIV_ID = r"^arXiv:(\d{4}\.\d{4,5})(?:v\d+)?$"i
const JOSS_DOI = r"^10\.21105/joss\."i
const ACTION_NAMES = ("action.yml", "action.yaml")
const SETUP_JULIA = "julia-actions/setup-julia@"
# no release reaches this version: a compat entry that admits it has no upper bound
const UNBOUNDED_PROBE = v"1000000000"
const BADGE = r"\[!\[([^\]]*)\]\(([^)\s]+)\)\]\(([^)\s]+)\)"
const BADGE_LINE = Regex("^$(BADGE.pattern)(?:\\s+$(BADGE.pattern))*\$")
# ASCII punctuation, escaped when a literal string enters a regex
const REGEX_SPECIAL = r"[!-/:-@\[-`{-~]"

# --- settings --------------------------------------------------------------------------

"""
    Settings(required_versions, optional_versions, version_keys, housekeeping, ecosystems,
             tree_max_lines, tree_within_lines)

Validated configuration: the Julia version names one CI matrix must hold together and
those it may hold besides, the matrix keys that carry Julia versions, the lower-case
workflow stems that get no badge, the Dependabot ecosystems that need an update entry,
the largest number of lines of the README file tree and the README line after which the
tree may not open.
"""
struct Settings
    required_versions::Vector{String}
    optional_versions::Vector{String}
    version_keys::Vector{String}
    housekeeping::Vector{String}
    ecosystems::Vector{String}
    tree_max_lines::Int
    tree_within_lines::Int
end

const SETTING_KEYS = Dict(
    "workflows" =>
        ("required_versions", "optional_versions", "version_keys", "housekeeping"),
    "dependabot" => ("ecosystems",),
    "readme" => ("tree_max_lines", "tree_within_lines"),
)

"""
    string_list(table, section, key, default; nonempty) -> Vector{String}

Value of `key` in `table` (`default` when absent) as a vector of non-empty strings; with
`nonempty`, the vector itself must not be empty. Throws an `ArgumentError` naming
`[section].key` otherwise.
"""
function string_list(
    table::AbstractDict,
    section::AbstractString,
    key::AbstractString,
    default::Vector{String};
    nonempty::Bool,
)
    value = get(table, key, default)
    valid =
        value isa AbstractVector &&
        all(x -> x isa AbstractString && !isempty(x), value) &&
        !(nonempty && isempty(value))
    valid || throw(
        ArgumentError(
            "[$section].$key must be a $(nonempty ? "non-empty " : "")list of non-empty " *
            "strings, got $(repr(value))",
        ),
    )
    return String[String(x) for x in value]
end

"""
    bounded_integer(table, section, key, default, low, high) -> Int

Value of `key` in `table` (`default` when absent), an integer other than `Bool` in
`[low, high]`. Throws an `ArgumentError` naming `[section].key` otherwise.
"""
function bounded_integer(
    table::AbstractDict,
    section::AbstractString,
    key::AbstractString,
    default::Int,
    low::Int,
    high::Int,
)
    value = get(table, key, default)
    (value isa Integer && !(value isa Bool) && low <= value <= high) || throw(
        ArgumentError(
            "[$section].$key must be an integer in [$low, $high], got $(repr(value))",
        ),
    )
    return Int(value)
end

"""
    validate_settings(raw::AbstractDict) -> Settings

Enforce the schema of the configuration tables `[workflows]`, `[dependabot]` and
`[readme]`; absent keys take the defaults of the shipped `config.toml`. Fails with an
`ArgumentError` naming the offending section or key.
"""
function validate_settings(raw::AbstractDict)
    for key in keys(raw)
        haskey(SETTING_KEYS, key) || throw(
            ArgumentError(
                "unknown section [$key]; allowed: " *
                join(("[$name]" for name in sort!(collect(keys(SETTING_KEYS)))), ", "),
            ),
        )
    end
    tables = Dict{String, AbstractDict}()
    for (name, known) in SETTING_KEYS
        table = get(raw, name, Dict{String, Any}())
        table isa AbstractDict || throw(ArgumentError("[$name] must be a table"))
        for key in keys(table)
            key in known || throw(
                ArgumentError("unknown key [$name].$key; allowed: $(join(known, ", "))"),
            )
        end
        tables[name] = table
    end
    workflows = tables["workflows"]
    readme = tables["readme"]
    return Settings(
        string_list(
            workflows,
            "workflows",
            "required_versions",
            ["min", "1"];
            nonempty = true,
        ),
        string_list(
            workflows,
            "workflows",
            "optional_versions",
            ["lts", "pre", "nightly"];
            nonempty = false,
        ),
        string_list(
            workflows,
            "workflows",
            "version_keys",
            ["version", "julia-version"];
            nonempty = true,
        ),
        string_list(
            workflows,
            "workflows",
            "housekeeping",
            ["tagbot", "compathelper", "register"];
            nonempty = false,
        ),
        string_list(
            tables["dependabot"],
            "dependabot",
            "ecosystems",
            ["julia", "github-actions"];
            nonempty = true,
        ),
        bounded_integer(readme, "readme", "tree_max_lines", 20, 5, 60),
        bounded_integer(readme, "readme", "tree_within_lines", 40, 5, 200),
    )
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

# --- repository ------------------------------------------------------------------------

"""
    RepositoryOptions(project_file, platform, platform_logo, repository, branch, waive)

Per-repository options of `.launch-check.toml`: the project file whose `[compat].julia`
the Julia badge reads, the platform constraint and its Simple Icons slug for the platform
badge, the `USER/REPO` slug and default branch, each `""` when unset, and the waived
checks with their reasons (check id => reason).
"""
struct RepositoryOptions
    project_file::String
    platform::String
    platform_logo::String
    repository::String
    branch::String
    waive::Dict{String, String}
end

"""
    Repository(root, tracked, slug, branch, tags)

What git reports about the audited repository: the absolute path of its top level, the
tracked paths (relative, `/`-separated, sorted), the GitHub slug `USER/REPO` (`""` when
unknown), the default branch and the tags.
"""
struct Repository
    root::String
    tracked::Vector{String}
    slug::String
    branch::String
    tags::Vector{String}
end

"""
    git(root, args...) -> Tuple{Bool, String}

Run `git --no-optional-locks -C root args...` with standard error discarded. Returns
whether it succeeded and its untrimmed standard output.
"""
function git(root::AbstractString, args::AbstractString...)
    out = IOBuffer()
    argv = collect(args)
    command = `git --no-optional-locks -C $root $argv`
    ok = success(pipeline(command; stdin = devnull, stdout = out, stderr = devnull))
    return ok, String(take!(out))
end

"""
    validate_slug(slug, source) -> String

`slug` when it has the form `USER/REPO`; otherwise an `ArgumentError` naming `source`.
"""
function validate_slug(slug::AbstractString, source::AbstractString)
    occursin(SLUG, slug) ||
        throw(ArgumentError("$source must have the form USER/REPO, got '$slug'"))
    return String(slug)
end

"""
    read_repository(root::AbstractString; repository = "", branch = "") -> Repository

Read the tracked files, GitHub slug, default branch and tags of the git work tree whose
top level is `root`. The slug is `repository` when given, else parsed from the GitHub URL
of the remote `origin`, else `""`; the branch is `branch` when given, else the target of
`origin/HEAD`, else the current branch, else `"main"`. Throws an `ArgumentError` when
`root` is not the top level of a work tree or `repository` is not of the form
`USER/REPO`. Nothing is written to the repository.
"""
function read_repository(
    root::AbstractString;
    repository::AbstractString = "",
    branch::AbstractString = "",
)
    isempty(repository) || validate_slug(repository, "repository")
    Sys.which("git") === nothing && throw(ArgumentError("git is not on PATH"))
    isdir(root) || throw(ArgumentError("not a directory: $root"))
    top_level = realpath(root)
    ok, top = git(top_level, "rev-parse", "--show-toplevel")
    (ok && !isempty(strip(top)) && realpath(String(strip(top))) == top_level) ||
        throw(ArgumentError("not the top level of a git work tree: $root"))

    ok, payload = git(top_level, "ls-files", "-z")
    ok || throw(ArgumentError("git ls-files failed in $root"))
    tracked = sort!(String.(split(payload, '\0'; keepempty = false)))

    slug = String(repository)
    if isempty(slug)
        ok, url = git(top_level, "remote", "get-url", "origin")
        m = ok ? match(REMOTE_URL, strip(url)) : nothing
        m === nothing || (slug = "$(m.captures[1])/$(m.captures[2])")
    end

    name = String(branch)
    if isempty(name)
        ok, head =
            git(top_level, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
        head = String(strip(head))
        ok && !isempty(head) && (name = String(chopprefix(head, "origin/")))
    end
    if isempty(name)
        ok, current = git(top_level, "branch", "--show-current")
        ok && (name = String(strip(current)))
    end
    isempty(name) && (name = "main")

    ok, tag_text = git(top_level, "tag", "--list")
    tags = ok ? String.(filter(!isempty, strip.(split(tag_text, '\n')))) : String[]
    return Repository(top_level, tracked, slug, name, tags)
end

"""
    read_tracked(repo::Repository, path::AbstractString) -> Union{String, Nothing}

Content of the tracked file `path` (relative to the root), or `nothing` when `path` is
not tracked or cannot be read.
"""
function read_tracked(repo::Repository, path::AbstractString)
    path in repo.tracked || return nothing
    full = joinpath(repo.root, path)
    isfile(full) || return nothing
    return try
        read(full, String)
    catch err
        err isa Union{SystemError, Base.IOError} || rethrow()
        nothing
    end
end

"""
    first_tracked(repo::Repository, candidates) -> Union{String, Nothing}

The first path of `candidates` that is tracked, or `nothing`.
"""
function first_tracked(repo::Repository, candidates)
    for path in candidates
        path in repo.tracked && return String(path)
    end
    return nothing
end

"""
    load_repository_options(repo::Repository) -> RepositoryOptions

Read the tracked file `.launch-check.toml` at the root of `repo`; every field is empty
when it is absent. Throws an `ArgumentError` naming the key or check id for invalid TOML,
an unknown key, a value that is not a string, a waiver of an unknown check or with an
empty reason, and a `project_file` that is not tracked.
"""
function load_repository_options(repo::Repository)
    text = read_tracked(repo, OPTIONS_FILE)
    text === nothing && return RepositoryOptions("", "", "", "", "", Dict{String, String}())
    raw = TOML.tryparse(text)
    raw isa TOML.ParserError &&
        throw(ArgumentError("$OPTIONS_FILE: not valid TOML: $(sprint(showerror, raw))"))
    string_keys = ("project_file", "platform", "platform_logo", "repository", "branch")
    for key in keys(raw)
        (key in string_keys || key == "waive") || throw(
            ArgumentError(
                "$OPTIONS_FILE: unknown key '$key'; allowed: " *
                join((string_keys..., "waive"), ", "),
            ),
        )
    end
    values = Dict{String, String}()
    for key in string_keys
        value = get(raw, key, "")
        value isa AbstractString ||
            throw(ArgumentError("$OPTIONS_FILE: $key must be a string, got $(repr(value))"))
        values[key] = String(value)
    end
    project_file = values["project_file"]
    (isempty(project_file) || project_file in repo.tracked) || throw(
        ArgumentError("$OPTIONS_FILE: project_file '$project_file' is not a tracked file"),
    )
    table = get(raw, "waive", Dict{String, Any}())
    table isa AbstractDict ||
        throw(ArgumentError("$OPTIONS_FILE: waive must be a table of check id = reason"))
    waive = Dict{String, String}()
    for (id, reason) in table
        id in CHECK_IDS ||
            throw(ArgumentError("$OPTIONS_FILE: [waive].$id: unknown check id '$id'"))
        (reason isa AbstractString && !isempty(strip(reason))) || throw(
            ArgumentError("$OPTIONS_FILE: [waive].$id needs a non-empty reason string"),
        )
        waive[id] = String(reason)
    end
    return RepositoryOptions(
        project_file,
        values["platform"],
        values["platform_logo"],
        values["repository"],
        values["branch"],
        waive,
    )
end

# --- text ------------------------------------------------------------------------------

"""
    text_lines(text::AbstractString) -> Vector{SubString{String}}

Lines of `text` without their terminators (`\\n` or `\\r\\n`); a final terminator opens
no further line.
"""
text_lines(text::AbstractString) = split(chomp(text), r"\r?\n")

"""
    scan_markdown(lines) -> Tuple{Vector{NamedTuple}, BitVector}

Fenced code blocks and HTML comments of Markdown `lines`. A block is `(open, close,
content)`: the line numbers of its fences (`close` is 0 for a block left open at the end
of the file) and of its content lines. A fence is a line starting, after up to three
spaces, with three or more backticks or tildes; as in CommonMark, the closing fence uses
the same character, is at least as long as the opening one and carries no text. A
comment runs from a line that starts with `<!--` to the first line holding `-->`; the
second value marks its lines. Fences inside a comment and comment marks inside a code
block are text.
"""
function scan_markdown(lines::AbstractVector{<:AbstractString})
    blocks = @NamedTuple{open::Int, close::Int, content::Vector{Int}}[]
    comment = falses(length(lines))
    open = 0
    fence = ""
    content = Int[]
    commenting = false
    for (i, line) in enumerate(lines)
        if commenting
            comment[i] = true
            commenting = !occursin("-->", line)
            continue
        end
        m = match(FENCE, line)
        if open != 0
            closing =
                m !== nothing &&
                first(m.captures[1]) == first(fence) &&
                length(m.captures[1]) >= length(fence) &&
                isempty(strip(m.captures[2]))
            if closing
                push!(blocks, (; open, close = i, content))
                open = 0
            else
                push!(content, i)
            end
        elseif m !== nothing
            open = i
            fence = String(m.captures[1])
            content = Int[]
        elseif occursin(COMMENT_OPEN, line)
            comment[i] = true
            commenting = !occursin("-->", line)
        end
    end
    open == 0 || push!(blocks, (; open, close = 0, content))
    return blocks, comment
end

"""
    code_blocks(lines) -> Vector{NamedTuple{(:open, :close, :content)}}

The fenced code blocks of Markdown `lines`; see [`scan_markdown`](@ref).
"""
code_blocks(lines::AbstractVector{<:AbstractString}) = first(scan_markdown(lines))

"""
    in_code(lines, blocks) -> BitVector

Whether each line of `lines` is a fence or the content of one of the fenced code
`blocks`.
"""
function in_code(lines::AbstractVector{<:AbstractString}, blocks)
    inside = falses(length(lines))
    for block in blocks
        inside[block.open] = true
        block.close == 0 || (inside[block.close] = true)
        inside[block.content] .= true
    end
    return inside
end

"""
    load_yaml(text::AbstractString) -> Tuple{Bool, Any}

Whether `text` is valid YAML, and the value of its first document (`nothing` for an
empty document or invalid YAML).
"""
function load_yaml(text::AbstractString)
    value = try
        YAML.load(text)
    catch err
        (err isa Exception && !(err isa InterruptException)) || rethrow()
        return (false, nothing)
    end
    return (true, value)
end

"""
    nonempty_string(value) -> Bool

Whether `value` is a string holding more than whitespace.
"""
nonempty_string(value) = value isa AbstractString && !isempty(strip(value))

"""
    table_of(dict::AbstractDict, key) -> AbstractDict

The table stored under `key` in `dict`, or an empty one when it is absent or not a table.
"""
function table_of(dict::AbstractDict, key)
    table = get(dict, key, nothing)
    return table isa AbstractDict ? table : Dict{String, Any}()
end

"""
    stem(path::AbstractString) -> String

Base name of `path` without its extension.
"""
stem(path::AbstractString) = String(first(splitext(basename(path))))

"""
    regex_escape(text::AbstractString) -> String

`text` with every ASCII punctuation character escaped, so that a regex matches it
literally.
"""
regex_escape(text::AbstractString) = replace(text, REGEX_SPECIAL => m -> "\\" * m)

# --- workflows -------------------------------------------------------------------------

"""
    Workflow(path, text, document)

A tracked workflow file: its path relative to the root, its text (`""` when unreadable)
and its parsed document, `nothing` when the text is not valid YAML or not a mapping.
"""
struct Workflow
    path::String
    text::String
    document::Union{Dict{Any, Any}, Nothing}
end

"""
    read_workflows(repo::Repository) -> Vector{Workflow}

The tracked files matching `.github/workflows/*.yml` or `*.yaml`, sorted by base name.
"""
function read_workflows(repo::Repository)
    workflows = Workflow[]
    paths = filter(path -> occursin(WORKFLOW_PATH, path), repo.tracked)
    for path in sort!(paths; by = basename)
        text = read_tracked(repo, path)
        document = nothing
        if text !== nothing
            valid, value = load_yaml(text)
            (valid && value isa AbstractDict) && (document = Dict{Any, Any}(value))
        end
        push!(workflows, Workflow(path, something(text, ""), document))
    end
    return workflows
end

"""
    job_entries(document::AbstractDict) -> Vector{Pair{String, Any}}

The jobs of a workflow document as `id => job`, sorted by id; empty when `jobs` is
absent or not a mapping.
"""
function job_entries(document::AbstractDict)
    jobs = get(document, "jobs", nothing)
    jobs isa AbstractDict || return Pair{String, Any}[]
    return sort!(Pair{String, Any}[string(id) => job for (id, job) in jobs]; by = first)
end

"""
    uses_values(document::AbstractDict) -> Vector{String}

The distinct string `uses` values of a workflow document, from `jobs.<id>.uses` and
`jobs.<id>.steps[*].uses`, in the order of the sorted job ids and their steps.
"""
function uses_values(document::AbstractDict)
    values = String[]
    add(value) = (value isa AbstractString && !(value in values)) && push!(values, value)
    for (_, job) in job_entries(document)
        job isa AbstractDict || continue
        add(get(job, "uses", nothing))
        steps = get(job, "steps", nothing)
        steps isa AbstractVector || continue
        for step in steps
            step isa AbstractDict && add(get(step, "uses", nothing))
        end
    end
    return values
end

"""
    uses_line(value::AbstractString) -> Regex

Pattern of a line `uses: <value>`, the value optionally quoted and the line optionally a
list item, followed by an optional comment, which is the second capture.
"""
uses_line(value::AbstractString) = Regex(
    "^\\s*(?:-\\s+)?uses:\\s*(['\"]?)" *
    regex_escape(value) *
    "\\1\\s*(?:#\\s*(.*?))?\\s*\$",
)

"""
    value_line(value::AbstractString) -> Regex

Pattern of a line that ends with `value` in another YAML form than `uses: <value>`: after
an anchor, in a flow mapping or under a quoted key. The comment is the only capture.
"""
value_line(value::AbstractString) = Regex(
    "(?<![\\w./@-])" * regex_escape(value) * "['\"]?\\s*\\}?\\s*(?:#\\s*(.*?))?\\s*\$",
)

"""
    uses_occurrences(lines, value) -> Vector{Tuple{Int, Union{String, Nothing}}}

Line number and comment of every line that gives the `uses` value `value`: the lines of
the form `uses: <value>`, or, when there is none, those that end with the value in
another YAML form. A value found on no line is returned once with line 0.
"""
function uses_occurrences(lines::AbstractVector{<:AbstractString}, value::AbstractString)
    for pattern in (uses_line(value), value_line(value))
        occurrences = Tuple{Int, Union{String, Nothing}}[]
        for (i, line) in enumerate(lines)
            m = match(pattern, line)
            m === nothing && continue
            comment = last(m.captures)
            push!(occurrences, (i, comment === nothing ? nothing : String(comment)))
        end
        isempty(occurrences) || return occurrences
    end
    return Tuple{Int, Union{String, Nothing}}[(0, nothing)]
end

"""
    pin_details(path, text, values) -> Vector{String}

One detail line per occurrence of a `uses` value of `values` in `text` that
[`pin_finding`](@ref) objects to, prefixed by `path` and the line number.
"""
function pin_details(path::AbstractString, text::AbstractString, values)
    details = String[]
    lines = text_lines(text)
    for value in values, (line, comment) in uses_occurrences(lines, value)
        finding = pin_finding(value, comment)
        finding === nothing || push!(details, "$path:$line: $value $finding")
    end
    return details
end

"""
    action_uses(document::AbstractDict) -> Vector{String}

The distinct string `uses` values of the steps of a composite action (`runs.steps`).
"""
function action_uses(document::AbstractDict)
    values = String[]
    runs = get(document, "runs", nothing)
    steps = runs isa AbstractDict ? get(runs, "steps", nothing) : nothing
    steps isa AbstractVector || return values
    for step in steps
        value = step isa AbstractDict ? get(step, "uses", nothing) : nothing
        (value isa AbstractString && !(value in values)) && push!(values, value)
    end
    return values
end

"""
    pin_finding(value, comment) -> Union{String, Nothing}

Judgement of one occurrence of the `uses` value `value` with its line comment (`nothing`
when absent): `nothing` for a local reference and for a reference pinned by a commit SHA
with a release comment, otherwise the finding that follows the value in the detail line.
"""
function pin_finding(value::AbstractString, comment::Union{AbstractString, Nothing})
    (startswith(value, "./") || startswith(value, "../")) && return nothing
    if startswith(value, "docker://")
        occursin(IMAGE_DIGEST, value) && return nothing
        return "is not pinned by a digest"
    end
    at = findlast('@', value)
    (at === nothing || !occursin(COMMIT_SHA, value[nextind(value, at):end])) &&
        return "is not pinned by a commit SHA"
    (comment === nothing || !occursin(RELEASE_COMMENT, comment)) &&
        return "has no release comment"
    return nothing
end

"""
    declares_permissions(value) -> Bool

Whether a workflow or job mapping holds a `permissions` key with a value; the empty
mapping `{}`, which grants nothing, is one.
"""
declares_permissions(value) =
    value isa AbstractDict && get(value, "permissions", nothing) !== nothing

"""
    cancels(concurrency) -> Bool

Whether a `concurrency` value is a mapping whose `cancel-in-progress` is `true` or an
expression `\${{ ... }}`.
"""
function cancels(concurrency)
    concurrency isa AbstractDict || return false
    flag = get(concurrency, "cancel-in-progress", nothing)
    return flag === true || (flag isa AbstractString && occursin("\${{", flag))
end

# --- results ---------------------------------------------------------------------------

"""
    CheckResult(id::String, status::Symbol, details::Vector{String})

Outcome of one check: its id, the status `:ok`, `:fail`, `:note` (a finding that does
not fail) or `:waived`, and one line per finding (the reason for a waived check).
"""
struct CheckResult
    id::String
    status::Symbol
    details::Vector{String}
end

"""
    outcome(id, details; status = :fail) -> CheckResult

`:ok` without details when `details` is empty, otherwise `status` with `details`.
"""
outcome(id::AbstractString, details::Vector{String}; status::Symbol = :fail) =
    isempty(details) ? CheckResult(String(id), :ok, String[]) :
    CheckResult(String(id), status, details)

# --- checks ----------------------------------------------------------------------------

"""
    check_license(repo, settings, options) -> CheckResult

The first tracked of `LICENSE`, `LICENSE.md`, `LICENSE.txt` at the root holds a
copyright holder line, and no holder line holds an e-mail address.
"""
function check_license(repo::Repository, ::Settings, ::RepositoryOptions)
    name = first_tracked(repo, LICENSE_FILES)
    text = name === nothing ? nothing : read_tracked(repo, name)
    text === nothing && return outcome("license", ["no LICENSE at the repository root"])
    details = String[]
    holders = 0
    for (i, line) in enumerate(text_lines(text))
        occursin(HOLDER_LINE, line) || continue
        holders += 1
        occursin(EMAIL, line) &&
            push!(details, "$name:$i: e-mail address in the holder line")
        occursin(TEMPLATE_HOLDER, line) &&
            push!(details, "$name:$i: the holder line is the unedited template")
    end
    holders == 0 && push!(details, "$name: no copyright holder line")
    return outcome("license", details)
end

"""
    check_citation(repo, settings, options) -> CheckResult

`CITATION.cff` at the root is a YAML mapping with `cff-version`, non-empty string
`message` and `title`, and `authors` as a non-empty list of mappings.
"""
function check_citation(repo::Repository, ::Settings, ::RepositoryOptions)
    text = read_tracked(repo, "CITATION.cff")
    text === nothing && return outcome("citation", ["no CITATION.cff"])
    valid, document = load_yaml(text)
    valid || return outcome("citation", ["CITATION.cff: not valid YAML"])
    document isa AbstractDict || return outcome("citation", ["CITATION.cff: not a mapping"])
    details = String[]
    for key in ("cff-version", "message", "title", "authors")
        if !haskey(document, key)
            push!(details, "CITATION.cff: missing key '$key'")
        elseif key in ("message", "title") && !nonempty_string(document[key])
            push!(details, "CITATION.cff: '$key' is not a non-empty string")
        elseif key == "authors"
            authors = document[key]
            valid_authors =
                authors isa AbstractVector &&
                !isempty(authors) &&
                all(author -> author isa AbstractDict, authors)
            valid_authors || push!(
                details,
                "CITATION.cff: 'authors' is not a non-empty list of mappings",
            )
        end
    end
    return outcome("citation", details)
end

"""
    check_cite_section(repo, settings, options) -> CheckResult

`README.md` holds, outside code blocks, a heading on citing, and a fenced code block
with a BibTeX entry lies between it and the next heading of the same or a higher level.
"""
function check_cite_section(repo::Repository, ::Settings, ::RepositoryOptions)
    text = read_tracked(repo, "README.md")
    text === nothing && return outcome("cite-section", ["no README.md"])
    lines = text_lines(text)
    blocks, comment = scan_markdown(lines)
    inside = in_code(lines, blocks) .| comment
    headings = Tuple{Int, Int}[]
    for (i, line) in enumerate(lines)
        inside[i] && continue
        m = match(HEADING, line)
        m === nothing || push!(headings, (i, length(m.captures[1])))
    end
    cite = [
        (k, heading) for
        (k, heading) in enumerate(headings) if occursin(CITE_HEADING, lines[heading[1]])
    ]
    isempty(cite) && return outcome("cite-section", ["README.md: no heading on citing"])
    details = String[]
    for (k, (line, level)) in cite
        following = findfirst(h -> h[2] <= level, headings[(k + 1):end])
        stop = following === nothing ? length(lines) + 1 : headings[k + following][1]
        entry = any(blocks) do block
            line < block.open < stop &&
                any(i -> occursin(BIBTEX_ENTRY, lines[i]), block.content)
        end
        entry && return outcome("cite-section", String[])
        push!(details, "README.md:$line: no BibTeX entry under the heading")
    end
    return outcome("cite-section", details)
end

"""
    check_manifest(repo, settings, options) -> CheckResult

No `Manifest.toml`, `JuliaManifest.toml` or versioned manifest is tracked.
"""
function check_manifest(repo::Repository, ::Settings, ::RepositoryOptions)
    manifests = filter(path -> occursin(MANIFEST_NAME, basename(path)), repo.tracked)
    details = String["$path is tracked" for path in manifests]
    return outcome("manifest", details)
end

"""
    project_files(repo::Repository) -> Vector{String}

Tracked paths whose base name is `Project.toml` or `JuliaProject.toml`.
"""
project_files(repo::Repository) =
    filter(path -> basename(path) in PROJECT_NAMES, repo.tracked)

"""
    compat_verdict(entry) -> Symbol

How Pkg reads a `[compat]` entry: `:invalid` when it is not a string its parser accepts
(`*`, an empty string and `<=` among them), `:unbounded` when the versions it admits
have no upper limit (`>= 1.2`, `≥ 1.2`), `:bounded` otherwise.
"""
function compat_verdict(entry)
    entry isa AbstractString || return :invalid
    spec = try
        Pkg.Types.semver_spec(entry)
    catch err
        err isa Union{ErrorException, ArgumentError, OverflowError} || rethrow()
        return :invalid
    end
    return UNBOUNDED_PROBE in spec ? :unbounded : :bounded
end

"""
    path_source(sources::AbstractDict, name) -> Bool

Whether the `[sources]` entry of `name` is a table with a `path`, a dependency taken
from the local tree.
"""
function compat_finding!(details::Vector{String}, path, name, entry)
    verdict = compat_verdict(entry)
    verdict == :unbounded && push!(details, "$path: $name = \"$entry\" has no upper bound")
    verdict == :invalid &&
        push!(details, "$path: $name = $(repr(entry)) is not a compat entry Pkg accepts")
    return details
end

"""
    path_source(sources::AbstractDict, name::AbstractString) -> Bool

Whether the `[sources]` table gives `name` by a local path.
"""
function path_source(sources::AbstractDict, name::AbstractString)
    source = get(sources, name, nothing)
    return source isa AbstractDict && haskey(source, "path")
end

"""
    check_compat(repo, settings, options) -> CheckResult

Every tracked project file is valid TOML with a `[compat]` entry for `julia` and for
every name of `[deps]`, `[weakdeps]` and `[extras]` (a name with a `[sources]` path is
exempt), and every `[compat]` entry carries an upper bound.
"""
function check_compat(repo::Repository, ::Settings, ::RepositoryOptions)
    paths = project_files(repo)
    isempty(paths) && return outcome("compat", ["no Project.toml tracked"])
    projects = Dict{String, Any}()
    for path in paths
        text = read_tracked(repo, path)
        projects[path] = text === nothing ? nothing : TOML.tryparse(text)
    end
    packages = Set{Any}(
        project["uuid"] for project in values(projects) if
        project isa AbstractDict && haskey(project, "uuid")
    )
    details = String[]
    for path in paths
        project = projects[path]
        if !(project isa AbstractDict)
            push!(details, "$path: not valid TOML")
            continue
        end
        compat = table_of(project, "compat")
        sources = table_of(project, "sources")
        uuids = Dict{String, Any}()
        for section in ("deps", "weakdeps", "extras")
            merge!(uuids, Dict(string(k) => v for (k, v) in table_of(project, section)))
        end
        delete!(uuids, "julia")
        checked = ["julia"; sort!(collect(keys(uuids)))]
        for name in checked
            if haskey(compat, name)
                compat_finding!(details, path, name, compat[name])
            elseif name == "julia" ||
                   !(path_source(sources, name) || get(uuids, name, nothing) in packages)
                # a package of this repository is taken by path and has no version
                push!(details, "$path: $name has no [compat] entry")
            end
        end
        for name in sort!([string(key) for key in keys(compat) if !(key in checked)])
            compat_finding!(details, path, name, compat[name])
        end
    end
    return outcome("compat", details)
end

"""
    read_dependabot(repo::Repository) -> Tuple{Union{String, Nothing}, Any, String}

Path of the tracked Dependabot configuration, its `updates` list (`nothing` when it
cannot be had) and the problem that prevents it (`""` when there is none).
"""
function read_dependabot(repo::Repository)
    path = first_tracked(repo, DEPENDABOT_FILES)
    path === nothing && return (nothing, nothing, "no .github/dependabot.yml")
    text = read_tracked(repo, path)
    text === nothing && return (path, nothing, "$path: not readable")
    valid, document = load_yaml(text)
    valid || return (path, nothing, "$path: not valid YAML")
    updates = document isa AbstractDict ? get(document, "updates", nothing) : nothing
    updates isa AbstractVector || return (path, nothing, "$path: no 'updates' list")
    return (path, updates, "")
end

"""
    ecosystem_of(entry) -> String

The `package-ecosystem` of a Dependabot update entry, `"?"` when it has none.
"""
function ecosystem_of(entry)
    ecosystem = entry isa AbstractDict ? get(entry, "package-ecosystem", nothing) : nothing
    return ecosystem isa AbstractString ? String(ecosystem) : "?"
end

"""
    check_dependabot(repo, settings, options) -> CheckResult

`.github/dependabot.yml` (or `.yaml`) has an update entry for every ecosystem of the
settings; every entry has a schedule interval and does not set
`open-pull-requests-limit` to 0.
"""
function check_dependabot(repo::Repository, settings::Settings, ::RepositoryOptions)
    _, updates, problem = read_dependabot(repo)
    updates === nothing && return outcome("dependabot", [problem])
    details = String[]
    present = ecosystem_of.(updates)
    for ecosystem in settings.ecosystems
        ecosystem in present ||
            push!(details, "no update entry for the ecosystem '$ecosystem'")
    end
    for (i, entry) in enumerate(updates)
        label = "updates[$i] ($(present[i]))"
        mapping = entry isa AbstractDict ? entry : Dict{Any, Any}()
        schedule = get(mapping, "schedule", nothing)
        (schedule isa AbstractDict && get(schedule, "interval", nothing) !== nothing) ||
            push!(details, "$label: no schedule interval")
        limit = get(mapping, "open-pull-requests-limit", nothing)
        (limit isa Integer && !(limit isa Bool) && limit == 0) && push!(
            details,
            "$label: open-pull-requests-limit is 0, version updates are switched off",
        )
    end
    return outcome("dependabot", details)
end

"""
    check_dependabot_cooldown(repo, settings, options) -> CheckResult

A note for every Dependabot update entry without a `cooldown` mapping; `:ok` when the
configuration is absent or unreadable, which `dependabot` reports.
"""
function check_dependabot_cooldown(repo::Repository, ::Settings, ::RepositoryOptions)
    _, updates, _ = read_dependabot(repo)
    updates === nothing && return outcome("dependabot-cooldown", String[])
    details = String[]
    for (i, entry) in enumerate(updates)
        cooldown = entry isa AbstractDict ? get(entry, "cooldown", nothing) : nothing
        cooldown isa AbstractDict ||
            push!(details, "updates[$i] ($(ecosystem_of(entry))): no cooldown")
    end
    return outcome("dependabot-cooldown", details; status = :note)
end

"""
    check_workflow_pins(repo, settings, options) -> CheckResult

At least one workflow is tracked; every action and reusable workflow it uses is local,
a Docker image pinned by digest, or pinned by a 40-digit commit SHA with a release
comment (`# v1.2.3`) on its `uses:` line.
"""
function check_workflow_pins(repo::Repository, ::Settings, ::RepositoryOptions)
    workflows = read_workflows(repo)
    isempty(workflows) &&
        return outcome("workflow-pins", ["no workflow under .github/workflows"])
    details = String[]
    for workflow in workflows
        if workflow.document === nothing
            push!(details, "$(workflow.path): not valid YAML")
            continue
        end
        values = uses_values(workflow.document)
        append!(details, pin_details(workflow.path, workflow.text, values))
    end
    # composite actions of the repository, which a workflow reaches through `./`
    for path in filter(path -> basename(path) in ACTION_NAMES, repo.tracked)
        text = read_tracked(repo, path)
        valid, document = text === nothing ? (false, nothing) : load_yaml(text)
        if !(valid && document isa AbstractDict)
            push!(details, "$path: not valid YAML")
            continue
        end
        append!(details, pin_details(path, text, action_uses(document)))
    end
    return outcome("workflow-pins", details)
end

"""
    check_workflow_permissions(repo, settings, options) -> CheckResult

Every workflow declares `permissions` at the top level or in every job, and none grants
`write-all`.
"""
function check_workflow_permissions(repo::Repository, ::Settings, ::RepositoryOptions)
    details = String[]
    for workflow in read_workflows(repo)
        document = workflow.document
        if document === nothing
            push!(details, "$(workflow.path): not valid YAML")
            continue
        end
        jobs = job_entries(document)
        if !declares_permissions(document)
            if isempty(jobs)
                push!(details, "$(workflow.path): no permissions")
            else
                for (id, job) in jobs
                    declares_permissions(job) || push!(
                        details,
                        "$(workflow.path): no permissions at workflow level, and job " *
                        "'$id' declares none",
                    )
                end
            end
        end
        get(document, "permissions", nothing) == "write-all" &&
            push!(details, "$(workflow.path): permissions: write-all (workflow)")
        for (id, job) in jobs
            (job isa AbstractDict && get(job, "permissions", nothing) == "write-all") &&
                push!(details, "$(workflow.path): permissions: write-all (job '$id')")
        end
    end
    return outcome("workflow-permissions", details)
end

"""
    check_workflow_concurrency(repo, settings, options) -> CheckResult

Every workflow has a concurrency group that cancels superseded runs, at the top level or
in every job.
"""
function check_workflow_concurrency(repo::Repository, ::Settings, ::RepositoryOptions)
    details = String[]
    for workflow in read_workflows(repo)
        document = workflow.document
        if document === nothing
            push!(details, "$(workflow.path): not valid YAML")
            continue
        end
        cancels(get(document, "concurrency", nothing)) && continue
        jobs = job_entries(document)
        every_job =
            !isempty(jobs) && all(jobs) do (_, job)
                job isa AbstractDict && cancels(get(job, "concurrency", nothing))
            end
        every_job || push!(
            details,
            "$(workflow.path): no concurrency group that cancels superseded runs",
        )
    end
    return outcome("workflow-concurrency", details)
end

"""
    check_ci_matrix(repo, settings, options) -> CheckResult

Some workflow job has a Julia version matrix (`strategy.matrix.<key>` for a key of
`version_keys`); every version in such a matrix is a quoted name of `required_versions`
or `optional_versions`, and one matrix holds all of `required_versions`.
"""
function version_finding!(details::Vector{String}, context, entry, allowed)
    if !(entry isa AbstractString)
        push!(
            details,
            "$context: version $(repr(entry)) is a number (pinned, or unquoted in YAML)",
        )
    elseif !(entry in allowed)
        push!(details, "$context: version '$entry' is pinned")
    end
    return details
end

"""
    check_ci_matrix(repo, settings, options) -> CheckResult

Some job matrix lists Julia versions under a key of `version_keys` and holds every
required one; every version of a matrix, of its `include` entries and of a literal
`with: version:` of `julia-actions/setup-julia` is an allowed name, not a number.
"""
function check_ci_matrix(repo::Repository, settings::Settings, ::RepositoryOptions)
    allowed = union(settings.required_versions, settings.optional_versions)
    details = String[]
    matrices = Vector{Any}[]
    for workflow in read_workflows(repo)
        document = workflow.document
        if document === nothing
            push!(details, "$(workflow.path): not valid YAML")
            continue
        end
        for (id, job) in job_entries(document)
            job isa AbstractDict || continue
            context = "$(workflow.path): job '$id'"
            # a version written out for setup-julia, outside any matrix
            steps = get(job, "steps", nothing)
            for step in (steps isa AbstractVector ? steps : Any[])
                step isa AbstractDict || continue
                uses = get(step, "uses", nothing)
                (uses isa AbstractString && startswith(uses, SETUP_JULIA)) || continue
                version = get(table_of(step, "with"), "version", nothing)
                (
                    version === nothing ||
                    (version isa AbstractString && occursin("\${{", version))
                ) && continue
                version_finding!(details, context, version, allowed)
            end
            strategy = get(job, "strategy", nothing)
            strategy isa AbstractDict || continue
            matrix = get(strategy, "matrix", nothing)
            matrix isa AbstractDict || continue
            for key in settings.version_keys
                versions = get(matrix, key, nothing)
                versions isa AbstractVector || continue
                push!(matrices, collect(Any, versions))
                for entry in versions
                    version_finding!(details, context, entry, allowed)
                end
            end
            additions = get(matrix, "include", nothing)
            for item in (additions isa AbstractVector ? additions : Any[])
                item isa AbstractDict || continue
                for key in settings.version_keys
                    haskey(item, key) &&
                        version_finding!(details, context, item[key], allowed)
                end
            end
        end
    end
    if isempty(matrices)
        push!(details, "no Julia version matrix in any workflow")
    else
        complete = any(matrices) do versions
            all(required -> any(isequal(required), versions), settings.required_versions)
        end
        required = join(settings.required_versions, ", ")
        complete || push!(details, "no matrix holds all of: $required")
    end
    return outcome("ci-matrix", details)
end

"""
    check_format(repo, settings, options) -> CheckResult

`.JuliaFormatter.toml` is tracked at the root and a workflow whose stem starts with
`format` (any case) exists.
"""
function check_format(repo::Repository, ::Settings, ::RepositoryOptions)
    details = String[]
    ".JuliaFormatter.toml" in repo.tracked || push!(details, "no .JuliaFormatter.toml")
    any(w -> startswith(lowercase(stem(w.path)), "format"), read_workflows(repo)) ||
        push!(details, "no format workflow (.github/workflows/Format.yml)")
    return outcome("format", details)
end

"""
    check_changelog(repo, settings, options) -> CheckResult

`CHANGELOG.md` is tracked at the root.
"""
check_changelog(repo::Repository, ::Settings, ::RepositoryOptions) =
    outcome("changelog", "CHANGELOG.md" in repo.tracked ? String[] : ["no CHANGELOG.md"])

"""
    check_readme_tree(repo, settings, options) -> CheckResult

The first fenced code block of `README.md` is a file tree (a line holds `├` or `└`) of
at most `tree_max_lines` content lines, whose opening fence lies at or before line
`tree_within_lines`.
"""
function check_readme_tree(repo::Repository, settings::Settings, ::RepositoryOptions)
    text = read_tracked(repo, "README.md")
    text === nothing && return outcome("readme-tree", ["no README.md"])
    lines = text_lines(text)
    blocks = code_blocks(lines)
    isempty(blocks) &&
        return outcome("readme-tree", ["README.md: no code block, so no file tree"])
    block = first(blocks)
    at = block.open
    any(i -> occursin('├', lines[i]) || occursin('└', lines[i]), block.content) ||
        return outcome(
            "readme-tree",
            ["README.md:$at: the first code block is not a file tree"],
        )
    details = String[]
    n = length(block.content)
    n > settings.tree_max_lines && push!(
        details,
        "README.md:$at: the tree has $n lines, more than $(settings.tree_max_lines)",
    )
    at > settings.tree_within_lines && push!(
        details,
        "README.md:$at: the tree opens after line $(settings.tree_within_lines)",
    )
    return outcome("readme-tree", details)
end

"""
    check_badges(repo, settings, options) -> CheckResult

The badge row of `README.md` equals, in its image and link URLs and their order, the row
[`expected_badges`](@ref) generates. Fails when the repository slug is unknown.
"""
function check_badges(repo::Repository, settings::Settings, options::RepositoryOptions)
    isempty(repo.slug) &&
        return outcome("badges", ["repository unknown: pass --repository USER/REPO"])
    expected = expected_badges(repo, settings, options)
    actual = readme_badges(something(read_tracked(repo, "README.md"), ""))
    key(badge) = (badge.image, badge.link)
    key.(expected) == key.(actual) && return outcome("badges", String[])
    # multiset difference: each README badge matches at most one expected badge
    unmatched = collect(actual)
    missing_badges = Badge[]
    for badge in expected
        k = findfirst(b -> key(b) == key(badge), unmatched)
        k === nothing ? push!(missing_badges, badge) : deleteat!(unmatched, k)
    end
    details = String[]
    for badge in missing_badges
        push!(details, "missing $(badge.kind): $(markdown(badge))")
    end
    for badge in unmatched
        push!(details, "unexpected: $(markdown(badge))")
    end
    isempty(details) &&
        push!(details, "order: expected $(join((b.kind for b in expected), ", "))")
    return outcome("badges", details)
end

"""
    check_docs(repo, settings, options) -> CheckResult

`docs/make.jl` is tracked and a workflow refers to `julia-docdeploy` or `docs/make.jl`.
"""
function check_docs(repo::Repository, ::Settings, ::RepositoryOptions)
    details = String[]
    "docs/make.jl" in repo.tracked || push!(details, "no docs/make.jl")
    builds = any(read_workflows(repo)) do workflow
        text = workflow.text
        occursin("julia-docdeploy", text) || occursin("docs/make.jl", text)
    end
    builds || push!(details, "no workflow builds the documentation")
    return outcome("docs", details)
end

"""
    all_uses(repo::Repository) -> Vector{String}

The `uses` values of every parsable workflow, as collected by [`uses_values`](@ref).
"""
function all_uses(repo::Repository)
    values = String[]
    for workflow in read_workflows(repo)
        workflow.document === nothing || append!(values, uses_values(workflow.document))
    end
    return values
end

"""
    check_coverage(repo, settings, options) -> CheckResult

A workflow uses `julia-actions/julia-processcoverage` and one uses
`codecov/codecov-action`.
"""
function check_coverage(repo::Repository, ::Settings, ::RepositoryOptions)
    values = all_uses(repo)
    details = String[]
    any(v -> startswith(v, "julia-actions/julia-processcoverage@"), values) || push!(
        details,
        "no workflow processes coverage (julia-actions/julia-processcoverage)",
    )
    any(v -> startswith(v, "codecov/codecov-action@"), values) ||
        push!(details, "no workflow uploads coverage (codecov/codecov-action)")
    return outcome("coverage", details)
end

"""
    exit_status(command::Cmd) -> Int

Exit status of `command`, run with standard input, output and error detached; a process
killed by a signal reports 128 plus the signal number, as a shell does.
"""
function exit_status(command::Cmd)
    detached =
        pipeline(ignorestatus(command); stdin = devnull, stdout = devnull, stderr = devnull)
    process = run(detached)
    process.termsignal > 0 && return 128 + process.termsignal
    return process.exitcode
end

"""
    check_self_contained(repo, settings, options) -> CheckResult

`standalone/workspace-audit.jl` of the toolbox, run with `--self-contained` on the
root, finds no path that leads outside the repository.
"""
function check_self_contained(repo::Repository, ::Settings, ::RepositoryOptions)
    julia = Base.julia_cmd()
    script = joinpath(TOOLBOX_ROOT, "standalone", "workspace-audit.jl")
    command = `$julia --startup-file=no $script $(repo.root) --self-contained`
    status = exit_status(command)
    status == 0 && return outcome("self-contained", String[])
    return outcome(
        "self-contained",
        [
            "workspace-audit --self-contained exited with status $status",
            "the findings: julia run.jl workspace-audit $(repo.root) --self-contained",
        ],
    )
end

"""
    check_history(repo, settings, options) -> CheckResult

`standalone/commit-guard.jl log` of the toolbox finds no attribution trailer,
attribution line or session URL in the commit messages of the repository.
"""
function check_history(repo::Repository, ::Settings, ::RepositoryOptions)
    julia = Base.julia_cmd()
    script = joinpath(TOOLBOX_ROOT, "standalone", "commit-guard.jl")
    rules = "trailer,attribution,session_url"
    command = `$julia --startup-file=no $script log --repo $(repo.root) --rules $rules`
    status = exit_status(command)
    status == 0 && return outcome("history", String[])
    return outcome(
        "history",
        [
            "commit-guard log exited with status $status",
            "the findings: julia run.jl commit-guard log --repo $(repo.root) --rules " *
            "trailer,attribution,session_url",
        ],
    )
end

"Checks in reporting order, as id => check function."
const CHECKS = Pair{String, Function}[
    "license" => check_license,
    "citation" => check_citation,
    "cite-section" => check_cite_section,
    "manifest" => check_manifest,
    "compat" => check_compat,
    "dependabot" => check_dependabot,
    "dependabot-cooldown" => check_dependabot_cooldown,
    "workflow-pins" => check_workflow_pins,
    "workflow-permissions" => check_workflow_permissions,
    "workflow-concurrency" => check_workflow_concurrency,
    "ci-matrix" => check_ci_matrix,
    "format" => check_format,
    "changelog" => check_changelog,
    "readme-tree" => check_readme_tree,
    "badges" => check_badges,
    "docs" => check_docs,
    "coverage" => check_coverage,
    "self-contained" => check_self_contained,
    "history" => check_history,
]

"Ids of [`CHECKS`](@ref), in order."
const CHECK_IDS = first.(CHECKS)

"One-line description of every check, for `--list`."
const CHECK_DESCRIPTIONS = Dict(
    "license" => "LICENSE at the root, a copyright holder line without e-mail address",
    "citation" => "CITATION.cff with cff-version, message, title and authors",
    "cite-section" => "README heading on citing with a BibTeX entry beneath",
    "manifest" => "no Manifest.toml tracked",
    "compat" => "julia and every dependency with a bounded [compat] entry",
    "dependabot" => "Dependabot update entries for the ecosystems, each with a schedule",
    "dependabot-cooldown" => "a cooldown on every Dependabot update entry (note only)",
    "workflow-pins" => "actions pinned by commit SHA with a release comment",
    "workflow-permissions" => "permissions declared in every workflow, none write-all",
    "workflow-concurrency" => "a concurrency group that cancels superseded runs",
    "ci-matrix" => "Julia versions as named channels, one matrix with all required",
    "format" => ".JuliaFormatter.toml and a Format workflow",
    "changelog" => "CHANGELOG.md at the root",
    "readme-tree" => "README opens with a short file tree",
    "badges" => "README badge row equal to the generated one",
    "docs" => "docs/make.jl and a workflow that builds the documentation",
    "coverage" => "coverage processed and uploaded to Codecov",
    "self-contained" => "workspace-audit --self-contained finds nothing",
    "history" => "commit-guard finds no attribution trailer or session URL",
)

"""
    launch_checks(repo, settings, options; only::Vector{String} = String[])
        -> Vector{CheckResult}

Run the checks of [`CHECKS`](@ref) in order, restricted to the ids of `only` when it is
not empty. A check waived in `options.waive` is not run; its result is `:waived` with the
reason as its detail. An unknown id in `only` is an `ArgumentError`.
"""
function launch_checks(
    repo::Repository,
    settings::Settings,
    options::RepositoryOptions;
    only::Vector{String} = String[],
)
    for id in only
        id in CHECK_IDS || throw(ArgumentError("unknown check '$id'; see --list"))
    end
    results = CheckResult[]
    for (id, check) in CHECKS
        (isempty(only) || id in only) || continue
        if haskey(options.waive, id)
            push!(results, CheckResult(id, :waived, [options.waive[id]]))
        else
            push!(results, check(repo, settings, options))
        end
    end
    return results
end

# --- badges ----------------------------------------------------------------------------

"""
    Badge(kind, alt, image, link)

A README badge: its kind (`"docs"`, `"ci"`, `"workflow"`, `"coverage"`, `"aqua"`,
`"jet"`, `"style"`, `"format"`, `"julia"`, `"doi"`, `"arxiv"`, `"platform"`; `""` for a
badge read from a README), the alternative text, the image URL and the link URL.
"""
struct Badge
    kind::String
    alt::String
    image::String
    link::String
end

"""
    markdown(badge::Badge) -> String

The Markdown of a badge, `[![alt](image)](link)`.
"""
markdown(badge::Badge) = "[![$(badge.alt)]($(badge.image))]($(badge.link))"

"""
    shields_escape(text) -> String

`text` escaped for a path segment of a static shields.io badge: `-` becomes `--`, `_`
becomes `__`, a space `%20` and `/` `%2F`.
"""
function shields_escape(text::AbstractString)
    io = IOBuffer()
    for c in text
        if c == '-'
            print(io, "--")
        elseif c == '_'
            print(io, "__")
        elseif c == ' '
            print(io, "%20")
        elseif c == '/'
            print(io, "%2F")
        else
            print(io, c)
        end
    end
    return String(take!(io))
end

"""
    url_encode(text) -> String

`text` percent-encoded byte by byte (UTF-8), with upper-case hexadecimal digits; only
`A-Z`, `a-z`, `0-9` and `-._~` are left as they are.
"""
function url_encode(text::AbstractString)
    io = IOBuffer()
    for byte in codeunits(String(text))
        c = Char(byte)
        if byte < 0x80 && (isletter(c) || isdigit(c) || c in ('-', '.', '_', '~'))
            print(io, c)
        else
            print(io, @sprintf("%%%02X", byte))
        end
    end
    return String(take!(io))
end

"""
    readme_badges(text::AbstractString) -> Vector{Badge}

The badge row of a README: the consecutive lines after the first `# ` title, past blank
lines, that consist only of badges `[![alt](image)](link)` separated by whitespace. The
badges carry the kind `""`; the vector is empty when there is no title or no such line.
"""
function readme_badges(text::AbstractString)
    lines = text_lines(text)
    blocks, comment = scan_markdown(lines)
    hidden = in_code(lines, blocks) .| comment
    # the title: a line `# ...`, or a line underlined with `=`
    at = 0
    for (i, line) in enumerate(lines)
        hidden[i] && continue
        if startswith(line, "# ")
            at = i + 1
            break
        elseif i < length(lines) &&
               !isempty(strip(line)) &&
               !hidden[i + 1] &&
               occursin(SETEXT_UNDERLINE, lines[i + 1])
            at = i + 2
            break
        end
    end
    at == 0 && return Badge[]
    while at <= length(lines) && (isempty(strip(lines[at])) || comment[at])
        at += 1
    end
    badges = Badge[]
    while at <= length(lines)
        line = strip(lines[at])
        (!isempty(line) && occursin(BADGE_LINE, line)) || break
        for m in eachmatch(BADGE, line)
            push!(
                badges,
                Badge(
                    "",
                    String(m.captures[1]),
                    String(m.captures[2]),
                    String(m.captures[3]),
                ),
            )
        end
        at += 1
    end
    return badges
end

"""
    workflow_badge(kind, alt, slug, branch, path) -> Badge

Status badge of the GitHub Actions workflow file `path` on `branch` of `slug`.
"""
function workflow_badge(
    kind::AbstractString,
    alt::AbstractString,
    slug::AbstractString,
    branch::AbstractString,
    path::AbstractString,
)
    file = basename(path)
    return Badge(
        kind,
        alt,
        "https://github.com/$slug/actions/workflows/$file/badge.svg?branch=$branch",
        "https://github.com/$slug/actions/workflows/$file?query=branch%3A$branch",
    )
end

"""
    citation_identifiers(repo::Repository) -> Tuple{Vector{String}, Vector{String}}

DOIs and arXiv identifiers of the tracked root `CITATION.cff`: the distinct DOIs of the
top-level `doi`, of the `identifiers` of type `doi` and of `preferred-citation.doi`, in
that order, and the arXiv numbers of the `identifiers` of type `other` written
`arXiv:NNNN.NNNNN`. Both are empty when the file is absent or not a YAML mapping.
"""
function citation_identifiers(repo::Repository)
    dois = String[]
    arxiv = String[]
    text = read_tracked(repo, "CITATION.cff")
    text === nothing && return dois, arxiv
    valid, document = load_yaml(text)
    (valid && document isa AbstractDict) || return dois, arxiv
    add_doi(value) = (value isa AbstractString && !(value in dois)) && push!(dois, value)
    add_doi(get(document, "doi", nothing))
    identifiers = get(document, "identifiers", nothing)
    entries = identifiers isa AbstractVector ? identifiers : Any[]
    for entry in entries
        (entry isa AbstractDict && get(entry, "type", nothing) == "doi") &&
            add_doi(get(entry, "value", nothing))
    end
    preferred = get(document, "preferred-citation", nothing)
    preferred isa AbstractDict && add_doi(get(preferred, "doi", nothing))
    for entry in entries
        (entry isa AbstractDict && get(entry, "type", nothing) == "other") || continue
        value = get(entry, "value", nothing)
        value isa AbstractString || continue
        m = match(ARXIV_ID, value)
        m === nothing || push!(arxiv, String(m.captures[1]))
    end
    return dois, arxiv
end

"""
    dependency_names(repo::Repository) -> Set{String}

Names in `[deps]` or `[extras]` of every tracked project file; unreadable files are
ignored.
"""
function dependency_names(repo::Repository)
    names = Set{String}()
    for path in project_files(repo)
        text = read_tracked(repo, path)
        project = text === nothing ? nothing : TOML.tryparse(text)
        project isa AbstractDict || continue
        for section in ("deps", "extras")
            union!(names, string.(keys(table_of(project, section))))
        end
    end
    return names
end

"""
    formatter_style(repo::Repository) -> Union{String, Nothing}

The `style` of the tracked root `.JuliaFormatter.toml`, `nothing` when the file is
absent, unreadable or names no style.
"""
function formatter_style(repo::Repository)
    text = read_tracked(repo, ".JuliaFormatter.toml")
    config = text === nothing ? nothing : TOML.tryparse(text)
    config isa AbstractDict || return nothing
    style = get(config, "style", nothing)
    return style isa AbstractString ? String(style) : nothing
end

"""
    expected_badges(repo::Repository, settings::Settings, options::RepositoryOptions)
        -> Vector{Badge}

The README badge row the repository warrants, in order: stable docs (with `docs/make.jl`
and a `vX.Y.Z` tag), CI, further user-facing workflows, coverage (Codecov upload), Aqua,
JET, code style (Blue or SciML), formatter workflow, Julia compat, DOIs and arXiv
preprints of `CITATION.cff`, platform. Throws an `ArgumentError` when the repository
slug is unknown.
"""
function expected_badges(repo::Repository, settings::Settings, options::RepositoryOptions)
    isempty(repo.slug) &&
        throw(ArgumentError("repository unknown: pass --repository USER/REPO"))
    slug, branch = repo.slug, repo.branch
    user, name = split(slug, '/'; limit = 2)
    workflows = read_workflows(repo)
    stems = [lowercase(stem(w.path)) for w in workflows]
    badges = Badge[]

    if "docs/make.jl" in repo.tracked && any(tag -> occursin(RELEASE_TAG, tag), repo.tags)
        push!(
            badges,
            Badge(
                "docs",
                "Stable",
                "https://img.shields.io/badge/docs-stable-blue.svg",
                "https://$user.github.io/$name/stable/",
            ),
        )
    end
    ci = findfirst(==("ci"), stems)
    ci === nothing ||
        push!(badges, workflow_badge("ci", "CI", slug, branch, workflows[ci].path))
    for (workflow, lower) in zip(workflows, stems)
        (lower == "ci" || startswith(lower, "format") || lower in settings.housekeeping) &&
            continue
        document = workflow.document
        title = document === nothing ? nothing : get(document, "name", nothing)
        alt = title isa AbstractString ? String(title) : stem(workflow.path)
        push!(badges, workflow_badge("workflow", alt, slug, branch, workflow.path))
    end
    if any(v -> startswith(v, "codecov/codecov-action@"), all_uses(repo))
        push!(
            badges,
            Badge(
                "coverage",
                "Coverage",
                "https://codecov.io/gh/$slug/branch/$branch/graph/badge.svg",
                "https://codecov.io/gh/$slug",
            ),
        )
    end
    dependencies = dependency_names(repo)
    if "Aqua" in dependencies
        push!(
            badges,
            Badge(
                "aqua",
                "Aqua QA",
                "https://juliatesting.github.io/Aqua.jl/dev/assets/badge.svg",
                "https://github.com/JuliaTesting/Aqua.jl",
            ),
        )
    end
    if "JET" in dependencies
        push!(
            badges,
            Badge(
                "jet",
                "JET",
                "https://img.shields.io/badge/" *
                "%F0%9F%9B%A9%EF%B8%8F_tested_with-JET.jl-233f9a",
                "https://github.com/aviatesk/JET.jl",
            ),
        )
    end
    style = formatter_style(repo)
    if style == "blue"
        push!(
            badges,
            Badge(
                "style",
                "Code Style: Blue",
                "https://img.shields.io/badge/code%20style-blue-4495d1.svg",
                "https://github.com/JuliaDiff/BlueStyle",
            ),
        )
    elseif style == "sciml"
        push!(
            badges,
            Badge(
                "style",
                "SciML Code Style",
                "https://img.shields.io/static/v1?label=code%20style&message=SciML" *
                "&color=9558b2&labelColor=389826",
                "https://github.com/SciML/SciMLStyle",
            ),
        )
    end
    format = findfirst(lower -> startswith(lower, "format"), stems)
    format === nothing || push!(
        badges,
        workflow_badge("format", "Format", slug, branch, workflows[format].path),
    )
    project =
        !isempty(options.project_file) ? options.project_file :
        "Project.toml" in repo.tracked ? "Project.toml" : nothing
    if project !== nothing
        raw = url_encode("https://raw.githubusercontent.com/$slug/$branch/$project")
        push!(
            badges,
            Badge(
                "julia",
                "Julia",
                "https://img.shields.io/badge/dynamic/toml?url=$raw" *
                "&query=%24.compat.julia&label=julia&logo=julia&color=9558b2",
                "https://julialang.org/downloads/",
            ),
        )
    end
    dois, arxiv = citation_identifiers(repo)
    for doi in dois
        # a parenthesis would end the Markdown link the badge is written as
        link = replace("https://doi.org/$doi", "(" => "%28", ")" => "%29")
        if occursin(JOSS_DOI, doi)
            image = "https://joss.theoj.org/papers/$doi/status.svg"
            push!(badges, Badge("joss", "JOSS", image, link))
        else
            label = replace(shields_escape(doi), "(" => "%28", ")" => "%29")
            image = "https://img.shields.io/badge/DOI-$label-blue?logo=doi"
            push!(badges, Badge("doi", "DOI", image, link))
        end
    end
    for id in arxiv
        push!(
            badges,
            Badge(
                "arxiv",
                "arXiv",
                "https://img.shields.io/badge/arXiv-$id-b31b1b?logo=arxiv",
                "https://arxiv.org/abs/$id",
            ),
        )
    end
    if !isempty(options.platform)
        image =
            "https://img.shields.io/badge/platform-$(shields_escape(options.platform))" *
            "-lightgrey"
        isempty(options.platform_logo) || (image *= "?logo=$(options.platform_logo)")
        push!(badges, Badge("platform", "Platform", image, "#requirements"))
    end
    return badges
end

# --- command line ----------------------------------------------------------------------

const STATUS_LABELS =
    Dict(:ok => "ok", :fail => "FAIL", :note => "note", :waived => "waived")

"""
    usage(io::IO = stdout)

Print the command-line help.
"""
function usage(io::IO = stdout)
    print(
        io,
        """
        launch-check — a Julia repository against the conventions of a public launch

        Usage:
          julia run.jl launch-check [PATH] [--only ID,...] [--waive ID,...] [--verbose]
                                    [OPTIONS]
          julia run.jl launch-check badges [PATH] [OPTIONS]
          julia run.jl launch-check --list
          julia run.jl launch-check --help

          PATH                    top level of a git work tree (default: working directory)
          badges                  print the badge row instead of running the checks
          --only ID,...           run only these checks
          --waive ID,...          skip these checks and report them as waived
          --verbose               print the generated badge row after the summary
          --list                  list the checks

        Options:
          --repository USER/REPO  GitHub slug (default: .launch-check.toml, else origin)
          --branch NAME           default branch (default: .launch-check.toml, else
                                  origin/HEAD, else the current branch)
          --project-file FILE     tracked project file read by the Julia badge
          --platform TEXT         platform constraint shown by the platform badge
          --platform-logo SLUG    Simple Icons slug of the platform badge
          --config PATH           configuration file (default: config.toml next to the tool)

        Exit status: 0 when no check fails, 1 when one does, 2 for invalid arguments.
        """,
    )
    return nothing
end

"""
    list_checks(io::IO = stdout)

Print every check id with its description, one per line.
"""
function list_checks(io::IO = stdout)
    width = maximum(length, CHECK_IDS) + 2
    for id in CHECK_IDS
        println(io, rpad(id, width), CHECK_DESCRIPTIONS[id])
    end
    return nothing
end

"""
    id_list(text, flag) -> Vector{String}

The comma-separated check ids of a `--only` or `--waive` value. Throws an
`ArgumentError` for an empty list or an unknown id.
"""
function id_list(text::AbstractString, flag::AbstractString)
    ids = String.(filter(!isempty, strip.(split(text, ','))))
    isempty(ids) && throw(ArgumentError("$flag takes at least one check id"))
    for id in ids
        id in CHECK_IDS || throw(ArgumentError("$flag: unknown check '$id'; see --list"))
    end
    return ids
end

"""
    print_results(io::IO, repo::Repository, results::AbstractVector{CheckResult})

The header line, one line per result with its details indented beneath (except for
`ok`), and the summary line.
"""
function print_results(io::IO, repo::Repository, results::AbstractVector{CheckResult})
    slug = isempty(repo.slug) ? "repository unknown" : repo.slug
    println(io, "launch-check: $(repo.root) ($slug, branch $(repo.branch))")
    for result in results
        println(io, rpad(STATUS_LABELS[result.status], 8), result.id)
        result.status == :ok && continue
        for detail in result.details
            println(io, " "^8, detail)
        end
    end
    tally(status) = count(r -> r.status == status, results)
    plural(n, word) = n == 1 ? "$n $word" : "$n $(word)s"
    println(
        io,
        "$(plural(length(results), "check")): $(tally(:ok)) ok, $(tally(:fail)) failed, ",
        "$(tally(:waived)) waived, $(plural(tally(:note), "note"))",
    )
    return nothing
end

"""
    main(args::Vector{String} = ARGS; io::IO = stdout) -> Union{Nothing, NamedTuple}

Parse the command line, read the repository and its `.launch-check.toml`, apply the
command-line overrides, then run the checks and print the report to `io`, or, after
`badges`, print the badge row. Returns `(results, failed)` in check mode, with `failed`
true when a check failed, and `(badges, failed = false)` in badges mode; returns
`nothing` after `--help` and `--list`.
"""
function main(args::Vector{String} = ARGS; io::IO = stdout)
    config_path = joinpath(@__DIR__, "config.toml")
    badges_mode = !isempty(args) && args[1] == "badges"
    path = nothing
    only = String[]
    waive = String[]
    verbose = false
    repository = nothing
    branch = nothing
    project_file = nothing
    platform = nothing
    platform_logo = nothing
    i = badges_mode ? 2 : 1
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
        elseif argument == "--list"
            list_checks(io)
            return nothing
        elseif !badges_mode && argument == "--only"
            append!(only, id_list(value_of(argument), argument))
        elseif !badges_mode && argument == "--waive"
            append!(waive, id_list(value_of(argument), argument))
        elseif !badges_mode && argument == "--verbose"
            verbose = true
        elseif argument == "--repository"
            repository = validate_slug(value_of(argument), "--repository")
        elseif argument == "--branch"
            branch = value_of(argument)
            isempty(branch) && throw(ArgumentError("--branch requires a non-empty value"))
        elseif argument == "--project-file"
            project_file = value_of(argument)
        elseif argument == "--platform"
            platform = value_of(argument)
        elseif argument == "--platform-logo"
            platform_logo = value_of(argument)
        elseif argument == "--config"
            config_path = value_of(argument)
        elseif startswith(argument, "-")
            throw(ArgumentError("unknown command-line argument '$argument'; see --help"))
        else
            path === nothing ||
                throw(ArgumentError("more than one PATH given: '$path' and '$argument'"))
            path = argument
        end
        i += 1
    end

    settings = load_settings(config_path)
    repo = read_repository(something(path, pwd()))
    options = load_repository_options(repo)

    # the file overrides what git reports, the command line overrides the file
    slug =
        repository !== nothing ? repository :
        !isempty(options.repository) ?
        validate_slug(options.repository, "$OPTIONS_FILE: repository") : repo.slug
    default_branch =
        branch !== nothing ? branch :
        !isempty(options.branch) ? options.branch : repo.branch
    repo = Repository(repo.root, repo.tracked, slug, default_branch, repo.tags)
    if project_file !== nothing
        project_file in repo.tracked ||
            throw(ArgumentError("--project-file '$project_file' is not a tracked file"))
    end
    waivers = copy(options.waive)
    for id in waive
        waivers[id] = "waived on the command line"
    end
    options = RepositoryOptions(
        something(project_file, options.project_file),
        something(platform, options.platform),
        something(platform_logo, options.platform_logo),
        slug,
        default_branch,
        waivers,
    )

    if badges_mode
        badges = expected_badges(repo, settings, options)
        for badge in badges
            println(io, markdown(badge))
        end
        return (; badges, failed = false)
    end

    results = launch_checks(repo, settings, options; only)
    print_results(io, repo, results)
    if verbose
        if isempty(repo.slug)
            println(io, "badges: repository unknown: pass --repository USER/REPO")
        else
            for badge in expected_badges(repo, settings, options)
                println(io, markdown(badge))
            end
        end
    end
    failed = any(r -> r.status == :fail, results)
    return (; results, failed)
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = try
        main(ARGS)
    catch err
        if err isa ArgumentError
            println(stderr, "launch-check: ", err.msg)
            exit(2)
        end
        # not a verdict on the repository: kept apart from the status of a failed check
        showerror(stderr, err, catch_backtrace())
        println(stderr)
        exit(3)
    end
    exit(result !== nothing && result.failed ? 1 : 0)
end
