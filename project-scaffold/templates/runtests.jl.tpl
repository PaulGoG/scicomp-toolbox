using <<PKG>>
using Test
using Aqua

@testset "<<PKG>>.jl" begin
    @testset "Static QA" begin
        Aqua.test_all(<<PKG>>)
        # JET follows the compiler: it runs from the release series this suite was
        # written on, and is only installed on the older ones
        @static if VERSION >= v"<<STABLE>>"
            @eval using JET: JET
            report = JET.report_package(<<PKG>>; target_modules = (<<PKG>>,))
            reports = JET.get_reports(report)
            isempty(reports) || show(stdout, MIME"text/plain"(), report)
            @test isempty(reports)
        end
    end
end
