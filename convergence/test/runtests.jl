# Tests of the Convergence package. The numerical cases are schemes of known order on
# problems with closed-form solutions, so the suite validates itself without data.

using Convergence
using Test
using Aqua
using ExplicitImports
using JET
using TOML: TOML

const TOOL_DIR = normpath(joinpath(@__DIR__, ".."))

"Global error of forward Euler on y' = -y, y(0) = 1, at t = 1 with step h."
function euler_error(h)
    y = 1.0
    for _ in 1:round(Int, 1 / h)
        y -= h * y
    end
    return abs(y - exp(-1))
end

"Global error of the classical Runge-Kutta scheme on the same problem."
function rk4_error(h)
    y = 1.0
    f(y) = -y
    for _ in 1:round(Int, 1 / h)
        k1 = f(y)
        k2 = f(y + h / 2 * k1)
        k3 = f(y + h / 2 * k2)
        k4 = f(y + h * k3)
        y += h / 6 * (k1 + 2k2 + 2k3 + k4)
    end
    return abs(y - exp(-1))
end

"Error of the central difference of sin at x = 1."
central_error(h) = abs(cos(1.0) - (sin(1 + h) - sin(1 - h)) / (2h))

"Error of the trapezoidal rule on the integral of exp over [0, 1]."
function trapezoid_error(h)
    N = round(Int, 1 / h)
    s = (exp(0.0) + exp(1.0)) / 2 + sum(exp(j * h) for j in 1:(N - 1))
    return abs(h * s - (exp(1.0) - 1))
end

"Central difference of exp on the interior nodes of a grid of spacing h over [0, 1]."
function central_difference(h)
    N = round(Int, 1 / h)
    return [(exp(j * h + h) - exp(j * h - h)) / (2h) for j in 1:(N - 1)]
end

exact_derivative(h) = [exp(j * h) for j in 1:(round(Int, 1 / h) - 1)]

# Three-grid synthetic quantity with an exact power law: q(h) = 1.5 + 0.8 h^1.7.
synthetic_quantity(h) = 1.5 + 0.8 * h^1.7

@testset "Convergence" begin
    @testset "Static QA" begin
        Aqua.test_all(Convergence)
        @test ExplicitImports.check_no_implicit_imports(Convergence) === nothing
        @test ExplicitImports.check_no_stale_explicit_imports(Convergence) === nothing
        @test ExplicitImports.check_all_explicit_imports_via_owners(Convergence) === nothing
        report = JET.report_package(Convergence; target_modules = (Convergence,))
        reports = JET.get_reports(report)
        isempty(reports) || show(stdout, MIME"text/plain"(), report)
        @test isempty(reports)
    end

    @testset "Error norms" begin
        u = [1.0, 2.0, 3.0]
        v = [1.0, 2.0, 5.0]
        @test error_norm(u, v, :L1; measure = 0.5) ≈ 1.0
        @test error_norm(u, v, :L2; measure = 0.5) ≈ sqrt(2)
        @test error_norm(u, v, :Linf) ≈ 2.0
        @test error_norm(u, v, :relative) ≈ 2 / sqrt(30)
        @test error_norm(u, v) == error_norm(u, v, :L2)
        @test error_norm(Float32[1, 2, 3], Float32[1, 2, 5], :L2) isa Float64
        @test error_norm(reshape(u, 1, 3), reshape(v, 1, 3), :Linf) ≈ 2.0
        @test error_norm(2.0, 3.0) == 1.0
        @test error_norm(1.5, 1.0, :relative) == 0.5
        @test error_norm(1.5, 1.0, :L1; measure = 7) == 0.5
        @test_throws DimensionMismatch error_norm(u, [1.0, 2.0])
        @test_throws ArgumentError error_norm(u, v, :H1)
        @test_throws ArgumentError error_norm(u, v, :L2; measure = 0)
        @test_throws ArgumentError error_norm(u, zeros(3), :relative)
        @test_throws ArgumentError error_norm(1.0, 0.0, :relative)
        @test_throws ArgumentError error_norm(1.0, 2.0, :H1)
    end

    @testset "Pairwise orders" begin
        h = [0.4, 0.2, 0.1, 0.05, 0.025]
        e = 3 .* h .^ 2
        @test pairwise_orders(h, e) ≈ fill(2.0, 4)
        @test pairwise_orders(reverse(h), reverse(e)) ≈ fill(2.0, 4)
        @test pairwise_orders([0.2, 0.1], [0.2, 0.05]) ≈ [2.0]
        @test_throws ArgumentError pairwise_orders([0.1], [0.1])
        @test_throws ArgumentError pairwise_orders([0.2, 0.1], [0.2, 0.0])
        @test_throws ArgumentError pairwise_orders([0.2, 0.2], [0.2, 0.1])
        @test_throws ArgumentError pairwise_orders([0.2, -0.1], [0.2, 0.1])
        @test_throws DimensionMismatch pairwise_orders([0.2, 0.1], [0.2])
    end

    @testset "Exact power law" begin
        h = [0.1, 0.4, 0.025, 0.2, 0.05]
        e = 3 .* h .^ 2
        est = fit_order(h, e)
        @test est.order ≈ 2.0 atol = 1e-10
        @test est.constant ≈ 3.0 rtol = 1e-8
        @test est.standard_error ≈ 0.0 atol = 1e-8
        @test est.confidence_interval[1] ≈ 2.0 atol = 1e-6
        @test est.confidence_interval[2] ≈ 2.0 atol = 1e-6
        @test est.confidence_level == 0.95
        @test [l.h for l in est.levels] == [0.4, 0.2, 0.1, 0.05, 0.025]
        @test est.levels[1].order === nothing
        @test all(l.order ≈ 2.0 for l in est.levels[2:end])
        @test all(l.fitted for l in est.levels)
        @test occursin("p = 2", sprint(show, MIME"text/plain"(), est))
    end

    @testset "Skipped levels and the interval" begin
        h = [0.4, 0.2, 0.1, 0.05, 0.025]
        e = 3 .* h .^ 2
        e[1] *= 3  # a pre-asymptotic coarsest level
        biased = fit_order(h, e)
        @test abs(biased.order - 2) > 0.1
        est = fit_order(h, e; skip = 1)
        @test est.order ≈ 2.0 atol = 1e-10
        @test est.levels[1].fitted == false
        @test all(l.fitted for l in est.levels[2:end])
        @test est.levels[2].order ≈ 2 + log(3) / log(2)
        # a fit over three levels has one degree of freedom: t(1, 0.975) = 12.706
        noisy = fit_order([0.4, 0.2, 0.1], [1.0, 0.3, 0.06])
        @test noisy.standard_error > 0
        @test noisy.confidence_interval[2] - noisy.order ≈
              12.706204736174698 * noisy.standard_error rtol = 1e-6
        @test noisy.order - noisy.confidence_interval[1] ≈
              12.706204736174698 * noisy.standard_error rtol = 1e-6
        wider = fit_order([0.4, 0.2, 0.1], [1.0, 0.3, 0.06]; confidence = 0.99)
        @test wider.confidence_interval[2] > noisy.confidence_interval[2]
        @test wider.confidence_level == 0.99
        @test_throws ArgumentError fit_order(h, e; skip = 3)
        @test_throws ArgumentError fit_order(h, e; skip = -1)
        @test_throws ArgumentError fit_order(h, e; confidence = 1.0)
        @test_throws ArgumentError fit_order(h, e; confidence = 0.0)
        @test_throws ArgumentError fit_order([0.2, 0.1], [0.2, 0.05])
        @test_throws ArgumentError fit_order(h, [1.0, 0.5, 0.0, 0.1, 0.05])
        @test_throws ArgumentError fit_order([0.4, 0.4, 0.1], [1.0, 0.3, 0.06])
        @test_throws ArgumentError fit_order([0.4, 0.2, Inf], [1.0, 0.3, 0.06])
        @test_throws DimensionMismatch fit_order([0.4, 0.2], [1.0, 0.3, 0.06])
    end

    @testset "Schemes of known order" begin
        euler = convergence_study(euler_error, 2.0 .^ -(3:8))
        @test 0.98 < euler.order < 1.05
        @test all(1.0 < l.order < 1.05 for l in euler.levels[2:end])
        @test euler.order ≈ 1.0139626718473365 rtol = 1e-6
        @test euler.constant ≈ 0.1974275003937855 rtol = 1e-6
        @test euler.standard_error ≈ 0.00334063326373347 rtol = 1e-4
        rk4 = convergence_study(rk4_error, 2.0 .^ -(1:5))
        @test 3.9 < rk4.order < 4.3
        central = convergence_study(central_error, 2.0 .^ -(2:7))
        @test central.order ≈ 2.0 atol = 0.01
        @test central.constant ≈ cos(1.0) / 6 rtol = 0.02
        @test central.standard_error ≈ 0.00029181073341439366 rtol = 1e-4
        trapezoid = convergence_study(trapezoid_error, 2.0 .^ -(2:7))
        @test trapezoid.order ≈ 2.0 atol = 0.01
        @test trapezoid.constant ≈ (exp(1.0) - 1) / 12 rtol = 0.02
        l2 = convergence_study(
            central_difference,
            exact_derivative,
            2.0 .^ -(3:8);
            norm = :L2,
            measure = identity,
        )
        @test 1.95 < l2.order < 2.0
        linf = convergence_study(
            central_difference,
            exact_derivative,
            2.0 .^ -(3:8);
            norm = :Linf,
        )
        @test 1.9 < linf.order < 2.05
        skipped = convergence_study(euler_error, 2.0 .^ -(3:8); skip = 2)
        @test count(l -> l.fitted, skipped.levels) == 4
    end

    @testset "Three-grid procedure" begin
        h = [0.1, 0.2, 0.4]
        grid = grid_convergence(h, synthetic_quantity.(h))
        @test grid.h == (0.1, 0.2, 0.4)
        @test grid.refinement_ratios == (2.0, 2.0)
        @test grid.order ≈ 1.7 atol = 1e-8
        @test grid.extrapolated ≈ 1.5 atol = 1e-8
        @test grid.relative_error ≈ 0.02368061352554299 rtol = 1e-8
        @test grid.gci_fine ≈ 0.013161689971781835 rtol = 1e-6
        @test grid.gci_medium ≈ 0.04177324090512686 rtol = 1e-6
        @test grid.asymptotic_ratio ≈ 1.023680613525543 rtol = 1e-6
        @test grid.extrapolated_relative_error ≈ abs(1.5 - grid.values[1]) / 1.5 rtol = 1e-8
        @test !grid.oscillatory
        shuffled = grid_convergence([0.4, 0.1, 0.2], synthetic_quantity.([0.4, 0.1, 0.2]))
        @test shuffled.order ≈ grid.order
        uneven = grid_convergence([0.1, 0.2, 0.3], synthetic_quantity.([0.1, 0.2, 0.3]))
        @test collect(uneven.refinement_ratios) ≈ [2.0, 1.5]
        @test uneven.order ≈ 1.7 atol = 1e-8
        @test uneven.extrapolated ≈ 1.5 atol = 1e-8
        safer = grid_convergence(h, synthetic_quantity.(h); safety_factor = 3.0)
        @test safer.gci_fine ≈ 3 / 1.25 * grid.gci_fine
        oscillating = grid_convergence([0.1, 0.2, 0.4], [1.0, 1.2, 1.1])
        @test oscillating.oscillatory
        @test oscillating.order ≈ 1.0
        @test_throws ArgumentError grid_convergence([0.1, 0.2], [1.0, 1.1])
        @test_throws ArgumentError grid_convergence(h, [1.0, 1.0, 1.2])
        @test_throws ArgumentError grid_convergence(h, [0.0, 1.0, 1.2])
        @test_throws ArgumentError grid_convergence(h, [1.0, 1.1, 1.2]; safety_factor = 0.9)
        @test_throws ArgumentError grid_convergence([0.1, 0.1, 0.4], [1.0, 1.1, 1.2])
        io = IOBuffer()
        convergence_table(io, grid)
        text = String(take!(io))
        @test occursin("GCI", text)
        @test occursin("1.7", text)
        @test occursin("1.5", text)
    end

    @testset "Richardson extrapolation" begin
        c = 0.37
        @test richardson_extrapolate(1 + 0.25c, 1 + c, 2, 2) ≈ 1.0
        @test richardson_extrapolate([1 + 0.25c, 2 + 0.25c], [1 + c, 2 + c], 2, 2) ≈
              [1.0, 2.0]
        @test richardson_extrapolate(1 + c / 2^1.7, 1 + c, 2, 1.7) ≈ 1.0
        @test_throws ArgumentError richardson_extrapolate(1.0, 2.0, 1.0, 2)
        @test_throws ArgumentError richardson_extrapolate(1.0, 2.0, 2.0, 0)
        @test_throws DimensionMismatch richardson_extrapolate([1.0, 2.0], [1.0], 2, 2)
    end

    @testset "Settings" begin
        shipped = load_settings(joinpath(TOOL_DIR, "config.toml"))
        defaults = validate_settings(Dict{String, Any}())
        for name in fieldnames(StudySettings)
            @test getfield(shipped, name) == getfield(defaults, name)
        end
        @test shipped.confidence_level == 0.95
        @test shipped.skip_coarsest == 0
        @test shipped.safety_factor == 1.25
        @test shipped.format == "pdf"
        @test shipped.width_mm == 86.0
        @test shipped.fontsize_pt == 9.0
        @test shipped.reference_orders == Float64[]
        @test shipped.xlabel == "Step size h"
        bad(d) = validate_settings(d)
        @test_throws "unknown key 'extra'" bad(Dict("extra" => Dict()))
        @test_throws "confidence_level" bad(Dict("fit" => Dict("confidence_level" => 1.0)))
        @test_throws "confidence_level" bad(Dict("fit" => Dict("confidence_level" => true)))
        @test_throws "skip_coarsest" bad(Dict("fit" => Dict("skip_coarsest" => -1)))
        @test_throws "safety_factor" bad(Dict("fit" => Dict("safety_factor" => 0.5)))
        @test_throws "format" bad(Dict("figures" => Dict("format" => "jpg")))
        @test_throws "width_mm" bad(Dict("figures" => Dict("width_mm" => 10)))
        @test_throws "px_per_unit" bad(Dict("figures" => Dict("px_per_unit" => 0)))
        @test_throws "fontsize_pt" bad(Dict("figures" => Dict("fontsize_pt" => 20)))
        @test_throws "reference_orders" bad(
            Dict("figures" => Dict("reference_orders" => [0])),
        )
        @test_throws "xlabel" bad(Dict("figures" => Dict("xlabel" => "")))
        @test_throws "csv_directory" bad(Dict("output" => Dict("csv_directory" => "")))
        @test validate_settings(Dict("fit" => Dict("confidence_level" => 0.9))).confidence_level ==
              0.9
        @test validate_settings(Dict("figures" => Dict("reference_orders" => [1, 2.5]))).reference_orders ==
              [1.0, 2.5]
        @test_throws ArgumentError load_settings(joinpath(TOOL_DIR, "missing.toml"))
        mktempdir() do dir
            path = joinpath(dir, "broken.toml")
            write(path, "[fit\n")
            @test_throws path load_settings(path)
        end
    end

    @testset "Report and figure" begin
        h = [0.4, 0.2, 0.1, 0.05, 0.025]
        exact = fit_order(h, 3 .* h .^ 2)
        noisy = fit_order(h, [1.0, 0.3, 0.06, 0.02, 0.004]; skip = 1)
        io = IOBuffer()
        convergence_table(io, exact; label = "L2")
        text = String(take!(io))
        @test occursin("L2", text)
        @test occursin("exact power law", text)
        convergence_table(io, noisy)
        text = String(take!(io))
        @test occursin("±", text)
        @test occursin("95 % interval", text)
        @test occursin("4 levels", text)
        fig = convergence_figure(exact)
        @test fig isa Convergence.Figure
        both = convergence_figure(
            ["L2" => exact, "Linf" => noisy];
            reference_orders = [1, 2],
            xlabel = "Spacing h",
            ylabel = "Discrete error",
        )
        @test both isa Convergence.Figure
        settings = validate_settings(Dict{String, Any}())
        mktempdir() do dir
            pdf = Convergence.save_figure(both, joinpath(dir, "fig.pdf"), settings)
            @test isfile(pdf) && filesize(pdf) > 1000
            again = Convergence.save_figure(both, joinpath(dir, "fig.pdf"), settings)
            @test again == joinpath(dir, "fig#1.pdf")
            png_settings = validate_settings(Dict("figures" => Dict("format" => "png")))
            png = Convergence.save_figure(fig, joinpath(dir, "fig.png"), png_settings)
            @test isfile(png) && filesize(png) > 1000
        end
    end

    @testset "Command line" begin
        mktempdir() do dir
            h = [0.4, 0.2, 0.1, 0.05, 0.025]
            path = joinpath(dir, "errors.csv")
            open(path, "w") do io
                println(io, "h,L2,Linf")
                for (hk, e2, einf) in zip(h, 3 .* h .^ 2, 0.5 .* h)
                    println(io, "$hk,$e2,$einf")
                end
            end
            hs, series = read_series(path)
            @test hs == h
            @test first.(series) == ["L2", "Linf"]
            io = IOBuffer()
            result = main([path, "--out-dir", dir, "--format", "png"]; io)
            @test first.(result.estimates) == ["L2", "Linf"]
            @test result.estimates[1].second.order ≈ 2.0 atol = 1e-8
            @test result.estimates[2].second.order ≈ 1.0 atol = 1e-8
            @test isempty(result.grids)
            @test isfile(result.csv) && dirname(result.csv) == dir
            @test startswith(basename(result.csv), "convergence_errors_")
            @test result.figure == joinpath(dir, "convergence_errors.png")
            @test isfile(result.figure)
            text = String(take!(io))
            @test occursin("CSV written to", text)
            @test occursin("Figure written to", text)
            @test occursin("exact power law", text)
            lines = readlines(result.csv)
            @test lines[1] == "series,h,error,order,fitted"
            @test length(lines) == 11
            @test endswith(lines[2], ",true")
            @test count(==(','), lines[2]) == 4
            quiet = main(
                [
                    path,
                    "--no-csv",
                    "--no-figure",
                    "--skip",
                    "1",
                    "--confidence",
                    "0.9",
                    "--reference-orders",
                    "1,2",
                ];
                io = IOBuffer(),
            )
            @test quiet.csv === nothing && quiet.figure === nothing
            @test quiet.estimates[1].second.confidence_level == 0.9
            @test quiet.estimates[1].second.levels[1].fitted == false
            quantity = joinpath(dir, "quantity.csv")
            open(quantity, "w") do io
                println(io, "h,energy")
                for hk in [0.4, 0.2, 0.1, 0.05, 0.025]
                    println(io, "$hk,$(synthetic_quantity(hk))")
                end
            end
            io = IOBuffer()
            studied = main([quantity, "--quantity", "--out-dir", dir, "--no-figure"]; io)
            @test length(studied.grids) == 1
            @test studied.grids[1].first == "energy"
            @test studied.grids[1].second.order ≈ 1.7 atol = 1e-8
            @test studied.grids[1].second.extrapolated ≈ 1.5 atol = 1e-8
            @test studied.estimates[1].second.order ≈ 1.7 atol = 1e-6
            @test occursin("GCI", String(take!(io)))
            custom = joinpath(dir, "custom.toml")
            write(custom, "[fit]\nskip_coarsest = 2\n[figures]\nformat = \"svg\"\n")
            configured = main(
                [path, "--config", custom, "--out-dir", dir, "--no-csv"];
                io = IOBuffer(),
            )
            @test count(l -> l.fitted, configured.estimates[1].second.levels) == 3
            @test endswith(configured.figure, ".svg")
            @test main(["--help"]; io = IOBuffer()) === nothing
            io = IOBuffer()
            main(["-h"]; io)
            @test occursin("--quantity", String(take!(io)))
            noh = joinpath(dir, "noh.csv")
            write(noh, "x,L2\n0.1,1\n0.05,0.25\n0.025,0.0625\n")
            @test_throws ArgumentError main(
                [noh, "--no-csv", "--no-figure"];
                io = IOBuffer(),
            )
            text_column = joinpath(dir, "text.csv")
            write(text_column, "h,L2,note\n0.1,1,a\n0.05,0.25,b\n0.025,0.0625,c\n")
            @test_throws "note" main(
                [text_column, "--no-csv", "--no-figure"];
                io = IOBuffer(),
            )
            short = joinpath(dir, "short.csv")
            write(short, "h,L2\n0.1,1\n0.05,0.25\n")
            @test_throws ArgumentError main(
                [short, "--quantity", "--no-csv", "--no-figure"];
                io = IOBuffer(),
            )
            @test_throws "unknown command-line argument" main(
                [path, "--bogus"];
                io = IOBuffer(),
            )
            @test_throws "--skip" main([path, "--skip", "-1"]; io = IOBuffer())
            @test_throws "--confidence" main([path, "--confidence", "1"]; io = IOBuffer())
            @test_throws "--format" main([path, "--format", "jpg"]; io = IOBuffer())
            @test_throws "requires a value" main([path, "--skip"]; io = IOBuffer())
            @test_throws ArgumentError main([path, path]; io = IOBuffer())
            @test_throws ArgumentError main(String[]; io = IOBuffer())
            @test_throws ArgumentError main([joinpath(dir, "absent.csv")]; io = IOBuffer())
        end
    end
end
