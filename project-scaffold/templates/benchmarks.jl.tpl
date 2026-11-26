# Benchmarks of <<PKG>>, kept out of the test suite.
#
#   julia bench/benchmarks.jl

include(joinpath(@__DIR__, "activate.jl"))

using BenchmarkTools: BenchmarkGroup, @benchmarkable, run, tune!
using <<PKG>>

const SUITE = BenchmarkGroup()
# SUITE["name"] = @benchmarkable f($x)

if abspath(PROGRAM_FILE) == @__FILE__
    tune!(SUITE)
    display(run(SUITE; verbose = true))
end
