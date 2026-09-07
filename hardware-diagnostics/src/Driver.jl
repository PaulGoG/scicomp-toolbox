"""
Top-level orchestration: configuration, discovery, verification, benchmark stages and
exports.
"""
module Driver

using Dates: Dates, now
using KernelAbstractions: KernelAbstractions, CPU
using Printf: @sprintf
using Random: Xoshiro
using ..Backends: backend_label, discover_accelerators
using ..Benchmark:
    BenchmarkRecord,
    engines_of,
    plan_total_steps,
    run_accelerator_benchmarks,
    run_cpu_multitype,
    run_cpu_thread_sweep
using ..Config: BenchmarkConfig, parse_cli_args, usage_text
using ..Export:
    export_metadata_to_toml, export_records_to_csv, repository_commit, safe_filepath
using ..Formatting: format_bytes, format_seconds
using ..Host: host_info, print_host_report
using ..Kernels: verify_engines
using ..Reporting: Reporter, emit, finish!

export configure, run_diagnostics, print_accelerator_report, run_verification

"""
    configure(args, base_dir) -> Union{BenchmarkConfig, Nothing}

Parse the command line on top of the configuration file in `base_dir`. Prints the usage
text and returns `nothing` when `-h` or `--help` is present.
"""
function configure(args::AbstractVector{<:AbstractString}, base_dir::AbstractString)
    if any(argument -> argument in ("-h", "--help"), args)
        print(usage_text())
        return nothing
    end
    return parse_cli_args(args, base_dir)
end

"""
    print_accelerator_report(io, devices, requested::Symbol, loaded::AbstractVector{Symbol})

Accelerator section of the report.
"""
function print_accelerator_report(
    io::IO,
    devices::AbstractVector,
    requested::Symbol,
    loaded::AbstractVector{Symbol},
)
    println(io, "Accelerators")
    println(io, "  Requested backend     : ", requested)
    println(
        io,
        "  Loaded packages       : ",
        isempty(loaded) ? "none" : join(string.(loaded), ", "),
    )
    if isempty(devices)
        println(io, "  Functional devices    : none")
        return nothing
    end
    for device in devices
        println(io, "  ", device.vendor_label, ": ", device.device_name)
        println(io, "    Backend             : ", backend_label(device.backend))
        println(io, "    Driver              : ", device.driver_version)
        device.compute_units > 0 && println(
            io,
            "    Compute units       : ",
            device.compute_units,
            " (",
            device.hardware_threads,
            " resident hardware threads)",
        )
        device.core_clock_mhz > 0 &&
            println(io, "    Core clock          : ", device.core_clock_mhz, " MHz")
        if device.total_memory_bytes > 0
            allocation =
                device.max_alloc_bytes > 0 ?
                " (maximum single allocation $(format_bytes(device.max_alloc_bytes)))" : ""
            println(
                io,
                "    Device memory       : ",
                format_bytes(device.total_memory_bytes),
                allocation,
            )
        end
        for (key, value) in sort(collect(device.attributes))
            println(io, "    ", rpad(key, 20), ": ", value)
        end
    end
    return nothing
end

first_line(text::AbstractString) = String(first(split(text, '\n')))

"""
    run_verification(config, backends, rng, reporter)

Compare both engines on every backend and element type at `verification_size`. Element
types the library cannot multiply on a backend are reported as unverifiable; a
deviation above tolerance aborts the run with an error.
"""
function run_verification(
    config::BenchmarkConfig,
    backends::AbstractVector,
    rng::Xoshiro,
    reporter::Reporter,
)
    emit(reporter, "")
    emit(reporter, "Cross-engine verification (N = $(config.verification_size))")
    for backend in backends, T in config.target_types
        result = try
            verify_engines(backend, T, config.verification_size, rng)
        catch err
            err isa InterruptException && rethrow()
            emit(
                reporter,
                @sprintf(
                    "  %-8s %-10s unavailable: %s",
                    backend_label(backend),
                    string(T),
                    first_line(sprint(showerror, err))
                )
            )
            continue
        end
        emit(
            reporter,
            @sprintf(
                "  %-8s %-10s max relative deviation %.3e (tolerance %.3e) %s",
                backend_label(backend),
                string(T),
                result.max_relative_deviation,
                result.tolerance,
                result.passed ? "passed" : "FAILED"
            )
        )
        result.passed || begin
            finish!(reporter)
            error(
                "cross-engine verification failed for $T on $(backend_label(backend)): deviation $(result.max_relative_deviation) exceeds tolerance $(result.tolerance)",
            )
        end
    end
    return nothing
end

"""
    run_diagnostics(config::BenchmarkConfig; base_dir = pwd(), loaded_backends = Symbol[])
        -> Vector{BenchmarkRecord}

Execute a run: host and accelerator reports, cross-engine verification, the CPU and
accelerator benchmark stages, then the CSV dataset and TOML sidecar in the output
directory (relative paths resolve against `base_dir`). Report lines go to the console
and, when enabled, to a log file free of terminal escape sequences.
"""
function run_diagnostics(
    config::BenchmarkConfig;
    base_dir::AbstractString = pwd(),
    loaded_backends::AbstractVector{Symbol} = Symbol[],
)
    host = host_info(; record_hostname = config.record_hostname)
    output_dir =
        isabspath(config.output_directory) ? config.output_directory :
        normpath(joinpath(base_dir, config.output_directory))
    mkpath(output_dir)
    stamp = Dates.format(now(), "yyyy-mm-dd_HH-MM-SS")
    log_path = safe_filepath(joinpath(output_dir, "hardware_benchmark_$stamp.log"))
    csv_path = safe_filepath(joinpath(output_dir, "hardware_benchmark_$stamp.csv"))
    toml_path = safe_filepath(joinpath(output_dir, "hardware_benchmark_$stamp.toml"))
    log_io = config.log_to_file ? open(log_path, "w") : nothing
    sinks = IO[stdout]
    log_io === nothing || push!(sinks, log_io)

    devices = discover_accelerators(config.gpu_backend)
    rng = Xoshiro(config.seed)
    reporter = Reporter(sinks; total = plan_total_steps(config, host, length(devices)))
    records = BenchmarkRecord[]
    wall_start = time()
    try
        emit(reporter, rstrip(sprint(print_host_report, host)))
        emit(reporter, "")
        emit(
            reporter,
            rstrip(
                sprint(
                    print_accelerator_report,
                    devices,
                    config.gpu_backend,
                    collect(loaded_backends),
                ),
            ),
        )
        sampling = config.sampling
        emit(reporter, "")
        emit(reporter, "Benchmark")
        emit(
            reporter,
            "  Problem sizes         : $(join(config.problem_sizes, ", ")) ($(config.preset))",
        )
        emit(
            reporter,
            "  Element types         : $(join(string.(config.target_types), ", "))",
        )
        emit(
            reporter,
            "  Engines               : $(join(engines_of(config.compute_engine), ", "))",
        )
        emit(
            reporter,
            @sprintf(
                "  Sampling              : at least %d evaluations and %.3g s per point, at most %d evaluations; points predicted above %.3g s per evaluation are skipped",
                sampling.min_samples,
                sampling.min_sampling_time_s,
                sampling.max_samples,
                sampling.max_point_seconds
            )
        )
        emit(
            reporter,
            "  Memory budget         : $(config.memory_safety_fraction) of free host memory / device memory",
        )
        emit(reporter, "  Seed                  : $(config.seed)")
        log_io === nothing || emit(reporter, "  Log file              : $log_path")

        if config.verify_kernels
            backends = Any[]
            config.run_cpu && push!(backends, CPU())
            append!(backends, [device.backend for device in devices])
            run_verification(config, backends, rng, reporter)
        end
        if config.run_cpu
            append!(records, run_cpu_thread_sweep(config, host, rng, reporter))
            append!(records, run_cpu_multitype(config, host, rng, reporter))
        end
        for device in devices
            append!(
                records,
                run_accelerator_benchmarks(device, config, host, records, rng, reporter),
            )
        end
        finish!(reporter)

        measured = count(record -> record.status == "ok", records)
        emit(reporter, "")
        emit(
            reporter,
            "Completed in $(format_seconds(time() - wall_start)); $measured of $(length(records)) points measured.",
        )
        if config.export_csv && !isempty(records)
            export_records_to_csv(records, csv_path)
            emit(reporter, "  Dataset               : $csv_path")
        end
        if config.export_metadata
            export_metadata_to_toml(
                config,
                host,
                devices,
                toml_path;
                loaded_backends = collect(loaded_backends),
                toolbox_commit = repository_commit(base_dir),
            )
            emit(reporter, "  Provenance            : $toml_path")
        end
        log_io === nothing || emit(reporter, "  Log                   : $log_path")
    finally
        finish!(reporter)
        log_io === nothing || close(log_io)
    end
    return records
end

end
