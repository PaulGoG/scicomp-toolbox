# Tests of the Convergence package. The numerical cases are schemes of known order on
# problems with closed-form solutions; the three-grid procedure is checked against the
# worked example of Celik et al. (2008), so the suite needs no data files.

using Convergence
using Convergence: StudySettings, load_settings, main, read_series, validate_settings
using Test
using Aqua
using ExplicitImports
using JET
using LinearAlgebra: diag

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

"""
Slope, intercept and standard error of the slope of the least-squares line through
(log h, log e), from the normal equations in extended precision: the reference for
`fit_order`, which forms the same quantities from centred sums.
"""
function reference_fit(h, e)
    X = hcat(log.(big.(h)), ones(BigFloat, length(h)))
    y = log.(big.(e))
    β = (X' * X) \ (X' * y)
    residual = y - X * β
    variance = sum(abs2, residual) / (length(h) - 2)
    return Float64(β[1]), Float64(exp(β[2])), Float64(sqrt(variance * diag(inv(X' * X))[1]))
end

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
        @test_throws ArgumentError error_norm(u, v, :L2; measure = Inf)
        @test error_norm(ComplexF32[1 + 2im], ComplexF32[1 - 2im], :Linf) == 4.0
        # entries wider than Float64 keep their precision until the norm is returned
        @test error_norm([big"1" + big"1e-30"], [big"1"], :Linf) ≈ 1e-30 rtol = 1e-12
        @test error_norm(big"1" + big"1e-30", big"1") ≈ 1e-30 rtol = 1e-12
        @test error_norm([big"1" + big"1e-30"], [big"1"], :L2; measure = 0.25) ≈ 5e-31 rtol =
            1e-12
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
        # round-off residuals are reported as an exact power law
        @test est.standard_error == 0.0
        @test est.confidence_interval[1] == est.order == est.confidence_interval[2]
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
        # a fit over three levels has one degree of freedom, where the quantile of
        # Student's t has the closed form t(1, P) = tan(π (P - 1/2))
        noisy = fit_order([0.4, 0.2, 0.1], [1.0, 0.3, 0.06])
        slope, constant, deviation = reference_fit([0.4, 0.2, 0.1], [1.0, 0.3, 0.06])
        @test noisy.order ≈ slope rtol = 1e-12
        @test noisy.constant ≈ constant rtol = 1e-12
        @test noisy.standard_error ≈ deviation rtol = 1e-10
        @test noisy.confidence_interval[2] - noisy.order ≈
              tan(0.475π) * noisy.standard_error rtol = 1e-10
        @test noisy.order - noisy.confidence_interval[1] ≈
              tan(0.475π) * noisy.standard_error rtol = 1e-10
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
        steps = 2.0 .^ -(3:8)
        euler = convergence_study(euler_error, steps)
        @test 0.98 < euler.order < 1.05
        @test all(1.0 < l.order < 1.05 for l in euler.levels[2:end])
        slope, constant, deviation = reference_fit(steps, euler_error.(steps))
        @test euler.order ≈ slope rtol = 1e-10
        @test euler.constant ≈ constant rtol = 1e-10
        @test euler.standard_error ≈ deviation rtol = 1e-8
        # e = (h / 2e)(1 + 5h/12 + ...): the constant tends to 1/(2e) from above
        @test exp(-1) / 2 < euler.constant < 1.1 * exp(-1) / 2
        # the residuals are the next term of the expansion, not noise: the interval of
        # the slope lies above the formal order
        @test euler.confidence_interval[1] > 1
        rk4 = convergence_study(rk4_error, 2.0 .^ -(1:5))
        @test 3.9 < rk4.order < 4.3
        steps = 2.0 .^ -(2:7)
        central = convergence_study(central_error, steps)
        @test central.order ≈ 2.0 atol = 0.01
        @test central.constant ≈ cos(1.0) / 6 rtol = 0.02
        @test central.standard_error ≈ last(reference_fit(steps, central_error.(steps))) rtol =
            1e-8
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
        # Celik et al. (2008), doi:10.1115/1.2960953, Table 1, first column: reattachment
        # length on 18000, 8000 and 4500 cells in two dimensions (h ∝ N^(-1/2)); the paper
        # gives r21 = 1.5, r32 = 1.333, p = 1.53, φ_ext = 6.1685, e_a = 1.5 %,
        # e_ext = 1.7 %, GCI = 2.2 %
        celik = grid_convergence([18000, 8000, 4500] .^ -0.5, [6.063, 5.972, 5.863])
        @test collect(celik.refinement_ratios) ≈ [1.5, 4 / 3]
        @test celik.order ≈ 1.53 atol = 0.005
        @test celik.extrapolated ≈ 6.1685 atol = 5e-5
        @test 100 * celik.relative_error ≈ 1.5 atol = 0.05
        @test 100 * celik.extrapolated_relative_error ≈ 1.7 atol = 0.05
        @test 100 * celik.gci_fine ≈ 2.2 atol = 0.05
        @test !celik.oscillatory

        # exact power law q = 1.5 + 0.8 h^1.7, constant ratio 2: closed forms
        h = [0.1, 0.2, 0.4]
        q1, q2, q3 = synthetic_quantity.(h)
        grid = grid_convergence(h, [q1, q2, q3])
        @test grid.h == (0.1, 0.2, 0.4)
        @test grid.refinement_ratios == (2.0, 2.0)
        @test grid.order ≈ 1.7 atol = 1e-10
        @test grid.extrapolated ≈ 1.5 atol = 1e-10
        @test grid.relative_error ≈ (q2 - q1) / q1 rtol = 1e-12
        @test grid.extrapolated_relative_error ≈ (q1 - 1.5) / 1.5 rtol = 1e-9
        @test grid.gci_fine ≈ 1.25 * (q2 - q1) / q1 / (2^1.7 - 1) rtol = 1e-9
        @test grid.gci_medium ≈ 1.25 * (q3 - q2) / q2 / (2^1.7 - 1) rtol = 1e-9
        # GCI32 / (r^p GCI21) = φ1 / φ2 on an exact power law
        @test grid.asymptotic_ratio ≈ q1 / q2 rtol = 1e-9
        @test !grid.oscillatory
        shuffled = grid_convergence([0.4, 0.1, 0.2], synthetic_quantity.([0.4, 0.1, 0.2]))
        @test shuffled.order ≈ grid.order
        safer = grid_convergence(h, [q1, q2, q3]; safety_factor = 3.0)
        @test safer.gci_fine ≈ 3 / 1.25 * grid.gci_fine

        # unequal ratios, including r32 well above r21, where the fixed-point iteration
        # of the paper diverges
        for steps in
            ([0.1, 0.2, 0.3], [0.1, 0.125, 0.25], [0.1, 0.15, 0.45], [1.0, 1.3, 2.6])
            uneven = grid_convergence(steps, synthetic_quantity.(steps))
            @test uneven.order ≈ 1.7 atol = 1e-9
            @test uneven.extrapolated ≈ 1.5 atol = 1e-9
        end
        linear = grid_convergence([1.0, 1.3, 2.6], 1 .+ 0.01 .* [1.0, 1.3, 2.6])
        @test linear.order ≈ 1.0 atol = 1e-9
        @test linear.extrapolated ≈ 1.0 atol = 1e-9

        # alternating error q = 1.5 + 0.8 (-1)^k h^1.7: same order, flagged
        for steps in ([0.1, 0.2, 0.4], [0.1, 0.2, 0.3])
            alternating =
                grid_convergence(steps, [1.5 + 0.8 * (-1)^k * steps[k]^1.7 for k in 1:3])
            @test alternating.oscillatory
            @test alternating.order ≈ 1.7 atol = 1e-9
        end
        # the extrapolated value is that of the published, monotone formula there, not
        # the limit 1.5 of the alternating sequence
        a1, a2, a3 = (1.5 + 0.8 * (-1)^k * h[k]^1.7 for k in 1:3)
        alternating = grid_convergence(h, [a1, a2, a3])
        @test alternating.extrapolated ≈ (2^1.7 * a1 - a2) / (2^1.7 - 1) rtol = 1e-9
        @test abs(alternating.extrapolated - 1.5) > 0.04
        io = IOBuffer()
        convergence_table(io, alternating)
        @test occursin("assume a monotone error", String(take!(io)))

        # no positive order: differences that grow or stay equal under refinement
        @test_throws "no positive order" grid_convergence(h, [1.0, 1.2, 1.3])
        @test_throws "no positive order" grid_convergence(h, [1.0, 1.2, 1.1])
        @test_throws "no positive order" grid_convergence(h, [1.0, 2.0, 3.0])
        @test_throws ArgumentError grid_convergence(h, [1.0, 1.1, 1.2])
        # monotone with unequal ratios: |ε32/ε21| = 1.5 does not exceed ln 4 / ln 2 = 2
        @test_throws "no positive order" grid_convergence([0.1, 0.2, 0.8], [1.0, 1.2, 1.5])
        # differences at the level of round-off: one ulp above the threshold, where the
        # unguarded order would be 6e-16, and ε21 = eps with ε32 = 99 eps, where it would
        # be log2(99) on a ratio known to a factor 7
        @test_throws "round-off" grid_convergence(h, [1.0, 2.0, nextfloat(3.0)])
        @test_throws "round-off" grid_convergence(h, [1.0, nextfloat(1.0), 1 + 100 * eps()])
        @test_throws ArgumentError grid_convergence([0.1, 0.2], [1.0, 1.1])
        @test_throws ArgumentError grid_convergence(h, [1.0, 1.0, 1.2])
        @test_throws ArgumentError grid_convergence(h, [0.0, 1.0, 3.0])
        @test_throws ArgumentError grid_convergence(h, [-1.0, 0.0, 3.0])
        @test_throws ArgumentError grid_convergence(h, [1.0, NaN, 2.0])
        @test_throws ArgumentError grid_convergence(h, [1.0, 1.1, 1.4]; safety_factor = 0.9)
        @test_throws ArgumentError grid_convergence([0.1, 0.1, 0.4], [1.0, 1.1, 1.4])
        # φ_ext = 0 for q = h²: the extrapolated relative error is infinite, the rest finite
        vanishing = grid_convergence(h, h .^ 2)
        @test vanishing.extrapolated == 0 && isinf(vanishing.extrapolated_relative_error)
        @test vanishing.order ≈ 2.0

        io = IOBuffer()
        convergence_table(io, grid)
        text = String(take!(io))
        @test occursin("GCI", text)
        @test occursin("1.7", text)
        @test occursin("1.5", text)
    end

    @testset "Quantity without an exact value" begin
        # q = 10, 3, 2 at h = 0.4, 0.2, 0.1: ε21 = 1, ε32 = 7, so p = log2(7) and
        # q_ext = (7·2 - 3) / 6 = 11/6
        grid = grid_convergence([0.4, 0.2, 0.1], [10.0, 3.0, 2.0])
        @test grid.order ≈ log2(7)
        @test grid.extrapolated ≈ 11 / 6
        estimate = extrapolated_estimate([0.4, 0.2, 0.1], [10.0, 3.0, 2.0], grid)
        @test estimate.order == grid.order
        @test isnan(estimate.standard_error)
        @test all(isnan, estimate.confidence_interval)
        @test [l.error for l in estimate.levels] ≈ [10 - 11 / 6, 3 - 11 / 6, 2 - 11 / 6]
        @test all(l.fitted for l in estimate.levels)
        @test estimate.constant ≈ (2 - 11 / 6) / 0.1^log2(7)
        # a fourth, coarser level is tabulated but did not determine the estimate
        h = [0.8, 0.4, 0.2, 0.1]
        q = synthetic_quantity.(h)
        grid = grid_convergence(h[2:4], q[2:4])
        estimate = extrapolated_estimate(h, q, grid)
        @test [l.fitted for l in estimate.levels] == [false, true, true, true]
        @test estimate.levels[1].error ≈ 0.8 * 0.8^1.7 rtol = 1e-8
        @test estimate.levels[2].order ≈ 1.7 atol = 1e-7
        io = IOBuffer()
        convergence_table(io, estimate)
        text = String(take!(io))
        @test occursin("three-grid", text)
        @test !occursin("exact power law", text) && !occursin("±", text)
        @test Convergence.fit_label("q", estimate) == "q: p = 1.70"
        # the estimate belongs to the grids it was computed from
        @test_throws "three finest levels" extrapolated_estimate(
            [0.05, 0.1, 0.2, 0.4],
            [9.0, q[4], q[3], q[2]],
            grid,
        )
        @test_throws "three finest levels" extrapolated_estimate(h, reverse(q), grid)
        oscillating = grid_convergence([0.1, 0.2, 0.4], [1.0, 0.9, 1.3])
        @test oscillating.oscillatory
        @test_throws ArgumentError extrapolated_estimate(
            [0.1, 0.2, 0.4],
            [1.0, 0.9, 1.3],
            oscillating,
        )
    end

    @testset "Richardson extrapolation" begin
        c = 0.37
        @test richardson_extrapolate(1 + 0.25c, 1 + c, 2, 2) ≈ 1.0
        @test richardson_extrapolate([1 + 0.25c, 2 + 0.25c], [1 + c, 2 + c], 2, 2) ≈
              [1.0, 2.0]
        @test richardson_extrapolate(1 + c / 2^1.7, 1 + c, 2, 1.7) ≈ 1.0
        @test_throws ArgumentError richardson_extrapolate(1.0, 2.0, 1.0, 2)
        @test_throws ArgumentError richardson_extrapolate(1.0, 2.0, 2.0, 0)
        @test_throws ArgumentError richardson_extrapolate(1.0, 2.0, Inf, 2)
        # integer r and p: 2^64 overflows Int64, the result is 1 - 1/(2^64 - 1)
        @test richardson_extrapolate(1.0, 2.0, 2, 64) ≈ 1.0 atol = 1e-15
        @test_throws DimensionMismatch richardson_extrapolate([1.0, 2.0], [1.0], 2, 2)
    end

    @testset "Settings" begin
        shipped = load_settings(joinpath(TOOL_DIR, "config.toml"))
        defaults = validate_settings(Dict{String, Any}())
        for name in fieldnames(StudySettings)
            @test getfield(shipped, name) == getfield(defaults, name)
        end
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
        # order and interval carry the decimals of the standard error
        steps = 2.0 .^ -(3:8)
        convergence_table(io, convergence_study(euler_error, steps))
        @test occursin(
            r"p = 1\.01\d\d ± 0\.00\d\d \(95 % interval \[1\.00\d\d, 1\.02\d\d\]\)",
            String(take!(io)),
        )
        convergence_table(
            io,
            fit_order(h, [1.0, 0.3, 0.06, 0.02, 0.004]; confidence = 0.999),
        )
        @test occursin("99.9 % interval", String(take!(io)))
        # legend: a standard error below the fourth decimal is not printed as zero
        tiny = fit_order([0.4, 0.2, 0.1], [0.16, 0.04, 0.01 * (1 + 1e-5)])
        @test 0 < tiny.standard_error < 5e-5
        @test Convergence.fit_label("s", tiny) == "s: p = 2.0000"
        @test Convergence.fit_label("L2", exact) == "L2: p = 2.00"
        @test occursin(
            r"^Linf: p = \d\.\d+ ± 0\.\d+$",
            Convergence.fit_label("Linf", noisy),
        )
        # x ticks: plain decimals at the step sizes when their labels fit
        ticks = Convergence.step_ticks([0.0125, 0.025, 0.05, 0.1], (0.011, 0.11), 190, 9)
        @test ticks == ([0.0125, 0.025, 0.05, 0.1], ["0.0125", "0.025", "0.05", "0.1"])
        @test Convergence.step_ticks(2.0 .^ -(9:-1:2), (0.0018, 0.27), 190, 9) === nothing
        @test Convergence.step_ticks([500.0, 1000.0, 2000.0], (450.0, 2200.0), 190, 9) ==
              ([500.0, 1000.0, 2000.0], ["500", "1000", "2000"])
        @test Convergence.step_ticks([1e-4, 2e-4], (9e-5, 2.2e-4), 190, 9) === nothing
        @test Convergence.log_label(1.0, false) == "1"
        @test Convergence.log_label(10.0, false) == "10"
        @test Convergence.log_label(0.01, true) == "0.01"
        makie = parentmodule(Convergence.Figure)
        theme_before = makie.current_default_theme().fontsize[]
        fig = convergence_figure(exact)
        @test fig isa Convergence.Figure
        # the figure is drawn under its own theme and leaves the active one alone
        @test makie.current_default_theme().fontsize[] == theme_before
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
            @test studied.estimates[1].second.order == studied.grids[1].second.order
            @test isnan(studied.estimates[1].second.standard_error)
            text = String(take!(io))
            @test occursin("GCI", text) && occursin("three-grid", text)
            @test !occursin("exact power law", text)
            # three arbitrary monotone levels are not reported as an exact power law
            arbitrary = joinpath(dir, "arbitrary.csv")
            write(arbitrary, "h,q\n0.4,10.0\n0.2,3.0\n0.1,2.0\n")
            io = IOBuffer()
            three = main([arbitrary, "--quantity", "--no-csv", "--no-figure"]; io)
            @test three.grids[1].second.extrapolated ≈ 11 / 6
            @test !occursin("exact power law", String(take!(io)))
            # oscillatory convergence: the three-grid report alone, no outputs
            wavy = joinpath(dir, "wavy.csv")
            write(wavy, "h,q\n0.4,1.3\n0.2,0.9\n0.1,1.0\n")
            io = IOBuffer()
            waved = main([wavy, "--quantity", "--out-dir", dir]; io)
            @test waved.grids[1].second.oscillatory
            @test isempty(waved.estimates) &&
                  waved.csv === nothing &&
                  waved.figure === nothing
            @test occursin("oscillatory convergence", String(take!(io)))
            # differences that grow under refinement are refused
            growing = joinpath(dir, "growing.csv")
            write(growing, "h,q\n0.4,1.3\n0.2,1.2\n0.1,1.0\n")
            @test_throws "no positive order" main(
                [growing, "--quantity", "--no-csv", "--no-figure"];
                io = IOBuffer(),
            )
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
