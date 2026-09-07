#!/usr/bin/env julia
# check.jl — pre-commit verification. Formats the repository with the pinned
# formatter environment (formatter/), then runs the global test runner.
#
#   julia check.jl            format in place, then test
#   julia check.jl --check    fail on formatting differences instead of applying them

const REPO_ROOT = @__DIR__

function run_step(label::String, cmd::Cmd)
    println("\n[$label]")
    process = run(ignorestatus(cmd))
    if process.exitcode != 0
        println(stderr, "$label failed (exit $(process.exitcode)).")
        exit(process.exitcode)
    end
    return nothing
end

function main(args::Vector{String} = ARGS)
    check_only = "--check" in args
    formatter_dir = joinpath(REPO_ROOT, "formatter")
    format_program = """
        using Pkg
        Pkg.activate(raw"$formatter_dir"; io = devnull)
        Pkg.instantiate(; io = devnull)
        using JuliaFormatter
        formatted = format(raw"$REPO_ROOT"; overwrite = $(!check_only))
        if $(check_only) && !formatted
            println(stderr, "Formatting differences found; run `julia check.jl` to apply them.")
            exit(1)
        end
        println(formatted ? "Formatting clean." : "Formatting applied.")
        """
    run_step("Formatting", `$(Base.julia_cmd()) --startup-file=no -e $format_program`)
    run_step(
        "Tests",
        `$(Base.julia_cmd()) --startup-file=no $(joinpath(REPO_ROOT, "test.jl"))`,
    )
    println("\nAll checks passed.")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
