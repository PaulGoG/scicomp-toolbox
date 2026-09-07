"""
Benchmark stages: the CPU thread-scaling sweep, the CPU element-type suite and the
accelerator suite, all producing [`BenchmarkRecord`](@ref)s.
"""
module Benchmark

using KernelAbstractions: KernelAbstractions, CPU
using LinearAlgebra: BLAS
using Printf: @sprintf
using Random: AbstractRNG
using ..Backends:
    AcceleratorDevice, backend_label, library_label, reclaim_device_memory!, to_device
using ..Config: BenchmarkConfig, SUPPORTED_TYPES
using ..Formatting: format_bytes, format_throughput
using ..Host: HostInfo, thread_sweep
using ..Kernels:
    create_matrix,
    dual_gemm_blas!,
    footprint_bytes,
    launch_dual_gemm!,
    matrix_bytes,
    nominal_ops
using ..Reporting: Reporter, advance!, emit
using ..Sampling: SamplingPolicy, TimingSummary, sample_timings, summarize_timings

export BenchmarkRecord,
    engines_of,
    reference_thread_counts,
    plan_total_steps,
    measure_point,
    run_cpu_thread_sweep,
    run_cpu_multitype,
    run_accelerator_benchmarks,
    cpu_reference_time_ms

"""
    BenchmarkRecord

One row of the tidy dataset. Times are in milliseconds, throughputs in 10⁹ operations
per second (from the minimum and from the median time), `dispersion_pct` is the median
absolute deviation relative to the median. `blas_threads` is 0 where the BLAS thread
count does not apply (KernelAbstractions engine, accelerators). Quantities that are
undefined for a row are `NaN`; `status` is `"ok"`, `"skipped: <reason>"` or
`"failed: <error>"`.
"""
struct BenchmarkRecord
    device_type::String
    backend::String
    engine::String
    library::String
    device_name::String
    data_type::String
    matrix_dim::Int
    julia_threads::Int
    blas_threads::Int
    exceeds_physical_cores::Bool
    nominal_ops::Float64
    samples::Int
    min_time_ms::Float64
    median_time_ms::Float64
    mad_time_ms::Float64
    dispersion_pct::Float64
    throughput_gops::Float64
    throughput_median_gops::Float64
    speedup_vs_1t::Float64
    parallel_efficiency_pct::Float64
    speedup_vs_cpu_1t::Float64
    speedup_vs_cpu_maxt::Float64
    status::String
end

"""
    BenchmarkRecord(; device_type, backend, engine, library, device_name, data_type,
                    matrix_dim, julia_threads, nominal_ops, blas_threads = 0,
                    exceeds_physical_cores = false, summary = nothing,
                    speedup_vs_1t = NaN, parallel_efficiency_pct = NaN,
                    speedup_vs_cpu_1t = NaN, speedup_vs_cpu_maxt = NaN, status = "ok")

Build a record from a [`TimingSummary`](@ref) (or none, for skipped and failed points).
"""
function BenchmarkRecord(;
    device_type::AbstractString,
    backend::AbstractString,
    engine::AbstractString,
    library::AbstractString,
    device_name::AbstractString,
    data_type::AbstractString,
    matrix_dim::Integer,
    julia_threads::Integer,
    nominal_ops::Real,
    blas_threads::Integer = 0,
    exceeds_physical_cores::Bool = false,
    summary::Union{TimingSummary, Nothing} = nothing,
    speedup_vs_1t::Real = NaN,
    parallel_efficiency_pct::Real = NaN,
    speedup_vs_cpu_1t::Real = NaN,
    speedup_vs_cpu_maxt::Real = NaN,
    status::AbstractString = "ok",
)
    if summary === nothing
        samples = 0
        min_ms = median_ms = mad_ms = dispersion = gops = gops_median = NaN
    else
        samples = summary.samples
        min_ms = 1e3 * summary.min_s
        median_ms = 1e3 * summary.median_s
        mad_ms = 1e3 * summary.mad_s
        dispersion = 100 * summary.mad_s / summary.median_s
        gops = nominal_ops / summary.min_s / 1e9
        gops_median = nominal_ops / summary.median_s / 1e9
    end
    return BenchmarkRecord(
        String(device_type),
        String(backend),
        String(engine),
        String(library),
        String(device_name),
        String(data_type),
        Int(matrix_dim),
        Int(julia_threads),
        Int(blas_threads),
        exceeds_physical_cores,
        Float64(nominal_ops),
        samples,
        min_ms,
        median_ms,
        mad_ms,
        dispersion,
        gops,
        gops_median,
        Float64(speedup_vs_1t),
        Float64(parallel_efficiency_pct),
        Float64(speedup_vs_cpu_1t),
        Float64(speedup_vs_cpu_maxt),
        String(status),
    )
end

element_type(record::BenchmarkRecord) = SUPPORTED_TYPES[record.data_type]

"""
    engines_of(compute_engine::Symbol) -> Tuple

Engines executed for a `compute_engine` setting: `(:blas, :ka)` for `:both`.
"""
engines_of(compute_engine::Symbol) =
    compute_engine === :both ? (:blas, :ka) : (compute_engine,)

"""
    reference_thread_counts(host::HostInfo, config::BenchmarkConfig) -> Vector{Int}

BLAS thread counts of the element-type suite and of the accelerator comparisons: one
thread and the ceiling of the scaling sweep.
"""
function reference_thread_counts(host::HostInfo, config::BenchmarkConfig)
    counts =
        thread_sweep(host.physical_cores, host.logical_threads, config.thread_sweep_ceiling)
    return unique([1, last(counts)])
end

"""
    plan_total_steps(config::BenchmarkConfig, host::HostInfo, n_devices::Int) -> Int

Number of progress steps of a run: every (size, type, engine, thread count) point,
skipped points included.
"""
function plan_total_steps(config::BenchmarkConfig, host::HostInfo, n_devices::Int)
    n_sizes = length(config.problem_sizes)
    n_types = length(config.target_types)
    engines = engines_of(config.compute_engine)
    sweep =
        config.run_cpu ?
        n_sizes * length(
            thread_sweep(
                host.physical_cores,
                host.logical_threads,
                config.thread_sweep_ceiling,
            ),
        ) : 0
    per_type =
        (:blas in engines ? length(reference_thread_counts(host, config)) : 0) +
        (:ka in engines ? 1 : 0)
    multitype = config.run_cpu ? n_sizes * n_types * per_type : 0
    accelerators = n_devices * n_sizes * n_types * length(engines)
    return sweep + multitype + accelerators
end

"""
    measure_point(engine::Symbol, backend, ::Type{T}, N::Int, rng, policy) -> TimingSummary

One benchmark point: generate the operands, move them to `backend`, evaluate once for
compilation and first touch, then sample the evaluation under `policy`.
"""
function measure_point(
    engine::Symbol,
    backend::KernelAbstractions.Backend,
    ::Type{T},
    N::Int,
    rng::AbstractRNG,
    policy::SamplingPolicy,
) where {T}
    A = to_device(create_matrix(rng, T, N), backend)
    B = to_device(create_matrix(rng, T, N), backend)
    C = to_device(create_matrix(rng, T, N), backend)
    D = similar(A)
    evaluate = if engine === :ka
        () -> launch_dual_gemm!(backend, D, A, B, C)
    elseif engine === :blas
        () -> dual_gemm_blas!(backend, D, A, B, C)
    else
        throw(ArgumentError("unknown engine :$engine; expected :ka or :blas"))
    end
    evaluate()
    GC.gc(false)
    times = sample_timings(evaluate, policy)
    summary = summarize_timings(times)
    reclaim_device_memory!(backend)
    return summary
end

first_line(text::AbstractString) = String(first(split(text, '\n')))

"""
    try_measure(engine, backend, T, N, rng, policy) -> (summary, status)

[`measure_point`](@ref) with failures of the point (unsupported element type on the
library, device errors) turned into a `"failed: ..."` status carrying the error text.
"""
function try_measure(
    engine::Symbol,
    backend::KernelAbstractions.Backend,
    ::Type{T},
    N::Int,
    rng::AbstractRNG,
    policy::SamplingPolicy,
) where {T}
    try
        return measure_point(engine, backend, T, N, rng, policy), "ok"
    catch err
        err isa InterruptException && rethrow()
        return nothing, "failed: " * first_line(sprint(showerror, err))
    end
end

"""
    memory_reason(N, ::Type{T}, budget_bytes) -> Union{Nothing, String}

Skip reason when the four operands exceed the memory budget, else `nothing`.
"""
function memory_reason(N::Int, ::Type{T}, budget_bytes::Real) where {T}
    footprint = footprint_bytes(N, T)
    footprint > budget_bytes || return nothing
    return "skipped: footprint $(format_bytes(footprint)) exceeds the memory budget $(format_bytes(budget_bytes))"
end

"""
    prediction_reason(previous, N, max_point_seconds) -> Union{Nothing, String}

Skip reason when the cubic extrapolation of the previous point of the same series,
`previous = (N₀, t₀)` in seconds, predicts more than `max_point_seconds` per
evaluation; `nothing` otherwise or without a previous point.
"""
function prediction_reason(
    previous::Union{Nothing, Tuple{Int, Float64}},
    N::Int,
    max_point_seconds::Real,
)
    previous === nothing && return nothing
    predicted = previous[2] * (N / previous[1])^3
    predicted > max_point_seconds || return nothing
    return @sprintf(
        "skipped: predicted %.1f s per evaluation (cubic extrapolation from N = %d) exceeds max_point_seconds = %.1f s",
        predicted,
        previous[1],
        max_point_seconds
    )
end

const SWEEP_HEADER = @sprintf(
    "  %-8s %8s %12s %12s %8s %-14s %8s %10s",
    "threads",
    "samples",
    "min [ms]",
    "median [ms]",
    "MAD [%]",
    "throughput",
    "speedup",
    "efficiency"
)
const TYPE_HEADER = @sprintf(
    "  %-10s %-6s %-22s %8s %10s %8s %12s %12s %8s %-14s",
    "type",
    "engine",
    "library",
    "threads",
    "footprint",
    "samples",
    "min [ms]",
    "median [ms]",
    "MAD [%]",
    "throughput"
)
const DEVICE_HEADER = @sprintf(
    "  %-10s %-6s %-22s %8s %12s %12s %8s %-14s %11s %11s",
    "type",
    "engine",
    "library",
    "samples",
    "min [ms]",
    "median [ms]",
    "MAD [%]",
    "throughput",
    "vs CPU 1T",
    "vs CPU maxT"
)

thread_label(record::BenchmarkRecord) =
    string(record.blas_threads, record.exceeds_physical_cores ? "*" : "")

function sweep_row(record::BenchmarkRecord)
    record.status == "ok" ||
        return @sprintf("  %-8s %s", thread_label(record), record.status)
    return @sprintf(
        "  %-8s %8d %12.3f %12.3f %8.2f %-14s %7.2fx %9.1f%%",
        thread_label(record),
        record.samples,
        record.min_time_ms,
        record.median_time_ms,
        record.dispersion_pct,
        format_throughput(record.throughput_gops, element_type(record)),
        record.speedup_vs_1t,
        record.parallel_efficiency_pct
    )
end

function type_row(record::BenchmarkRecord)
    threads = record.engine == "blas" ? thread_label(record) : string(record.julia_threads)
    footprint = format_bytes(footprint_bytes(record.matrix_dim, element_type(record)))
    record.status == "ok" || return @sprintf(
        "  %-10s %-6s %-22s %8s %10s %s",
        record.data_type,
        record.engine,
        record.library,
        threads,
        footprint,
        record.status
    )
    return @sprintf(
        "  %-10s %-6s %-22s %8s %10s %8d %12.3f %12.3f %8.2f %-14s",
        record.data_type,
        record.engine,
        record.library,
        threads,
        footprint,
        record.samples,
        record.min_time_ms,
        record.median_time_ms,
        record.dispersion_pct,
        format_throughput(record.throughput_gops, element_type(record))
    )
end

ratio_label(value::Real) = isnan(value) ? "n/a" : @sprintf("%.2fx", value)

function device_row(record::BenchmarkRecord)
    record.status == "ok" || return @sprintf(
        "  %-10s %-6s %-22s %s",
        record.data_type,
        record.engine,
        record.library,
        record.status
    )
    return @sprintf(
        "  %-10s %-6s %-22s %8d %12.3f %12.3f %8.2f %-14s %11s %11s",
        record.data_type,
        record.engine,
        record.library,
        record.samples,
        record.min_time_ms,
        record.median_time_ms,
        record.dispersion_pct,
        format_throughput(record.throughput_gops, element_type(record)),
        ratio_label(record.speedup_vs_cpu_1t),
        ratio_label(record.speedup_vs_cpu_maxt)
    )
end

"""
    run_cpu_thread_sweep(config, host, rng, reporter) -> Vector{BenchmarkRecord}

Float32 dual GEMM through the BLAS engine over the thread counts of
[`thread_sweep`](@ref); speedup and parallel efficiency refer to the one-thread point of
the same problem size. Sizes beyond the memory budget, or predicted to exceed
`max_point_seconds` from the previous size's one-thread time, are skipped.
"""
function run_cpu_thread_sweep(
    config::BenchmarkConfig,
    host::HostInfo,
    rng::AbstractRNG,
    reporter::Reporter,
)
    T = Float32
    cpu = CPU()
    counts =
        thread_sweep(host.physical_cores, host.logical_threads, config.thread_sweep_ceiling)
    library = library_label(:blas, cpu, T)
    budget = config.memory_safety_fraction * Sys.free_memory()
    records = BenchmarkRecord[]
    emit(reporter, "")
    note =
        any(>(host.physical_cores), counts) ?
        "; * marks thread counts above the $(host.physical_cores) physical cores" : ""
    emit(
        reporter,
        "CPU thread scaling: $T, engine blas ($library), threads $(join(counts, ", "))$note",
    )
    previous::Union{Nothing, Tuple{Int, Float64}} = nothing
    original_threads = BLAS.get_num_threads()
    try
        for N in config.problem_sizes
            reason = memory_reason(N, T, budget)
            reason === nothing &&
                (reason = prediction_reason(previous, N, config.sampling.max_point_seconds))
            if reason !== nothing
                advance!(reporter, "CPU sweep N = $N", length(counts))
                emit(reporter, "  N = $N: $reason")
                push!(
                    records,
                    BenchmarkRecord(;
                        device_type = "CPU",
                        backend = "CPU",
                        engine = "blas",
                        library,
                        device_name = host.cpu_model,
                        data_type = string(T),
                        matrix_dim = N,
                        julia_threads = host.julia_threads,
                        nominal_ops = nominal_ops(T, N),
                        status = reason,
                    ),
                )
                continue
            end
            emit(reporter, "")
            emit(
                reporter,
                @sprintf("  N = %d, footprint %s", N, format_bytes(footprint_bytes(N, T)))
            )
            emit(reporter, SWEEP_HEADER)
            baseline_s = NaN
            for t in counts
                advance!(reporter, "CPU blas $T N = $N, $t threads")
                BLAS.set_num_threads(t)
                summary, status = try_measure(:blas, cpu, T, N, rng, config.sampling)
                speedup = NaN
                efficiency = NaN
                if summary !== nothing
                    if t == 1
                        baseline_s = summary.min_s
                        previous = (N, baseline_s)
                    end
                    speedup = baseline_s / summary.min_s
                    efficiency = 100 * speedup / t
                end
                record = BenchmarkRecord(;
                    device_type = "CPU",
                    backend = "CPU",
                    engine = "blas",
                    library,
                    device_name = host.cpu_model,
                    data_type = string(T),
                    matrix_dim = N,
                    julia_threads = host.julia_threads,
                    blas_threads = t,
                    exceeds_physical_cores = t > host.physical_cores,
                    nominal_ops = nominal_ops(T, N),
                    summary,
                    speedup_vs_1t = speedup,
                    parallel_efficiency_pct = efficiency,
                    status,
                )
                push!(records, record)
                emit(reporter, sweep_row(record))
            end
        end
    finally
        BLAS.set_num_threads(original_threads)
    end
    return records
end

"""
    run_cpu_multitype(config, host, rng, reporter) -> Vector{BenchmarkRecord}

Every configured element type on the host: the BLAS engine at the reference thread
counts and the KernelAbstractions engine on the Julia thread pool.
"""
function run_cpu_multitype(
    config::BenchmarkConfig,
    host::HostInfo,
    rng::AbstractRNG,
    reporter::Reporter,
)
    cpu = CPU()
    engines = engines_of(config.compute_engine)
    blas_counts = reference_thread_counts(host, config)
    steps_per_type = (:blas in engines ? length(blas_counts) : 0) + (:ka in engines ? 1 : 0)
    budget = config.memory_safety_fraction * Sys.free_memory()
    previous = Dict{Tuple{Symbol, DataType, Int}, Tuple{Int, Float64}}()
    records = BenchmarkRecord[]
    emit(reporter, "")
    emit(
        reporter,
        "CPU element types: engines $(join(engines, ", ")); blas threads $(join(blas_counts, ", ")); ka on the $(host.julia_threads)-thread Julia pool",
    )
    original_threads = BLAS.get_num_threads()
    try
        for N in config.problem_sizes
            emit(reporter, "")
            emit(reporter, "  N = $N")
            emit(reporter, TYPE_HEADER)
            for T in config.target_types
                reason = memory_reason(N, T, budget)
                if reason !== nothing
                    advance!(reporter, "CPU $T N = $N", steps_per_type)
                    for engine in engines
                        record = BenchmarkRecord(;
                            device_type = "CPU",
                            backend = "CPU",
                            engine = string(engine),
                            library = library_label(engine, cpu, T),
                            device_name = host.cpu_model,
                            data_type = string(T),
                            matrix_dim = N,
                            julia_threads = host.julia_threads,
                            nominal_ops = nominal_ops(T, N),
                            status = reason,
                        )
                        push!(records, record)
                        emit(reporter, type_row(record))
                    end
                    continue
                end
                for engine in engines
                    threads = engine === :blas ? blas_counts : [host.julia_threads]
                    for t in threads
                        advance!(reporter, "CPU $engine $T N = $N, $t threads")
                        key = (engine, T, t)
                        skip = prediction_reason(
                            get(previous, key, nothing),
                            N,
                            config.sampling.max_point_seconds,
                        )
                        if skip === nothing
                            engine === :blas && BLAS.set_num_threads(t)
                            summary, status =
                                try_measure(engine, cpu, T, N, rng, config.sampling)
                            summary === nothing || (previous[key] = (N, summary.min_s))
                        else
                            summary, status = nothing, skip
                        end
                        record = BenchmarkRecord(;
                            device_type = "CPU",
                            backend = "CPU",
                            engine = string(engine),
                            library = library_label(engine, cpu, T),
                            device_name = host.cpu_model,
                            data_type = string(T),
                            matrix_dim = N,
                            julia_threads = host.julia_threads,
                            blas_threads = engine === :blas ? t : 0,
                            exceeds_physical_cores = engine === :blas &&
                                                     t > host.physical_cores,
                            nominal_ops = nominal_ops(T, N),
                            summary,
                            status,
                        )
                        push!(records, record)
                        emit(reporter, type_row(record))
                    end
                end
            end
        end
    finally
        BLAS.set_num_threads(original_threads)
    end
    return records
end

"""
    cpu_reference_time_ms(records, ::Type{T}, N, blas_threads) -> Float64

Minimum time of the measured CPU BLAS point for `T`, `N` and `blas_threads`, or `NaN`.
"""
function cpu_reference_time_ms(
    records::AbstractVector{BenchmarkRecord},
    ::Type{T},
    N::Int,
    blas_threads::Int,
) where {T}
    for record in records
        record.device_type == "CPU" &&
            record.engine == "blas" &&
            record.status == "ok" &&
            record.data_type == string(T) &&
            record.matrix_dim == N &&
            record.blas_threads == blas_threads &&
            return record.min_time_ms
    end
    return NaN
end

"""
    run_accelerator_benchmarks(device, config, host, cpu_records, rng, reporter)
        -> Vector{BenchmarkRecord}

Every configured element type and size on one accelerator through the selected
engines. Speedups compare against the CPU BLAS points at one thread and at the sweep
ceiling. Points whose single operand exceeds the device's maximum allocation or whose
footprint exceeds the device memory budget are skipped.
"""
function run_accelerator_benchmarks(
    device::AcceleratorDevice,
    config::BenchmarkConfig,
    host::HostInfo,
    cpu_records::AbstractVector{BenchmarkRecord},
    rng::AbstractRNG,
    reporter::Reporter,
)
    backend = device.backend
    label = backend_label(backend)
    engines = engines_of(config.compute_engine)
    max_threads = last(reference_thread_counts(host, config))
    budget =
        device.total_memory_bytes > 0 ?
        config.memory_safety_fraction * device.total_memory_bytes : Inf
    previous = Dict{Tuple{Symbol, DataType}, Tuple{Int, Float64}}()
    records = BenchmarkRecord[]
    emit(reporter, "")
    emit(
        reporter,
        "Accelerator: $(device.vendor_label), $(device.device_name) ($label backend); engines $(join(engines, ", ")); CPU references at 1 and $max_threads BLAS threads",
    )
    for N in config.problem_sizes
        emit(reporter, "")
        emit(reporter, "  N = $N")
        emit(reporter, DEVICE_HEADER)
        for T in config.target_types
            reason = memory_reason(N, T, budget)
            if reason === nothing &&
               device.max_alloc_bytes > 0 &&
               matrix_bytes(N, T) > device.max_alloc_bytes
                reason = "skipped: one operand of $(format_bytes(matrix_bytes(N, T))) exceeds the maximum device allocation $(format_bytes(device.max_alloc_bytes))"
            end
            for engine in engines
                advance!(reporter, "$label $engine $T N = $N")
                key = (engine, T)
                skip = reason
                skip === nothing && (
                    skip = prediction_reason(
                        get(previous, key, nothing),
                        N,
                        config.sampling.max_point_seconds,
                    )
                )
                if skip === nothing
                    summary, status =
                        try_measure(engine, backend, T, N, rng, config.sampling)
                    summary === nothing || (previous[key] = (N, summary.min_s))
                else
                    summary, status = nothing, skip
                end
                speedup_1t = NaN
                speedup_max = NaN
                if summary !== nothing
                    speedup_1t =
                        cpu_reference_time_ms(cpu_records, T, N, 1) / (1e3 * summary.min_s)
                    speedup_max =
                        cpu_reference_time_ms(cpu_records, T, N, max_threads) /
                        (1e3 * summary.min_s)
                end
                record = BenchmarkRecord(;
                    device_type = "GPU",
                    backend = label,
                    engine = string(engine),
                    library = library_label(engine, backend, T),
                    device_name = device.device_name,
                    data_type = string(T),
                    matrix_dim = N,
                    julia_threads = host.julia_threads,
                    nominal_ops = nominal_ops(T, N),
                    summary,
                    speedup_vs_cpu_1t = speedup_1t,
                    speedup_vs_cpu_maxt = speedup_max,
                    status,
                )
                push!(records, record)
                emit(reporter, device_row(record))
            end
        end
    end
    return records
end

end
