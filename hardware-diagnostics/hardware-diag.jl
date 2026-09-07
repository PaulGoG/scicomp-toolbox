#!/usr/bin/env julia
# ==============================================================================
# Julia System Diagnostics & High-Intensity Benchmark Suite
# ==============================================================================
# Comprehensive platform profiling and heterogeneous compute benchmarking suite.
# Fully backend-agnostic with KernelAbstractions.jl across:
#   • CPU Multithreading (KernelAbstractions.CPU)
#   • Intel oneAPI Level Zero (oneAPIBackend via oneAPI.jl)
#   • NVIDIA CUDA (CUDABackend via CUDA.jl)
#   • AMD ROCm / HIP (ROCBackend via AMDGPU.jl)
#   • Apple Silicon Metal (MetalBackend via Metal.jl)
# Alongside vendor-optimized BLAS libraries (oneMKL, cuBLAS, rocBLAS, MPS, OpenBLAS).
# ==============================================================================

using Printf
using LinearAlgebra
using Statistics
using Random
using Dates
using InteractiveUtils
using TOML
using KernelAbstractions

# ------------------------------------------------------------------------------
# 1. Data Models & Configuration Structures
# ------------------------------------------------------------------------------

"""
    BenchmarkConfig

Configuration parameters governing benchmark matrix sizes, trial counts, target data types,
execution targets (CPU and GPU), accelerator backend selection, compute engine (KA vs BLAS),
safety thresholds, and export paths.
"""
struct BenchmarkConfig
    mode::String
    compute_engine::String
    problem_sizes::Vector{Int}
    trials::Int
    target_types::Vector{DataType}
    run_cpu::Bool
    run_gpu::Bool
    gpu_backend::String
    memory_safety_fraction::Float64
    export_csv::Bool
    export_metadata::Bool
    output_directory::String
    log_to_file::Bool
end

"""
    GpuDeviceInfo

Hardware and runtime execution profile of a detected GPU accelerator backend.
"""
struct GpuDeviceInfo
    pkg_symbol::Symbol
    array_symbol::Symbol
    vendor_label::String
    is_functional::Bool
    device_name::String
    driver_version::String
    compute_units::Int
    hardware_threads::Int
    core_clock_mhz::Int
    total_memory_bytes::Int
    max_alloc_bytes::Int
    timer_resolution_ns::Int
    ka_backend_name::String
    extra_attributes::Dict{String, String}
end

"""
    BenchmarkRecord

Structured performance metrics for an individual benchmark configuration.
"""
struct BenchmarkRecord
    device_type::String
    backend::String
    kernel_engine::String
    device_name::String
    data_type::String
    matrix_dim::Int
    num_threads::Int
    total_ops::Float64
    min_time_ms::Float64
    median_time_ms::Float64
    mean_time_ms::Float64
    std_time_ms::Float64
    jitter_pct::Float64
    throughput_gflops::Float64
    speedup_vs_1t::Float64
    parallel_efficiency_pct::Float64
    speedup_vs_cpu_1t::Float64
    speedup_vs_cpu_maxt::Float64
end

# ------------------------------------------------------------------------------
# 2. Unified KernelAbstractions.jl Computational Kernel
# ------------------------------------------------------------------------------

"""
    gemm_accum_kernel!(D, @Const(A), @Const(B), @Const(C), N)

Unified, architecture-agnostic computational kernel implementing dual GEMM accumulation:
    D[i, j] = sum_{k=1}^N A[i, k] * (B[k, j] + C[k, j]) = (A*B + A*C)[i, j]
Executes identically on host CPU and GPU accelerator backends (oneAPI, CUDA, AMDGPU, Metal).
"""
@kernel function gemm_accum_kernel!(D, @Const(A), @Const(B), @Const(C), N)
    i, j = @index(Global, NTuple)
    acc = zero(eltype(D))
    for k in 1:N
        @inbounds acc += A[i, k] * (B[k, j] + C[k, j])
    end
    @inbounds D[i, j] = acc
end

# ------------------------------------------------------------------------------
# 3. Configuration Parser & Validator
# ------------------------------------------------------------------------------

const SUPPORTED_TYPE_MAP = Dict{String, DataType}(
    "Float16" => Float16,
    "Float32" => Float32,
    "Float64" => Float64,
    "Int8" => Int8,
    "Int16" => Int16,
    "Int32" => Int32,
    "Int64" => Int64,
    "ComplexF32" => ComplexF32,
    "ComplexF64" => ComplexF64,
)

const ALLOWED_GPU_BACKENDS = ["auto", "all", "oneapi", "cuda", "amdgpu", "metal"]
const ALLOWED_COMPUTE_ENGINES = ["both", "ka", "blas"]

"""
    validate_config(raw_dict::Dict{String, Any}) -> BenchmarkConfig

Parses and validates configuration parameters from a raw dictionary (e.g. loaded from TOML).
Enforces constraints and fails fast with informative `ArgumentError` messages.
"""
function validate_config(raw::Dict{String, Any})
    bench = get(raw, "benchmark", Dict{String, Any}())
    safety = get(raw, "safety", Dict{String, Any}())
    output = get(raw, "output", Dict{String, Any}())

    # Mode validation
    mode = lowercase(string(get(bench, "mode", "standard")))
    allowed_modes = ["quick", "standard", "stress", "custom"]
    if !(mode in allowed_modes)
        throw(
            ArgumentError(
                "Invalid mode '$mode'. Allowed choices: $(join(allowed_modes, ", "))",
            ),
        )
    end

    # Compute engine validation
    engine = lowercase(string(get(bench, "compute_engine", "both")))
    if !(engine in ALLOWED_COMPUTE_ENGINES)
        throw(
            ArgumentError(
                "Invalid compute_engine '$engine'. Allowed choices: $(join(ALLOWED_COMPUTE_ENGINES, ", "))",
            ),
        )
    end

    # Problem sizes
    sizes_raw = get(bench, "problem_sizes", [1024, 2048])
    if !isa(sizes_raw, AbstractVector) || isempty(sizes_raw)
        throw(
            ArgumentError("problem_sizes must be a non-empty vector of positive integers"),
        )
    end
    problem_sizes = Int[Int(s) for s in sizes_raw]
    for s in problem_sizes
        if s <= 0
            throw(ArgumentError("Matrix dimension $s must be strictly positive"))
        end
    end

    # Preset adjustments
    if mode == "quick"
        problem_sizes = [512, 1024]
        trials = 2
    elseif mode == "standard"
        problem_sizes = [1024, 2048]
        trials = 3
    elseif mode == "stress"
        problem_sizes = [1024, 2048, 4096]
        trials = 5
    else
        trials = Int(get(bench, "trials", 3))
    end

    # Explicit trials override if mode is custom
    if mode == "custom"
        trials = Int(get(bench, "trials", 3))
    end
    if trials < 1 || trials > 50
        throw(ArgumentError("trials must be an integer in [1, 50], got $trials"))
    end

    # Target types
    types_raw = get(
        bench,
        "target_types",
        ["Float16", "Float32", "Float64", "Int8", "Int16", "Int32", "Int64"],
    )
    target_types = DataType[]
    for t_str in types_raw
        if !haskey(SUPPORTED_TYPE_MAP, string(t_str))
            throw(
                ArgumentError(
                    "Unsupported data type '$t_str'. Allowed: $(join(keys(SUPPORTED_TYPE_MAP), ", "))",
                ),
            )
        end
        push!(target_types, SUPPORTED_TYPE_MAP[string(t_str)])
    end

    run_cpu = Bool(get(bench, "run_cpu", true))
    run_gpu = Bool(get(bench, "run_gpu", true))

    # Backend selection
    gpu_backend = lowercase(string(get(bench, "gpu_backend", "auto")))
    if !(gpu_backend in ALLOWED_GPU_BACKENDS)
        throw(
            ArgumentError(
                "Invalid gpu_backend '$gpu_backend'. Allowed choices: $(join(ALLOWED_GPU_BACKENDS, ", "))",
            ),
        )
    end

    # Safety limits
    mem_frac = Float64(get(safety, "memory_safety_fraction", 0.75))
    if mem_frac <= 0.0 || mem_frac > 0.95
        throw(ArgumentError("memory_safety_fraction must be in (0.0, 0.95], got $mem_frac"))
    end

    # Outputs
    export_csv = Bool(get(output, "export_csv", true))
    export_metadata = Bool(get(output, "export_metadata", true))
    out_dir = string(get(output, "output_directory", "."))
    log_to_file = Bool(get(output, "log_to_file", true))

    return BenchmarkConfig(
        mode,
        engine,
        problem_sizes,
        trials,
        target_types,
        run_cpu,
        run_gpu,
        gpu_backend,
        mem_frac,
        export_csv,
        export_metadata,
        out_dir,
        log_to_file,
    )
end

"""
    load_config(path::String) -> BenchmarkConfig

Loads and validates a TOML configuration file.
"""
function load_config(path::String)
    if !isfile(path)
        throw(ArgumentError("Configuration file not found: $path"))
    end
    raw = TOML.parsefile(path)
    return validate_config(raw)
end

"""
    parse_cli_args(args::Vector{String}, base_dir::String) -> BenchmarkConfig

Parses command-line arguments and returns a configured `BenchmarkConfig`.
"""
function parse_cli_args(args::Vector{String}, base_dir::String)
    config_file = joinpath(base_dir, "config.toml")
    initial_dict = isfile(config_file) ? TOML.parsefile(config_file) : Dict{String, Any}()

    bench = get(initial_dict, "benchmark", Dict{String, Any}())
    safety = get(initial_dict, "safety", Dict{String, Any}())
    output = get(initial_dict, "output", Dict{String, Any}())

    idx = 1
    while idx <= length(args)
        arg = args[idx]
        if arg in ["-h", "--help"]
            print_usage()
            exit(0)
        elseif arg in ["-q", "--quick"]
            bench["mode"] = "quick"
        elseif arg == "--standard"
            bench["mode"] = "standard"
        elseif arg in ["--stress", "--full"]
            bench["mode"] = "stress"
        elseif arg in ["-e", "--engine"]
            idx += 1
            if idx > length(args)
                throw(
                    ArgumentError(
                        "$arg requires an engine identifier: $(join(ALLOWED_COMPUTE_ENGINES, ", "))",
                    ),
                )
            end
            bench["compute_engine"] = lowercase(strip(args[idx]))
        elseif arg == "--ka-only"
            bench["compute_engine"] = "ka"
        elseif arg == "--blas-only"
            bench["compute_engine"] = "blas"
        elseif arg == "--sizes"
            idx += 1
            if idx > length(args)
                throw(ArgumentError("--sizes requires a comma-separated list of integers"))
            end
            bench["problem_sizes"] = [parse(Int, strip(s)) for s in split(args[idx], ",")]
            bench["mode"] = "custom"
        elseif arg == "--trials"
            idx += 1
            if idx > length(args)
                throw(ArgumentError("--trials requires an integer"))
            end
            bench["trials"] = parse(Int, args[idx])
            bench["mode"] = "custom"
        elseif arg == "--types"
            idx += 1
            if idx > length(args)
                throw(ArgumentError("--types requires a comma-separated list of types"))
            end
            bench["target_types"] = [strip(s) for s in split(args[idx], ",")]
        elseif arg == "--cpu-only"
            bench["run_cpu"] = true
            bench["run_gpu"] = false
        elseif arg == "--gpu-only"
            bench["run_cpu"] = false
            bench["run_gpu"] = true
        elseif arg in ["--gpu-backend", "--backend"]
            idx += 1
            if idx > length(args)
                throw(
                    ArgumentError(
                        "$arg requires a backend identifier: $(join(ALLOWED_GPU_BACKENDS, ", "))",
                    ),
                )
            end
            bench["gpu_backend"] = lowercase(strip(args[idx]))
        elseif arg == "--config"
            idx += 1
            if idx > length(args)
                throw(ArgumentError("--config requires a filepath"))
            end
            file_cfg = TOML.parsefile(args[idx])
            bench = merge(bench, get(file_cfg, "benchmark", Dict{String, Any}()))
            safety = merge(safety, get(file_cfg, "safety", Dict{String, Any}()))
            output = merge(output, get(file_cfg, "output", Dict{String, Any}()))
        elseif arg == "--no-csv"
            output["export_csv"] = false
        elseif arg == "--no-metadata"
            output["export_metadata"] = false
        elseif arg == "--no-log"
            output["log_to_file"] = false
        elseif arg == "--out-dir"
            idx += 1
            if idx > length(args)
                throw(ArgumentError("--out-dir requires a directory path"))
            end
            output["output_directory"] = args[idx]
        else
            throw(
                ArgumentError("Unknown command-line argument: $arg. Use --help for usage."),
            )
        end
        idx += 1
    end

    merged = Dict{String, Any}("benchmark" => bench, "safety" => safety, "output" => output)
    return validate_config(merged)
end

function print_usage()
    println(
        """
Julia System Diagnostics & High-Intensity Benchmark Suite

Usage:
  julia hardware-diag.jl [OPTIONS]

Operational Presets:
  -h, --help               Display this help text and exit
  -q, --quick              Quick diagnostic preset (sizes: 512, 1024 | 2 trials)
      --standard           Standard benchmark preset (sizes: 1024, 2048 | 3 trials) [default]
      --stress, --full     High-intensity stress preset (sizes: 1024, 2048, 4096 | 5 trials)

Compute Engine & Abstraction Layer:
  -e, --engine E           Compute engine: both | ka | blas [default: both]
      --ka-only            Execute only unified KernelAbstractions.jl native kernels
      --blas-only          Execute only vendor-optimized BLAS libraries (oneMKL, cuBLAS, etc.)

Execution & Target Controls:
      --sizes S1,S2,...    Explicit matrix dimensions (e.g. --sizes 512,1024,2048)
      --trials K           Repetitions per configuration point (1 <= K <= 50)
      --types T1,T2,...    Target numeric types (Float16, Float32, Float64, Int8, Int16, Int32, Int64)
      --cpu-only           Execute only CPU thread scaling and multi-type benchmarks
      --gpu-only           Execute only GPU accelerator benchmarks
      --gpu-backend B      Select GPU backend: auto | all | oneapi | cuda | amdgpu | metal [default: auto]

File I/O & Configuration:
      --config FILE        Load benchmark configuration from TOML file
      --no-csv             Disable tidy CSV dataset export
      --no-metadata        Disable TOML provenance metadata export
      --no-log             Disable writing formatted text log to disk
      --out-dir DIR        Destination directory for exported files (default: current dir)

Examples:
  julia hardware-diag.jl --quick
  julia hardware-diag.jl --engine ka
  julia hardware-diag.jl --gpu-backend oneapi --engine both
  julia hardware-diag.jl --sizes 512,1024,2048 --trials 3
""",
    )
end

# ------------------------------------------------------------------------------
# 4. Formatting & Computational Utilities
# ------------------------------------------------------------------------------

"""
    format_bytes(bytes::Number) -> String

Formats an integer or float byte quantity into standard IEC units (B, KiB, MiB, GiB, TiB).
"""
function format_bytes(bytes::Number)
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    b = Float64(bytes)
    idx = 1
    while b >= 1024.0 && idx < length(units)
        b /= 1024.0
        idx += 1
    end
    return Printf.@sprintf("%.2f %s", b, units[idx])
end

"""
    format_seconds(secs::Real) -> String

Formats a duration in seconds into `MMm SSs` or `S.sss s` notation.
"""
function format_seconds(secs::Real)
    if secs < 0 || isnan(secs) || isinf(secs)
        return "--:--"
    end
    if secs < 1.0
        return Printf.@sprintf("%.3f s", secs)
    end
    m = floor(Int, secs / 60)
    s = floor(Int, secs % 60)
    return Printf.@sprintf("%02dm %02ds", m, s)
end

"""
    format_throughput(gflops::Float64, ::Type{T}) where {T} -> String

Formats arithmetic throughput into GFLOPS/TFLOPS (for floats) or GOP/s / TOP/s (for integers).
"""
function format_throughput(gflops::Float64, ::Type{T}) where {T}
    is_float = (T <: AbstractFloat || T <: Complex{<:AbstractFloat})
    unit_base = is_float ? "FLOPS" : "OP/s"
    if gflops >= 1000.0
        return Printf.@sprintf("%.2f T%s", gflops / 1000.0, unit_base)
    else
        return Printf.@sprintf("%.2f G%s", gflops, unit_base)
    end
end

"""
    estimate_matrix_bytes(N::Int, ::Type{T}) where {T} -> Int

Computes the total memory required for four N × N dense matrices of type T (A, B, C, D).
"""
estimate_matrix_bytes(N::Int, ::Type{T}) where {T} = 4 * N * N * sizeof(T)

"""
    arithmetic_ops(::Type{T}, N::Int) where {T} -> Float64

Computes the total arithmetic operations for dual GEMM accumulation D = A*B + A*C (4 N^3 FLOPs/OPs).
"""
arithmetic_ops(::Type{T}, N::Int) where {T <: Real} = 4.0 * Float64(N)^3
arithmetic_ops(::Type{T}, N::Int) where {T <: Complex} = 16.0 * Float64(N)^3

"""
    create_matrix(::Type{T}, N::Int) where {T} -> Matrix{T}

Allocates an N × N host matrix initialized with pseudorandom numbers.
"""
create_matrix(::Type{T}, N::Int) where {T <: AbstractFloat} = randn(T, N, N)
create_matrix(::Type{T}, N::Int) where {T <: Integer} = rand(T(1):T(4), N, N)
create_matrix(::Type{Complex{T}}, N::Int) where {T <: AbstractFloat} =
    randn(Complex{T}, N, N)

"""
    render_progress(current::Int, total::Int, start_time::Float64, task_label::String)

Renders an in-place terminal progress bar indicating overall progress, elapsed time, ETA, and active task.
"""
function render_progress(current::Int, total::Int, start_time::Float64, task_label::String)
    if !isa(stdout, Base.TTY)
        return
    end
    width = 26
    pct = total > 0 ? (current / total) : 0.0
    filled = round(Int, pct * width)
    bar = "█"^filled * "░"^(width - filled)

    elapsed = time() - start_time
    eta = (pct > 0.0) ? (elapsed / pct) - elapsed : 0.0
    label_clean = length(task_label) > 28 ? task_label[1:25] * "..." : rpad(task_label, 28)

    Printf.@printf(
        "\r  [%s] %5.1f%% | ETA: %-7s | %s\033[K",
        bar,
        pct * 100,
        format_seconds(eta),
        label_clean
    )
    flush(stdout)
end

"""
    get_safe_filepath(target_path::String) -> String

Ensures a target file path does not overwrite existing data, appending '#1', '#2', etc. if needed.
"""
function get_safe_filepath(target_path::String)
    if !isfile(target_path)
        return target_path
    end
    dir = dirname(target_path)
    base = basename(target_path)
    stem, ext = splitext(base)
    k = 1
    while true
        candidate = joinpath(dir, "$(stem)#$(k)$(ext)")
        if !isfile(candidate)
            return candidate
        end
        k += 1
    end
end

# ------------------------------------------------------------------------------
# 5. Hardware Introspection & Discovery
# ------------------------------------------------------------------------------

"""
    query_linux_cpu_features() -> Vector{String}

Reads CPU capability flags from `/proc/cpuinfo` if running on Linux.
"""
function query_linux_cpu_features()
    features = String[]
    if Sys.islinux() && isfile("/proc/cpuinfo")
        for line in eachline("/proc/cpuinfo")
            if startswith(line, "flags")
                parts = split(line, ":")
                if length(parts) >= 2
                    raw_flags = split(parts[2])
                    interesting = [
                        "fma",
                        "avx",
                        "avx2",
                        "avx512f",
                        "avx512dq",
                        "avx512vl",
                        "sse4_2",
                        "vnni",
                        "amx_bf16",
                        "amx_tile",
                    ]
                    for f in interesting
                        if f in raw_flags
                            push!(features, f)
                        end
                    end
                end
                break
            end
        end
    end
    return features
end

"""
    scan_cpu_and_system(io::IO)

Profiles and displays host system architecture, CPU topology, threadpools, memory, and BLAS backend.
"""
function scan_cpu_and_system(io::IO)
    println(io, "="^80)
    println(io, "  CPU Architecture & System Environment")
    println(io, "="^80)

    cpu_info = Sys.cpu_info()
    cpu_model = isempty(cpu_info) ? "Unknown" : cpu_info[1].model
    logical_cores = Sys.CPU_THREADS
    total_mem = Sys.total_memory()
    free_mem = Sys.free_memory()

    println(
        io,
        "Julia Version        : ",
        VERSION,
        " (commit ",
        Base.GIT_VERSION_INFO.commit_short,
        ")",
    )
    println(io, "Platform / OS        : ", Sys.MACHINE, " (", Sys.KERNEL, " kernel)")
    println(io, "Architecture         : ", Sys.ARCH, " (", Sys.WORD_SIZE, "-bit pointer)")
    println(io, "CPU Model            : ", cpu_model)
    println(
        io,
        "Physical / Logical   : ",
        length(cpu_info),
        " cores reported / ",
        logical_cores,
        " logical threads",
    )

    # Clock speeds
    if !isempty(cpu_info) && hasproperty(cpu_info[1], :speed)
        speeds = [c.speed for c in cpu_info if c.speed > 0]
        if !isempty(speeds)
            min_sp, max_sp = minimum(speeds), maximum(speeds)
            println(
                io,
                "CPU Frequencies      : ",
                min_sp,
                " MHz to ",
                max_sp,
                " MHz (current samples)",
            )
        end
    end

    features = query_linux_cpu_features()
    if !isempty(features)
        println(io, "SIMD / Vector ISA    : ", join(features, ", "))
    end

    println(io, "System RAM (Total)   : ", format_bytes(total_mem))
    println(io, "System RAM (Free)    : ", format_bytes(free_mem))

    # Threadpool distribution
    println(io, "\n--- Threadpool Topology ---")
    println(io, "Default Pool Threads : ", Threads.nthreads(:default))
    if isdefined(Threads, :nthreadpools)
        println(io, "Interactive Threads  : ", Threads.nthreads(:interactive))
    end
    if isdefined(Threads, :ngcthreads)
        println(io, "GC Threads           : ", Threads.ngcthreads())
    end

    # BLAS configuration
    println(io, "\n--- Linear Algebra Acceleration (BLAS/LAPACK) ---")
    blas_cfg = BLAS.get_config()
    println(io, "BLAS Configuration   : ", blas_cfg)
    println(io, "Active BLAS Threads  : ", BLAS.get_num_threads())

    # KernelAbstractions backend
    println(io, "\n--- Portable Hardware Abstraction ---")
    println(
        io,
        "KernelAbstractions   : v",
        pkgversion(KernelAbstractions),
        " (CPUBackend: Active)",
    )
end

"""
    probe_oneapi_backend(io::IO) -> GpuDeviceInfo

Specialized hardware prober for Intel oneAPI / Level Zero accelerators.
"""
function probe_oneapi_backend(io::IO)
    pkg = :oneAPI
    arr = :oneArray
    label = "Intel oneAPI / Level Zero"
    println(io, "\n[$label]")

    if Base.find_package("oneAPI") === nothing
        println(io, "  [-] oneAPI.jl is not installed in the active environment.")
        return GpuDeviceInfo(
            pkg,
            arr,
            label,
            false,
            "N/A",
            "N/A",
            0,
            0,
            0,
            0,
            0,
            0,
            "N/A",
            Dict{String, String}(),
        )
    end

    try
        Core.eval(Main, :(using oneAPI))
        return Base.invokelatest() do
            mod = getfield(Main, :oneAPI)
            if !isdefined(mod, :functional) || !mod.functional()
                println(io, "  [-] Driver or hardware not functional.")
                return GpuDeviceInfo(
                    pkg,
                    arr,
                    label,
                    false,
                    "N/A",
                    "N/A",
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    "N/A",
                    Dict{String, String}(),
                )
            end

            dev = mod.device()
            props = mod.oneL0.properties(dev)
            mem_props = mod.oneL0.memory_properties(dev)
            drv = mod.driver()
            drv_props = mod.oneL0.properties(drv)

            total_eus =
                props.numSlices * props.numSubslicesPerSlice * props.numEUsPerSubslice
            hardware_threads = total_eus * props.numThreadsPerEU
            total_vram = isempty(mem_props) ? 0 : mem_props[1].totalSize
            max_alloc = props.maxMemAllocSize
            clock_mhz = props.coreClockRate
            driver_ver = string(drv_props.driverVersion)
            simd_width = props.physicalEUSimdWidth
            timer_ns = props.timerResolution

            extra = Dict{String, String}(
                "simd_width" => string(simd_width),
                "device_id" => Printf.@sprintf("0x%04x", props.deviceId),
                "vendor_id" => Printf.@sprintf("0x%04x", props.vendorId)
            )

            ka_name = isdefined(mod, :oneAPIBackend) ? "oneAPIBackend" : "N/A"

            println(io, "  [+] Status           : Functional")
            println(io, "  [+] Device Name      : ", props.name)
            println(io, "  [+] Driver Version   : Level Zero v", driver_ver)
            println(
                io,
                "  [+] Execution Units  : ",
                total_eus,
                " EUs (",
                hardware_threads,
                " hardware threads, SIMD width ",
                simd_width,
                ")",
            )
            println(io, "  [+] Core Clock       : ", clock_mhz, " MHz")
            println(
                io,
                "  [+] Device Memory    : ",
                format_bytes(total_vram),
                " (Max single allocation: ",
                format_bytes(max_alloc),
                ")",
            )
            println(io, "  [+] Timer Resolution : ", timer_ns, " ns")
            println(io, "  [+] KA Abstraction   : ", ka_name)

            return GpuDeviceInfo(
                pkg,
                arr,
                label,
                true,
                props.name,
                driver_ver,
                total_eus,
                hardware_threads,
                clock_mhz,
                total_vram,
                max_alloc,
                timer_ns,
                ka_name,
                extra,
            )
        end
    catch err
        println(io, "  [-] Detection Error: ", sprint(showerror, err))
        return GpuDeviceInfo(
            pkg,
            arr,
            label,
            false,
            "N/A",
            "N/A",
            0,
            0,
            0,
            0,
            0,
            0,
            "N/A",
            Dict{String, String}(),
        )
    end
end

"""
    probe_cuda_backend(io::IO) -> GpuDeviceInfo

Specialized hardware prober for NVIDIA CUDA accelerators.
"""
function probe_cuda_backend(io::IO)
    pkg = :CUDA
    arr = :CuArray
    label = "NVIDIA CUDA"
    println(io, "\n[$label]")

    if Base.find_package("CUDA") === nothing
        println(io, "  [-] CUDA.jl is not installed in the active environment.")
        return GpuDeviceInfo(
            pkg,
            arr,
            label,
            false,
            "N/A",
            "N/A",
            0,
            0,
            0,
            0,
            0,
            0,
            "N/A",
            Dict{String, String}(),
        )
    end

    try
        Core.eval(Main, :(using CUDA))
        return Base.invokelatest() do
            mod = getfield(Main, :CUDA)
            if !isdefined(mod, :functional) || !mod.functional()
                println(io, "  [-] CUDA driver or hardware not functional.")
                return GpuDeviceInfo(
                    pkg,
                    arr,
                    label,
                    false,
                    "N/A",
                    "N/A",
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    "N/A",
                    Dict{String, String}(),
                )
            end

            dev = mod.device()
            dev_name = mod.name(dev)
            vram = mod.totalmem(dev)
            drv_ver = isdefined(mod, :driver_version) ? string(mod.driver_version()) : "N/A"
            rt_ver =
                isdefined(mod, :runtime_version) ? string(mod.runtime_version()) : "N/A"
            cap = isdefined(mod, :capability) ? string(mod.capability(dev)) : "N/A"

            sms =
                isdefined(mod, :attribute) &&
                isdefined(mod, :DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT) ?
                mod.attribute(dev, mod.DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT) : 0
            clock_khz =
                isdefined(mod, :attribute) && isdefined(mod, :DEVICE_ATTRIBUTE_CLOCK_RATE) ?
                mod.attribute(dev, mod.DEVICE_ATTRIBUTE_CLOCK_RATE) : 0
            clock_mhz = round(Int, clock_khz / 1000)
            max_threads =
                isdefined(mod, :attribute) &&
                isdefined(mod, :DEVICE_ATTRIBUTE_MAX_THREADS_PER_BLOCK) ?
                mod.attribute(dev, mod.DEVICE_ATTRIBUTE_MAX_THREADS_PER_BLOCK) : 1024

            extra = Dict{String, String}(
                "compute_capability" => cap,
                "runtime_toolkit" => rt_ver,
                "max_threads_per_block" => string(max_threads),
            )

            ka_name = isdefined(mod, :CUDABackend) ? "CUDABackend" : "N/A"

            println(io, "  [+] Status           : Functional")
            println(
                io,
                "  [+] Device Name      : ",
                dev_name,
                " (Compute Capability ",
                cap,
                ")",
            )
            println(
                io,
                "  [+] Driver / Toolkit : Driver v",
                drv_ver,
                " / Toolkit v",
                rt_ver,
            )
            if sms > 0
                println(
                    io,
                    "  [+] Multiprocessors  : ",
                    sms,
                    " SMs (Clock: ",
                    clock_mhz,
                    " MHz)",
                )
            end
            println(io, "  [+] Device VRAM      : ", format_bytes(vram))
            println(io, "  [+] KA Abstraction   : ", ka_name)

            return GpuDeviceInfo(
                pkg,
                arr,
                label,
                true,
                dev_name,
                drv_ver,
                sms,
                sms * 128,
                clock_mhz,
                vram,
                vram,
                0,
                ka_name,
                extra,
            )
        end
    catch err
        println(io, "  [-] CUDA Detection Error: ", sprint(showerror, err))
        return GpuDeviceInfo(
            pkg,
            arr,
            label,
            false,
            "N/A",
            "N/A",
            0,
            0,
            0,
            0,
            0,
            0,
            "N/A",
            Dict{String, String}(),
        )
    end
end

"""
    probe_amdgpu_backend(io::IO) -> GpuDeviceInfo

Specialized hardware prober for AMD ROCm / HIP accelerators.
"""
function probe_amdgpu_backend(io::IO)
    pkg = :AMDGPU
    arr = :ROCArray
    label = "AMD ROCm / HIP"
    println(io, "\n[$label]")

    if Base.find_package("AMDGPU") === nothing
        println(io, "  [-] AMDGPU.jl is not installed in the active environment.")
        return GpuDeviceInfo(
            pkg,
            arr,
            label,
            false,
            "N/A",
            "N/A",
            0,
            0,
            0,
            0,
            0,
            0,
            "N/A",
            Dict{String, String}(),
        )
    end

    try
        Core.eval(Main, :(using AMDGPU))
        return Base.invokelatest() do
            mod = getfield(Main, :AMDGPU)
            if !isdefined(mod, :functional) || !mod.functional()
                println(io, "  [-] AMDGPU driver or hardware not functional.")
                return GpuDeviceInfo(
                    pkg,
                    arr,
                    label,
                    false,
                    "N/A",
                    "N/A",
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    "N/A",
                    Dict{String, String}(),
                )
            end

            dev = mod.device()
            dev_name =
                isdefined(mod, :name) ? mod.name(dev) :
                (hasproperty(dev, :name) ? dev.name : string(dev))
            vram =
                isdefined(mod, :totalmem) ? mod.totalmem(dev) :
                (hasproperty(dev, :total_memory) ? dev.total_memory : 0)
            arch =
                isdefined(mod, :architecture) ? string(mod.architecture(dev)) :
                (hasproperty(dev, :gcn_arch_name) ? dev.gcn_arch_name : "N/A")
            wave_size = isdefined(mod, :wavefrontsize) ? mod.wavefrontsize(dev) : 64
            cus = hasproperty(dev, :compute_units) ? dev.compute_units : 0
            clock_mhz = hasproperty(dev, :max_clock_frequency) ? dev.max_clock_frequency : 0
            rocm_ver = isdefined(mod, :version) ? string(mod.version()) : "ROCm"

            extra = Dict{String, String}(
                "architecture" => arch,
                "wavefront_size" => string(wave_size),
            )

            ka_name = isdefined(mod, :ROCBackend) ? "ROCBackend" : "N/A"

            println(io, "  [+] Status           : Functional")
            println(io, "  [+] Device Name      : ", dev_name, " (Arch: ", arch, ")")
            println(io, "  [+] Runtime Version  : ", rocm_ver)
            if cus > 0
                println(
                    io,
                    "  [+] Compute Units    : ",
                    cus,
                    " CUs (Wavefront: ",
                    wave_size,
                    ", Clock: ",
                    clock_mhz,
                    " MHz)",
                )
            end
            if vram > 0
                println(io, "  [+] Device VRAM      : ", format_bytes(vram))
            end
            println(io, "  [+] KA Abstraction   : ", ka_name)

            return GpuDeviceInfo(
                pkg,
                arr,
                label,
                true,
                dev_name,
                rocm_ver,
                cus,
                cus * wave_size,
                clock_mhz,
                vram,
                vram,
                0,
                ka_name,
                extra,
            )
        end
    catch err
        println(io, "  [-] AMDGPU Detection Error: ", sprint(showerror, err))
        return GpuDeviceInfo(
            pkg,
            arr,
            label,
            false,
            "N/A",
            "N/A",
            0,
            0,
            0,
            0,
            0,
            0,
            "N/A",
            Dict{String, String}(),
        )
    end
end

"""
    probe_metal_backend(io::IO) -> GpuDeviceInfo

Specialized hardware prober for Apple Silicon Metal accelerators.
"""
function probe_metal_backend(io::IO)
    pkg = :Metal
    arr = :MtlArray
    label = "Apple Silicon Metal"
    println(io, "\n[$label]")

    if Base.find_package("Metal") === nothing
        println(io, "  [-] Metal.jl is not installed in the active environment.")
        return GpuDeviceInfo(
            pkg,
            arr,
            label,
            false,
            "N/A",
            "N/A",
            0,
            0,
            0,
            0,
            0,
            0,
            "N/A",
            Dict{String, String}(),
        )
    end

    try
        Core.eval(Main, :(using Metal))
        return Base.invokelatest() do
            mod = getfield(Main, :Metal)
            if !isdefined(mod, :functional) || !mod.functional()
                println(io, "  [-] Metal framework not functional.")
                return GpuDeviceInfo(
                    pkg,
                    arr,
                    label,
                    false,
                    "N/A",
                    "N/A",
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    "N/A",
                    Dict{String, String}(),
                )
            end

            dev = mod.device()
            dev_name =
                isdefined(mod, :name) ? mod.name(dev) :
                (hasproperty(dev, :name) ? dev.name : string(dev))
            vram = Sys.total_memory() # Apple Unified Memory architecture
            max_alloc = hasproperty(dev, :maxBufferLength) ? dev.maxBufferLength : 0

            extra = Dict{String, String}("architecture" => "Apple Silicon Unified Memory")

            ka_name = isdefined(mod, :MetalBackend) ? "MetalBackend" : "N/A"

            println(io, "  [+] Status           : Functional")
            println(io, "  [+] Device Name      : ", dev_name)
            println(
                io,
                "  [+] Unified Memory   : ",
                format_bytes(vram),
                " (Max Buffer: ",
                format_bytes(max_alloc),
                ")",
            )
            println(io, "  [+] KA Abstraction   : ", ka_name)

            return GpuDeviceInfo(
                pkg,
                arr,
                label,
                true,
                dev_name,
                "Metal",
                0,
                0,
                0,
                vram,
                max_alloc,
                0,
                ka_name,
                extra,
            )
        end
    catch err
        println(io, "  [-] Metal Detection Error: ", sprint(showerror, err))
        return GpuDeviceInfo(
            pkg,
            arr,
            label,
            false,
            "N/A",
            "N/A",
            0,
            0,
            0,
            0,
            0,
            0,
            "N/A",
            Dict{String, String}(),
        )
    end
end

"""
    probe_all_gpus(io::IO, backend_filter::String="auto") -> Vector{GpuDeviceInfo}

Detects and profiles GPU accelerator backends according to the requested filter.
"""
function probe_all_gpus(io::IO, backend_filter::String = "auto")
    println(io, "\n" * "="^80)
    println(io, "  Heterogeneous GPU Accelerator Discovery")
    println(io, "="^80)

    devices = GpuDeviceInfo[]
    filter_norm = lowercase(strip(backend_filter))

    if filter_norm in ["auto", "all", "oneapi"]
        push!(devices, probe_oneapi_backend(io))
    end
    if filter_norm in ["auto", "all", "cuda"]
        push!(devices, probe_cuda_backend(io))
    end
    if filter_norm in ["auto", "all", "amdgpu"]
        push!(devices, probe_amdgpu_backend(io))
    end
    if filter_norm in ["auto", "all", "metal"]
        push!(devices, probe_metal_backend(io))
    end

    functional = filter(d -> d.is_functional, devices)
    if isempty(functional) && filter_norm != "auto" && filter_norm != "all"
        println(
            io,
            "\n[!] Warning: Requested GPU backend '$backend_filter' is not functional or not installed.",
        )
    end

    return functional
end

"""
    get_ka_backend(gpu_info::GpuDeviceInfo) -> KernelAbstractions.Backend

Constructs the concrete `KernelAbstractions.Backend` object corresponding to the target GPU accelerator.
"""
function get_ka_backend(gpu_info::GpuDeviceInfo)
    mod = getfield(Main, gpu_info.pkg_symbol)
    if gpu_info.pkg_symbol == :oneAPI
        return mod.oneAPIBackend()
    elseif gpu_info.pkg_symbol == :CUDA
        return mod.CUDABackend()
    elseif gpu_info.pkg_symbol == :AMDGPU
        return mod.ROCBackend()
    elseif gpu_info.pkg_symbol == :Metal
        return mod.MetalBackend()
    else
        return KernelAbstractions.CPU()
    end
end

# ------------------------------------------------------------------------------
# 6. Benchmarking Engines
# ------------------------------------------------------------------------------

"""
    run_cpu_thread_scaling(config::BenchmarkConfig, log_io::IO, start_time::Float64,
                           prog::Ref{Int}, total_steps::Int) -> Vector{BenchmarkRecord}

Benchmarks CPU multi-threaded scaling on Float32 matrices across thread counts using BLAS.
"""
function run_cpu_thread_scaling(
    config::BenchmarkConfig,
    log_io::IO,
    start_time::Float64,
    prog::Ref{Int},
    total_steps::Int,
)
    records = BenchmarkRecord[]
    max_threads = Sys.CPU_THREADS
    p2_threads = [2^i for i in 0:floor(Int, log2(max_threads))]
    thread_counts = unique(sort(vcat(p2_threads, max_threads)))
    original_blas_threads = BLAS.get_num_threads()

    cpu_model = isempty(Sys.cpu_info()) ? "Unknown CPU" : Sys.cpu_info()[1].model
    free_ram = Sys.free_memory()
    max_allowed_ram = free_ram * config.memory_safety_fraction

    println(log_io, "\n" * "="^80)
    println(log_io, "  CPU Thread Scaling Benchmark (Float32 | BLAS GEMM)")
    println(log_io, "="^80)

    try
        for N in config.problem_sizes
            required_bytes = estimate_matrix_bytes(N, Float32)
            if required_bytes > max_allowed_ram
                println(
                    log_io,
                    "\n[!] SKIPPED Problem Size $(N)x$(N): Memory footprint $(format_bytes(required_bytes)) exceeds threshold $(format_bytes(max_allowed_ram))",
                )
                continue
            end

            total_ops = arithmetic_ops(Float32, N)
            println(
                log_io,
                "\n▶ Problem Size: $(N) x $(N) | Matrix Footprint: ",
                format_bytes(required_bytes),
            )
            Printf.@printf(
                log_io,
                "  %-10s | %-12s | %-12s | %-12s | %-8s | %-12s | %-10s\n",
                "Threads",
                "Min Time",
                "Median Time",
                "Throughput",
                "Scaling",
                "Parallel Eff",
                "Jitter"
            )
            println(log_io, "  " * "-"^80)

            A = create_matrix(Float32, N)
            B = create_matrix(Float32, N)
            C = create_matrix(Float32, N)
            D = similar(A)
            baseline_time_ms = 0.0

            for t in thread_counts
                prog[] += 1
                render_progress(
                    prog[],
                    total_steps,
                    start_time,
                    "CPU BLAS $(N)x$(N) ($(t)T)",
                )

                BLAS.set_num_threads(t)

                # Warmup run & JIT compile
                mul!(D, A, B)
                mul!(D, A, C, true, true)

                GC.gc(false)
                times = Float64[]
                for _ in 1:config.trials
                    t_run = @elapsed begin
                        mul!(D, A, B)
                        mul!(D, A, C, true, true)
                    end
                    push!(times, t_run)
                end

                min_t_ms = minimum(times) * 1000.0
                med_t_ms = median(times) * 1000.0
                mean_t_ms = mean(times) * 1000.0
                std_t_ms = std(times) * 1000.0
                jitter = ((maximum(times) - minimum(times)) / minimum(times)) * 100.0
                gflops = total_ops / (minimum(times) * 1e9)

                if t == 1
                    baseline_time_ms = min_t_ms
                end
                scaling = baseline_time_ms / min_t_ms
                parallel_eff = (scaling / t) * 100.0

                label = (t == max_threads && !(t in p2_threads)) ? "$t (Max)" : "$t"
                tp_str = format_throughput(gflops, Float32)
                Printf.@printf(
                    log_io,
                    "  %-10s | %9.3f ms | %9.3f ms | %-12s | %6.2fx  | %8.1f%%   | %6.2f%%\n",
                    label,
                    min_t_ms,
                    med_t_ms,
                    tp_str,
                    scaling,
                    parallel_eff,
                    jitter
                )
                flush(log_io)

                push!(
                    records,
                    BenchmarkRecord(
                        "CPU",
                        "OpenBLAS",
                        "VendorBLAS",
                        cpu_model,
                        "Float32",
                        N,
                        t,
                        total_ops,
                        min_t_ms,
                        med_t_ms,
                        mean_t_ms,
                        std_t_ms,
                        jitter,
                        gflops,
                        scaling,
                        parallel_eff,
                        1.0,
                        1.0,
                    ),
                )
            end
        end
    finally
        BLAS.set_num_threads(original_blas_threads)
    end

    return records
end

"""
    run_cpu_multitype(config::BenchmarkConfig, log_io::IO, start_time::Float64,
                      prog::Ref{Int}, total_steps::Int) -> Vector{BenchmarkRecord}

Evaluates multi-precision floating-point and integer GEMM throughput on CPU.
Supports both Vendor BLAS and unified KernelAbstractions.jl native kernels.
"""
function run_cpu_multitype(
    config::BenchmarkConfig,
    log_io::IO,
    start_time::Float64,
    prog::Ref{Int},
    total_steps::Int,
)
    records = BenchmarkRecord[]
    max_threads = Sys.CPU_THREADS
    original_blas_threads = BLAS.get_num_threads()
    cpu_model = isempty(Sys.cpu_info()) ? "Unknown CPU" : Sys.cpu_info()[1].model
    cpu_backend = KernelAbstractions.CPU()

    free_ram = Sys.free_memory()
    max_allowed_ram = free_ram * config.memory_safety_fraction

    println(log_io, "\n" * "="^80)
    println(
        log_io,
        "  CPU Multi-Precision & Multi-Type Suite (Engine: $(uppercase(config.compute_engine)))",
    )
    println(log_io, "="^80)

    try
        for N in config.problem_sizes
            println(log_io, "\n▶ Problem Size: $(N) x $(N)")
            Printf.@printf(
                log_io,
                "  %-10s | %-12s | %-10s | %-12s | %-12s | %-12s | %-14s | %-10s\n",
                "Type",
                "Engine",
                "Threads",
                "Footprint",
                "Min Time",
                "Median Time",
                "Throughput",
                "Jitter"
            )
            println(log_io, "  " * "-"^98)

            for T in config.target_types
                required_bytes = estimate_matrix_bytes(N, T)
                if required_bytes > max_allowed_ram
                    println(
                        log_io,
                        "  [!] Skipped $(T): Memory $(format_bytes(required_bytes)) exceeds threshold",
                    )
                    continue
                end

                total_ops = arithmetic_ops(T, N)

                # 1. Vendor BLAS execution
                if config.compute_engine in ["both", "blas"]
                    for t in [1, max_threads]
                        prog[] += 1
                        render_progress(
                            prog[],
                            total_steps,
                            start_time,
                            "CPU BLAS $(T) $(N)x$(N) ($(t)T)",
                        )

                        BLAS.set_num_threads(t)
                        label_t = (t == max_threads) ? "$t (Max)" : "$t"

                        try
                            A = create_matrix(T, N)
                            B = create_matrix(T, N)
                            C = create_matrix(T, N)
                            D = similar(A)

                            # Warmup
                            mul!(D, A, B)
                            mul!(D, A, C, true, true)

                            GC.gc(false)
                            times = Float64[]
                            for _ in 1:config.trials
                                t_run = @elapsed begin
                                    mul!(D, A, B)
                                    mul!(D, A, C, true, true)
                                end
                                push!(times, t_run)
                            end

                            min_t_ms = minimum(times) * 1000.0
                            med_t_ms = median(times) * 1000.0
                            mean_t_ms = mean(times) * 1000.0
                            std_t_ms = std(times) * 1000.0
                            jitter =
                                ((maximum(times) - minimum(times)) / minimum(times)) * 100.0
                            gflops = total_ops / (minimum(times) * 1e9)

                            tp_str = format_throughput(gflops, T)
                            Printf.@printf(
                                log_io,
                                "  %-10s | %-12s | %-10s | %-12s | %9.3f ms | %9.3f ms | %-14s | %6.2f%%\n",
                                string(T),
                                "VendorBLAS",
                                label_t,
                                format_bytes(required_bytes),
                                min_t_ms,
                                med_t_ms,
                                tp_str,
                                jitter
                            )

                            push!(
                                records,
                                BenchmarkRecord(
                                    "CPU",
                                    "OpenBLAS",
                                    "VendorBLAS",
                                    cpu_model,
                                    string(T),
                                    N,
                                    t,
                                    total_ops,
                                    min_t_ms,
                                    med_t_ms,
                                    mean_t_ms,
                                    std_t_ms,
                                    jitter,
                                    gflops,
                                    1.0,
                                    100.0,
                                    1.0,
                                    1.0,
                                ),
                            )
                        catch err
                            Printf.@printf(
                                log_io,
                                "  %-10s | %-12s | %-10s | %-12s | %-40s\n",
                                string(T),
                                "VendorBLAS",
                                label_t,
                                format_bytes(required_bytes),
                                "UNSUPPORTED / FAILED: $(typeof(err))"
                            )
                        end
                        flush(log_io)
                    end
                end

                # 2. KernelAbstractions.jl Native Execution
                if config.compute_engine in ["both", "ka"]
                    prog[] += 1
                    render_progress(
                        prog[],
                        total_steps,
                        start_time,
                        "CPU KA $(T) $(N)x$(N)",
                    )

                    try
                        A = create_matrix(T, N)
                        B = create_matrix(T, N)
                        C = create_matrix(T, N)
                        D = similar(A)

                        ka_kernel! = gemm_accum_kernel!(cpu_backend, (16, 16))
                        # Warmup
                        ka_kernel!(D, A, B, C, N; ndrange = (N, N))
                        KernelAbstractions.synchronize(cpu_backend)

                        GC.gc(false)
                        times = Float64[]
                        for _ in 1:config.trials
                            t_run = @elapsed begin
                                ka_kernel!(D, A, B, C, N; ndrange = (N, N))
                                KernelAbstractions.synchronize(cpu_backend)
                            end
                            push!(times, t_run)
                        end

                        min_t_ms = minimum(times) * 1000.0
                        med_t_ms = median(times) * 1000.0
                        mean_t_ms = mean(times) * 1000.0
                        std_t_ms = std(times) * 1000.0
                        jitter =
                            ((maximum(times) - minimum(times)) / minimum(times)) * 100.0
                        gflops = total_ops / (minimum(times) * 1e9)

                        tp_str = format_throughput(gflops, T)
                        Printf.@printf(
                            log_io,
                            "  %-10s | %-12s | %-10s | %-12s | %9.3f ms | %9.3f ms | %-14s | %6.2f%%\n",
                            string(T),
                            "KernelAbstr",
                            "$(Threads.nthreads()) (Pool)",
                            format_bytes(required_bytes),
                            min_t_ms,
                            med_t_ms,
                            tp_str,
                            jitter
                        )

                        push!(
                            records,
                            BenchmarkRecord(
                                "CPU",
                                "KA.CPU",
                                "KernelAbstractions",
                                cpu_model,
                                string(T),
                                N,
                                Threads.nthreads(),
                                total_ops,
                                min_t_ms,
                                med_t_ms,
                                mean_t_ms,
                                std_t_ms,
                                jitter,
                                gflops,
                                1.0,
                                100.0,
                                1.0,
                                1.0,
                            ),
                        )
                    catch err
                        Printf.@printf(
                            log_io,
                            "  %-10s | %-12s | %-10s | %-12s | %-40s\n",
                            string(T),
                            "KernelAbstr",
                            "Pool",
                            format_bytes(required_bytes),
                            "UNSUPPORTED / FAILED: $(typeof(err))"
                        )
                    end
                    flush(log_io)
                end
            end
        end
    finally
        BLAS.set_num_threads(original_blas_threads)
    end

    return records
end

"""
    device_synchronize(mod::Module)

Issues hardware synchronization across any GPU accelerator backend.
"""
function device_synchronize(mod::Module)
    if isdefined(mod, :synchronize)
        mod.synchronize()
    end
end

"""
    reclaim_device_memory(mod::Module)

Reclaims cached memory allocations across GPU backends to prevent out-of-memory fragmentation.
"""
function reclaim_device_memory(mod::Module)
    GC.gc(false)
    if isdefined(mod, :reclaim)
        try
            mod.reclaim()
        catch
        end
    elseif isdefined(mod, :memory_pool)
        try
            pool = mod.memory_pool()
            if isdefined(pool, :reclaim)
                pool.reclaim()
            end
        catch
        end
    end
end

"""
    run_gpu_benchmarks(gpu_info::GpuDeviceInfo, config::BenchmarkConfig,
                       cpu_records::Vector{BenchmarkRecord}, log_io::IO,
                       start_time::Float64, prog::Ref{Int}, total_steps::Int) -> Vector{BenchmarkRecord}

Executes GPU benchmarks across matrix sizes and numeric types on any detected GPU backend.
Evaluates both architecture-agnostic KernelAbstractions.jl kernels and vendor-optimized BLAS libraries.
"""
function run_gpu_benchmarks(
    gpu_info::GpuDeviceInfo,
    config::BenchmarkConfig,
    cpu_records::Vector{BenchmarkRecord},
    log_io::IO,
    start_time::Float64,
    prog::Ref{Int},
    total_steps::Int,
)
    records = BenchmarkRecord[]
    max_t = Sys.CPU_THREADS

    println(log_io, "\n" * "="^80)
    println(log_io, "  GPU Accelerator Benchmark: $(gpu_info.vendor_label)")
    println(
        log_io,
        "  Target Device: $(gpu_info.device_name) | Abstraction: $(gpu_info.ka_backend_name)",
    )
    println(log_io, "="^80)

    Base.invokelatest() do
        mod = getfield(Main, gpu_info.pkg_symbol)
        ka_backend = get_ka_backend(gpu_info)

        for N in config.problem_sizes
            println(log_io, "\n▶ Problem Size: $(N) x $(N)")
            Printf.@printf(
                log_io,
                "  %-10s | %-12s | %-12s | %-12s | %-14s | %-10s | %-14s | %-15s\n",
                "Type",
                "Engine",
                "Min Time",
                "Median Time",
                "Throughput",
                "Jitter",
                "vs CPU (1T)",
                "vs CPU (Max T)"
            )
            println(log_io, "  " * "-"^104)

            for T in config.target_types
                total_ops = arithmetic_ops(T, N)
                matrix_bytes = N * N * sizeof(T)

                if gpu_info.max_alloc_bytes > 0 && matrix_bytes > gpu_info.max_alloc_bytes
                    Printf.@printf(
                        log_io,
                        "  %-10s | %-90s\n",
                        string(T),
                        "EXCEEDS MAX DEVICE ALLOCATION ($(format_bytes(matrix_bytes)) > $(format_bytes(gpu_info.max_alloc_bytes)))"
                    )
                    flush(log_io)
                    continue
                end

                # --------------------------------------------------------------
                # A. Backend-Agnostic KernelAbstractions.jl Native Kernel
                # --------------------------------------------------------------
                if config.compute_engine in ["both", "ka"]
                    prog[] += 1
                    render_progress(
                        prog[],
                        total_steps,
                        start_time,
                        "$(gpu_info.ka_backend_name) $(T) $(N)x$(N)",
                    )

                    try
                        h_A = create_matrix(T, N)
                        h_B = create_matrix(T, N)
                        h_C = create_matrix(T, N)

                        d_A = KernelAbstractions.allocate(ka_backend, T, N, N)
                        d_B = KernelAbstractions.allocate(ka_backend, T, N, N)
                        d_C = KernelAbstractions.allocate(ka_backend, T, N, N)
                        d_D = KernelAbstractions.allocate(ka_backend, T, N, N)

                        KernelAbstractions.copyto!(ka_backend, d_A, h_A)
                        KernelAbstractions.copyto!(ka_backend, d_B, h_B)
                        KernelAbstractions.copyto!(ka_backend, d_C, h_C)

                        ka_kernel! = gemm_accum_kernel!(ka_backend, (16, 16))
                        # Warmup & compile
                        ka_kernel!(d_D, d_A, d_B, d_C, N; ndrange = (N, N))
                        KernelAbstractions.synchronize(ka_backend)

                        times = Float64[]
                        for _ in 1:config.trials
                            t_run = @elapsed begin
                                ka_kernel!(d_D, d_A, d_B, d_C, N; ndrange = (N, N))
                                KernelAbstractions.synchronize(ka_backend)
                            end
                            push!(times, t_run)
                        end

                        min_t_ms = minimum(times) * 1000.0
                        med_t_ms = median(times) * 1000.0
                        mean_t_ms = mean(times) * 1000.0
                        std_t_ms = std(times) * 1000.0
                        jitter =
                            ((maximum(times) - minimum(times)) / minimum(times)) * 100.0
                        gflops = total_ops / (minimum(times) * 1e9)

                        cpu_1t_rec = filter(
                            r ->
                                r.device_type == "CPU" &&
                                r.data_type == string(T) &&
                                r.matrix_dim == N &&
                                r.num_threads == 1,
                            cpu_records,
                        )
                        cpu_maxt_rec = filter(
                            r ->
                                r.device_type == "CPU" &&
                                r.data_type == string(T) &&
                                r.matrix_dim == N &&
                                r.num_threads == max_t,
                            cpu_records,
                        )

                        speedup_1t =
                            !isempty(cpu_1t_rec) ? (cpu_1t_rec[1].min_time_ms / min_t_ms) :
                            1.0
                        speedup_maxt =
                            !isempty(cpu_maxt_rec) ?
                            (cpu_maxt_rec[1].min_time_ms / min_t_ms) : 1.0
                        speedup_1t_str =
                            !isempty(cpu_1t_rec) ? Printf.@sprintf("%.2fx", speedup_1t) :
                            "N/A"
                        speedup_maxt_str =
                            !isempty(cpu_maxt_rec) ?
                            Printf.@sprintf("%.2fx", speedup_maxt) : "N/A"

                        tp_str = format_throughput(gflops, T)
                        Printf.@printf(
                            log_io,
                            "  %-10s | %-12s | %9.3f ms | %9.3f ms | %-14s | %6.2f%%   | %-14s | %-15s\n",
                            string(T),
                            "KernelAbstr",
                            min_t_ms,
                            med_t_ms,
                            tp_str,
                            jitter,
                            speedup_1t_str,
                            speedup_maxt_str
                        )

                        push!(
                            records,
                            BenchmarkRecord(
                                "GPU",
                                String(gpu_info.pkg_symbol),
                                "KernelAbstractions",
                                gpu_info.device_name,
                                string(T),
                                N,
                                0,
                                total_ops,
                                min_t_ms,
                                med_t_ms,
                                mean_t_ms,
                                std_t_ms,
                                jitter,
                                gflops,
                                1.0,
                                100.0,
                                speedup_1t,
                                speedup_maxt,
                            ),
                        )

                        d_A = nothing
                        d_B = nothing
                        d_C = nothing
                        d_D = nothing
                        reclaim_device_memory(mod)
                    catch err
                        Printf.@printf(
                            log_io,
                            "  %-10s | %-12s | %-76s\n",
                            string(T),
                            "KernelAbstr",
                            "UNSUPPORTED ON KA BACKEND: $(typeof(err))"
                        )
                    end
                    flush(log_io)
                end

                # --------------------------------------------------------------
                # B. Vendor-Optimized BLAS GEMM (Peak Hardware Library)
                # --------------------------------------------------------------
                if config.compute_engine in ["both", "blas"]
                    prog[] += 1
                    render_progress(
                        prog[],
                        total_steps,
                        start_time,
                        "$(gpu_info.vendor_label) BLAS $(T) $(N)x$(N)",
                    )

                    try
                        ArrayType = getfield(mod, gpu_info.array_symbol)
                        h_A = create_matrix(T, N)
                        h_B = create_matrix(T, N)
                        h_C = create_matrix(T, N)

                        d_A = ArrayType(h_A)
                        d_B = ArrayType(h_B)
                        d_C = ArrayType(h_C)
                        d_D = similar(d_A)

                        # JIT compilation & warm-up
                        mul!(d_D, d_A, d_B)
                        mul!(d_D, d_A, d_C, true, true)
                        device_synchronize(mod)

                        times = Float64[]
                        for _ in 1:config.trials
                            t_run = @elapsed begin
                                mul!(d_D, d_A, d_B)
                                mul!(d_D, d_A, d_C, true, true)
                                device_synchronize(mod)
                            end
                            push!(times, t_run)
                        end

                        min_t_ms = minimum(times) * 1000.0
                        med_t_ms = median(times) * 1000.0
                        mean_t_ms = mean(times) * 1000.0
                        std_t_ms = std(times) * 1000.0
                        jitter =
                            ((maximum(times) - minimum(times)) / minimum(times)) * 100.0
                        gflops = total_ops / (minimum(times) * 1e9)

                        cpu_1t_rec = filter(
                            r ->
                                r.device_type == "CPU" &&
                                r.data_type == string(T) &&
                                r.matrix_dim == N &&
                                r.num_threads == 1,
                            cpu_records,
                        )
                        cpu_maxt_rec = filter(
                            r ->
                                r.device_type == "CPU" &&
                                r.data_type == string(T) &&
                                r.matrix_dim == N &&
                                r.num_threads == max_t,
                            cpu_records,
                        )

                        speedup_1t =
                            !isempty(cpu_1t_rec) ? (cpu_1t_rec[1].min_time_ms / min_t_ms) :
                            1.0
                        speedup_maxt =
                            !isempty(cpu_maxt_rec) ?
                            (cpu_maxt_rec[1].min_time_ms / min_t_ms) : 1.0
                        speedup_1t_str =
                            !isempty(cpu_1t_rec) ? Printf.@sprintf("%.2fx", speedup_1t) :
                            "N/A"
                        speedup_maxt_str =
                            !isempty(cpu_maxt_rec) ?
                            Printf.@sprintf("%.2fx", speedup_maxt) : "N/A"

                        tp_str = format_throughput(gflops, T)
                        Printf.@printf(
                            log_io,
                            "  %-10s | %-12s | %9.3f ms | %9.3f ms | %-14s | %6.2f%%   | %-14s | %-15s\n",
                            string(T),
                            "VendorBLAS",
                            min_t_ms,
                            med_t_ms,
                            tp_str,
                            jitter,
                            speedup_1t_str,
                            speedup_maxt_str
                        )

                        push!(
                            records,
                            BenchmarkRecord(
                                "GPU",
                                String(gpu_info.pkg_symbol),
                                "VendorBLAS",
                                gpu_info.device_name,
                                string(T),
                                N,
                                0,
                                total_ops,
                                min_t_ms,
                                med_t_ms,
                                mean_t_ms,
                                std_t_ms,
                                jitter,
                                gflops,
                                1.0,
                                100.0,
                                speedup_1t,
                                speedup_maxt,
                            ),
                        )

                        d_A = nothing
                        d_B = nothing
                        d_C = nothing
                        d_D = nothing
                        reclaim_device_memory(mod)
                    catch err
                        Printf.@printf(
                            log_io,
                            "  %-10s | %-12s | %-76s\n",
                            string(T),
                            "VendorBLAS",
                            "UNSUPPORTED ON BACKEND BLAS: $(typeof(err))"
                        )
                    end
                    flush(log_io)
                end
            end
        end
    end

    return records
end

# ------------------------------------------------------------------------------
# 7. Data Exporters (Tidy CSV & TOML Metadata)
# ------------------------------------------------------------------------------

"""
    export_records_to_csv(records::Vector{BenchmarkRecord}, filepath::String)

Writes benchmark records to a tidy CSV dataset for downstream analysis and plotting.
"""
function export_records_to_csv(records::Vector{BenchmarkRecord}, filepath::String)
    open(filepath, "w") do f
        println(
            f,
            "device_type,backend,kernel_engine,device_name,data_type,matrix_dim,num_threads,total_ops,min_time_ms,median_time_ms,mean_time_ms,std_time_ms,jitter_pct,throughput_gflops,speedup_vs_1t,parallel_efficiency_pct,speedup_vs_cpu_1t,speedup_vs_cpu_maxt",
        )
        for r in records
            Printf.@printf(
                f,
                "%s,%s,%s,\"%s\",%s,%d,%d,%.1f,%.4f,%.4f,%.4f,%.4f,%.2f,%.4f,%.4f,%.2f,%.4f,%.4f\n",
                r.device_type,
                r.backend,
                r.kernel_engine,
                r.device_name,
                r.data_type,
                r.matrix_dim,
                r.num_threads,
                r.total_ops,
                r.min_time_ms,
                r.median_time_ms,
                r.mean_time_ms,
                r.std_time_ms,
                r.jitter_pct,
                r.throughput_gflops,
                r.speedup_vs_1t,
                r.parallel_efficiency_pct,
                r.speedup_vs_cpu_1t,
                r.speedup_vs_cpu_maxt
            )
        end
    end
end

"""
    export_metadata_to_toml(config::BenchmarkConfig, gpus::Vector{GpuDeviceInfo}, filepath::String)

Exports platform fingerprint and runtime configuration parameters in structured TOML format.
"""
function export_metadata_to_toml(
    config::BenchmarkConfig,
    gpus::Vector{GpuDeviceInfo},
    filepath::String,
)
    cpu_info = Sys.cpu_info()
    cpu_model = isempty(cpu_info) ? "Unknown" : cpu_info[1].model

    meta = Dict{String, Any}(
        "provenance" => Dict{String, Any}(
            "timestamp" => Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"),
            "hostname" => gethostname(),
            "julia_version" => string(VERSION),
            "julia_commit" => string(Base.GIT_VERSION_INFO.commit_short),
            "os" => string(Sys.KERNEL),
            "machine" => string(Sys.MACHINE),
            "word_size" => Sys.WORD_SIZE,
            "cpu_model" => cpu_model,
            "logical_threads" => Sys.CPU_THREADS,
            "system_ram_bytes" => Sys.total_memory(),
            "blas_vendor" => string(BLAS.get_config()),
            "kernel_abstractions_version" => string(pkgversion(KernelAbstractions)),
        ),
        "configuration" => Dict{String, Any}(
            "mode" => config.mode,
            "compute_engine" => config.compute_engine,
            "problem_sizes" => config.problem_sizes,
            "trials" => config.trials,
            "target_types" => [string(t) for t in config.target_types],
            "run_cpu" => config.run_cpu,
            "run_gpu" => config.run_gpu,
            "gpu_backend" => config.gpu_backend,
            "memory_safety_fraction" => config.memory_safety_fraction,
        ),
        "accelerators" => [
            Dict{String, Any}(
                "vendor" => g.vendor_label,
                "device_name" => g.device_name,
                "driver_version" => g.driver_version,
                "compute_units" => g.compute_units,
                "hardware_threads" => g.hardware_threads,
                "core_clock_mhz" => g.core_clock_mhz,
                "total_memory_bytes" => g.total_memory_bytes,
                "ka_backend" => g.ka_backend_name,
                "extra_attributes" => g.extra_attributes,
            ) for g in gpus
        ],
    )

    open(filepath, "w") do f
        TOML.print(f, meta)
    end
end

# ------------------------------------------------------------------------------
# 8. Main Execution Pipeline
# ------------------------------------------------------------------------------

"""
    main(args::Vector{String}=ARGS)

Top-level orchestration function executing hardware discovery, multi-stage benchmarks,
progress visualization, and result serialization.
"""
function main(args::Vector{String} = ARGS)
    base_dir = @__DIR__
    config = parse_cli_args(args, base_dir)

    timestamp = Dates.format(now(), "yyyy-mm-dd_HH-MM-SS")
    out_dir = isempty(config.output_directory) ? base_dir : config.output_directory
    mkpath(out_dir)

    log_filename = joinpath(out_dir, "hardware_benchmark_$(timestamp).log")
    csv_filename = joinpath(out_dir, "hardware_benchmark_$(timestamp).csv")
    toml_filename = joinpath(out_dir, "hardware_benchmark_$(timestamp).toml")

    # Safekeeping checks
    log_filename = get_safe_filepath(log_filename)
    csv_filename = get_safe_filepath(csv_filename)
    toml_filename = get_safe_filepath(toml_filename)

    log_io = config.log_to_file ? open(log_filename, "w") : IOBuffer()

    try
        # Step 1: System Introspection
        scan_cpu_and_system(stdout)
        if config.log_to_file
            scan_cpu_and_system(log_io)
        end

        # Step 2: GPU Discovery
        functional_gpus = GpuDeviceInfo[]
        if config.run_gpu
            functional_gpus = probe_all_gpus(stdout, config.gpu_backend)
            if config.log_to_file
                probe_all_gpus(log_io, config.gpu_backend)
            end
        else
            println("\n[GPU Discovery Skipped (--cpu-only)]")
            if config.log_to_file
                println(log_io, "\n[GPU Discovery Skipped (--cpu-only)]")
            end
        end

        # Step 3: Compute Step Planning for Progress Meter
        max_threads = Sys.CPU_THREADS
        p2_threads = [2^i for i in 0:floor(Int, log2(max_threads))]
        num_thread_steps = length(unique(sort(vcat(p2_threads, max_threads))))

        cpu_scaling_steps =
            config.run_cpu ? (length(config.problem_sizes) * num_thread_steps) : 0

        # CPU multitype steps (BLAS: 2 thread counts per type; KA: 1 step per type)
        blas_cpu_steps =
            config.compute_engine in ["both", "blas"] ?
            (length(config.problem_sizes) * length(config.target_types) * 2) : 0
        ka_cpu_steps =
            config.compute_engine in ["both", "ka"] ?
            (length(config.problem_sizes) * length(config.target_types)) : 0
        cpu_multitype_steps = config.run_cpu ? (blas_cpu_steps + ka_cpu_steps) : 0

        # GPU steps (KA + BLAS per functional GPU)
        gpu_engine_factor = (config.compute_engine == "both") ? 2 : 1
        gpu_steps =
            config.run_gpu ?
            (
                length(functional_gpus) *
                length(config.problem_sizes) *
                length(config.target_types) *
                gpu_engine_factor
            ) : 0

        total_steps = cpu_scaling_steps + cpu_multitype_steps + gpu_steps
        prog_counter = Ref(0)

        # Step 4: Run Benchmark Stages
        println("\n" * "="^80)
        println("  Executing Benchmark Suite")
        println(
            "  Mode: $(uppercase(config.mode)) | Engine: $(uppercase(config.compute_engine)) | Backend: $(uppercase(config.gpu_backend))",
        )
        println(
            "  Problem Sizes: $(config.problem_sizes) | Measurement Trials: $(config.trials)",
        )
        if config.log_to_file
            println("  Output Log File: $log_filename")
        end
        println("="^80)

        wall_start = time()
        all_records = BenchmarkRecord[]

        if config.run_cpu
            cpu_scale_records = run_cpu_thread_scaling(
                config,
                log_io,
                wall_start,
                prog_counter,
                total_steps,
            )
            append!(all_records, cpu_scale_records)

            cpu_multi_records =
                run_cpu_multitype(config, log_io, wall_start, prog_counter, total_steps)
            append!(all_records, cpu_multi_records)
        end

        if config.run_gpu
            for gpu in functional_gpus
                gpu_records = run_gpu_benchmarks(
                    gpu,
                    config,
                    all_records,
                    log_io,
                    wall_start,
                    prog_counter,
                    total_steps,
                )
                append!(all_records, gpu_records)
            end
        end

        wall_elapsed = time() - wall_start

        # Clear progress line
        if isa(stdout, Base.TTY)
            print("\r\033[K")
        end

        # Step 5: Export Data Files
        if config.export_csv && !isempty(all_records)
            export_records_to_csv(all_records, csv_filename)
        end
        if config.export_metadata
            export_metadata_to_toml(config, functional_gpus, toml_filename)
        end

        # Step 6: Console Summary
        println("\n✓ Benchmarking Suite Completed Successfully!")
        println(
            "  • Total Elapsed Time : ",
            format_seconds(wall_elapsed),
            " (",
            Printf.@sprintf("%.2f s", wall_elapsed),
            ")",
        )
        if config.log_to_file
            println("  • Diagnostic Report  : ", abspath(log_filename))
        end
        if config.export_csv && !isempty(all_records)
            println("  • Tidy CSV Dataset   : ", abspath(csv_filename))
        end
        if config.export_metadata
            println("  • Platform Metadata  : ", abspath(toml_filename))
        end
        println()

    catch err
        if isa(stdout, Base.TTY)
            print("\r\033[K")
        end
        println("\n✖ Benchmark Execution Terminated on Error: ", sprint(showerror, err))
        rethrow(err)
    finally
        if config.log_to_file && isopen(log_io)
            close(log_io)
        end
    end
end

# Execute if invoked directly from command-line
if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
