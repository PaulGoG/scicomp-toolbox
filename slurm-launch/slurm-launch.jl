#!/usr/bin/env julia
# slurm-launch — job scripts for Julia pipelines and for wrapped native launch scripts,
# with the resource request derived from the run's own configuration; submission,
# status, cancellation and fetch hints, on a Slurm cluster or as a detached local run.
#
#   julia run.jl slurm-launch [generate|submit] [--payload julia|launcher] [options]
#   julia run.jl slurm-launch status|cancel|fetch RECORD ...

using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)

using Dates: Dates, DateTime, now
using Printf: @sprintf
using SHA: sha256
using TOML: TOML

const BACKENDS = ("local", "slurm")
const PAYLOADS = ("julia", "launcher")
const VERBS = ("generate", "submit", "status", "cancel", "fetch")
const MAIL_TYPES = (
    "NONE",
    "BEGIN",
    "END",
    "FAIL",
    "REQUEUE",
    "ALL",
    "INVALID_DEPEND",
    "STAGE_OUT",
    "TIME_LIMIT",
    "TIME_LIMIT_90",
    "TIME_LIMIT_80",
    "TIME_LIMIT_50",
    "ARRAY_TASKS",
)
const RECORD_NAME = "submission.toml"

"""
Quantities read from the run configuration per payload, each through one or more dotted
keys; `memory_gb` takes the largest of the values present.
"""
const DERIVATION_KEYS = Dict(
    "julia" => (
        threads = ["hardware.max_threads"],
        heap_size_hint_gb = ["hardware.heap_size_hint_gb"],
        memory_gb = ["hardware.heap_size_hint_gb", "safety.max_ram_gb"],
        gpu_backend = ["hardware.gpu_backend"],
        max_vram_gb = ["safety.max_vram_gb"],
    ),
    "launcher" => (
        mpi = ["build.enable_mpi"],
        tasks = ["simulation.mpi_ranks"],
        threads = ["simulation.omp_threads"],
        gpu = ["build.enable_gpu"],
        memory_gb = ["safety.max_ram_gb"],
    ),
)

# --- settings --------------------------------------------------------------------------

"""
    Cluster

Site settings of one Slurm cluster, none of which can be derived from a run: partition,
account, QoS, wall-clock limit, the Julia command and the setup lines (`module load`,
juliaup) on the cluster, the directory holding the deployed projects, a constraint, the
mail policy, the GPU types with their memory [GB] in ascending order, and verbatim extra
directives.
"""
struct Cluster
    name::String
    partition::String
    account::String
    qos::String
    time_limit::String
    julia::String
    setup::Vector{String}
    remote_root::String
    constraint::String
    mail_type::String
    mail_user::String
    gpu_types::Vector{Pair{String, Float64}}
    directives::Vector{String}
end

"""
    LaunchSettings

Validated configuration of the tool: default backend and cluster, the Julia command,
the job and log directories (relative to a project root), the memory margin, the fetch
template, the derivation keys per payload and the clusters.
"""
struct LaunchSettings
    backend::String
    cluster::String
    julia::String
    job_directory::String
    log_directory::String
    memory_margin::Float64
    fetch_command::String
    derivation::Dict{String, Dict{Symbol, Vector{String}}}
    clusters::Dict{String, Cluster}
end

function reject_unknown_keys(table::AbstractDict, known, context::AbstractString)
    for key in keys(table)
        key in known || throw(
            ArgumentError("unknown key '$key' at $context; allowed: $(join(known, ", "))"),
        )
    end
    return nothing
end

function section(raw::AbstractDict, name::AbstractString, context::AbstractString)
    table = get(raw, name, Dict{String, Any}())
    table isa AbstractDict || throw(ArgumentError("$context must be a table"))
    return table
end

function get_string(
    table::AbstractDict,
    key::AbstractString,
    default::AbstractString,
    context::AbstractString;
    nonempty::Bool = false,
)
    value = get(table, key, default)
    value isa AbstractString ||
        throw(ArgumentError("$context.$key must be a string, got $(repr(value))"))
    (nonempty && isempty(strip(value))) &&
        throw(ArgumentError("$context.$key must not be empty"))
    return String(strip(value))
end

function get_strings(
    table::AbstractDict,
    key::AbstractString,
    default::Vector{String},
    context::AbstractString,
)
    value = get(table, key, default)
    (value isa AbstractVector && all(v -> v isa AbstractString, value)) ||
        throw(ArgumentError("$context.$key must be a list of strings"))
    return String[strip(v) for v in value]
end

"Single-quote `text` for the shell unless it consists of safe characters only."
shell_quote(text::AbstractString) =
    occursin(r"^[A-Za-z0-9_./=:@%+,-]+$", text) ? String(text) :
    "'" * replace(text, "'" => "'\\''") * "'"

function dotted_keys(value, context::AbstractString)
    keys = value isa AbstractString ? [value] : value
    (
        keys isa AbstractVector &&
        !isempty(keys) &&
        all(k -> k isa AbstractString && !isempty(k) && all(!isempty, split(k, '.')), keys)
    ) || throw(
        ArgumentError(
            "$context must be a dotted key or a non-empty list of them, got $(repr(value))",
        ),
    )
    return String.(keys)
end

function validate_cluster(name::AbstractString, table)
    context = "[clusters.$name]"
    table isa AbstractDict || throw(ArgumentError("$context must be a table"))
    reject_unknown_keys(
        table,
        (
            "partition",
            "account",
            "qos",
            "time_limit",
            "julia",
            "setup",
            "remote_root",
            "constraint",
            "mail_type",
            "mail_user",
            "gpu_types",
            "directives",
        ),
        context,
    )
    occursin(r"^[A-Za-z0-9_.-]+$", name) || throw(
        ArgumentError("$context: a cluster name may hold letters, digits and _.- only"),
    )
    partition = get_string(table, "partition", "", context; nonempty = true)
    time_limit = get_string(table, "time_limit", "", context; nonempty = true)
    occursin(r"^(?:\d+-)?\d{1,2}:\d{2}:\d{2}$", time_limit) || throw(
        ArgumentError("$context.time_limit must read [D-]HH:MM:SS, got '$time_limit'"),
    )
    remote_root = get_string(table, "remote_root", "", context)
    (isempty(remote_root) || startswith(remote_root, "/")) ||
        throw(ArgumentError("$context.remote_root must be an absolute path"))
    mail_type = uppercase(get_string(table, "mail_type", "", context))
    for item in split(mail_type, ','; keepempty = false)
        item in MAIL_TYPES || throw(
            ArgumentError(
                "$context.mail_type entry '$item' is not one of: $(join(MAIL_TYPES, " | "))",
            ),
        )
    end
    gpu_table = get(table, "gpu_types", Dict{String, Any}())
    (
        gpu_table isa AbstractDict &&
        all(v -> v isa Real && !(v isa Bool) && v > 0, values(gpu_table))
    ) || throw(
        ArgumentError(
            "$context.gpu_types must map GPU type names to their memory in GB (> 0)",
        ),
    )
    gpu_types = sort!(
        [String(k) => Float64(v) for (k, v) in gpu_table];
        by = p -> (last(p), first(p)),
    )
    directives = get_strings(table, "directives", String[], context)
    all(d -> startswith(d, "--") && !occursin(r"\s", d), directives) || throw(
        ArgumentError(
            "$context.directives entries must be single sbatch options such as \"--exclusive\"",
        ),
    )
    account = get_string(table, "account", "", context)
    qos = get_string(table, "qos", "", context)
    any(field -> occursin(r"\s", field), (partition, account, qos)) &&
        throw(ArgumentError("$context: partition, account and qos may not hold spaces"))
    return Cluster(
        String(name),
        partition,
        account,
        qos,
        time_limit,
        get_string(table, "julia", "", context),
        get_strings(table, "setup", String[], context),
        remote_root,
        get_string(table, "constraint", "", context),
        mail_type,
        get_string(table, "mail_user", "", context),
        gpu_types,
        directives,
    )
end

"""
    validate_settings(raw::AbstractDict) -> LaunchSettings

Enforce the schema of the configuration tables; absent keys take the defaults of the
shipped `config.toml`. Fails with an `ArgumentError` naming the offending key.
"""
function validate_settings(raw::AbstractDict)
    reject_unknown_keys(raw, ("defaults", "derivation", "clusters"), "top level")
    defaults = section(raw, "defaults", "[defaults]")
    derivation = section(raw, "derivation", "[derivation]")
    clusters = section(raw, "clusters", "[clusters]")
    reject_unknown_keys(
        defaults,
        (
            "backend",
            "cluster",
            "julia",
            "job_directory",
            "log_directory",
            "memory_margin",
            "fetch_command",
        ),
        "[defaults]",
    )
    reject_unknown_keys(derivation, PAYLOADS, "[derivation]")

    backend = lowercase(get_string(defaults, "backend", "local", "[defaults]"))
    backend in BACKENDS || throw(
        ArgumentError(
            "[defaults].backend must be one of: $(join(BACKENDS, " | ")), got '$backend'",
        ),
    )
    margin = get(defaults, "memory_margin", 0.2)
    (margin isa Real && !(margin isa Bool) && 0 <= margin <= 1) || throw(
        ArgumentError(
            "[defaults].memory_margin must be a number in [0, 1], got $(repr(margin))",
        ),
    )
    directories =
        map(("job_directory" => "jobs", "log_directory" => "data/logs")) do (key, default)
            path = get_string(defaults, key, default, "[defaults]"; nonempty = true)
            (
                isabspath(path) ||
                startswith(normpath(path), "..") ||
                occursin(r"\s", path)
            ) && throw(
                ArgumentError(
                    "[defaults].$key must be a relative path inside the project, without spaces",
                ),
            )
            normpath(path)
        end

    keys_per_payload = Dict{String, Dict{Symbol, Vector{String}}}()
    for payload in PAYLOADS
        table = section(derivation, payload, "[derivation.$payload]")
        defaults_of = DERIVATION_KEYS[payload]
        reject_unknown_keys(table, string.(keys(defaults_of)), "[derivation.$payload]")
        keys_per_payload[payload] = Dict(
            quantity => dotted_keys(
                get(table, string(quantity), default),
                "[derivation.$payload].$quantity",
            ) for (quantity, default) in pairs(defaults_of)
        )
    end

    parsed =
        Dict(String(name) => validate_cluster(name, table) for (name, table) in clusters)
    cluster = get_string(defaults, "cluster", "", "[defaults]")
    (isempty(cluster) || haskey(parsed, cluster)) || throw(
        ArgumentError("[defaults].cluster '$cluster' has no [clusters.$cluster] table"),
    )
    return LaunchSettings(
        backend,
        cluster,
        get_string(defaults, "julia", "julia", "[defaults]"; nonempty = true),
        directories[1],
        directories[2],
        Float64(margin),
        get_string(defaults, "fetch_command", "", "[defaults]"),
        keys_per_payload,
        parsed,
    )
end

"""
    load_settings(path::AbstractString) -> LaunchSettings

Parse and validate a configuration file of the tool.
"""
function load_settings(path::AbstractString)
    isfile(path) || throw(ArgumentError("configuration file not found: $path"))
    return validate_settings(parse_toml(path))
end

function parse_toml(path::AbstractString)
    try
        return TOML.parsefile(path)
    catch err
        err isa TOML.ParserError || rethrow()
        throw(ArgumentError("$path: $(sprint(showerror, err))"))
    end
end

# --- resources -------------------------------------------------------------------------

"""
    config_value(config, key) -> value or nothing

Value at the dotted `key` of a parsed run configuration; `nothing` when a component is
absent.
"""
function config_value(config::AbstractDict, key::AbstractString)
    value = config
    for part in split(key, '.')
        (value isa AbstractDict && haskey(value, part)) || return nothing
        value = value[part]
    end
    return value
end

function first_value(config::AbstractDict, keys::Vector{String})
    for key in keys
        value = config_value(config, key)
        value === nothing || return key => value
    end
    return nothing
end

is_count(value) = value isa Integer && !(value isa Bool) && value >= 1
is_positive(value) = value isa Real && !(value isa Bool) && value > 0

"""
    Resources

Request of one run: CPUs per task and tasks (0 CPUs: not requested), memory [GB]
(0: not requested), GPUs with their type, and for the Julia payload the values of
`--threads` and `--heap-size-hint`. `notes` say what could not be derived.
"""
struct Resources
    cpus_per_task::Int
    tasks::Int
    memory_gb::Int
    gpus::Int
    gpu_type::String
    threads::String
    heap_size_hint::String
    notes::Vector{String}
end

"""
    heap_hint(gb) -> String

Value of Julia's `--heap-size-hint`: whole gigabytes as `<n>G`, other amounts in MiB.
"""
heap_hint(gb::Real) = isinteger(gb) ? "$(Int(gb))G" : "$(max(1, round(Int, 1024 * gb)))M"

function memory_request(config, keys, settings, source, notes)
    values = Float64[]
    for key in keys
        value = config_value(config, key)
        value === nothing && continue
        is_positive(value) || throw(
            ArgumentError(
                "$source: $key must be a positive number [GB], got $(repr(value))",
            ),
        )
        push!(values, value)
    end
    if isempty(values)
        push!(
            notes,
            "no $(join(keys, " or ")) in $source: --mem omitted, the partition default applies",
        )
        return 0
    end
    return ceil(Int, maximum(values) * (1 + settings.memory_margin))
end

function gpu_type(cluster, config, keys, source, notes)
    (cluster === nothing || isempty(cluster.gpu_types)) && return ""
    found = first_value(config, keys)
    if found === nothing
        push!(notes, "no $(join(keys, " or ")) in $source: any GPU type of $(cluster.name)")
        return ""
    end
    key, vram = found
    is_positive(vram) || throw(
        ArgumentError("$source: $key must be a positive number [GB], got $(repr(vram))"),
    )
    for (name, memory) in cluster.gpu_types
        memory >= vram && return name
    end
    throw(
        ArgumentError(
            "$source: $key = $vram GB exceeds every GPU type of $(cluster.name) ($(join(("$n: $(m) GB" for (n, m) in cluster.gpu_types), ", ")))",
        ),
    )
end

"""
    derive_resources(payload, config, source, settings, backend, cluster) -> Resources

The request of one run, read from its parsed configuration `config` (file `source`)
through the derivation keys of `payload`. Nothing is invented: a quantity the slurm
backend needs and the configuration lacks is an error naming the key, and an optional
one that is absent is left to the site default with a note.
"""
function derive_resources(
    payload::AbstractString,
    config::AbstractDict,
    source::AbstractString,
    settings::LaunchSettings,
    backend::AbstractString,
    cluster::Union{Cluster, Nothing},
)
    keys = settings.derivation[payload]
    notes = String[]
    slurm = backend == "slurm"
    if payload == "julia"
        found = first_value(config, keys[:threads])
        if found === nothing || last(found) == "auto"
            slurm && throw(
                ArgumentError(
                    "$source: $(found === nothing ? "no " * join(keys[:threads], " or ") : first(found) * " = \"auto\""); the slurm backend derives --cpus-per-task from an integer",
                ),
            )
            threads, cpus = "auto", 0
        elseif is_count(last(found))
            threads, cpus = string(last(found)), Int(last(found))
        else
            throw(
                ArgumentError(
                    "$source: $(first(found)) must be an integer >= 1 or \"auto\", got $(repr(last(found)))",
                ),
            )
        end
        heap = first_value(config, keys[:heap_size_hint_gb])
        heap === nothing ||
            is_positive(last(heap)) ||
            throw(
                ArgumentError(
                    "$source: $(first(heap)) must be a positive number [GB], got $(repr(last(heap)))",
                ),
            )
        backend_value = first_value(config, keys[:gpu_backend])
        backend_value === nothing ||
            last(backend_value) isa AbstractString ||
            throw(ArgumentError("$source: $(first(backend_value)) must be a string"))
        gpus = backend_value !== nothing && lowercase(last(backend_value)) != "none" ? 1 : 0
        memory =
            slurm ? memory_request(config, keys[:memory_gb], settings, source, notes) : 0
        type =
            gpus > 0 && slurm ?
            gpu_type(cluster, config, keys[:max_vram_gb], source, notes) : ""
        return Resources(
            cpus,
            1,
            memory,
            gpus,
            type,
            threads,
            heap === nothing ? "" : heap_hint(last(heap)),
            notes,
        )
    end
    flag(name) = begin
        found = first_value(config, keys[name])
        found === nothing && return false
        last(found) isa Bool ||
            throw(ArgumentError("$source: $(first(found)) must be a boolean"))
        last(found)
    end
    tasks = 1
    if flag(:mpi)
        found = first_value(config, keys[:tasks])
        (found !== nothing && is_count(last(found))) || throw(
            ArgumentError(
                "$source: MPI is enabled but $(join(keys[:tasks], " or ")) is not an integer >= 1",
            ),
        )
        tasks = Int(last(found))
    end
    threads = first_value(config, keys[:threads])
    if threads === nothing
        slurm && throw(
            ArgumentError(
                "$source: no $(join(keys[:threads], " or ")); the slurm backend derives --cpus-per-task from it",
            ),
        )
        cpus = 0
    else
        is_count(last(threads)) ||
            throw(ArgumentError("$source: $(first(threads)) must be an integer >= 1"))
        cpus = Int(last(threads))
    end
    gpus = flag(:gpu) ? 1 : 0
    memory = slurm ? memory_request(config, keys[:memory_gb], settings, source, notes) : 0
    return Resources(cpus, tasks, memory, gpus, "", "", "", notes)
end

"""
    combine(requests) -> Resources

The request of an array job: the largest value of every quantity over the cases, the
first GPU type among the largest, and every note once.
"""
function combine(requests::Vector{Resources})
    length(requests) == 1 && return only(requests)
    gpu_types = unique(r.gpu_type for r in requests if !isempty(r.gpu_type))
    return Resources(
        maximum(r.cpus_per_task for r in requests),
        maximum(r.tasks for r in requests),
        maximum(r.memory_gb for r in requests),
        maximum(r.gpus for r in requests),
        isempty(gpu_types) ? "" : last(gpu_types),
        "",
        "",
        unique(vcat((r.notes for r in requests)...)),
    )
end

# --- job specification -----------------------------------------------------------------

"""
    JobSpec

Everything a job script states: payload and backend, the cluster, the project root here
and where the job runs (`target`), job name and file stem, generation time, commit of the
project, the run configuration and the script it runs (relative to the project root, or
file names inside each case directory of an array job), the output directory, the cases
with their own requests, the combined request, the configuration hash, a dependency and
the array throttle.
"""
struct JobSpec
    payload::String
    backend::String
    cluster::Union{Cluster, Nothing}
    project::String
    target::String
    name::String
    stem::String
    timestamp::DateTime
    commit::String
    dirty::Bool
    run_config::String
    script::String
    output_directory::String
    cases::Vector{Pair{String, Resources}}
    resources::Resources
    config_hash::String
    after::String
    parallel::Int
end

is_array(spec::JobSpec) = !isempty(spec.cases)
job_script(spec::JobSpec, settings::LaunchSettings) = joinpath(
    settings.job_directory,
    spec.stem * (spec.backend == "slurm" ? ".sbatch" : ".sh"),
)
cases_file(spec::JobSpec, settings::LaunchSettings) =
    joinpath(settings.job_directory, spec.stem * ".cases")
exit_file(spec::JobSpec, settings::LaunchSettings) =
    joinpath(settings.job_directory, spec.stem * ".exit")
log_file(spec::JobSpec, settings::LaunchSettings) =
    spec.backend == "slurm" ?
    joinpath(
        settings.job_directory,
        spec.stem * (is_array(spec) ? "_%A_%a.log" : "_%j.log"),
    ) : joinpath(settings.log_directory, spec.stem * ".log")

"""
    project_commit(project) -> (commit, dirty)

HEAD of the git checkout holding `project` and whether tracked files are modified;
`("unavailable", false)` without git or outside a repository.
"""
function project_commit(project::AbstractString)
    Sys.which("git") === nothing && return ("unavailable", false)
    capture(args...) =
        try
            String(
                strip(
                    read(
                        pipeline(
                            `git --no-optional-locks -C $project $args`;
                            stderr = devnull,
                        ),
                        String,
                    ),
                ),
            )
        catch err
            err isa ProcessFailedException || rethrow()
            nothing
        end
    commit = capture("rev-parse", "HEAD")
    commit === nothing && return ("unavailable", false)
    status = capture("status", "--porcelain", "--untracked-files=no")
    return (commit, status !== nothing && !isempty(status))
end

"""
    inside(project, path, flag) -> String

`path` (relative paths resolve against the working directory) as a path relative to the
project root; `ArgumentError` naming `flag` when it lies outside the project or holds
whitespace, which job scripts and Slurm directives cannot carry safely.
"""
function inside(project::AbstractString, path::AbstractString, flag::AbstractString)
    relative = relpath(normpath(abspath(path)), project)
    (relative == ".." || startswith(relative, "../")) &&
        throw(ArgumentError("$flag $path lies outside the project $project"))
    occursin(r"\s", relative) && throw(ArgumentError("$flag $path holds whitespace"))
    return relative
end

function pipeline_script(project::AbstractString, options::AbstractDict)
    script = inside(
        project,
        get(options, "script", joinpath(project, "scripts", "run_pipeline.jl")),
        "--script",
    )
    isfile(joinpath(project, script)) ||
        throw(ArgumentError("--script $script is not a file"))
    return script
end

function file_hash(paths::Vector{String})
    length(paths) == 1 && return bytes2hex(sha256(read(only(paths))))
    return bytes2hex(sha256(join(bytes2hex(sha256(read(p))) for p in paths)))
end

"""
    build_spec(options, settings; timestamp = now()) -> JobSpec

Resolve the command-line `options` (a `Dict` of strings) against the project and the
settings, read every run configuration and derive the request. Single runs need
`--run-config` and, for the Julia payload, `--output-dir`; an array job (`--cases DIR`)
takes every subdirectory of `DIR` that holds the run configuration file.
"""
function build_spec(
    options::AbstractDict,
    settings::LaunchSettings;
    timestamp::DateTime = now(),
)
    payload = get(options, "payload", "julia")
    payload in PAYLOADS || throw(
        ArgumentError("--payload must be one of: $(join(PAYLOADS, " | ")), got '$payload'"),
    )
    backend = lowercase(get(options, "backend", settings.backend))
    backend in BACKENDS || throw(
        ArgumentError("--backend must be one of: $(join(BACKENDS, " | ")), got '$backend'"),
    )
    project = normpath(abspath(get(options, "project", pwd())))
    isdir(project) || throw(ArgumentError("--project $project is not a directory"))
    payload == "julia" &&
        !isfile(joinpath(project, "Project.toml")) &&
        throw(ArgumentError("--project $project holds no Project.toml"))

    cluster = nothing
    if backend == "slurm"
        name = get(options, "cluster", settings.cluster)
        isempty(name) && throw(
            ArgumentError(
                "the slurm backend needs a cluster: pass --cluster NAME or set [defaults].cluster, with a [clusters.NAME] table holding the site settings",
            ),
        )
        haskey(settings.clusters, name) ||
            throw(ArgumentError("no [clusters.$name] table in the configuration"))
        cluster = settings.clusters[name]
    end
    target =
        haskey(options, "remote-project") ? options["remote-project"] :
        cluster !== nothing && !isempty(cluster.remote_root) ?
        joinpath(cluster.remote_root, basename(project)) : project
    (startswith(target, "/") && !occursin(r"\s", target)) || throw(
        ArgumentError(
            "the project path on the target must be absolute and free of whitespace, got '$target'",
        ),
    )

    haskey(options, "run-config") || throw(ArgumentError("--run-config is required"))
    cases = Pair{String, Resources}[]
    if haskey(options, "cases")
        root = inside(project, options["cases"], "--cases")
        isdir(joinpath(project, root)) ||
            throw(ArgumentError("--cases $(options["cases"]) is not a directory"))
        config_name = options["run-config"]
        (basename(config_name) == config_name) || throw(
            ArgumentError(
                "with --cases, --run-config is a file name inside each case directory",
            ),
        )
        if payload == "launcher"
            script = get(options, "script", "_launch.sh")
            basename(script) == script || throw(
                ArgumentError(
                    "with --cases, --script is a file name inside each case directory",
                ),
            )
        else
            script = pipeline_script(project, options)
        end
        directories = sort!(filter(readdir(joinpath(project, root); join = true)) do dir
            isdir(dir) && isfile(joinpath(dir, config_name))
        end)
        isempty(directories) && throw(
            ArgumentError(
                "no subdirectory of --cases $(options["cases"]) holds $config_name",
            ),
        )
        sources = String[]
        for dir in directories
            source = joinpath(dir, config_name)
            payload == "launcher" &&
                !isfile(joinpath(dir, script)) &&
                throw(ArgumentError("case $(relpath(dir, project)) holds no $script"))
            push!(sources, source)
            push!(
                cases,
                inside(project, dir, "--cases") => derive_resources(
                    payload,
                    parse_toml(source),
                    relpath(source, project),
                    settings,
                    backend,
                    cluster,
                ),
            )
        end
        resources = combine(last.(cases))
        run_config = config_name
        output = root
        config_hash = file_hash(sources)
    else
        source = options["run-config"]
        isfile(source) || throw(ArgumentError("--run-config $source is not a file"))
        run_config = inside(project, source, "--run-config")
        resources = derive_resources(
            payload,
            parse_toml(source),
            run_config,
            settings,
            backend,
            cluster,
        )
        if payload == "julia"
            script = pipeline_script(project, options)
            haskey(options, "output-dir") ||
                throw(ArgumentError("--output-dir is required for a single Julia run"))
            output = inside(project, options["output-dir"], "--output-dir")
        else
            haskey(options, "script") || throw(
                ArgumentError(
                    "--script (the launch script) is required for the launcher payload",
                ),
            )
            script = inside(project, options["script"], "--script")
            output = dirname(script)
        end
        isfile(joinpath(project, script)) ||
            throw(ArgumentError("--script $script is not a file"))
        config_hash = file_hash([abspath(source)])
    end

    after = get(options, "after", "")
    if !isempty(after)
        backend == "slurm" ||
            throw(ArgumentError("--after needs the slurm backend; local jobs do not queue"))
        if ispath(after)
            record = read_record(after)
            record["backend"] == "slurm" || throw(
                ArgumentError(
                    "--after $after is a local job; dependencies need Slurm jobs",
                ),
            )
            after = string(record["job_id"])
        end
        occursin(r"^\d+(?:_\d+)?$", after) || throw(
            ArgumentError("--after expects a job id or a submission record, got '$after'"),
        )
    end
    parallel = parse(Int, get(options, "parallel", "0"))
    name = get(options, "name", basename(project))
    occursin(r"^[A-Za-z0-9_.-]+$", name) ||
        throw(ArgumentError("--name may hold letters, digits and _.- only, got '$name'"))
    # jobs generated within the same second take a numeric suffix
    base = "$(name)_$(Dates.format(timestamp, "yyyy-mm-dd_HH-MM-SS"))"
    extension = backend == "slurm" ? ".sbatch" : ".sh"
    stem = base
    k = 1
    while isfile(joinpath(project, settings.job_directory, stem * extension))
        k += 1
        stem = "$(base)_$k"
    end
    commit, dirty = project_commit(project)
    return JobSpec(
        payload,
        backend,
        cluster,
        project,
        target,
        name,
        stem,
        timestamp,
        commit,
        dirty,
        run_config,
        script,
        output,
        cases,
        resources,
        config_hash,
        after,
        parallel,
    )
end

# --- rendering -------------------------------------------------------------------------

"""
    directives(spec, settings) -> Vector{String}

The `#SBATCH` options of a Slurm job, in a fixed order.
"""
function directives(spec::JobSpec, settings::LaunchSettings)
    c = spec.cluster
    r = spec.resources
    lines = ["--job-name=$(spec.name)", "--partition=$(c.partition)"]
    isempty(c.account) || push!(lines, "--account=$(c.account)")
    isempty(c.qos) || push!(lines, "--qos=$(c.qos)")
    push!(lines, "--time=$(c.time_limit)")
    spec.payload == "julia" && push!(lines, "--nodes=1")
    push!(lines, "--ntasks=$(r.tasks)")
    r.cpus_per_task > 0 && push!(lines, "--cpus-per-task=$(r.cpus_per_task)")
    r.memory_gb > 0 && push!(lines, "--mem=$(r.memory_gb)G")
    r.gpus > 0 && push!(
        lines,
        "--gres=gpu:" * (isempty(r.gpu_type) ? "" : r.gpu_type * ":") * "$(r.gpus)",
    )
    isempty(c.constraint) || push!(lines, "--constraint=$(c.constraint)")
    push!(lines, "--chdir=$(spec.target)")
    push!(lines, "--output=$(log_file(spec, settings))")
    if is_array(spec)
        throttle = spec.parallel > 0 ? "%$(spec.parallel)" : ""
        push!(lines, "--array=1-$(length(spec.cases))$throttle")
    end
    isempty(spec.after) || push!(lines, "--dependency=afterok:$(spec.after)")
    isempty(c.mail_type) || push!(lines, "--mail-type=$(c.mail_type)")
    isempty(c.mail_user) || push!(lines, "--mail-user=$(c.mail_user)")
    append!(lines, c.directives)
    return lines
end

julia_command(spec::JobSpec, settings::LaunchSettings) =
    spec.cluster !== nothing && !isempty(spec.cluster.julia) ? spec.cluster.julia :
    settings.julia

"""
    payload_lines(spec, settings) -> Vector{String}

Shell lines that run the payload from the project root: the Julia command of the
pipeline, or the launch script run inside its directory; for an array job, the case of
the task (Slurm) or a loop over every case (local).
"""
function payload_lines(spec::JobSpec, settings::LaunchSettings)
    julia = julia_command(spec, settings)
    r = spec.resources
    if !is_array(spec)
        spec.payload == "launcher" && return [
            "cd $(shell_quote(dirname(spec.script)))",
            "bash $(shell_quote(basename(spec.script)))",
        ]
        flags = ["--project=.", "--threads=$(r.threads)"]
        isempty(r.heap_size_hint) || push!(flags, "--heap-size-hint=$(r.heap_size_hint)")
        return [
            join(
                [
                    julia,
                    flags...,
                    shell_quote(spec.script),
                    "--config",
                    shell_quote(spec.run_config),
                    "--output-dir",
                    shell_quote(spec.output_directory),
                ],
                " ",
            ),
        ]
    end
    list = shell_quote(cases_file(spec, settings))
    run_case =
        spec.payload == "julia" ?
        "$julia --project=. --threads=\"\$threads\" \${heap:+--heap-size-hint=\"\$heap\"} $(shell_quote(spec.script)) --config \"\$case/$(spec.run_config)\" --output-dir \"\$case\"" :
        "(cd \"\$case\" && bash $(shell_quote(spec.script)))"
    fields = spec.payload == "julia" ? "case threads heap" : "case"
    spec.backend == "slurm" && return [
        "IFS=\$'\\t' read -r $fields <<< \"\$(sed -n \"\${SLURM_ARRAY_TASK_ID}p\" $list)\"",
        run_case,
    ]
    return [
        "while IFS=\$'\\t' read -r $fields; do",
        "    $run_case < /dev/null",
        "done < $list",
    ]
end

"""
    render_script(spec, settings) -> String

Text of the job script: a provenance header, the `#SBATCH` block (Slurm) or the log
redirection and exit-status trap (local), the cluster's setup lines and the payload.
"""
function render_script(spec::JobSpec, settings::LaunchSettings)
    io = IOBuffer()
    println(io, "#!/bin/bash")
    println(
        io,
        "# Generated by slurm-launch on $(Dates.format(spec.timestamp, "yyyy-mm-ddTHH:MM:SS")): $(spec.payload) payload of $(basename(spec.project)) at $(spec.commit)$(spec.dirty ? " with uncommitted changes" : "")",
    )
    configuration =
        is_array(spec) ?
        "$(spec.run_config) of $(length(spec.cases)) cases under $(spec.output_directory)" :
        spec.run_config
    println(io, "# Configuration $configuration, sha256 $(first(spec.config_hash, 16))")
    if spec.backend == "slurm"
        for line in directives(spec, settings)
            println(io, "#SBATCH ", line)
        end
        println(io)
        println(io, "set -euo pipefail")
        for line in spec.cluster.setup
            println(io, line)
        end
    else
        println(io)
        println(io, "set -euo pipefail")
        println(io, "cd $(shell_quote(spec.target))")
        println(io, "mkdir -p $(shell_quote(settings.log_directory))")
        println(io, "exec >> $(shell_quote(log_file(spec, settings))) 2>&1")
        # a signal must end the script with 128 + its number, not with the status of
        # the last command before it
        println(
            io,
            "trap 'echo \$? > $(joinpath(spec.target, exit_file(spec, settings)))' EXIT",
        )
        println(io, "trap 'exit 143' TERM")
        println(io, "trap 'exit 130' INT")
    end
    for line in payload_lines(spec, settings)
        println(io, line)
    end
    return String(take!(io))
end

"""
    render_cases(spec) -> String

The case list of an array job, one line per case: its directory and, for the Julia
payload, its `--threads` and `--heap-size-hint` values, separated by tabs.
"""
function render_cases(spec::JobSpec)
    lines = map(spec.cases) do (dir, r)
        spec.payload == "julia" ? join([dir, r.threads, r.heap_size_hint], '\t') : dir
    end
    return join(lines, '\n') * "\n"
end

"""
    write_job(spec, settings) -> String

Write the job script (and the case list of an array job) into the job directory of the
project and return the script's absolute path. Existing files are never replaced.
"""
function write_job(spec::JobSpec, settings::LaunchSettings)
    script = joinpath(spec.project, job_script(spec, settings))
    isfile(script) && throw(ArgumentError("$script exists"))
    mkpath(dirname(script))
    if is_array(spec)
        write(joinpath(spec.project, cases_file(spec, settings)), render_cases(spec))
    end
    write(script, render_script(spec, settings))
    chmod(script, 0o755)
    return script
end

# --- submission records ----------------------------------------------------------------

record_path(spec::JobSpec) = joinpath(spec.project, spec.output_directory, RECORD_NAME)

"""
    write_record(spec, settings, job_id) -> String

The submission record beside the run (`submission.toml` in its output directory): job
id, backend, cluster, partition, files, configuration and hash, commit, submission time
and the request, so that a queue job can be joined to its run directory.
"""
function write_record(spec::JobSpec, settings::LaunchSettings, job_id::AbstractString)
    r = spec.resources
    record = Dict{String, Any}(
        "job_id" => String(job_id),
        "name" => spec.name,
        "backend" => spec.backend,
        "cluster" => spec.cluster === nothing ? "" : spec.cluster.name,
        "partition" => spec.cluster === nothing ? "" : spec.cluster.partition,
        "payload" => spec.payload,
        "project" => spec.project,
        "target_project" => spec.target,
        "script" => job_script(spec, settings),
        "log" => log_file(spec, settings),
        "exit_file" => spec.backend == "local" ? exit_file(spec, settings) : "",
        "output_directory" => spec.output_directory,
        "run_config" => spec.run_config,
        "config_hash" => spec.config_hash,
        "commit" => spec.commit,
        "dirty" => spec.dirty,
        "submitted" => now(),
        "after" => spec.after,
        "cases" => length(spec.cases),
        "resources" => Dict{String, Any}(
            "cpus_per_task" => r.cpus_per_task,
            "tasks" => r.tasks,
            "memory_gb" => r.memory_gb,
            "gpus" => r.gpus,
            "gpu_type" => r.gpu_type,
            "threads" => r.threads,
            "heap_size_hint" => r.heap_size_hint,
            "time_limit" => spec.cluster === nothing ? "" : spec.cluster.time_limit,
        ),
    )
    path = record_path(spec)
    mkpath(dirname(path))
    open(io -> TOML.print(io, record; sorted = true), path, "w")
    return path
end

"""
    read_record(path) -> Dict

A submission record, given as the file or as the directory that holds it.
"""
function read_record(path::AbstractString)
    file = isdir(path) ? joinpath(path, RECORD_NAME) : path
    isfile(file) || throw(ArgumentError("no submission record at $path"))
    record = parse_toml(file)
    for key in ("job_id", "backend", "project", "output_directory")
        haskey(record, key) ||
            throw(ArgumentError("$file lacks '$key'; not a submission record"))
    end
    return record
end

# --- scheduler and process interaction -------------------------------------------------

"""
    capture(cmd) -> (success, stdout, stderr)

Run `cmd` to completion and return its streams, stripped.
"""
function capture(cmd::Cmd)
    out, err = IOBuffer(), IOBuffer()
    process = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err))
    return success(process),
    String(strip(String(take!(out)))),
    String(strip(String(take!(err))))
end

function require_command(name::AbstractString)
    Sys.which(name) === nothing && throw(
        ArgumentError(
            "$name not found; Slurm commands run where the scheduler is, on the cluster's login node",
        ),
    )
    return nothing
end

"""
    submit_job(spec, settings, script) -> String

Queue the Slurm job (`sbatch --parsable`) or start the local one as a detached process
group, and return the job id (the process id for local jobs).
"""
function submit_job(spec::JobSpec, settings::LaunchSettings, script::AbstractString)
    if spec.backend == "slurm"
        require_command("sbatch")
        spec.target == spec.project ||
            @warn "the job runs in $(spec.target), but sbatch is called here, where the project is $(spec.project)"
        ok, out, err = capture(`sbatch --parsable $script`)
        m = match(r"^(\d+)", out)
        (ok && m !== nothing) ||
            throw(ArgumentError("sbatch failed: $(isempty(err) ? out : err)"))
        return String(m.captures[1])
    end
    process = run(
        pipeline(
            detach(`bash $script`);
            stdin = devnull,
            stdout = devnull,
            stderr = devnull,
        );
        wait = false,
    )
    return string(getpid(process))
end

"""
    job_state(record) -> (state, detail)

State of the job of a submission record. Slurm: `squeue` while queued or running, then
`sacct`. Local: the exit status the script records on exit, or whether the process is
still alive.
"""
function job_state(record::AbstractDict)
    id = string(record["job_id"])
    if record["backend"] == "slurm"
        if Sys.which("squeue") !== nothing
            ok, out, _ = capture(`squeue -h -j $id -o "%T|%M|%R"`)
            if ok && !isempty(out)
                state, elapsed, reason =
                    (split(first(split(out, '\n')), '|')..., "", "")[1:3]
                return (String(state), "elapsed $elapsed, $reason")
            end
        end
        if Sys.which("sacct") !== nothing
            ok, out, _ = capture(`sacct -n -X -P -j $id -o State,ExitCode,Elapsed`)
            if ok && !isempty(out)
                state, code, elapsed = (split(first(split(out, '\n')), '|')..., "", "")[1:3]
                return (String(first(split(state))), "exit code $code, elapsed $elapsed")
            end
        end
        return ("UNKNOWN", "neither squeue nor sacct reports job $id here")
    end
    exit_path = joinpath(record["project"], record["exit_file"])
    if isfile(exit_path)
        code = tryparse(Int, strip(read(exit_path, String)))
        code === nothing && return ("UNKNOWN", "unreadable exit status in $exit_path")
        code == 0 && return ("COMPLETED", "exit 0")
        code > 128 && return ("TERMINATED", "signal $(code - 128)")
        return ("FAILED", "exit $code")
    end
    alive = success(pipeline(ignorestatus(`kill -0 $id`); stderr = devnull))
    alive && return ("RUNNING", "process $id")
    return ("TERMINATED", "process $id is gone without an exit status")
end

"""
    cancel_job(record) -> String

Cancel the job of a submission record: `scancel` for Slurm, SIGTERM to the process
group of a local job.
"""
function cancel_job(record::AbstractDict)
    id = string(record["job_id"])
    if record["backend"] == "slurm"
        require_command("scancel")
        ok, out, err = capture(`scancel $id`)
        ok || throw(ArgumentError("scancel failed: $(isempty(err) ? out : err)"))
        return "scancel $id"
    end
    first(job_state(record)) == "RUNNING" ||
        throw(ArgumentError("local job $id is not running"))
    ok, _, err = capture(`kill -TERM -- -$id`)
    ok || throw(ArgumentError("kill failed: $err"))
    return "SIGTERM to process group $id"
end

# --- command line ----------------------------------------------------------------------

function usage(io::IO = stdout)
    print(
        io,
        """
        slurm-launch — job scripts with the resource request derived from the run configuration

        Usage:
          julia run.jl slurm-launch [generate|submit] [options]
          julia run.jl slurm-launch status|cancel|fetch RECORD ...

          generate            write the job script and print it (the default)
          submit              write the job script, queue or start it, write the submission record
          status, cancel, fetch
                              act on the jobs of submission records (files or their directories)

          --payload P         julia | launcher (default julia)
          --project DIR       project root (default: the working directory)
          --run-config FILE   run configuration; with --cases, its file name inside each case
          --script FILE       julia: pipeline script (default scripts/run_pipeline.jl);
                              launcher: launch script, with --cases its name inside each case
                              (default _launch.sh)
          --output-dir DIR    julia: output directory passed to the pipeline (single runs)
          --cases DIR         array job over the subdirectories of DIR holding the run configuration
          --parallel K        at most K array tasks at once (Slurm)
          --backend B         local | slurm (default [defaults].backend)
          --cluster NAME      the [clusters.NAME] table to use (default [defaults].cluster)
          --name NAME         job name (default: the project directory name)
          --remote-project P  project path on the cluster (default: remote_root/<project>, else here)
          --after JOB         start once JOB, a job id or a submission record, has completed (Slurm)
          --config PATH       configuration of this tool (default config.toml next to it)
          -h, --help

        Paths resolve against the working directory and must lie inside the project.
        """,
    )
    return nothing
end

const VALUE_OPTIONS = (
    "payload",
    "project",
    "run-config",
    "script",
    "output-dir",
    "cases",
    "parallel",
    "backend",
    "cluster",
    "name",
    "remote-project",
    "after",
    "config",
)

function parse_options(args::Vector{String})
    options = Dict{String, String}()
    positional = String[]
    i = 1
    while i <= length(args)
        argument = args[i]
        if startswith(argument, "--")
            name = argument[3:end]
            name in VALUE_OPTIONS || throw(
                ArgumentError("unknown command-line argument '$argument'; see --help"),
            )
            i < length(args) || throw(ArgumentError("$argument requires a value"))
            haskey(options, name) && throw(ArgumentError("$argument given twice"))
            options[name] = args[i + 1]
            i += 2
        else
            push!(positional, argument)
            i += 1
        end
    end
    if haskey(options, "parallel")
        k = tryparse(Int, options["parallel"])
        (k === nothing || k < 1) && throw(
            ArgumentError(
                "--parallel must be an integer >= 1, got '$(options["parallel"])'",
            ),
        )
    end
    return options, positional
end

function print_notes(io::IO, spec::JobSpec)
    for note in spec.resources.notes
        println(io, "note: ", note)
    end
    return nothing
end

"""
    main(args = ARGS; io = stdout, timestamp = now()) -> NamedTuple or nothing

Run one verb. `generate` and `submit` return the job specification with the script path
(and, after `submit`, the job id and record path); `status`, `cancel` and `fetch` return
the per-record results; `--help` returns `nothing`.
"""
function main(args::Vector{String} = ARGS; io::IO = stdout, timestamp::DateTime = now())
    any(a -> a in ("-h", "--help"), args) && (usage(io); return nothing)
    verb = !isempty(args) && first(args) in VERBS ? first(args) : "generate"
    rest = !isempty(args) && first(args) in VERBS ? args[2:end] : args
    options, positional = parse_options(rest)
    settings = load_settings(get(options, "config", joinpath(@__DIR__, "config.toml")))

    if verb in ("generate", "submit")
        isempty(positional) ||
            throw(ArgumentError("unexpected argument '$(first(positional))'; see --help"))
        spec = build_spec(options, settings; timestamp)
        if verb == "submit" && isfile(record_path(spec))
            existing = read_record(record_path(spec))
            throw(
                ArgumentError(
                    "$(record_path(spec)) already records job $(existing["job_id"]); choose another output directory",
                ),
            )
        end
        script = write_job(spec, settings)
        if verb == "generate"
            print(io, render_script(spec, settings))
            println(io)
            println(io, "wrote ", script)
            print_notes(io, spec)
            if spec.backend == "slurm"
                println(
                    io,
                    "submit on the login node with: sbatch $(spec.target)/$(job_script(spec, settings))",
                )
            else
                println(
                    io,
                    "start detached with the verb submit and the same options, or run: bash $script",
                )
            end
            return (; spec, script)
        end
        job_id = submit_job(spec, settings, script)
        record = write_record(spec, settings, job_id)
        print_notes(io, spec)
        println(io, "submitted $(spec.backend) job $job_id: ", script)
        println(io, "record: ", record)
        return (; spec, script, job_id, record)
    end

    isempty(positional) &&
        throw(ArgumentError("$verb needs one or more submission records"))
    results = map(positional) do path
        record = read_record(path)
        state, detail = job_state(record)
        output = joinpath(record["project"], record["output_directory"])
        if verb == "status"
            println(
                io,
                "$(record["name"])  $(record["backend"]) job $(record["job_id"])  $state ($detail)  $output",
            )
        elseif verb == "cancel"
            action = cancel_job(record)
            println(io, "$(record["name"]): $action")
        else
            state == "COMPLETED" || println(
                io,
                "$(record["name"]): job $(record["job_id"]) is $state ($detail); its output may be incomplete",
            )
            target = joinpath(
                get(record, "target_project", record["project"]),
                record["output_directory"],
            )
            println(io, "$(record["name"]): output $target")
            if !isempty(settings.fetch_command)
                command = replace(
                    settings.fetch_command,
                    "{project}" => get(record, "target_project", record["project"]),
                    "{output_directory}" => record["output_directory"],
                )
                println(io, "fetch with: ", command)
            end
        end
        (; path, job_id = string(record["job_id"]), state, detail)
    end
    return results
end

if abspath(PROGRAM_FILE) == @__FILE__
    try
        main(ARGS)
    catch err
        err isa ArgumentError || rethrow()
        println(stderr, "slurm-launch: ", err.msg)
        exit(2)
    end
end
