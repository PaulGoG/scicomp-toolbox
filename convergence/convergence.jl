#!/usr/bin/env julia
# convergence — observed order of accuracy of a numerical scheme from an error sequence:
# pairwise orders, least-squares fit with a t-interval, Richardson extrapolation and the
# three-grid procedure of Celik et al. (2008), with a report, a CSV and a figure.
#
#   julia run.jl convergence FILE [--skip N] [--confidence X] [--quantity]
#                            [--reference-orders LIST] [--xlabel TEXT] [--ylabel TEXT]
#                            [--format pdf|png|svg] [--out-dir DIR] [--no-csv]
#                            [--no-figure] [--config PATH]

include(joinpath(@__DIR__, "activate.jl"))

using Convergence

if abspath(PROGRAM_FILE) == @__FILE__
    try
        Convergence.main(ARGS)
    catch err
        err isa ArgumentError || rethrow()
        println(stderr, "convergence: ", err.msg)
        exit(2)
    end
end
