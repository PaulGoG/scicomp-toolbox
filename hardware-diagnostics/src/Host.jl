"""
Host introspection: CPU topology (physical and logical), thread pools, memory, BLAS
library and the thread counts of the scaling sweep.
"""
module Host

using KernelAbstractions: KernelAbstractions
using LinearAlgebra: BLAS
using ..Backends: blas_library_label
using ..Formatting: format_bytes

export HostInfo,
    host_info, physical_core_count, thread_sweep, print_host_report, cpu_isa_features

"""
    HostInfo

Platform fingerprint of the host. `hostname` is empty when recording it was disabled.
`topology_source` names where the physical core count came from.
"""
struct HostInfo
    hostname::String
    julia_version::String
    julia_commit::String
    os::String
    machine::String
    word_size::Int
    cpu_model::String
    physical_cores::Int
    logical_threads::Int
    topology_source::String
    julia_threads::Int
    interactive_threads::Int
    gc_threads::Int
    blas_library::String
    blas_threads::Int
    total_memory_bytes::Int
    free_memory_bytes::Int
    isa_features::Vector{String}
    cpu_frequency_mhz::Tuple{Int, Int}
    kernel_abstractions_version::String
end

"""
    physical_core_count() -> Tuple{Int, String}

Number of physical cores and the source of the figure. On Linux the unique
(physical id, core id) pairs of `/proc/cpuinfo` are counted; elsewhere the logical
thread count is returned and the source string says so.
"""
function physical_core_count()
    if Sys.islinux() && isfile("/proc/cpuinfo")
        pairs = Set{Tuple{Int, Int}}()
        physical = -1
        core = -1
        for line in eachline("/proc/cpuinfo")
            if startswith(line, "physical id")
                physical = parse(Int, strip(last(split(line, ':'))))
            elseif startswith(line, "core id")
                core = parse(Int, strip(last(split(line, ':'))))
            elseif isempty(strip(line))
                physical >= 0 && core >= 0 && push!(pairs, (physical, core))
                physical = -1
                core = -1
            end
        end
        physical >= 0 && core >= 0 && push!(pairs, (physical, core))
        isempty(pairs) || return (length(pairs), "/proc/cpuinfo")
    end
    return (Sys.CPU_THREADS, "logical thread count; physical topology unavailable")
end

const ISA_FLAGS_OF_INTEREST = (
    "sse4_2",
    "fma",
    "avx",
    "avx2",
    "avx512f",
    "avx512dq",
    "avx512vl",
    "avx512_bf16",
    "avx_vnni",
    "amx_tile",
    "amx_bf16",
    "amx_int8",
)

"""
    cpu_isa_features() -> Vector{String}

Vector-instruction-set flags of `/proc/cpuinfo` relevant to dense linear algebra
(Linux only; empty elsewhere).
"""
function cpu_isa_features()
    (Sys.islinux() && isfile("/proc/cpuinfo")) || return String[]
    for line in eachline("/proc/cpuinfo")
        startswith(line, "flags") || continue
        flags = Set(split(last(split(line, ':'))))
        return String[flag for flag in ISA_FLAGS_OF_INTEREST if flag in flags]
    end
    return String[]
end

"""
    host_info(; record_hostname::Bool = true) -> HostInfo

Collect the platform fingerprint of the current process.
"""
function host_info(; record_hostname::Bool = true)
    cpu = Sys.cpu_info()
    model = isempty(cpu) ? "unknown" : String(strip(cpu[1].model))
    speeds = [Int(c.speed) for c in cpu if c.speed > 0]
    physical, source = physical_core_count()
    return HostInfo(
        record_hostname ? gethostname() : "",
        string(VERSION),
        string(Base.GIT_VERSION_INFO.commit_short),
        string(Sys.KERNEL),
        string(Sys.MACHINE),
        Sys.WORD_SIZE,
        model,
        physical,
        Sys.CPU_THREADS,
        source,
        Threads.nthreads(),
        Threads.nthreads(:interactive),
        Threads.ngcthreads(),
        blas_library_label(),
        BLAS.get_num_threads(),
        Int(Sys.total_memory()),
        Int(Sys.free_memory()),
        cpu_isa_features(),
        isempty(speeds) ? (0, 0) : (minimum(speeds), maximum(speeds)),
        string(pkgversion(KernelAbstractions)),
    )
end

"""
    thread_sweep(physical::Int, logical::Int, ceiling::Symbol) -> Vector{Int}

Thread counts of the scaling sweep: the powers of two up to the ceiling and the ceiling
itself. With `ceiling = :physical` the sweep stops at the physical core count; with
`:logical` it continues to the logical thread count and also includes the physical
core count, so that oversubscription of hyper-threads is visible as its own point.
"""
function thread_sweep(physical::Int, logical::Int, ceiling::Symbol)
    ceiling in (:physical, :logical) || throw(
        ArgumentError("thread sweep ceiling must be :physical or :logical, got :$ceiling"),
    )
    (physical >= 1 && logical >= 1) || throw(
        ArgumentError(
            "thread counts must be >= 1, got physical = $physical, logical = $logical",
        ),
    )
    top = ceiling === :physical ? physical : logical
    counts = [2^k for k in 0:floor(Int, log2(top))]
    push!(counts, top)
    ceiling === :logical && push!(counts, physical)
    return sort(unique(counts))
end

"""
    print_host_report(io::IO, host::HostInfo)

Human-readable host section of the report.
"""
function print_host_report(io::IO, host::HostInfo)
    println(io, "Host")
    isempty(host.hostname) || println(io, "  Hostname              : ", host.hostname)
    println(
        io,
        "  Julia                 : ",
        host.julia_version,
        " (",
        host.julia_commit,
        ")",
    )
    println(
        io,
        "  Platform              : ",
        host.machine,
        ", ",
        host.os,
        " kernel, ",
        host.word_size,
        "-bit",
    )
    println(io, "  CPU model             : ", host.cpu_model)
    println(
        io,
        "  Physical cores        : ",
        host.physical_cores,
        " (",
        host.topology_source,
        ")",
    )
    println(io, "  Logical threads       : ", host.logical_threads)
    if host.cpu_frequency_mhz != (0, 0)
        println(
            io,
            "  Sampled frequencies   : ",
            host.cpu_frequency_mhz[1],
            " to ",
            host.cpu_frequency_mhz[2],
            " MHz",
        )
    end
    isempty(host.isa_features) ||
        println(io, "  Vector ISA            : ", join(host.isa_features, ", "))
    println(
        io,
        "  Memory total / free   : ",
        format_bytes(host.total_memory_bytes),
        " / ",
        format_bytes(host.free_memory_bytes),
    )
    println(
        io,
        "  Julia threads         : ",
        host.julia_threads,
        " default, ",
        host.interactive_threads,
        " interactive, ",
        host.gc_threads,
        " GC",
    )
    println(
        io,
        "  BLAS                  : ",
        host.blas_library,
        ", ",
        host.blas_threads,
        " threads",
    )
    println(io, "  KernelAbstractions    : v", host.kernel_abstractions_version)
    return nothing
end

end
