#!/usr/bin/env julia
# test.jl — global test runner. Discovers every sub-environment with test/runtests.jl,
# instantiates it, and runs its suite in an isolated child process. Package
# environments (Project.toml with name and uuid plus src/<Name>.jl) run through
# Pkg.test, which honors test/Project.toml; plain environments run the script directly.
#
#   julia test.jl            all suites
#   julia test.jl <tool>     one suite

using Printf: @printf
using TOML: TOML

const REPO_ROOT = @__DIR__
const NON_TOOL_ENVIRONMENTS = Set(["formatter"])

struct SuiteResult
    name::String
    passed::Bool
    duration_s::Float64
    exit_code::Int
end

"""
    is_package(dir::String) -> Bool

Whether the environment in `dir` is a package (named project with a source module).
"""
function is_package(dir::String)
    project = TOML.parsefile(joinpath(dir, "Project.toml"))
    (haskey(project, "name") && haskey(project, "uuid")) || return false
    return isfile(joinpath(dir, "src", project["name"] * ".jl"))
end

"""
    discover_test_suites(target::Union{String, Nothing}) -> Vector{String}

Names of the sub-environments that ship `test/runtests.jl`, optionally restricted to
`target`.
"""
function discover_test_suites(target::Union{String, Nothing} = nothing)
    suites = String[]
    for item in sort(readdir(REPO_ROOT))
        startswith(item, ".") && continue
        item in NON_TOOL_ENVIRONMENTS && continue
        target !== nothing && item != target && continue
        dir = joinpath(REPO_ROOT, item)
        isfile(joinpath(dir, "Project.toml")) || continue
        isfile(joinpath(dir, "test", "runtests.jl")) || continue
        push!(suites, item)
    end
    return suites
end

"""
    run_suite(name::String) -> SuiteResult

Instantiate the environment `name` and run its tests in a child process.
"""
function run_suite(name::String)
    dir = joinpath(REPO_ROOT, name)
    julia = `$(Base.julia_cmd()) --startup-file=no --project=$dir`
    println("\n>>> $name")
    t_start = time()
    instantiate =
        run(ignorestatus(`$julia -e 'using Pkg; Pkg.instantiate(; io = devnull)'`))
    if instantiate.exitcode != 0
        println(stderr, "<<< $name: instantiation failed (exit $(instantiate.exitcode))")
        return SuiteResult(name, false, time() - t_start, instantiate.exitcode)
    end
    cmd =
        is_package(dir) ? `$julia -e 'using Pkg; Pkg.test()'` :
        `$julia $(joinpath(dir, "test", "runtests.jl"))`
    process = run(ignorestatus(cmd))
    elapsed = time() - t_start
    passed = process.exitcode == 0
    @printf(
        "<<< %s: %s (%.1f s)\n",
        name,
        passed ? "passed" : "FAILED (exit $(process.exitcode))",
        elapsed
    )
    return SuiteResult(name, passed, elapsed, process.exitcode)
end

function main(args::Vector{String} = ARGS)
    target = isempty(args) ? nothing : args[1]
    suites = discover_test_suites(target)
    if isempty(suites)
        if target !== nothing
            println(stderr, "No test suite found for '$target'.")
            exit(1)
        end
        println("No test suites discovered.")
        return
    end
    println("Discovered $(length(suites)) test suite(s): ", join(suites, ", "))
    results = [run_suite(name) for name in suites]

    println("\nSummary")
    @printf("  %-28s %-8s %10s\n", "suite", "status", "duration")
    for r in results
        @printf(
            "  %-28s %-8s %8.1f s\n",
            r.name,
            r.passed ? "passed" : "FAILED",
            r.duration_s
        )
    end
    all(r -> r.passed, results) || exit(1)
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
