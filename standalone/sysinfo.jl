#!/usr/bin/env julia
# sysinfo.jl — host and Julia runtime introspection with the standard library only.
# Reports the CPU topology (physical and logical), memory, thread pools, the BLAS
# library and, when run inside a git checkout, the repository revision.

using LinearAlgebra: BLAS
using Printf: @printf

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

"""
    repository_revision(dir::AbstractString) -> Union{Nothing, Tuple{String, String}}

Branch and short commit of the git checkout containing `dir`, or `nothing` when git or
the repository is unavailable.
"""
function repository_revision(dir::AbstractString)
    Sys.which("git") === nothing && return nothing
    branch = IOBuffer()
    commit = IOBuffer()
    ok_branch = success(
        pipeline(
            `git -C $dir rev-parse --abbrev-ref HEAD`;
            stdout = branch,
            stderr = devnull,
        ),
    )
    ok_commit = success(
        pipeline(`git -C $dir rev-parse --short HEAD`; stdout = commit, stderr = devnull),
    )
    (ok_branch && ok_commit) || return nothing
    return (strip(String(take!(branch))), strip(String(take!(commit))))
end

function main()
    println("Host and runtime introspection")

    println("\n[Julia runtime]")
    println(
        "  Version              : ",
        VERSION,
        " (",
        Base.GIT_VERSION_INFO.commit_short,
        ", ",
        Base.GIT_VERSION_INFO.date_string,
        ")",
    )
    println("  Binary directory     : ", Sys.BINDIR)
    println("  Active project       : ", something(Base.active_project(), "none"))
    println(
        "  Threads              : ",
        Threads.nthreads(),
        " default, ",
        Threads.nthreads(:interactive),
        " interactive, ",
        Threads.ngcthreads(),
        " GC",
    )

    println("\n[Hardware topology]")
    println("  Operating system     : ", Sys.KERNEL, " (", Sys.MACHINE, ")")
    println("  Hostname             : ", gethostname())
    cpu = Sys.cpu_info()
    println("  CPU model            : ", isempty(cpu) ? "unknown" : strip(cpu[1].model))
    physical, source = physical_core_count()
    println("  Physical cores       : ", physical, " (", source, ")")
    println("  Logical threads      : ", Sys.CPU_THREADS)
    @printf("  Memory total         : %.2f GiB\n", Sys.total_memory() / 1024^3)
    @printf("  Memory free          : %.2f GiB\n", Sys.free_memory() / 1024^3)

    println("\n[BLAS]")
    libraries = BLAS.get_config().loaded_libs
    if isempty(libraries)
        println("  Library              : none loaded")
    else
        library = first(libraries)
        println(
            "  Library              : ",
            basename(library.libname),
            " (",
            uppercase(string(library.interface)),
            ")",
        )
    end
    println("  Threads              : ", BLAS.get_num_threads())

    revision = repository_revision(@__DIR__)
    if revision !== nothing
        println("\n[Repository]")
        println("  Branch               : ", revision[1])
        println("  Commit               : ", revision[2])
    end
    println()
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
