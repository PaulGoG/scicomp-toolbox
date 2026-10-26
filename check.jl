#!/usr/bin/env julia
# check.jl — pre-commit verification. Formats the repository through formatter/format.jl
# (pinned formatter environment), then runs the global test runner.
#
#   julia check.jl            format in place, then test
#   julia check.jl --check    fail on formatting differences instead of applying them

const REPO_ROOT = @__DIR__

"""
    exit_status(process::Base.Process) -> Int

Conventional status of a finished child: its exit code, or 128 plus the signal number when
a signal terminated it.
"""
exit_status(process::Base.Process) =
    process.termsignal != 0 ? 128 + process.termsignal : process.exitcode

function run_step(label::String, cmd::Cmd)
    println("\n[$label]")
    process = run(ignorestatus(cmd))
    if !success(process)
        println(stderr, "$label failed (exit $(exit_status(process))).")
        exit(exit_status(process))
    end
    return nothing
end

function main(args::Vector{String} = ARGS)
    check_only = "--check" in args
    format_script = joinpath(REPO_ROOT, "formatter", "format.jl")
    format_args = check_only ? [REPO_ROOT, "--check"] : [REPO_ROOT]
    run_step(
        "Formatting",
        `$(Base.julia_cmd()) --startup-file=no $format_script $format_args`,
    )
    run_step(
        "Tests",
        `$(Base.julia_cmd()) --startup-file=no $(joinpath(REPO_ROOT, "test.jl"))`,
    )
    println("\nAll checks passed.")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
