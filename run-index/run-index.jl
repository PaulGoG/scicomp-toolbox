#!/usr/bin/env julia
# run-index — catalogue of DrWatson-style run directories: what was run, from which commit
# and configuration, on what hardware, how long it took and how much disk it occupies,
# with the runs that need attention flagged and the figures whose run is gone. Read-only.
#
#   julia run.jl run-index [ROOT ...] [--flagged] [--depth N] [--csv FILE | --no-csv]
#                          [--config PATH]

using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)

using Dates: Dates, Date, DateTime, @dateformat_str, now
using PrettyTables: PrettyTables, TextTableFormat, pretty_table, text_table_borders__compact
using Printf: @sprintf
using TOML: TOML

"""
Canonical fields read from a provenance file, with the kind of value each accepts:
`:text` (non-empty string), `:time` (TOML date-time or date, or a string),
`:number` (real), `:scalar` (string or real) or `:table`.
"""
const FIELDS = (
    commit = :text,
    patch = :text,
    script = :text,
    job_id = :scalar,
    started = :time,
    finished = :time,
    wall_time_s = :number,
    hostname = :text,
    cpu = :text,
    gpu = :text,
    julia_version = :text,
    seed = :scalar,
    configuration = :table,
)

const DEFAULT_ALIASES = Dict(
    :commit => ["gitcommit", "commit", "git_commit", "toolbox_commit"],
    :patch => ["gitpatch"],
    :script => ["script"],
    :job_id => ["job_id"],
    :started => ["timestamp", "started", "start_time", "created"],
    :finished => ["finished", "end_time", "completed"],
    :wall_time_s => ["wall_time_s", "elapsed_s", "runtime_s", "duration_s"],
    :hostname => ["hostname", "host"],
    :cpu => ["cpu_model", "cpu"],
    :gpu => ["device_name", "gpu"],
    :julia_version => ["julia_version"],
    :seed => ["seed", "rng_seed", "master_seed"],
    :configuration => ["configuration", "config", "parameters", "params"],
)

const DEFAULT_RUN_ID = "run_[0-9a-f]{8}(?:_r[0-9]+)?"

"""
    IndexSettings

Validated configuration: the run-id pattern (`run_id` unanchored, for figure names;
`run_name` anchored, for directory names), the provenance file names, the names of the
supplementary files read inside a run (submission records), the figure directories and
extensions, the search depth, the key aliases of every field of [`FIELDS`](@ref) as key
paths, and the directory of the CSV index.
"""
struct IndexSettings
    run_id::Regex
    run_name::Regex
    sidecar_names::Vector{String}
    supplementary_names::Vector{String}
    figure_directories::Vector{String}
    figure_extensions::Vector{String}
    max_depth::Int
    aliases::Dict{Symbol, Vector{Vector{String}}}
    csv_directory::String
end

function reject_unknown_keys(table::AbstractDict, known, context::AbstractString)
    for key in keys(table)
        key in known || throw(
            ArgumentError("unknown key '$key' at $context; allowed: $(join(known, ", "))"),
        )
    end
    return nothing
end

function section(raw::AbstractDict, name::AbstractString)
    table = get(raw, name, Dict{String, Any}())
    table isa AbstractDict || throw(ArgumentError("[$name] must be a table"))
    return table
end

function string_list(
    table::AbstractDict,
    key::AbstractString,
    default::Vector{String},
    context::AbstractString;
    nonempty::Bool = false,
)
    value = get(table, key, default)
    (
        value isa AbstractVector &&
        all(item -> item isa AbstractString && !isempty(strip(item)), value)
    ) || throw(ArgumentError("$context.$key must be a list of non-empty strings"))
    (nonempty && isempty(value)) && throw(ArgumentError("$context.$key must not be empty"))
    return String[strip(item) for item in value]
end

"""
    validate_settings(raw::AbstractDict) -> IndexSettings

Enforce the schema of the configuration tables; absent keys take the defaults of the
shipped `config.toml`. Fails with an `ArgumentError` naming the offending key.
"""
function validate_settings(raw::AbstractDict)
    reject_unknown_keys(raw, ("discovery", "fields", "output"), "top level")
    discovery = section(raw, "discovery")
    fields = section(raw, "fields")
    output = section(raw, "output")
    reject_unknown_keys(
        discovery,
        (
            "run_id_pattern",
            "sidecar_names",
            "supplementary_names",
            "figure_directories",
            "figure_extensions",
            "max_depth",
        ),
        "[discovery]",
    )
    reject_unknown_keys(fields, string.(keys(FIELDS)), "[fields]")
    reject_unknown_keys(output, ("csv_directory",), "[output]")

    pattern = get(discovery, "run_id_pattern", DEFAULT_RUN_ID)
    (pattern isa AbstractString && !isempty(pattern)) ||
        throw(ArgumentError("[discovery].run_id_pattern must be a non-empty string"))
    run_id, run_name = try
        Regex(pattern), Regex("^(?:" * pattern * ")\$")
    catch err
        err isa ErrorException || rethrow()
        throw(
            ArgumentError(
                "[discovery].run_id_pattern is not a valid regular expression: $(err.msg)",
            ),
        )
    end
    sidecar_names = string_list(
        discovery,
        "sidecar_names",
        ["provenance.toml", "metadata.toml"],
        "[discovery]";
        nonempty = true,
    )
    supplementary_names =
        string_list(discovery, "supplementary_names", ["submission.toml"], "[discovery]")
    figure_directories =
        string_list(discovery, "figure_directories", ["plots"], "[discovery]")
    figure_extensions = lowercase.(
        string_list(
            discovery,
            "figure_extensions",
            [".pdf", ".png", ".svg"],
            "[discovery]",
        ),
    )
    all(startswith("."), figure_extensions) ||
        throw(ArgumentError("[discovery].figure_extensions entries must start with \".\""))
    max_depth = get(discovery, "max_depth", 8)
    (max_depth isa Integer && !(max_depth isa Bool) && 1 <= max_depth <= 64) || throw(
        ArgumentError(
            "[discovery].max_depth must be an integer in [1, 64], got $(repr(max_depth))",
        ),
    )
    aliases = Dict{Symbol, Vector{Vector{String}}}()
    for field in keys(FIELDS)
        names = string_list(
            fields,
            string(field),
            DEFAULT_ALIASES[field],
            "[fields]";
            nonempty = true,
        )
        paths = [String.(split(name, '.')) for name in names]
        any(path -> any(isempty, path), paths) &&
            throw(ArgumentError("[fields].$field: a key path has an empty component"))
        aliases[field] = paths
    end
    csv_directory = get(output, "csv_directory", "data")
    (csv_directory isa AbstractString && !isempty(strip(csv_directory))) ||
        throw(ArgumentError("[output].csv_directory must be a non-empty string"))
    return IndexSettings(
        run_id,
        run_name,
        sidecar_names,
        supplementary_names,
        figure_directories,
        figure_extensions,
        Int(max_depth),
        aliases,
        String(csv_directory),
    )
end

"""
    load_settings(path::AbstractString) -> IndexSettings

Parse and validate a configuration file.
"""
function load_settings(path::AbstractString)
    isfile(path) || throw(ArgumentError("configuration file not found: $path"))
    raw = try
        TOML.parsefile(path)
    catch err
        err isa TOML.ParserError || rethrow()
        throw(ArgumentError("$path: $(sprint(showerror, err))"))
    end
    return validate_settings(raw)
end

first_line(text::AbstractString) = String(first(split(text, '\n')))

# --- discovery -------------------------------------------------------------------------

"""
    is_run_directory(dir, settings) -> Bool

Whether the whole name of `dir` matches the run-id pattern or `dir` holds a provenance
file.
"""
is_run_directory(dir::AbstractString, settings::IndexSettings) =
    occursin(settings.run_name, basename(dir)) ||
    any(name -> isfile(joinpath(dir, name)), settings.sidecar_names)

"""
    find_runs(root, settings; max_depth = settings.max_depth) -> Vector{String}

Run directories under `root` ([`is_run_directory`](@ref)), sorted. The search does not
descend into a run, into hidden directories or through symbolic links, and stops
`max_depth` levels below `root`; `root` itself may be a run.
"""
function find_runs(
    root::AbstractString,
    settings::IndexSettings;
    max_depth::Int = settings.max_depth,
)
    runs = String[]
    function visit(dir::String, depth::Int)
        if is_run_directory(dir, settings)
            push!(runs, dir)
            return nothing
        end
        depth >= max_depth && return nothing
        entries = try
            readdir(dir)
        catch err
            err isa Base.IOError || rethrow()
            @warn "run-index: cannot list $dir: $(sprint(showerror, err))"
            return nothing
        end
        for entry in entries
            startswith(entry, ".") && continue
            path = joinpath(dir, entry)
            (isdir(path) && !islink(path)) || continue
            visit(path, depth + 1)
        end
        return nothing
    end
    visit(normpath(abspath(root)), 0)
    return sort!(runs)
end

"""
    project_root(run_dir, fallback) -> String

Nearest directory above `run_dir` that holds a `Project.toml` (the DrWatson project),
else the top level of its git repository, else `fallback`.
"""
function project_root(run_dir::AbstractString, fallback::AbstractString)
    dir = dirname(run_dir)
    while true
        isfile(joinpath(dir, "Project.toml")) && return dir
        parent = dirname(dir)
        parent == dir && break
        dir = parent
    end
    top = git(run_dir, "rev-parse", "--show-toplevel")
    return top === nothing ? String(fallback) : top
end

"""
    disk_usage(dir) -> (bytes, files)

Apparent size and number of the regular files below `dir`; symbolic links are neither
followed nor counted.
"""
function disk_usage(dir::AbstractString)
    bytes = 0
    files = 0
    for (root, _, names) in walkdir(dir; follow_symlinks = false)
        for name in names
            path = joinpath(root, name)
            (islink(path) || !isfile(path)) && continue
            bytes += filesize(path)
            files += 1
        end
    end
    return bytes, files
end

# --- provenance ------------------------------------------------------------------------

"""
    read_provenance(dir, settings) -> Vector{@NamedTuple{name, table, problem}}

The provenance files of the run `dir`, in the order they are consulted: the first file
of `sidecar_names` present, then every supplementary file present (a submission record
written when the job was queued). Each comes with its parsed table (`nothing` when it is
not valid TOML) and the first line of the parse error.
"""
function read_provenance(dir::AbstractString, settings::IndexSettings)
    primary = findfirst(name -> isfile(joinpath(dir, name)), settings.sidecar_names)
    names = primary === nothing ? String[] : [settings.sidecar_names[primary]]
    for name in settings.supplementary_names
        (isfile(joinpath(dir, name)) && !(name in names)) && push!(names, name)
    end
    files = @NamedTuple{
        name::String,
        table::Union{Dict{String, Any}, Nothing},
        problem::String,
    }[]
    for name in names
        try
            push!(
                files,
                (; name, table = TOML.parsefile(joinpath(dir, name)), problem = ""),
            )
        catch err
            err isa TOML.ParserError || rethrow()
            push!(
                files,
                (; name, table = nothing, problem = first_line(sprint(showerror, err))),
            )
        end
    end
    return files
end

is_table_array(value) =
    value isa AbstractVector && !isempty(value) && all(v -> v isa AbstractDict, value)

"""
    flatten(table) -> Vector{Pair{Vector{String}, Any}}

Every value of a nested provenance table with its key path, keys in sorted order. Tables
appear themselves and through their entries; the tables of an array are entered with
their 1-based index as a path component.
"""
function flatten(
    table::AbstractDict,
    prefix::Vector{String} = String[],
    out::Vector{Pair{Vector{String}, Any}} = Pair{Vector{String}, Any}[],
)
    for key in sort!(collect(keys(table)))
        path = vcat(prefix, String(key))
        value = table[key]
        push!(out, path => value)
        if value isa AbstractDict
            flatten(value, path, out)
        elseif is_table_array(value)
            for (i, item) in enumerate(value)
                flatten(item, vcat(path, string(i)), out)
            end
        end
    end
    return out
end

ends_with_path(path::Vector{String}, alias::Vector{String}) =
    length(path) >= length(alias) && path[(end - length(alias) + 1):end] == alias

accepts(::Val, value) = false
accepts(::Val{:text}, value::AbstractString) = !isempty(strip(value))
accepts(::Val{:time}, value::Union{DateTime, Date}) = true
accepts(::Val{:time}, value::AbstractString) = !isempty(strip(value))
accepts(::Val{:number}, value::Real) = !(value isa Bool)
accepts(::Val{:scalar}, value::Union{AbstractString, Real}) = !(value isa Bool)
accepts(::Val{:table}, value::AbstractDict) = true

"""
    lookup(entries, aliases, kind::Symbol) -> value or nothing

Value of the first alias that matches the trailing components of a key path in
`entries` ([`flatten`](@ref)) with a value of `kind`; among several matches of one
alias the shallowest, then the first in key order.
"""
function lookup(
    entries::Vector{Pair{Vector{String}, Any}},
    aliases::Vector{Vector{String}},
    kind::Symbol,
)
    for alias in aliases
        best = nothing
        for (path, value) in entries
            (ends_with_path(path, alias) && accepts(Val(kind), value)) || continue
            if best === nothing || length(path) < length(first(best))
                best = path => value
            end
        end
        best === nothing || return last(best)
    end
    return nothing
end

const TIME_FORMATS = (
    Dates.ISODateTimeFormat,
    dateformat"yyyy-mm-dd HH:MM:SS.s",
    dateformat"yyyy-mm-dd HH:MM:SS",
    dateformat"yyyy-mm-dd HH:MM",
    dateformat"yyyy-mm-dd_HH-MM-SS",
    Dates.ISODateFormat,
)

"""
    parse_time(value) -> Union{DateTime, Nothing}

A TOML date-time or date, or a string in ISO 8601 form (`T` or a space between date and
time, optional fraction; a trailing `Z` or UTC offset is dropped and the clock time
taken as written) or in the `yyyy-mm-dd_HH-MM-SS` form of file-name stamps; `nothing`
for anything else.
"""
parse_time(value::DateTime) = value
parse_time(value::Date) = DateTime(value)
parse_time(::Nothing) = nothing
function parse_time(value::AbstractString)
    text = replace(strip(value), r"(?:Z|[+-]\d{2}:?\d{2})$" => "")
    for format in TIME_FORMATS
        parsed = tryparse(DateTime, text, format)
        parsed === nothing || return parsed
    end
    return nothing
end

"""
    commit_reference(text) -> (revision, dirty)

The revision to resolve and whether the recorded commit was marked dirty: a `-dirty` or
`_dirty` suffix (`git describe --dirty`, DrWatson) is removed and reported.
"""
function commit_reference(text::AbstractString)
    revision = String(strip(text))
    m = match(r"^(.+?)[-_]dirty$", revision)
    m === nothing && return (revision, false)
    return (String(m.captures[1]), true)
end

text_value(value::AbstractString) = String(strip(value))
text_value(value::Real) = string(value)
text_value(::Nothing) = ""

# --- git -------------------------------------------------------------------------------

"""
    git(dir, args...) -> Union{String, Nothing}

Standard output of a read-only git command run in `dir`, stripped, or `nothing` when git
is absent or the command fails. Optional locks are disabled, so the index never writes
to a repository.
"""
function git(dir::AbstractString, args::AbstractString...)
    Sys.which("git") === nothing && return nothing
    out = IOBuffer()
    command = `git --no-optional-locks -C $dir $(collect(args))`
    success(pipeline(command; stdout = out, stderr = devnull)) || return nothing
    return String(strip(String(take!(out))))
end

"""
    Repository

Git repository of a project: its top level, the checked-out branch (`"detached"` when
none) and the commit of HEAD (empty in a repository without commits).
"""
struct Repository
    toplevel::String
    branch::String
    head::String
end

function repository(dir::AbstractString)
    toplevel = git(dir, "rev-parse", "--show-toplevel")
    toplevel === nothing && return nothing
    head = something(git(toplevel, "rev-parse", "--verify", "--quiet", "HEAD"), "")
    branch =
        something(git(toplevel, "symbolic-ref", "--quiet", "--short", "HEAD"), "detached")
    return Repository(toplevel, branch, head)
end

"""
    resolve_commit(repo, revision) -> Union{String, Nothing}

Full hash of `revision` (a hash, a tag or `git describe` output) in `repo`, or `nothing`
when the repository does not know it. Revisions that git could read as an option are
refused.
"""
function resolve_commit(repo::Repository, revision::AbstractString)
    (isempty(revision) || startswith(revision, "-") || occursin(r"\s", revision)) &&
        return nothing
    return git(repo.toplevel, "rev-parse", "--verify", "--quiet", revision * "^{commit}")
end

"""
    on_head(repo, hash) -> Union{Bool, Nothing}

Whether commit `hash` is HEAD or one of its ancestors; `nothing` when the repository has
no HEAD or git cannot decide.
"""
function on_head(repo::Repository, hash::AbstractString)
    isempty(repo.head) && return nothing
    Sys.which("git") === nothing && return nothing
    command = `git --no-optional-locks -C $(repo.toplevel) merge-base --is-ancestor $hash HEAD`
    process = run(pipeline(ignorestatus(command); stdout = devnull, stderr = devnull))
    process.exitcode == 0 && return true
    process.exitcode == 1 && return false
    return nothing
end

# --- index -----------------------------------------------------------------------------

"""
    RunRecord

One indexed run directory: its project, its path relative to the project root and in
full, what its provenance files state (`provenance` lists them, separated by `;`), what
git says about its commit, its disk usage, its replicate group and its flags. Absent text is empty, an absent wall time `NaN`;
`on_head` is `nothing` when the ancestry of the commit was not decided.
"""
struct RunRecord
    project::String
    project_root::String
    run::String
    path::String
    provenance::String
    started::Union{DateTime, Nothing}
    finished::Union{DateTime, Nothing}
    wall_time_s::Float64
    commit::String
    resolved_commit::String
    dirty::Bool
    on_head::Union{Bool, Nothing}
    script::String
    job_id::String
    hostname::String
    cpu::String
    gpu::String
    julia_version::String
    seed::String
    size_bytes::Int
    files::Int
    group::String
    flags::Vector{String}
end

"""
    ProjectSummary

A project holding indexed runs: name, root, git repository (`nothing` outside one), and
the number, total size and number of flagged runs.
"""
struct ProjectSummary
    name::String
    root::String
    repository::Union{Repository, Nothing}
    runs::Int
    size_bytes::Int
    flagged::Int
end

"""
    OrphanFigure

A figure under a project's figure directories whose file name carries a run id with no
run directory in that project.
"""
struct OrphanFigure
    project::String
    path::String
    run_id::String
end

"""
Flags of the index, in reporting order:

- `no-provenance`: no provenance file; nothing else can be said about the run.
- `unreadable-provenance`: the provenance file is not valid TOML.
- `no-commit`: the provenance file records no commit.
- `no-repository`: a commit is recorded but the run lies in no git repository.
- `unknown-commit`: the repository does not know the recorded commit.
- `off-head`: the commit is not HEAD or an ancestor of it, so the checked-out code may
  not reproduce the run.
- `dirty`: the commit was recorded with uncommitted changes (a `dirty` suffix or a patch).
- `seed-replicate`: another run of the project has the same configuration apart from the
  seed.
- `repeat`: another run of the project has the same configuration and seed.
"""
const FLAGS = (
    "no-provenance",
    "unreadable-provenance",
    "no-commit",
    "no-repository",
    "unknown-commit",
    "off-head",
    "dirty",
    "seed-replicate",
    "repeat",
)

"""
    canonical_configuration(table, seed_aliases) -> Vector{Pair{String, String}}

The leaves of a configuration table as sorted `dotted.key => repr(value)` pairs, the
seed keys left out, so that runs differing only in seed compare equal.
"""
function canonical_configuration(table::AbstractDict, seed_aliases::Vector{Vector{String}})
    entries = Pair{String, String}[]
    for (path, value) in flatten(table)
        (value isa AbstractDict || is_table_array(value)) && continue
        any(alias -> ends_with_path(path, alias), seed_aliases) && continue
        push!(entries, join(path, ".") => repr(value))
    end
    return sort!(entries)
end

"""
    build_index(roots, settings; max_depth = settings.max_depth)
        -> (; records, projects, orphans)

Find, read and assess the run directories under `roots`. Records are sorted by project,
then start time (runs without one last), then path; replicate groups are labelled `G1`,
`G2`, ... in that order.
"""
function build_index(
    roots::AbstractVector{<:AbstractString},
    settings::IndexSettings;
    max_depth::Int = settings.max_depth,
)
    located = Dict{String, String}()
    for root in roots, run in find_runs(root, settings; max_depth)
        haskey(located, run) || (located[run] = normpath(abspath(root)))
    end
    repositories = Dict{String, Union{Repository, Nothing}}()
    resolved = Dict{Tuple{String, String}, Union{String, Nothing}}()
    ancestry = Dict{Tuple{String, String}, Union{Bool, Nothing}}()
    drafts = NamedTuple[]
    for run in sort!(collect(keys(located)))
        root = project_root(run, located[run])
        repo = get!(() -> repository(run), repositories, root)
        sources = read_provenance(run, settings)
        flags = String[]
        isempty(sources) && push!(flags, "no-provenance")
        any(f -> f.table === nothing, sources) && push!(flags, "unreadable-provenance")
        entry_sets = [flatten(f.table) for f in sources if f.table !== nothing]
        # a field comes from the first provenance file that has it
        function field(name)
            for entries in entry_sets
                value = lookup(entries, settings.aliases[name], FIELDS[name])
                value === nothing || return value
            end
            return nothing
        end
        commit = text_value(field(:commit))
        revision, dirty = commit_reference(commit)
        dirty |= !isempty(text_value(field(:patch)))
        hash = ""
        head = nothing
        if !isempty(entry_sets)
            if isempty(commit)
                push!(flags, "no-commit")
            elseif repo === nothing
                push!(flags, "no-repository")
            else
                full = get!(
                    () -> resolve_commit(repo, revision),
                    resolved,
                    (repo.toplevel, revision),
                )
                if full === nothing
                    push!(flags, "unknown-commit")
                else
                    hash = full
                    head = get!(() -> on_head(repo, full), ancestry, (repo.toplevel, full))
                    head === false && push!(flags, "off-head")
                end
            end
            dirty && push!(flags, "dirty")
        end
        started = parse_time(field(:started))
        finished = parse_time(field(:finished))
        wall = field(:wall_time_s)
        wall_time_s =
            wall !== nothing ? Float64(wall) :
            (started !== nothing && finished !== nothing && finished >= started) ?
            Dates.value(finished - started) / 1e3 : NaN
        configuration = field(:configuration)
        bytes, files = disk_usage(run)
        push!(
            drafts,
            (;
                project = basename(root),
                project_root = root,
                run = relpath(run, root),
                path = run,
                provenance = join((f.name for f in sources), ";"),
                started,
                finished,
                wall_time_s,
                commit,
                resolved_commit = hash,
                dirty,
                on_head = head,
                script = text_value(field(:script)),
                job_id = text_value(field(:job_id)),
                hostname = text_value(field(:hostname)),
                cpu = text_value(field(:cpu)),
                gpu = text_value(field(:gpu)),
                julia_version = text_value(field(:julia_version)),
                seed = text_value(field(:seed)),
                size_bytes = bytes,
                files,
                flags,
                configuration = configuration === nothing ? nothing :
                                canonical_configuration(
                    configuration,
                    settings.aliases[:seed],
                ),
            ),
        )
    end
    sort!(
        drafts;
        by = d -> (
            d.project_root,
            d.started === nothing,
            something(d.started, DateTime(0)),
            d.run,
        ),
    )

    # replicate groups: runs of one project with equal configurations apart from the seed
    members = Dict{Tuple{String, Vector{Pair{String, String}}}, Vector{Int}}()
    for (i, d) in enumerate(drafts)
        d.configuration === nothing && continue
        push!(get!(members, (d.project_root, d.configuration), Int[]), i)
    end
    labels = fill("", length(drafts))
    n_groups = 0
    for i in eachindex(drafts)
        d = drafts[i]
        (d.configuration === nothing || !isempty(labels[i])) && continue
        group = members[(d.project_root, d.configuration)]
        length(group) >= 2 || continue
        n_groups += 1
        seeds = [drafts[j].seed for j in group]
        replicated = length(unique(seeds)) >= 2
        for (j, seed) in zip(group, seeds)
            labels[j] = "G$n_groups"
            replicated && push!(drafts[j].flags, "seed-replicate")
            Base.count(==(seed), seeds) >= 2 && push!(drafts[j].flags, "repeat")
        end
    end

    records = RunRecord[
        RunRecord(
            d.project,
            d.project_root,
            d.run,
            d.path,
            d.provenance,
            d.started,
            d.finished,
            d.wall_time_s,
            d.commit,
            d.resolved_commit,
            d.dirty,
            d.on_head,
            d.script,
            d.job_id,
            d.hostname,
            d.cpu,
            d.gpu,
            d.julia_version,
            d.seed,
            d.size_bytes,
            d.files,
            labels[i],
            d.flags,
        ) for (i, d) in enumerate(drafts)
    ]
    projects = ProjectSummary[]
    for root in unique(r.project_root for r in records)
        rows = filter(r -> r.project_root == root, records)
        push!(
            projects,
            ProjectSummary(
                basename(root),
                root,
                repositories[root],
                length(rows),
                sum(r.size_bytes for r in rows),
                Base.count(r -> !isempty(r.flags), rows),
            ),
        )
    end
    return (; records, projects, orphans = orphan_figures(records, projects, settings))
end

"""
    orphan_figures(records, projects, settings) -> Vector{OrphanFigure}

Figures under the figure directories of every project whose file name carries a run id
that no run directory of the project has, sorted by project and path.
"""
function orphan_figures(
    records::Vector{RunRecord},
    projects::Vector{ProjectSummary},
    settings::IndexSettings,
)
    orphans = OrphanFigure[]
    for project in projects
        ids = Set(basename(r.path) for r in records if r.project_root == project.root)
        for directory in settings.figure_directories
            top = joinpath(project.root, directory)
            isdir(top) || continue
            for (dir, _, names) in walkdir(top; follow_symlinks = false)
                for name in sort(names)
                    lowercase(splitext(name)[2]) in settings.figure_extensions || continue
                    m = match(settings.run_id, name)
                    (m === nothing || m.match in ids) && continue
                    path = relpath(joinpath(dir, name), project.root)
                    push!(orphans, OrphanFigure(project.name, path, String(m.match)))
                end
            end
        end
    end
    return sort!(orphans; by = f -> (f.project, f.path))
end

# --- output ----------------------------------------------------------------------------

function format_bytes(bytes::Integer)
    bytes < 1024 && return @sprintf("%d B", bytes)
    value = float(bytes)
    for unit in ("KiB", "MiB", "GiB", "TiB")
        value /= 1024
        value < 1024 && return @sprintf("%.2f %s", value, unit)
    end
    return @sprintf("%.2f PiB", value / 1024)
end

"""
    format_duration(seconds) -> String

`12.3 s`, `4m 05s`, `2h 07m` or `3d 04h`; `-` for an undefined duration.
"""
function format_duration(seconds::Real)
    (isfinite(seconds) && seconds >= 0) || return "-"
    seconds < 60 && return @sprintf("%.1f s", seconds)
    minutes = floor(Int, seconds / 60)
    minutes < 60 &&
        return @sprintf("%dm %02ds", minutes, floor(Int, seconds - 60 * minutes))
    hours = minutes ÷ 60
    hours < 48 && return @sprintf("%dh %02dm", hours, minutes % 60)
    return @sprintf("%dd %02dh", hours ÷ 24, hours % 24)
end

counted(n::Integer, noun::AbstractString) = n == 1 ? "1 $noun" : "$n $(noun)s"

format_time(::Nothing) = "-"
format_time(time::DateTime) = Dates.format(time, "yyyy-mm-dd HH:MM")

function short_commit(record::RunRecord)
    isempty(record.resolved_commit) || return first(record.resolved_commit, 8)
    isempty(record.commit) && return "-"
    return length(record.commit) > 12 ? first(record.commit, 11) * "…" : record.commit
end

const COLUMN_LABELS = ["run", "started", "wall", "commit", "host", "size", "group", "flags"]
const ALIGNMENT = [:l, :l, :r, :l, :l, :r, :l, :l]
const TABLE_FORMAT = TextTableFormat(;
    borders = text_table_borders__compact,
    horizontal_line_at_beginning = false,
    horizontal_line_after_data_rows = false,
    vertical_line_at_beginning = false,
    vertical_lines_at_data_columns = :none,
    vertical_line_after_data_columns = false,
)

function table_rows(records::Vector{RunRecord})
    rows = Matrix{String}(undef, length(records), length(COLUMN_LABELS))
    for (i, r) in enumerate(records)
        rows[i, :] = [
            r.run,
            format_time(r.started),
            format_duration(r.wall_time_s),
            short_commit(r),
            isempty(r.hostname) ? "-" : r.hostname,
            format_bytes(r.size_bytes),
            r.group,
            join(r.flags, ", "),
        ]
    end
    return rows
end

function project_heading(project::ProjectSummary)
    repo = project.repository
    where =
        repo === nothing ? "no git repository" :
        isempty(repo.head) ? "git $(repo.branch), no commits" :
        "git $(repo.branch) at $(first(repo.head, 8))"
    return "$(project.name)  $(project.root)  ($where; $(counted(project.runs, "run")), $(format_bytes(project.size_bytes)), $(project.flagged) flagged)"
end

"""
    print_report(io, index; flagged_only = false)

Summary line, one table per project (only the flagged runs with `flagged_only`), the
replicate groups and the figures whose run has no directory.
"""
function print_report(io::IO, index; flagged_only::Bool = false)
    records = index.records
    total = sum((r.size_bytes for r in records); init = 0)
    flagged = Base.count(r -> !isempty(r.flags), records)
    println(
        io,
        "$(counted(length(records), "run")) in $(counted(length(index.projects), "project")), $(format_bytes(total)), $flagged flagged",
    )
    for project in index.projects
        rows = filter(records) do r
            r.project_root == project.root && (!flagged_only || !isempty(r.flags))
        end
        isempty(rows) && continue
        println(io)
        println(io, project_heading(project))
        pretty_table(
            io,
            table_rows(rows);
            column_labels = COLUMN_LABELS,
            alignment = ALIGNMENT,
            table_format = TABLE_FORMAT,
            fit_table_in_display_horizontally = false,
            fit_table_in_display_vertically = false,
        )
    end
    labels = unique(r.group for r in records if !isempty(r.group))
    if !isempty(labels)
        println(io)
        println(io, "Replicate groups (equal configuration apart from the seed)")
        for label in labels
            members = filter(r -> r.group == label, records)
            runs = join(
                [isempty(r.seed) ? r.run : "$(r.run) (seed $(r.seed))" for r in members],
                ", ",
            )
            println(io, "  $label  $(first(members).project): $runs")
        end
    end
    if !isempty(index.orphans)
        println(io)
        println(io, "Figures whose run has no directory")
        for figure in index.orphans
            println(io, "  $(figure.project): $(figure.path) ($(figure.run_id))")
        end
    end
    return nothing
end

csv_cell(value::AbstractString) = "\"" * replace(value, "\"" => "\"\"") * "\""
csv_cell(value::Bool) = string(value)
csv_cell(value::Integer) = string(value)
csv_cell(value::AbstractFloat) = isfinite(value) ? @sprintf("%.6g", value) : ""
csv_cell(value::DateTime) = Dates.format(value, "yyyy-mm-ddTHH:MM:SS")
csv_cell(::Nothing) = ""
csv_cell(value::Vector{String}) = csv_cell(join(value, ";"))

"Columns of the CSV index: the fields of [`RunRecord`](@ref) in order."
csv_header() = join(string.(fieldnames(RunRecord)), ",")

"""
    write_csv(path, records) -> path

The index as a tidy CSV file, one row per run; flags are joined by `;`.
"""
function write_csv(path::AbstractString, records::Vector{RunRecord})
    open(path, "w") do io
        println(io, csv_header())
        for record in records
            println(
                io,
                join((csv_cell(getfield(record, f)) for f in fieldnames(RunRecord)), ","),
            )
        end
    end
    return path
end

"""
    safe_filepath(path) -> String

`path` when no file exists there, otherwise the first free `stem#k.ext`.
"""
function safe_filepath(path::AbstractString)
    isfile(path) || return String(path)
    stem, extension = splitext(basename(path))
    k = 1
    while true
        candidate = joinpath(dirname(path), "$(stem)#$(k)$(extension)")
        isfile(candidate) || return candidate
        k += 1
    end
end

function usage(io::IO = stdout)
    print(
        io,
        """
        run-index — catalogue of DrWatson-style run directories

        Usage:
          julia run.jl run-index [ROOT ...] [options]

          ROOT ...            directories searched for runs (default: the working directory);
                              relative paths resolve against the working directory
          --flagged           list only the runs that carry a flag
          --depth N           directory levels searched below each root (default: [discovery].max_depth)
          --csv FILE          write the index to FILE (default: run_index_<stamp>.csv in [output].csv_directory)
          --no-csv            write no CSV file
          --config PATH       configuration file (default: config.toml next to the tool)
          -h, --help

        Flags: $(join(FLAGS, ", ")).
        """,
    )
    return nothing
end

"""
    main(args = ARGS; io = stdout) -> Union{NamedTuple, Nothing}

Parse the command line, build the index of every root, print the report to `io` and
write the CSV index; returns the index with the CSV path (`nothing` when none was
written), or `nothing` after `--help`.
"""
function main(args::Vector{String} = ARGS; io::IO = stdout)
    config_path = joinpath(@__DIR__, "config.toml")
    roots = String[]
    flagged_only = false
    depth = nothing
    csv = ""
    write_index = true
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
        elseif argument == "--flagged"
            flagged_only = true
        elseif argument == "--depth"
            text = value_of(argument)
            depth = tryparse(Int, text)
            (depth === nothing || !(1 <= depth <= 64)) &&
                throw(ArgumentError("--depth must be an integer in [1, 64], got '$text'"))
        elseif argument == "--csv"
            csv = value_of(argument)
        elseif argument == "--no-csv"
            write_index = false
        elseif argument == "--config"
            config_path = value_of(argument)
        elseif startswith(argument, "-")
            throw(ArgumentError("unknown command-line argument '$argument'; see --help"))
        else
            push!(roots, argument)
        end
        i += 1
    end
    settings = load_settings(config_path)
    isempty(roots) && push!(roots, pwd())
    for root in roots
        isdir(root) || throw(ArgumentError("not a directory: $root"))
    end
    index = build_index(
        [normpath(abspath(root)) for root in roots],
        settings;
        max_depth = something(depth, settings.max_depth),
    )
    if isempty(index.records)
        println(io, "No run directories under ", join(abspath.(roots), ", "), ".")
        return merge(index, (; csv = nothing))
    end
    print_report(io, index; flagged_only)
    path = nothing
    if write_index
        resolve(dir) = isabspath(dir) ? dir : normpath(joinpath(@__DIR__, dir))
        target =
            isempty(csv) ?
            joinpath(
                resolve(settings.csv_directory),
                "run_index_$(Dates.format(now(), "yyyy-mm-dd_HH-MM-SS")).csv",
            ) : abspath(csv)
        mkpath(dirname(target))
        path = write_csv(safe_filepath(target), index.records)
        println(io)
        println(io, "Index written to ", path)
    end
    return merge(index, (; csv = path))
end

if abspath(PROGRAM_FILE) == @__FILE__
    try
        main(ARGS)
    catch err
        err isa ArgumentError || rethrow()
        println(stderr, "run-index: ", err.msg)
        exit(2)
    end
end
