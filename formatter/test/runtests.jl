# Tests of the formatting script on three small trees: one to format, one clean, one with
# a file that does not parse, about which JuliaFormatter only warns.

using Test: @test, @testset

const SCRIPT = joinpath(@__DIR__, "..", "format.jl")

"Exit status of format.jl on `dir`, output discarded."
function status(dir::AbstractString, flags::String...)
    command =
        ignorestatus(`$(Base.julia_cmd()) --startup-file=no $SCRIPT $dir $(collect(flags))`)
    return run(pipeline(command; stdin = devnull, stdout = devnull, stderr = devnull)).exitcode
end

@testset "formatter" begin
    dir = mktempdir()
    source = joinpath(dir, "a.jl")
    write(source, "f( x )=x+1\n")
    # differences are reported by --check and removed without it
    @test status(dir, "--check") == 1
    @test read(source, String) == "f( x )=x+1\n"
    @test status(dir) == 0
    @test read(source, String) == "f(x) = x+1\n"
    @test status(dir, "--check") == 0
    @test status(dir) == 0

    # a file the formatter cannot parse fails both modes and is left as it is
    broken = joinpath(dir, "b.jl")
    write(broken, "function f(\n")
    @test status(dir) == 1
    @test status(dir, "--check") == 1
    @test read(broken, String) == "function f(\n"
    @test read(source, String) == "f(x) = x+1\n"

    # one directory, no more and no less
    @test status(dir, dir) == 2
end
