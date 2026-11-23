# Observed order of accuracy: pairwise orders, least-squares fit with a t-interval,
# Richardson extrapolation and the three-grid procedure of Celik et al. (2008).

"""
    ConvergenceLevel

One level of a convergence study: step size `h`, error `error`, pairwise observed order
`order` with respect to the previous, coarser level (`nothing` for the coarsest), and
`fitted`, whether the level entered the least-squares fit.
"""
struct ConvergenceLevel
    h::Float64
    error::Float64
    order::Union{Float64, Nothing}
    fitted::Bool
end

"""
    OrderEstimate

Estimate of the order p in e ≈ C hᵖ: the order `order`, its standard error
`standard_error`, the two-sided Student-t interval `confidence_interval` at
`confidence_level`, the constant `constant` (C) and the levels of the study `levels`,
sorted by decreasing h (coarsest first).

The interval is that of the regression slope: it measures the scatter of the fitted
levels about one power law. Discretisation errors are deterministic, so it is not a
confidence interval for the asymptotic order, which pre-asymptotic levels bias beyond it.

An estimate taken from the three-grid procedure ([`extrapolated_estimate`](@ref)) has no
interval: `standard_error`, `confidence_interval` and `confidence_level` are `NaN`.
"""
struct OrderEstimate
    order::Float64
    standard_error::Float64
    confidence_interval::Tuple{Float64, Float64}
    confidence_level::Float64
    constant::Float64
    levels::Vector{ConvergenceLevel}
end

"""
    GridConvergence

Result of the three-grid procedure: step sizes `h` and values `values` of the quantity
on the fine, medium and coarse grids, refinement ratios `refinement_ratios` (r₂₁ = h₂/h₁,
r₃₂ = h₃/h₂), observed order `order`, extrapolated value `extrapolated`, approximate
relative error e_a = `relative_error`, extrapolated relative error e_ext =
`extrapolated_relative_error`, grid convergence indices of the fine and medium grids
`gci_fine` and `gci_medium` (fractions), `asymptotic_ratio` GCI₃₂ / (r₂₁ᵖ GCI₂₁), which
approaches 1 in the asymptotic range, and `oscillatory`, set when the differences
between successive grids change sign.
"""
struct GridConvergence
    h::NTuple{3, Float64}
    values::NTuple{3, Float64}
    refinement_ratios::NTuple{2, Float64}
    order::Float64
    extrapolated::Float64
    relative_error::Float64
    extrapolated_relative_error::Float64
    gci_fine::Float64
    gci_medium::Float64
    asymptotic_ratio::Float64
    oscillatory::Bool
end

"""
    sorted_levels(h, errors) -> (Vector{Float64}, Vector{Float64})

Step sizes and errors as `Float64` vectors sorted by decreasing h. Every h must be
positive and finite, every error non-negative and finite, and the step sizes distinct;
an `ArgumentError` names the offending index.
"""
function sorted_levels(h::AbstractVector{<:Real}, errors::AbstractVector{<:Real})
    length(h) == length(errors) || throw(
        DimensionMismatch(
            "h has $(length(h)) entries but the errors have $(length(errors))",
        ),
    )
    for (k, (hk, ek)) in enumerate(zip(h, errors))
        (isfinite(hk) && hk > 0) ||
            throw(ArgumentError("h[$k] must be positive and finite, got $hk"))
        (isfinite(ek) && ek >= 0) ||
            throw(ArgumentError("errors[$k] must be non-negative and finite, got $ek"))
    end
    allunique(h) || throw(ArgumentError("the step sizes h must be distinct"))
    permutation = sortperm(collect(h); rev = true)
    hs = Float64[h[k] for k in permutation]
    es = Float64[errors[k] for k in permutation]
    return hs, es
end

"""
Residual sum of squares of log e below which a fit is reported as an exact power law:
residuals of 10⁻¹² in log e, above round-off and below any genuine misfit.
"""
const EXACT_RESIDUAL = 1e-24

function check_nonzero(hs::Vector{Float64}, es::Vector{Float64})
    k = findfirst(iszero, es)
    k === nothing ||
        throw(ArgumentError("the error vanishes at h = $(hs[k]); no order can be formed"))
    return nothing
end

"Pairwise orders of levels already sorted by decreasing h."
consecutive_orders(hs::Vector{Float64}, es::Vector{Float64}) =
    Float64[log(es[k] / es[k + 1]) / log(hs[k] / hs[k + 1]) for k in 1:(length(hs) - 1)]

"""
    pairwise_orders(h::AbstractVector{<:Real}, errors::AbstractVector{<:Real})
        -> Vector{Float64}

Observed orders of successive levels. After sorting by decreasing h, element k is
log(eₖ / eₖ₊₁) / log(hₖ / hₖ₊₁), so the result has one entry fewer than the levels.

Throws `ArgumentError` for fewer than two levels, for a vanishing error and for the
conditions of the level validation (positive, finite, distinct h; non-negative, finite
errors).

# Example
```julia
pairwise_orders([0.1, 0.05, 0.025], [1e-2, 2.5e-3, 6.25e-4])  # [2.0, 2.0]
```
"""
function pairwise_orders(h::AbstractVector{<:Real}, errors::AbstractVector{<:Real})
    hs, es = sorted_levels(h, errors)
    length(hs) >= 2 ||
        throw(ArgumentError("at least two levels are required, got $(length(hs))"))
    check_nonzero(hs, es)
    return consecutive_orders(hs, es)
end

"""
    fit_order(h, errors; confidence::Real = 0.95, skip::Integer = 0) -> OrderEstimate

Order p and constant C of e ≈ C hᵖ by ordinary least squares of y = log e on x = log h.
The levels are sorted by decreasing h and the `skip` coarsest are left out of the fit,
which then runs over m = n - skip ≥ 3 levels: p = Sxy / Sxx, log C = ȳ - p x̄. With the
residual sum of squares SSR and s² = SSR / (m - 2), the standard error of p is
(s² / Sxx)^(1/2) and the interval is p ± t s_p with t the 1 - (1 - confidence)/2
quantile of Student's t distribution with m - 2 degrees of freedom. An exact power law
(SSR at the level of round-off, below [`EXACT_RESIDUAL`](@ref)) gives a zero standard
error and the interval (p, p). The interval describes the scatter of the levels about
the fitted power law, not the uncertainty of the asymptotic order
([`OrderEstimate`](@ref)).

Every level carries its pairwise order with respect to the next coarser one, whether it
entered the fit or not.

Returns an [`OrderEstimate`](@ref). Throws `ArgumentError` for a confidence outside
(0, 1), a negative `skip`, fewer than three fitted levels, a vanishing error, or invalid
levels.

# Example
```julia
h = [0.2, 0.1, 0.05, 0.025]
fit_order(h, 0.3 .* h .^ 2)  # order 2, constant 0.3
```
"""
function fit_order(
    h::AbstractVector{<:Real},
    errors::AbstractVector{<:Real};
    confidence::Real = 0.95,
    skip::Integer = 0,
)
    0 < confidence < 1 ||
        throw(ArgumentError("the confidence level must lie in (0, 1), got $confidence"))
    skip >= 0 || throw(ArgumentError("skip must be an integer >= 0, got $skip"))
    hs, es = sorted_levels(h, errors)
    n = length(hs)
    m = n - skip
    m >= 3 || throw(ArgumentError("at least three levels must enter the fit, got $m"))
    check_nonzero(hs, es)
    x = log.(hs[(skip + 1):n])
    y = log.(es[(skip + 1):n])
    x̄ = mean(x)
    ȳ = mean(y)
    Sxx = sum(abs2(xk - x̄) for xk in x)
    Sxy = sum((xk - x̄) * (yk - ȳ) for (xk, yk) in zip(x, y))
    p = Sxy / Sxx
    b = ȳ - p * x̄
    SSR = sum(abs2(yk - (b + p * xk)) for (xk, yk) in zip(x, y))
    # residuals of log e at the level of round-off mean an exact power law
    SSR <= EXACT_RESIDUAL && (SSR = 0.0)
    s_p = SSR == 0 ? 0.0 : sqrt(SSR / (m - 2) / Sxx)
    t = quantile(TDist(m - 2), 1 - (1 - confidence) / 2)
    orders = consecutive_orders(hs, es)
    levels = ConvergenceLevel[
        ConvergenceLevel(hs[k], es[k], k == 1 ? nothing : orders[k - 1], k > skip) for
        k in 1:n
    ]
    return OrderEstimate(
        p,
        s_p,
        (p - t * s_p, p + t * s_p),
        Float64(confidence),
        exp(b),
        levels,
    )
end

function check_extrapolation(r::Real, p::Real)
    (isfinite(r) && r > 1) ||
        throw(ArgumentError("the refinement ratio must be finite and exceed 1, got $r"))
    (isfinite(p) && p > 0) ||
        throw(ArgumentError("the order must be positive and finite, got $p"))
    return nothing
end

"""
    richardson_extrapolate(fine, coarse, r::Real, p::Real)

Richardson extrapolation (rᵖ f_fine - f_coarse) / (rᵖ - 1) of two solutions of a scheme
of order `p` on grids with refinement ratio `r` = h_coarse / h_fine. `fine` and
`coarse` are two numbers or two arrays of equal size, extrapolated entry by entry.

Returns a number or an array. Throws `ArgumentError` unless r > 1 and p > 0, and
`DimensionMismatch` for arrays of different size.

# Example
```julia
richardson_extrapolate(1.0025, 1.01, 2, 2)  # 1.0
```
"""
function richardson_extrapolate(fine::Number, coarse::Number, r::Real, p::Real)
    check_extrapolation(r, p)
    rᵖ = float(r)^p
    return (rᵖ * fine - coarse) / (rᵖ - 1)
end

function richardson_extrapolate(
    fine::AbstractArray,
    coarse::AbstractArray,
    r::Real,
    p::Real,
)
    check_extrapolation(r, p)
    size(fine) == size(coarse) || throw(
        DimensionMismatch("fine has size $(size(fine)), coarse has size $(size(coarse))"),
    )
    rᵖ = float(r)^p
    return (rᵖ .* fine .- coarse) ./ (rᵖ - 1)
end

"""
    order_threshold(r21, r32, s) -> Float64

Value that R = |ε₃₂/ε₂₁| must exceed for a positive order to exist: the limit of
r₂₁ᵖ (r₃₂ᵖ - s) / (r₂₁ᵖ - s) as p → 0, which is ln r₃₂ / ln r₂₁ for monotone convergence
(s = 1; 1 for a constant ratio) and 1 for oscillatory convergence (s = -1).
"""
order_threshold(r21::Float64, r32::Float64, s::Float64) = s > 0 ? log(r32) / log(r21) : 1.0

"""
    observed_order(ratio, r21, r32, s) -> Float64

Order of the three-grid procedure from R = |ε₃₂/ε₂₁| = `ratio` and the sign `s` of
ε₃₂/ε₂₁. Three values that follow φₖ = φ_ext + C (±1)ᵏ hₖᵖ satisfy

    R = r₂₁ᵖ (r₃₂ᵖ - s) / (r₂₁ᵖ - s),

which is p ln r₂₁ = ln R + q(p) with q(p) = ln((r₂₁ᵖ - s) / (r₃₂ᵖ - s)), the equation of
Celik et al. without its absolute value. The right-hand side of the first form increases
strictly with p from [`order_threshold`](@ref) to ∞, so the order is unique; it is
ln R / ln r for a constant ratio r and is found by bisection to 10⁻¹³ otherwise. The
fixed-point iteration of the paper diverges on such grids once r₃₂ is well above r₂₁.

Throws `ArgumentError` when R does not exceed the threshold, where no positive order
exists (for a constant ratio, the differences between the grids do not shrink under
refinement). The absolute value of the published equation would return a positive order
there.
"""
function observed_order(ratio::Float64, r21::Float64, r32::Float64, s::Float64)
    threshold = order_threshold(r21, r32, s)
    ratio > threshold || throw(
        ArgumentError(
            "no positive order exists: |ε32/ε21| = $ratio does not exceed $threshold, so the differences between the grids do not shrink fast enough under refinement",
        ),
    )
    a, b = log(r21), log(r32)
    isapprox(r21, r32; rtol = 1e-12) && return log(ratio) / a
    # ln(1 - s e⁻ˣ), without cancellation at small x and without overflow at large x
    tail(x) = s > 0 ? log(-expm1(-x)) : log1p(exp(-x))
    residual(p) = b * p + tail(b * p) - tail(a * p) - log(ratio)
    low, high = 0.0, 1.0
    while residual(high) < 0
        high *= 2
        high <= 1024 || throw(ArgumentError("the observed order exceeds 1024"))
    end
    while high - low > 1e-13 * max(1.0, high)
        middle = (low + high) / 2
        residual(middle) < 0 ? (low = middle) : (high = middle)
    end
    return (low + high) / 2
end

"""
    grid_convergence(h::AbstractVector{<:Real}, values::AbstractVector{<:Real};
                     safety_factor::Real = 1.25) -> GridConvergence

Three-grid procedure of Celik et al. for a scalar quantity φ computed on three grids.
The levels are sorted by increasing h into fine, medium and coarse (h₁ < h₂ < h₃), with
r₂₁ = h₂/h₁, r₃₂ = h₃/h₂, ε₂₁ = φ₂ - φ₁, ε₃₂ = φ₃ - φ₂ and s = sign(ε₃₂/ε₂₁); s < 0
marks oscillatory convergence. The order solves p ln r₂₁ = ln|ε₃₂/ε₂₁| + q(p) with
q(p) = ln((r₂₁ᵖ - s) / (r₃₂ᵖ - s)) ([`observed_order`](@ref)). Then

    φ_ext = (r₂₁ᵖ φ₁ - φ₂) / (r₂₁ᵖ - 1)
    e_a = |(φ₁ - φ₂) / φ₁|,  e_ext = |(φ_ext - φ₁) / φ_ext|
    GCI₂₁ = F_s e_a / (r₂₁ᵖ - 1),  GCI₃₂ = F_s |(φ₂ - φ₃) / φ₂| / (r₃₂ᵖ - 1)

with the safety factor F_s = `safety_factor` (1.25 in Celik et al. for three grids), and
the asymptotic ratio GCI₃₂ / (r₂₁ᵖ GCI₂₁). `e_ext` is `Inf` when φ_ext vanishes.

Under oscillatory convergence φ_ext, e_ext and the indices are those of the published
formulas, which assume a monotone error; an alternating error would place the limit
between φ₁ and φ₂.

References: I. B. Celik, U. Ghia, P. J. Roache, C. J. Freitas, H. Coleman and
P. E. Raad, J. Fluids Eng. 130(7), 078001 (2008), doi:10.1115/1.2960953;
P. J. Roache, J. Fluids Eng. 116(3), 405–413 (1994), doi:10.1115/1.2910291.

Returns a [`GridConvergence`](@ref). Throws `ArgumentError` unless exactly three levels
with distinct, positive, finite h and finite values are given; for F_s < 1; when the
quantity does not change between two grids; when φ₁ or φ₂ vanishes; when no positive
order exists ([`observed_order`](@ref)); and when the differences are so close to
round-off that their rounding error could change the order by more than half its value.

# Example
```julia
grid_convergence([0.01, 0.02, 0.04], [1.0001, 1.0004, 1.0016])  # order 2, φ_ext = 1
```
"""
function grid_convergence(
    h::AbstractVector{<:Real},
    values::AbstractVector{<:Real};
    safety_factor::Real = 1.25,
)
    (length(h) == 3 && length(values) == 3) || throw(
        ArgumentError(
            "the three-grid procedure takes exactly three levels, got $(length(h)) step sizes and $(length(values)) values",
        ),
    )
    safety_factor >= 1 ||
        throw(ArgumentError("the safety factor must be >= 1, got $safety_factor"))
    all(hk -> isfinite(hk) && hk > 0, h) ||
        throw(ArgumentError("the step sizes h must be positive and finite"))
    allunique(h) || throw(ArgumentError("the step sizes h must be distinct"))
    all(isfinite, values) || throw(ArgumentError("the values must be finite"))
    fine, medium, coarse = sortperm(collect(h))
    h1, h2, h3 = Float64(h[fine]), Float64(h[medium]), Float64(h[coarse])
    φ1, φ2, φ3 = Float64(values[fine]), Float64(values[medium]), Float64(values[coarse])
    r21 = h2 / h1
    r32 = h3 / h2
    ε21 = φ2 - φ1
    ε32 = φ3 - φ2
    (iszero(ε21) || iszero(ε32)) &&
        throw(ArgumentError("the quantity does not change between two of the grids"))
    (φ1 == 0 || φ2 == 0) && throw(
        ArgumentError(
            "the fine- or medium-grid value vanishes; the relative errors are undefined",
        ),
    )
    s = sign(ε32 / ε21)
    ratio = abs(ε32 / ε21)
    # relative rounding error of the ratio: each difference carries that of its operands
    roundoff = eps() * ((abs(φ1) + abs(φ2)) / abs(ε21) + (abs(φ2) + abs(φ3)) / abs(ε32))
    p = observed_order(ratio, r21, r32, s)
    # d ln R / dp is at least ln(min r) / 2, which bounds the change of p under that error
    uncertainty = 2 * roundoff / log(min(r21, r32))
    uncertainty > p / 2 && throw(
        ArgumentError(
            "the differences between the grids are at the level of round-off: the observed order $p is uncertain by up to $uncertainty",
        ),
    )
    extrapolated = (r21^p * φ1 - φ2) / (r21^p - 1)
    relative_error = abs((φ1 - φ2) / φ1)
    gci_fine = safety_factor * relative_error / (r21^p - 1)
    gci_medium = safety_factor * abs((φ2 - φ3) / φ2) / (r32^p - 1)
    return GridConvergence(
        (h1, h2, h3),
        (φ1, φ2, φ3),
        (r21, r32),
        p,
        extrapolated,
        relative_error,
        abs((extrapolated - φ1) / extrapolated),
        gci_fine,
        gci_medium,
        gci_medium / (r21^p * gci_fine),
        s < 0,
    )
end

"""
    extrapolated_estimate(h, values, grid::GridConvergence) -> OrderEstimate

Levels of a quantity of interest without an exact value, measured against the
extrapolated value of the three-grid procedure: the error of each level is
|φ - φ_ext|, the order is `grid.order` and the constant is that of the power law through
the finest level. The three levels of `grid` are marked as fitted; they lie on that power
law by construction, so no least-squares fit is made and the estimate carries no interval
(`NaN`). Coarser levels show whether the sequence had reached that power law earlier.

Throws `ArgumentError` for oscillatory convergence, where the distances from the
extrapolated value are not errors; when the three finest levels of `h` and `values` are
not those of `grid`; and under the conditions of the level validation.
"""
function extrapolated_estimate(
    h::AbstractVector{<:Real},
    values::AbstractVector{<:Real},
    grid::GridConvergence,
)
    grid.oscillatory && throw(
        ArgumentError(
            "under oscillatory convergence the distances from the extrapolated value are not errors",
        ),
    )
    length(h) == length(values) || throw(
        DimensionMismatch(
            "h has $(length(h)) entries but the values have $(length(values))",
        ),
    )
    finest = sortperm(collect(h))[1:min(3, length(h))]
    (
        Tuple(Float64.(h[finest])) == grid.h &&
        Tuple(Float64.(values[finest])) == grid.values
    ) || throw(
        ArgumentError("the three finest levels are not those of the three-grid result"),
    )
    hs, es = sorted_levels(h, abs.(Float64.(values) .- grid.extrapolated))
    check_nonzero(hs, es)
    orders = consecutive_orders(hs, es)
    n = length(hs)
    levels = ConvergenceLevel[
        ConvergenceLevel(hs[k], es[k], k == 1 ? nothing : orders[k - 1], hs[k] in grid.h) for k in 1:n
    ]
    constant = es[n] / hs[n]^grid.order
    return OrderEstimate(grid.order, NaN, (NaN, NaN), NaN, constant, levels)
end

"""
    convergence_study(error_of_h, h::AbstractVector{<:Real}; kwargs...) -> OrderEstimate
    convergence_study(solve, exact, h::AbstractVector{<:Real}; norm::Symbol = :L2,
                      measure = identity, kwargs...) -> OrderEstimate

Evaluate a scheme at every step size of `h` and fit its order with
[`fit_order`](@ref), to which `kwargs` (`confidence`, `skip`) are passed.

In the first form `error_of_h(h)` returns the error at step size h. In the second,
`solve(h)` and `exact(h)` return the numerical and the exact solution on the grid of
step size h, and the error is [`error_norm`](@ref)`(solve(h), exact(h), norm;
measure = measure(h))`; `measure` maps h to the cell measure (h in one dimension, h² in
two), and the default `identity` suits one-dimensional grids.

Returns an [`OrderEstimate`](@ref).

# Example
```julia
euler(h) = (1 - h)^round(Int, 1 / h)    # forward Euler for y' = -y, y(0) = 1, at t = 1
convergence_study(h -> abs(euler(h) - exp(-1)), [0.1, 0.05, 0.025, 0.0125])
```
"""
function convergence_study(error_of_h, h::AbstractVector{<:Real}; kwargs...)
    errors = [Float64(error_of_h(hk)) for hk in h]
    return fit_order(h, errors; kwargs...)
end

function convergence_study(
    solve,
    exact,
    h::AbstractVector{<:Real};
    norm::Symbol = :L2,
    measure = identity,
    kwargs...,
)
    errors = [error_norm(solve(hk), exact(hk), norm; measure = measure(hk)) for hk in h]
    return fit_order(h, errors; kwargs...)
end
