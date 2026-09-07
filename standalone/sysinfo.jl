#!/usr/bin/env julia
# ==============================================================================
# sysinfo.jl — Standalone Host & Runtime Introspection Utility
# ==============================================================================
# Tier 2 standalone script requiring only standard Julia libraries.
# Reports CPU topology, memory capacity, BLAS thread configuration, and runtime.
# ==============================================================================

using InteractiveUtils
using LinearAlgebra
using Printf

function main()
    println("="^76)
    println(" Host & Runtime Platform Introspection")
    println("="^76)

    # Runtime metadata
    println("\n[Julia Runtime]")
    println("  • Julia Version      : ", VERSION)
    println(
        "  • Commit / Date      : ",
        Base.GIT_VERSION_INFO.commit_short,
        " (",
        Base.GIT_VERSION_INFO.date_string,
        ")",
    )
    println("  • Executable Path    : ", Base.julia_cmd())
    println("  • Active Environment : ", Base.active_project())

    # CPU & System Architecture
    println("\n[Hardware Topology]")
    println(
        "  • Operating System   : ",
        Sys.islinux() ? "Linux" :
        Sys.isapple() ? "macOS" : Sys.iswindows() ? "Windows" : string(Sys.KERNEL),
    )
    println("  • Kernel Architecture: ", Sys.ARCH, " (", Sys.WORD_SIZE, "-bit)")
    println("  • Hostname           : ", gethostname())

    cpu_info = Sys.cpu_info()
    if !isempty(cpu_info)
        println("  • CPU Model          : ", strip(cpu_info[1].model))
        println("  • Physical Sockets   : ", length(cpu_info))
    end
    println("  • Logical Threads    : ", Sys.CPU_THREADS)
    println("  • Active Julia Threads: ", Threads.nthreads())

    total_ram_gib = Sys.total_memory() / 1024^3
    free_ram_gib = Sys.free_memory() / 1024^3
    @printf("  • Total Physical RAM : %.2f GiB\n", total_ram_gib)
    @printf("  • Available Free RAM : %.2f GiB\n", free_ram_gib)

    # Linear Algebra & BLAS
    println("\n[Linear Algebra & BLAS Backend]")
    println("  • BLAS Vendor        : ", BLAS.get_config().loaded_libs[1].libname)
    println("  • BLAS Worker Threads: ", BLAS.get_num_threads())

    # Git repository provenance if within git tree
    git_dir = joinpath(@__DIR__, "..", ".git")
    if isdir(git_dir)
        try
            branch = strip(read(`git rev-parse --abbrev-ref HEAD`, String))
            commit = strip(read(`git rev-parse --short HEAD`, String))
            println("\n[Repository Provenance]")
            println("  • Git Branch         : ", branch)
            println("  • Commit Hash        : ", commit)
        catch
            # Git command not available or not in repo
        end
    end

    println("\n" * "="^76)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
