#!/usr/bin/env julia
# format.jl — formats a directory tree with the pinned JuliaFormatter environment.
#
#   julia formatter/format.jl DIR            format in place
#   julia formatter/format.jl DIR --check    report differences without applying them
#
# Exit status 1 with --check when a file differs from its formatted form, and in both
# modes when the formatter warns about a file, as about one that does not parse.

include(joinpath(@__DIR__, "activate.jl"))

using JuliaFormatter: format
using Logging: Logging, AbstractLogger, current_logger, with_logger

"""
    WarningCounter(parent, count)

Logger that hands every message to `parent` and counts those at warning level or above.
JuliaFormatter reports a file it cannot parse with a warning and goes on, so its return
value does not tell that a file was left as it was.
"""
struct WarningCounter <: AbstractLogger
    parent::AbstractLogger
    count::Base.RefValue{Int}
end

Logging.min_enabled_level(logger::WarningCounter) = Logging.min_enabled_level(logger.parent)
Logging.shouldlog(logger::WarningCounter, args...) =
    Logging.shouldlog(logger.parent, args...)
Logging.catch_exceptions(logger::WarningCounter) = Logging.catch_exceptions(logger.parent)
function Logging.handle_message(logger::WarningCounter, level, args...; kwargs...)
    level >= Logging.Warn && (logger.count[] += 1)
    return Logging.handle_message(logger.parent, level, args...; kwargs...)
end

function main(args::Vector{String} = ARGS)
    check_only = "--check" in args
    targets = filter(!=("--check"), args)
    if length(targets) != 1
        println(stderr, "Usage: julia format.jl DIR [--check]")
        exit(2)
    end
    warnings = Ref(0)
    formatted = with_logger(WarningCounter(current_logger(), warnings)) do
        format(only(targets); overwrite = !check_only)
    end
    if warnings[] > 0
        println(stderr, "Not every file could be formatted; see the warnings above.")
        exit(1)
    end
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
