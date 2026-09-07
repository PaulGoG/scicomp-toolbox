"""
Validated configuration: TOML tables merged with command-line options into a
[`BenchmarkConfig`](@ref). Every constraint stated in `config.toml` is enforced here.
"""
module Config

using TOML: TOML
using ..Backends: BACKEND_NAMES
using ..Kernels: ENGINES, integer_accumulation_bound, integer_range_safe
using ..Sampling: SamplingPolicy

export BenchmarkConfig,
    validate_config, load_config, parse_cli_args, usage_text, PRESET_SIZES, SUPPORTED_TYPES

"""
Element types accepted in `target_types`.
"""
const SUPPORTED_TYPES = Dict{String, DataType}(
    "Float16" => Float16,
    "Float32" => Float32,
    "Float64" => Float64,
    "ComplexF32" => ComplexF32,
    "ComplexF64" => ComplexF64,
    "Int8" => Int8,
    "Int16" => Int16,
    "Int32" => Int32,
    "Int64" => Int64,
)

const DEFAULT_TYPES = ["Float16", "Float32", "Float64", "Int32", "Int64"]

"""
Problem sizes selected by the command-line presets.
"""
const PRESET_SIZES = Dict{String, Vector{Int}}(
    "quick" => [512, 1024],
    "standard" => [1024, 2048],
    "stress" => [1024, 2048, 4096],
)

const ENGINE_NAMES = string.(ENGINES)
const SWEEP_CEILINGS = ("physical", "logical")

const KNOWN_KEYS = Dict{String, Vector{String}}(
    "" => ["benchmark", "sampling", "hardware", "safety", "output"],
    "benchmark" => ["engines", "problem_sizes", "target_types", "seed"],
    "sampling" =>
        ["min_sampling_time_s", "min_samples", "max_samples", "max_point_seconds"],
    "hardware" => [
        "run_cpu",
        "gpu_backend",
        "thread_sweep_ceiling",
        "verify_kernels",
        "verification_size",
    ],
    "safety" => ["memory_safety_fraction"],
    "output" => [
        "export_csv",
        "export_metadata",
        "output_directory",
        "log_to_file",
        "record_hostname",
    ],
)

"""
    BenchmarkConfig

Validated run configuration. `preset` records how the problem sizes were chosen
(`"config"`, `"quick"`, `"standard"`, `"stress"` or `"custom"`).
"""
struct BenchmarkConfig
    preset::String
    engines::Vector{Symbol}
    problem_sizes::Vector{Int}
    target_types::Vector{DataType}
    seed::Int
    sampling::SamplingPolicy
    run_cpu::Bool
    gpu_backend::Symbol
    thread_sweep_ceiling::Symbol
    verify_kernels::Bool
    verification_size::Int
    memory_safety_fraction::Float64
    export_csv::Bool
    export_metadata::Bool
    output_directory::String
    log_to_file::Bool
    record_hostname::Bool
end

context_label(context::String) = isempty(context) ? "top level" : "[$context]"

function reject_unknown_keys(table::AbstractDict, context::String)
    known = KNOWN_KEYS[context]
    for key in keys(table)
        key in known || throw(
            ArgumentError(
                "unknown key '$key' at $(context_label(context)); allowed: $(join(known, ", "))",
            ),
        )
    end
    return nothing
end

function section(raw::AbstractDict, name::String)
    table = get(raw, name, Dict{String, Any}())
    table isa AbstractDict || throw(ArgumentError("[$name] must be a table"))
    reject_unknown_keys(table, name)
    return table
end

function get_boolean(table::AbstractDict, key::String, default::Bool, context::String)
    value = get(table, key, default)
    value isa Bool ||
        throw(ArgumentError("[$context].$key must be a boolean, got $(repr(value))"))
    return value
end

function get_integer(
    table::AbstractDict,
    key::String,
    default::Integer,
    context::String;
    low::Integer = typemin(Int),
    high::Integer = typemax(Int),
)
    value = get(table, key, default)
    (value isa Integer && !(value isa Bool)) ||
        throw(ArgumentError("[$context].$key must be an integer, got $(repr(value))"))
    low <= value <= high ||
        throw(ArgumentError("[$context].$key must be in [$low, $high], got $value"))
    return Int(value)
end

function get_real(
    table::AbstractDict,
    key::String,
    default::Real,
    context::String;
    low::Real,
    high::Real,
    low_open::Bool = false,
)
    value = get(table, key, default)
    (value isa Real && !(value isa Bool)) ||
        throw(ArgumentError("[$context].$key must be a number, got $(repr(value))"))
    inside = low_open ? (low < value <= high) : (low <= value <= high)
    inside || throw(
        ArgumentError(
            "[$context].$key must be in $(low_open ? "(" : "[")$low, $high], got $value",
        ),
    )
    return Float64(value)
end

function get_choice(
    table::AbstractDict,
    key::String,
    default::String,
    context::String,
    allowed,
)
    value = get(table, key, default)
    value isa AbstractString ||
        throw(ArgumentError("[$context].$key must be a string, got $(repr(value))"))
    choice = lowercase(strip(value))
    choice in allowed || throw(
        ArgumentError(
            "[$context].$key must be one of: $(join(allowed, " | ")), got '$value'",
        ),
    )
    return String(choice)
end

function get_string(table::AbstractDict, key::String, default::String, context::String)
    value = get(table, key, default)
    value isa AbstractString ||
        throw(ArgumentError("[$context].$key must be a string, got $(repr(value))"))
    return String(value)
end

function parse_problem_sizes(table::AbstractDict)
    raw = get(table, "problem_sizes", [1024, 2048])
    (raw isa AbstractVector && !isempty(raw)) || throw(
        ArgumentError(
            "[benchmark].problem_sizes must be a non-empty list of positive integers",
        ),
    )
    sizes = Int[]
    for value in raw
        (value isa Integer && !(value isa Bool) && value > 0) || throw(
            ArgumentError(
                "[benchmark].problem_sizes entries must be positive integers, got $(repr(value))",
            ),
        )
        push!(sizes, Int(value))
    end
    return sizes
end

function parse_engines(table::AbstractDict)
    raw = get(table, "engines", collect(ENGINE_NAMES))
    (raw isa AbstractVector && !isempty(raw)) ||
        throw(ArgumentError("[benchmark].engines must be a non-empty list of engine names"))
    engines = Symbol[]
    for value in raw
        (value isa AbstractString && lowercase(strip(value)) in ENGINE_NAMES) || throw(
            ArgumentError(
                "[benchmark].engines entry $(repr(value)) is not one of: $(join(ENGINE_NAMES, " | "))",
            ),
        )
        engine = Symbol(lowercase(strip(value)))
        engine in engines || push!(engines, engine)
    end
    return engines
end

function parse_target_types(table::AbstractDict)
    raw = get(table, "target_types", DEFAULT_TYPES)
    (raw isa AbstractVector && !isempty(raw)) || throw(
        ArgumentError("[benchmark].target_types must be a non-empty list of type names"),
    )
    types = DataType[]
    for value in raw
        (value isa AbstractString && haskey(SUPPORTED_TYPES, String(value))) || throw(
            ArgumentError(
                "[benchmark].target_types entry $(repr(value)) is not one of: $(join(sort(collect(keys(SUPPORTED_TYPES))), " | "))",
            ),
        )
        push!(types, SUPPORTED_TYPES[String(value)])
    end
    return types
end

"""
    validate_config(raw::AbstractDict; preset::String = "config") -> BenchmarkConfig

Enforce the schema and constraints of the configuration tables and build a
[`BenchmarkConfig`](@ref). Fails with an `ArgumentError` naming the offending key.
"""
function validate_config(raw::AbstractDict; preset::String = "config")
    reject_unknown_keys(raw, "")
    benchmark = section(raw, "benchmark")
    sampling = section(raw, "sampling")
    hardware = section(raw, "hardware")
    safety = section(raw, "safety")
    output = section(raw, "output")

    engines = parse_engines(benchmark)
    problem_sizes = parse_problem_sizes(benchmark)
    target_types = parse_target_types(benchmark)
    seed = get_integer(benchmark, "seed", 20260907, "benchmark"; low = 0)
    for T in target_types, N in problem_sizes
        integer_range_safe(T, N) || throw(
            ArgumentError(
                "[benchmark].target_types: $T overflows at N = $N (accumulation bound $(integer_accumulation_bound(N)) > typemax = $(typemax(T))); drop the type or reduce problem_sizes",
            ),
        )
    end

    min_samples =
        get_integer(sampling, "min_samples", 3, "sampling"; low = 1, high = 10_000)
    policy = SamplingPolicy(;
        min_sampling_time_s = get_real(
            sampling,
            "min_sampling_time_s",
            0.5,
            "sampling";
            low = 0.0,
            high = Inf,
            low_open = true,
        ),
        min_samples,
        max_samples = get_integer(
            sampling,
            "max_samples",
            30,
            "sampling";
            low = min_samples,
            high = 10_000,
        ),
        max_point_seconds = get_real(
            sampling,
            "max_point_seconds",
            60.0,
            "sampling";
            low = 0.0,
            high = Inf,
            low_open = true,
        ),
    )

    run_cpu = get_boolean(hardware, "run_cpu", true, "hardware")
    gpu_backend = Symbol(
        get_choice(hardware, "gpu_backend", "auto", "hardware", string.(BACKEND_NAMES)),
    )
    thread_sweep_ceiling = Symbol(
        get_choice(
            hardware,
            "thread_sweep_ceiling",
            "physical",
            "hardware",
            SWEEP_CEILINGS,
        ),
    )
    verify_kernels = get_boolean(hardware, "verify_kernels", true, "hardware")
    verification_size =
        get_integer(hardware, "verification_size", 64, "hardware"; low = 8, high = 1024)
    (run_cpu || gpu_backend !== :none) || throw(
        ArgumentError(
            "[hardware]: run_cpu = false together with gpu_backend = \"none\" leaves nothing to run",
        ),
    )

    memory_safety_fraction = get_real(
        safety,
        "memory_safety_fraction",
        0.75,
        "safety";
        low = 0.0,
        high = 0.95,
        low_open = true,
    )

    return BenchmarkConfig(
        preset,
        engines,
        problem_sizes,
        target_types,
        seed,
        policy,
        run_cpu,
        gpu_backend,
        thread_sweep_ceiling,
        verify_kernels,
        verification_size,
        memory_safety_fraction,
        get_boolean(output, "export_csv", true, "output"),
        get_boolean(output, "export_metadata", true, "output"),
        get_string(output, "output_directory", "data", "output"),
        get_boolean(output, "log_to_file", true, "output"),
        get_boolean(output, "record_hostname", true, "output"),
    )
end

"""
    load_config(path::AbstractString) -> BenchmarkConfig

Parse and validate a TOML configuration file.
"""
function load_config(path::AbstractString)
    isfile(path) || throw(ArgumentError("configuration file not found: $path"))
    return validate_config(TOML.parsefile(path))
end

function usage_text()
    return """
    hardware-diagnostics — host and accelerator introspection with a dual-GEMM benchmark

    Usage:
      julia run.jl hardware-diagnostics [options]

    Problem sizes (default: problem_sizes of the configuration file):
      -q, --quick               N = 512, 1024
          --standard            N = 1024, 2048
          --stress              N = 1024, 2048, 4096
          --sizes N1,N2,...     explicit dimensions

    Engines and types:
          --engines E1,E2,...   subset of blas | ka | ka_tiled (default: all three)
          --ka-only             KernelAbstractions kernels only (ka, ka_tiled)
          --blas-only           LinearAlgebra.mul! (vendor library) only
          --types T1,T2,...     Float16 Float32 Float64 ComplexF32 ComplexF64 Int8 Int16 Int32 Int64

    Sampling:
          --min-time S          minimum sampling time per point [s]
          --min-samples K       minimum evaluations per point
          --max-samples K       maximum evaluations per point
          --max-point-seconds S skip a point predicted to exceed S seconds per evaluation
          --seed S              operand generator seed

    Hardware:
          --cpu-only            host only (gpu_backend = none)
          --gpu-only            accelerators only (run_cpu = false)
          --gpu-backend B       none | auto | oneapi | cuda | amdgpu | metal
          --threads-ceiling C   physical | logical (thread sweep ceiling)
          --no-verify           skip the cross-engine verification

    Files:
          --config FILE         configuration file (default: config.toml next to the tool)
          --out-dir DIR         output directory (relative paths resolve against the tool)
          --no-csv, --no-metadata, --no-log, --no-hostname

      -h, --help
    """
end

"""
    parse_cli_args(args, base_dir) -> BenchmarkConfig

Read `config.toml` from `base_dir` (or the file given by `--config`), apply the
command-line options on top, and validate. `--help` is handled by the caller.
"""
function parse_cli_args(args::AbstractVector{<:AbstractString}, base_dir::AbstractString)
    arguments = String.(args)
    config_path = joinpath(base_dir, "config.toml")
    for (i, argument) in enumerate(arguments)
        if argument == "--config"
            i < length(arguments) || throw(ArgumentError("--config requires a file path"))
            config_path = arguments[i + 1]
            isfile(config_path) ||
                throw(ArgumentError("configuration file not found: $config_path"))
        end
    end
    raw = isfile(config_path) ? TOML.parsefile(config_path) : Dict{String, Any}()
    raw isa Dict{String, Any} || (raw = convert(Dict{String, Any}, raw))
    tables = Dict(
        name => get!(raw, name, Dict{String, Any}()) for
        name in ("benchmark", "sampling", "hardware", "safety", "output")
    )
    preset = "config"

    i = 1
    function value_of(flag::String)
        i < length(arguments) || throw(ArgumentError("$flag requires a value"))
        i += 1
        return arguments[i]
    end
    parse_list(text::String) = String.(strip.(split(text, ',')))

    while i <= length(arguments)
        argument = arguments[i]
        if argument in ("-q", "--quick")
            tables["benchmark"]["problem_sizes"] = copy(PRESET_SIZES["quick"])
            preset = "quick"
        elseif argument == "--standard"
            tables["benchmark"]["problem_sizes"] = copy(PRESET_SIZES["standard"])
            preset = "standard"
        elseif argument == "--stress"
            tables["benchmark"]["problem_sizes"] = copy(PRESET_SIZES["stress"])
            preset = "stress"
        elseif argument == "--sizes"
            tables["benchmark"]["problem_sizes"] =
                parse.(Int, parse_list(value_of(argument)))
            preset = "custom"
        elseif argument == "--engines"
            tables["benchmark"]["engines"] = parse_list(value_of(argument))
        elseif argument == "--ka-only"
            tables["benchmark"]["engines"] = ["ka", "ka_tiled"]
        elseif argument == "--blas-only"
            tables["benchmark"]["engines"] = ["blas"]
        elseif argument == "--types"
            tables["benchmark"]["target_types"] = parse_list(value_of(argument))
        elseif argument == "--seed"
            tables["benchmark"]["seed"] = parse(Int, value_of(argument))
        elseif argument == "--min-time"
            tables["sampling"]["min_sampling_time_s"] = parse(Float64, value_of(argument))
        elseif argument == "--min-samples"
            tables["sampling"]["min_samples"] = parse(Int, value_of(argument))
        elseif argument == "--max-samples"
            tables["sampling"]["max_samples"] = parse(Int, value_of(argument))
        elseif argument == "--max-point-seconds"
            tables["sampling"]["max_point_seconds"] = parse(Float64, value_of(argument))
        elseif argument == "--cpu-only"
            tables["hardware"]["gpu_backend"] = "none"
        elseif argument == "--gpu-only"
            tables["hardware"]["run_cpu"] = false
        elseif argument == "--gpu-backend"
            tables["hardware"]["gpu_backend"] = value_of(argument)
        elseif argument == "--threads-ceiling"
            tables["hardware"]["thread_sweep_ceiling"] = value_of(argument)
        elseif argument == "--no-verify"
            tables["hardware"]["verify_kernels"] = false
        elseif argument == "--config"
            value_of(argument)  # already applied
        elseif argument == "--out-dir"
            tables["output"]["output_directory"] = value_of(argument)
        elseif argument == "--no-csv"
            tables["output"]["export_csv"] = false
        elseif argument == "--no-metadata"
            tables["output"]["export_metadata"] = false
        elseif argument == "--no-log"
            tables["output"]["log_to_file"] = false
        elseif argument == "--no-hostname"
            tables["output"]["record_hostname"] = false
        else
            throw(ArgumentError("unknown command-line argument '$argument'; see --help"))
        end
        i += 1
    end
    return validate_config(raw; preset)
end

end
