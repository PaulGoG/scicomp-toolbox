#!/usr/bin/env julia
# ==============================================================================
# check.jl — Pre-Commit Code Quality & Verification Runner
# ==============================================================================
# 1. Formats all repository source code against .JuliaFormatter.toml.
# 2. Executes global test runner across all isolated sub-environments.
# ==============================================================================

using Printf

const REPO_ROOT = @__DIR__

function main()
    println("="^80)
    println(" Scientific Computing Workbench — Quality Assurance Check")
    println("="^80)

    # 1. Code Formatting
    println("\n[Step 1/2] Verifying & Applying Code Formatting (JuliaFormatter.jl)...")
    format_cmd = `$(Base.julia_cmd()) --startup-file=no -e '
        using Pkg
        Pkg.activate(temp=true; io=devnull)
        Pkg.add("JuliaFormatter"; io=devnull)
        using JuliaFormatter
        is_formatted = format(".", overwrite=true)
        println("  • JuliaFormatter applied successfully.")
    '`
    fmt_proc = Base.run(ignorestatus(format_cmd))
    if fmt_proc.exitcode != 0
        println(stderr, "✖ Code formatting failed.")
        exit(fmt_proc.exitcode)
    end

    # 2. Test Execution
    println("\n[Step 2/2] Running Global Test Suite across Sub-Environments...")
    test_script = joinpath(REPO_ROOT, "test.jl")
    test_proc = Base.run(ignorestatus(`$(Base.julia_cmd()) $test_script`))
    if test_proc.exitcode != 0
        println(stderr, "✖ Global tests failed.")
        exit(test_proc.exitcode)
    end

    println("\n" * "="^80)
    println("✓ All Quality Assurance Checks Passed Cleanly.")
    println("="^80)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
