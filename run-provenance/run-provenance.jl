#!/usr/bin/env julia
# run-provenance — platform, environment, source and input provenance of a run as one
# flat record, printed or written as TOML.
#
#   julia run.jl run-provenance [--project PATH] [--root DIR] [--input FILE]...
#                               [--out FILE]

include(joinpath(@__DIR__, "activate.jl"))

using RunProvenance

if abspath(PROGRAM_FILE) == @__FILE__
    try
        RunProvenance.main(ARGS)
    catch err
        err isa ArgumentError || rethrow()
        println(stderr, "run-provenance: ", err.msg)
        exit(2)
    end
end
