"""
Tidy CSV dataset, TOML provenance sidecar and collision-free output paths.
"""
module Export

using Dates: Dates, now
using Printf: @sprintf
using TOML: TOML
using ..Backends: backend_label, device_fingerprint
using ..Benchmark: BenchmarkRecord
using ..Config: BenchmarkConfig
using ..Host: HostInfo

export export_records_to_csv,
    export_metadata_to_toml, safe_filepath, repository_commit, csv_header

"""
    csv_header() -> String

Column names of the dataset: the fields of [`BenchmarkRecord`](@ref) in order.
"""
csv_header() = join(string.(fieldnames(BenchmarkRecord)), ",")

csv_cell(value::AbstractString) = "\"" * replace(value, "\"" => "\"\"") * "\""
csv_cell(value::Bool) = string(value)
csv_cell(value::Integer) = string(value)
csv_cell(value::AbstractFloat) = isfinite(value) ? @sprintf("%.10g", value) : ""

"""
    export_records_to_csv(records, filepath) -> filepath

Write the records as a tidy CSV file. Strings are quoted, undefined quantities (`NaN`)
and inapplicable thread counts (0) are written as empty cells.
"""
function export_records_to_csv(
    records::AbstractVector{BenchmarkRecord},
    filepath::AbstractString,
)
    open(filepath, "w") do io
        println(io, csv_header())
        for record in records
            cells = String[]
            for name in fieldnames(BenchmarkRecord)
                value = getfield(record, name)
                push!(cells, name === :blas_threads && value == 0 ? "" : csv_cell(value))
            end
            println(io, join(cells, ","))
        end
    end
    return filepath
end

"""
    export_metadata_to_toml(config, host, devices, filepath;
                            loaded_backends = Symbol[], toolbox_commit = "unavailable")
        -> filepath

Write the provenance sidecar: host fingerprint, run configuration and accelerator
inventory, all integers in decimal notation.
"""
function export_metadata_to_toml(
    config::BenchmarkConfig,
    host::HostInfo,
    devices::AbstractVector,
    filepath::AbstractString;
    loaded_backends::AbstractVector{Symbol} = Symbol[],
    toolbox_commit::AbstractString = "unavailable",
)
    provenance = Dict{String, Any}(
        "timestamp" => Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"),
        "toolbox_commit" => String(toolbox_commit),
        "hostname" => host.hostname,
        "julia_version" => host.julia_version,
        "julia_commit" => host.julia_commit,
        "os" => host.os,
        "machine" => host.machine,
        "word_size" => host.word_size,
        "cpu_model" => host.cpu_model,
        "physical_cores" => host.physical_cores,
        "logical_threads" => host.logical_threads,
        "topology_source" => host.topology_source,
        "julia_threads" => host.julia_threads,
        "interactive_threads" => host.interactive_threads,
        "gc_threads" => host.gc_threads,
        "blas_library" => host.blas_library,
        "blas_threads" => host.blas_threads,
        "total_memory_bytes" => host.total_memory_bytes,
        "free_memory_bytes" => host.free_memory_bytes,
        "isa_features" => host.isa_features,
        "cpu_frequency_mhz" => collect(host.cpu_frequency_mhz),
        "kernel_abstractions_version" => host.kernel_abstractions_version,
        "loaded_accelerator_packages" => String.(loaded_backends),
    )
    sampling = config.sampling
    configuration = Dict{String, Any}(
        "preset" => config.preset,
        "compute_engine" => string(config.compute_engine),
        "problem_sizes" => config.problem_sizes,
        "target_types" => string.(config.target_types),
        "seed" => config.seed,
        "sampling" => Dict{String, Any}(
            "min_sampling_time_s" => sampling.min_sampling_time_s,
            "min_samples" => sampling.min_samples,
            "max_samples" => sampling.max_samples,
            "max_point_seconds" => sampling.max_point_seconds,
        ),
        "run_cpu" => config.run_cpu,
        "gpu_backend" => string(config.gpu_backend),
        "thread_sweep_ceiling" => string(config.thread_sweep_ceiling),
        "verify_kernels" => config.verify_kernels,
        "verification_size" => config.verification_size,
        "memory_safety_fraction" => config.memory_safety_fraction,
    )
    accelerators = Any[
        Dict{String, Any}(
            "backend" => string(device.name),
            "vendor" => device.vendor_label,
            "device_name" => device.device_name,
            "driver_version" => device.driver_version,
            "compute_units" => device.compute_units,
            "hardware_threads" => device.hardware_threads,
            "core_clock_mhz" => device.core_clock_mhz,
            "total_memory_bytes" => device.total_memory_bytes,
            "max_alloc_bytes" => device.max_alloc_bytes,
            "ka_backend" => backend_label(device.backend),
            "attributes" => device.attributes,
            "fingerprint" => device_fingerprint(device.backend),
        ) for device in devices
    ]
    open(filepath, "w") do io
        TOML.print(
            io,
            Dict{String, Any}(
                "provenance" => provenance,
                "configuration" => configuration,
                "accelerators" => accelerators,
            );
            sorted = true,
        )
    end
    return filepath
end

"""
    safe_filepath(path) -> String

`path` itself when no file exists there, otherwise the first of `stem#1.ext`,
`stem#2.ext`, ... that is free, so that earlier results are never overwritten.
"""
function safe_filepath(path::AbstractString)
    isfile(path) || return String(path)
    stem, extension = splitext(basename(path))
    directory = dirname(path)
    k = 1
    while true
        candidate = joinpath(directory, "$(stem)#$(k)$(extension)")
        isfile(candidate) || return candidate
        k += 1
    end
end

"""
    repository_commit(dir) -> String

Short commit of the git checkout containing `dir`, suffixed with `-dirty` when the
working tree has modifications; `"unavailable"` without git or outside a repository.
"""
function repository_commit(dir::AbstractString)
    Sys.which("git") === nothing && return "unavailable"
    commit = IOBuffer()
    success(
        pipeline(`git -C $dir rev-parse --short HEAD`; stdout = commit, stderr = devnull),
    ) || return "unavailable"
    status = IOBuffer()
    success(
        pipeline(`git -C $dir status --porcelain`; stdout = status, stderr = devnull),
    ) || return "unavailable"
    revision = String(strip(String(take!(commit))))
    return isempty(strip(String(take!(status)))) ? revision : revision * "-dirty"
end

end
