# The benchmark as a plan of points, executed in order: the CPU thread-scaling sweep, the
# CPU element-type stage and the accelerator stage, each point producing one
# [`BenchmarkRecord`](@ref).

"""
Stages of a run in execution order, as written to the `stage` column: the Float32
library engine over the BLAS thread counts, every element type and engine on the host,
every element type and engine on each accelerator.
"""
const STAGES = (:thread_sweep, :element_types, :accelerator)

"""
    BenchmarkRecord

One row of the tidy dataset. `stage` is one of [`STAGES`](@ref). Times are in
milliseconds, throughputs in 10⁹ operations per second (from the minimum and from the
median time), `dispersion_pct` is the median absolute deviation relative to the median.
`blas_threads` is 0 where the BLAS thread count does not apply (KernelAbstractions
engine, accelerators). Quantities that are undefined for a row are `NaN`, the dispersion
of a single-sample point included; `status` is `"ok"`, `"skipped: <reason>"` or
`"failed: <error>"`.
"""
struct BenchmarkRecord
    stage::String
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
    BenchmarkRecord(; stage, device_type, backend, engine, library, device_name,
                    data_type, matrix_dim, julia_threads, nominal_ops, blas_threads = 0,
                    exceeds_physical_cores = false, summary = nothing,
                    speedup_vs_1t = NaN, parallel_efficiency_pct = NaN,
                    speedup_vs_cpu_1t = NaN, speedup_vs_cpu_maxt = NaN, status = "ok")

Build a record from a [`TimingSummary`](@ref) (or none, for skipped and failed points).
"""
function BenchmarkRecord(;
    stage::AbstractString,
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
        String(stage),
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
    BenchmarkPoint

One measurement of the plan: its `stage` (one of [`STAGES`](@ref)), the accelerator
`device` (`nothing` on the host), engine, element type, problem size N and BLAS thread
count (0 where it does not apply: kernel engines and accelerators).
"""
struct BenchmarkPoint
    stage::Symbol
    device::Union{AcceleratorDevice, Nothing}
    engine::Symbol
    element_type::DataType
    matrix_dim::Int
    blas_threads::Int
end

"""
    reference_thread_counts(host::HostInfo, config::BenchmarkConfig) -> Vector{Int}

BLAS thread counts of the element-type stage and of the accelerator comparisons: one
thread and the ceiling of the scaling sweep.
"""
function reference_thread_counts(host::HostInfo, config::BenchmarkConfig)
    counts =
        thread_sweep(host.physical_cores, host.logical_threads, config.thread_sweep_ceiling)
    return unique([1, last(counts)])
end

"""
    benchmark_plan(config, host, devices) -> Vector{BenchmarkPoint}

Every point of a run in execution order. With `run_cpu`: the thread sweep (Float32,
library engine, each size at every count of [`thread_sweep`](@ref)), then the
element-type stage (each size, type and engine; the library engine at the
[`reference_thread_counts`](@ref)). Then each size, type and engine on every device.
"""
function benchmark_plan(
    config::BenchmarkConfig,
    host::HostInfo,
    devices::AbstractVector{<:AcceleratorDevice},
)
    plan = BenchmarkPoint[]
    if config.run_cpu
        counts = thread_sweep(
            host.physical_cores,
            host.logical_threads,
            config.thread_sweep_ceiling,
        )
        for N in config.problem_sizes, t in counts
            push!(plan, BenchmarkPoint(:thread_sweep, nothing, :blas, Float32, N, t))
        end
        blas_counts = reference_thread_counts(host, config)
        for N in config.problem_sizes, T in config.target_types, engine in config.engines
            for t in (engine === :blas ? blas_counts : [0])
                push!(plan, BenchmarkPoint(:element_types, nothing, engine, T, N, t))
            end
        end
    end
    for device in devices,
        N in config.problem_sizes,
        T in config.target_types,
        engine in config.engines

        push!(plan, BenchmarkPoint(:accelerator, device, engine, T, N, 0))
    end
    return plan
end

"""
    warm_up_and_sample(evaluate, policy::SamplingPolicy) -> TimingSummary

Evaluate once for compilation and first touch, timed, then sample under `policy`. When
the warm-up alone exceeds `policy.max_point_seconds`, sampling is skipped and the
summary is that single evaluation, so no point costs much more than twice the cap.
"""
function warm_up_and_sample(evaluate::F, policy::SamplingPolicy) where {F}
    t0 = time_ns()
    evaluate()
    t_warm = (time_ns() - t0) / 1e9
    t_warm > policy.max_point_seconds && return summarize_timings([t_warm])
    GC.gc(false)
    return summarize_timings(sample_timings(evaluate, policy))
end

"""
    measure_point(engine::Symbol, backend, ::Type{T}, N::Int, rng, policy) -> TimingSummary

One benchmark point: generate the operands, move them to `backend`, then warm up and
sample the evaluation under `policy` ([`warm_up_and_sample`](@ref)). The device
operands are released on return and on failure alike.
"""
function measure_point(
    engine::Symbol,
    backend::KernelAbstractions.Backend,
    ::Type{T},
    N::Int,
    rng::AbstractRNG,
    policy::SamplingPolicy,
) where {T}
    allocated = AbstractArray[]
    try
        A = track!(allocated, to_device(create_matrix(rng, T, N), backend))
        B = track!(allocated, to_device(create_matrix(rng, T, N), backend))
        C = track!(allocated, to_device(create_matrix(rng, T, N), backend))
        D = track!(allocated, similar(A))
        return sample_engine(engine, backend, D, A, B, C, policy)
    finally
        foreach(release_device_array!, allocated)
        reclaim_device_memory!(backend)
    end
end

# A function barrier: the timed closure captures concretely typed operands.
sample_engine(engine::Symbol, backend, D, A, B, C, policy::SamplingPolicy) =
    warm_up_and_sample(() -> evaluate_engine!(engine, backend, D, A, B, C), policy)

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

"""
    memory_budget(point::BenchmarkPoint, config::BenchmarkConfig) -> Float64

Bytes available to the operands of a point: `memory_safety_fraction` of the free host
memory, or of the device memory (unbounded when the device does not report it).
"""
function memory_budget(point::BenchmarkPoint, config::BenchmarkConfig)
    device = point.device
    device === nothing && return config.memory_safety_fraction * Sys.free_memory()
    device.total_memory_bytes > 0 || return Inf
    return config.memory_safety_fraction * device.total_memory_bytes
end

"""
    skip_reason(point, budget_bytes, previous, max_point_seconds) -> Union{Nothing, String}

Why `point` is not measured: its operands exceed the memory budget, one operand exceeds
the device's maximum allocation, or the previous point of its series predicts more than
`max_point_seconds` ([`prediction_reason`](@ref)); `nothing` when it is measured.
"""
function skip_reason(
    point::BenchmarkPoint,
    budget_bytes::Real,
    previous::Union{Nothing, Tuple{Int, Float64}},
    max_point_seconds::Real,
)
    N, T = point.matrix_dim, point.element_type
    reason = memory_reason(N, T, budget_bytes)
    reason === nothing || return reason
    device = point.device
    if device !== nothing &&
       device.max_alloc_bytes > 0 &&
       matrix_bytes(N, T) > device.max_alloc_bytes
        return "skipped: one operand of $(format_bytes(matrix_bytes(N, T))) exceeds the maximum device allocation $(format_bytes(device.max_alloc_bytes))"
    end
    return prediction_reason(previous, N, max_point_seconds)
end

const SeriesKey = Tuple{Symbol, Union{AcceleratorDevice, Nothing}, Symbol, DataType, Int}

"""
Series of a point for the cost prediction: the points that differ only in N.
"""
series_key(point::BenchmarkPoint)::SeriesKey =
    (point.stage, point.device, point.engine, point.element_type, point.blas_threads)

"""
    reference_time_ms(records, stage::Symbol, ::Type{T}, N, blas_threads) -> Float64

Minimum time of the measured CPU library point of `stage` for `T`, `N` and
`blas_threads`, or `NaN`.
"""
function reference_time_ms(
    records::AbstractVector{BenchmarkRecord},
    stage::Symbol,
    ::Type{T},
    N::Int,
    blas_threads::Int,
) where {T}
    for record in records
        record.stage == string(stage) &&
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
    run_point(point, budget_bytes, previous, records, config, host) -> BenchmarkRecord

Measure `point` unless [`skip_reason`](@ref) applies and build its record. `previous`
maps each series to its last measured `(N, minimum time [s])` and is updated; `records`
holds the points measured so far, against which the speedups are taken.
"""
function run_point(
    point::BenchmarkPoint,
    budget_bytes::Real,
    previous::AbstractDict,
    records::AbstractVector{BenchmarkRecord},
    config::BenchmarkConfig,
    host::HostInfo,
)
    T, N, t = point.element_type, point.matrix_dim, point.blas_threads
    on_host = point.device === nothing
    backend = on_host ? CPU() : point.device.backend
    key = series_key(point)
    reason = skip_reason(
        point,
        budget_bytes,
        get(previous, key, nothing),
        config.sampling.max_point_seconds,
    )
    if reason === nothing
        t > 0 && BLAS.set_num_threads(t)
        rng = operand_rng(config.seed, T, N)
        summary, status = try_measure(point.engine, backend, T, N, rng, config.sampling)
        summary === nothing || (previous[key] = (N, summary.min_s))
    else
        summary, status = nothing, reason
    end
    speedup_vs_1t = parallel_efficiency_pct = speedup_vs_cpu_1t = speedup_vs_cpu_maxt = NaN
    if summary !== nothing
        time_ms = 1e3 * summary.min_s
        if point.stage === :thread_sweep
            baseline_ms =
                t == 1 ? time_ms : reference_time_ms(records, :thread_sweep, T, N, 1)
            speedup_vs_1t = baseline_ms / time_ms
            parallel_efficiency_pct = 100 * speedup_vs_1t / t
        elseif point.stage === :accelerator
            max_threads = last(reference_thread_counts(host, config))
            speedup_vs_cpu_1t =
                reference_time_ms(records, :element_types, T, N, 1) / time_ms
            speedup_vs_cpu_maxt =
                reference_time_ms(records, :element_types, T, N, max_threads) / time_ms
        end
    end
    return BenchmarkRecord(;
        stage = string(point.stage),
        device_type = on_host ? "CPU" : "GPU",
        backend = backend_label(backend),
        engine = string(point.engine),
        library = library_label(point.engine, backend, T),
        device_name = on_host ? host.cpu_model : point.device.device_name,
        data_type = string(T),
        matrix_dim = N,
        julia_threads = host.julia_threads,
        blas_threads = t,
        exceeds_physical_cores = t > host.physical_cores,
        nominal_ops = nominal_ops(T, N),
        summary,
        speedup_vs_1t,
        parallel_efficiency_pct,
        speedup_vs_cpu_1t,
        speedup_vs_cpu_maxt,
        status,
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
    "  %-10s %-8s %-24s %8s %10s %8s %12s %12s %8s %-14s",
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
    "  %-10s %-8s %-24s %8s %12s %12s %8s %-14s %11s %11s",
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
        "  %-10s %-8s %-24s %8s %10s %s",
        record.data_type,
        record.engine,
        record.library,
        threads,
        footprint,
        record.status
    )
    return @sprintf(
        "  %-10s %-8s %-24s %8s %10s %8d %12.3f %12.3f %8.2f %-14s",
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
        "  %-10s %-8s %-24s %s",
        record.data_type,
        record.engine,
        record.library,
        record.status
    )
    return @sprintf(
        "  %-10s %-8s %-24s %8d %12.3f %12.3f %8.2f %-14s %11s %11s",
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
    report_row(record::BenchmarkRecord) -> String

Table line of `record` in the layout of its stage.
"""
function report_row(record::BenchmarkRecord)
    record.stage == "thread_sweep" && return sweep_row(record)
    record.stage == "element_types" && return type_row(record)
    return device_row(record)
end

"""
    stage_banner(point::BenchmarkPoint, config, host) -> String

Heading line of the stage that `point` opens.
"""
function stage_banner(point::BenchmarkPoint, config::BenchmarkConfig, host::HostInfo)
    if point.stage === :thread_sweep
        counts = thread_sweep(
            host.physical_cores,
            host.logical_threads,
            config.thread_sweep_ceiling,
        )
        note =
            any(>(host.physical_cores), counts) ?
            "; * marks thread counts above the $(host.physical_cores) physical cores" : ""
        library = library_label(:blas, CPU(), Float32)
        return "CPU thread scaling: Float32, engine blas ($library), threads $(join(counts, ", "))$note"
    elseif point.stage === :element_types
        blas_counts = join(reference_thread_counts(host, config), ", ")
        return "CPU element types: engines $(join(config.engines, ", ")); blas threads $blas_counts; kernels on the $(host.julia_threads)-thread Julia pool"
    end
    device = point.device
    max_threads = last(reference_thread_counts(host, config))
    return "Accelerator: $(device.vendor_label), $(device.device_name) ($(backend_label(device.backend)) backend); engines $(join(config.engines, ", ")); CPU references at 1 and $max_threads BLAS threads"
end

"""
    size_header(point::BenchmarkPoint) -> Vector{String}

Lines that open the table of a problem size within the stage of `point`.
"""
function size_header(point::BenchmarkPoint)
    N = point.matrix_dim
    point.stage === :thread_sweep && return [
        @sprintf("  N = %d, footprint %s", N, format_bytes(footprint_bytes(N, Float32))),
        SWEEP_HEADER,
    ]
    return ["  N = $N", point.stage === :element_types ? TYPE_HEADER : DEVICE_HEADER]
end

function point_label(point::BenchmarkPoint)
    target = point.device === nothing ? "CPU" : backend_label(point.device.backend)
    threads = point.blas_threads > 0 ? ", $(point.blas_threads) threads" : ""
    return "$target $(point.engine) $(point.element_type) N = $(point.matrix_dim)$threads"
end

"""
    run_benchmark_plan(plan, config, host, reporter; on_record = Returns(nothing))
        -> Vector{BenchmarkRecord}

Execute `plan` in order, one record per point ([`run_point`](@ref)). The host memory
budget is taken when a stage begins. Thread-sweep rows carry the speedup and parallel
efficiency against the one-thread point of their size; accelerator rows carry the
speedup against the library points of the element-type stage at one thread and at the
sweep ceiling. `on_record` is called with every record as it is produced; the BLAS
thread count is restored on return.
"""
function run_benchmark_plan(
    plan::AbstractVector{BenchmarkPoint},
    config::BenchmarkConfig,
    host::HostInfo,
    reporter::Reporter;
    on_record = Returns(nothing),
)
    records = BenchmarkRecord[]
    previous = Dict{SeriesKey, Tuple{Int, Float64}}()
    budget = Inf
    original_threads = BLAS.get_num_threads()
    try
        for (k, point) in enumerate(plan)
            earlier = k == 1 ? nothing : plan[k - 1]
            new_stage =
                earlier === nothing ||
                earlier.stage !== point.stage ||
                earlier.device !== point.device
            if new_stage
                budget = memory_budget(point, config)
                emit(reporter, "")
                emit(reporter, stage_banner(point, config, host))
            end
            if new_stage || earlier.matrix_dim != point.matrix_dim
                emit(reporter, "")
                foreach(line -> emit(reporter, line), size_header(point))
            end
            advance!(reporter, point_label(point))
            record = run_point(point, budget, previous, records, config, host)
            push!(records, record)
            on_record(record)
            emit(reporter, report_row(record))
        end
    finally
        BLAS.set_num_threads(original_threads)
    end
    return records
end
