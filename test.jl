#!/usr/bin/env julia
# ==============================================================================
# test.jl — Global Test Runner for Scientific Computing Workbench
# ==============================================================================
# Dynamically discovers and runs unit test suites across all sub-environments.
# Ensures each sub-environment is tested in isolation with its own Project.toml.
# ==============================================================================

using Printf

const REPO_ROOT = @__DIR__
const EXCLUDED_DIRS =
    Set(["test", ".git", ".github", "paper", "notes", "context", "standalone"])

struct TestResult
    name::String
    passed::Bool
    duration_s::Float64
    exit_code::Int
end

function discover_test_suites(target_filter::Union{String, Nothing} = nothing)
    suites = Pair{String, String}[]
    for item in readdir(REPO_ROOT)
        item in EXCLUDED_DIRS && continue
        if target_filter !== nothing && item != target_filter
            continue
        end
        test_file = joinpath(REPO_ROOT, item, "test", "runtests.jl")
        if isfile(test_file)
            push!(suites, item => test_file)
        end
    end
    return suites
end

function run_all_tests(args::Vector{String} = ARGS)
    target = isempty(args) ? nothing : args[1]
    suites = discover_test_suites(target)

    if isempty(suites)
        if target !== nothing
            println(stderr, "Error: No test suite found for target '$target'.")
            exit(1)
        else
            println("No test suites discovered in repository.")
            exit(0)
        end
    end

    println("="^80)
    println(" Scientific Computing Workbench — Global Test Suite")
    println(" Discovered $(length(suites)) test suite(s)")
    println("="^80)

    results = TestResult[]

    for (name, test_path) in suites
        env_dir = joinpath(REPO_ROOT, name)
        println("\n>>> Running Test Suite: [$name]")
        println("    Environment: ", relpath(env_dir, REPO_ROOT))
        println("    Test Script: ", relpath(test_path, REPO_ROOT))
        println("-"^80)

        t_start = time()
        cmd = `$(Base.julia_cmd()) --project=$env_dir $test_path`
        process = Base.run(ignorestatus(cmd))
        t_elapsed = time() - t_start
        passed = (process.exitcode == 0)

        push!(results, TestResult(name, passed, t_elapsed, process.exitcode))
        status_str = passed ? "PASSED" : "FAILED (exit $(process.exitcode))"
        println("-"^80)
        @printf("<<< Finished [%s]: %s (%.2f s)\n", name, status_str, t_elapsed)
    end

    # Summary table
    println("\n" * "="^80)
    println(" Global Test Summary")
    println("="^80)
    @printf(" %-28s │ %-10s │ %-12s\n", "Sub-Environment", "Status", "Duration")
    println("─"^30 * "┼" * "─"^12 * "┼" * "─"^14)

    all_passed = true
    for r in results
        status_display = r.passed ? "✓ PASS" : "✗ FAIL"
        @printf(" %-28s │ %-10s │ %8.2f s\n", r.name, status_display, r.duration_s)
        if !r.passed
            all_passed = false
        end
    end
    println("="^80)

    if all_passed
        println("✓ All $(length(results)) test suite(s) passed successfully.")
        exit(0)
    else
        println(stderr, "✖ Some test suites failed.")
        exit(1)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_all_tests(ARGS)
end
