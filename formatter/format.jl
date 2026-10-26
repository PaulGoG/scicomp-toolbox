#!/usr/bin/env julia
# format.jl — formats a directory tree with the pinned JuliaFormatter environment.
#
#   julia formatter/format.jl DIR            format in place
#   julia formatter/format.jl DIR --check    report differences without applying them

include(joinpath(@__DIR__, "activate.jl"))

using JuliaFormatter: format

function main(args::Vector{String} = ARGS)
    check_only = "--check" in args
    targets = filter(!=("--check"), args)
    if length(targets) != 1
        println(stderr, "Usage: julia format.jl DIR [--check]")
        exit(2)
    end
    formatted = format(only(targets); overwrite = !check_only)
    if check_only && !formatted
        println(stderr, "Formatting differences found; run `julia check.jl` to apply them.")
        exit(1)
    end
    println(formatted ? "Formatting clean." : "Formatting applied.")
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
