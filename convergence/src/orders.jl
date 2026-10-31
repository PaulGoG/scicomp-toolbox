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

Least-squares estimate of the order p in e ≈ C hᵖ: the order `order`, its standard error
`standard_error`, the two-sided Student-t interval `confidence_interval` at
`confidence_level`, the constant `constant` (C) and the levels of the study `levels`,
sorted by decreasing h (coarsest first).
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
`gci_fine` and `gci_medium` (fractions), `asymptotic_ratio` r₂₁ᵖ GCI₂₁ / GCI₃₂, which
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
residuals of 10⁻¹² in log e, far above round-off and far below any real misfit.
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
error and the interval (p, p).

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
    r > 1 || throw(ArgumentError("the refinement ratio must exceed 1, got $r"))
    p > 0 || throw(ArgumentError("the order must be positive, got $p"))
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
    return (r^p * fine - coarse) / (r^p - 1)
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
    return (r^p .* fine .- coarse) ./ (r^p - 1)
end

"""
    observed_order(ratio, r21, r32, s) -> Float64

Order of the three-grid procedure from |ε₃₂/ε₂₁| = `ratio` and the sign `s` of ε₃₂/ε₂₁:
the fixed point of p = |ln ratio + q(p)| / ln r₂₁ with
q(p) = ln((r₂₁ᵖ - s) / (r₃₂ᵖ - s)), started from q = 0. For a constant refinement ratio
q vanishes and the start value is the order.
"""
function observed_order(ratio::Float64, r21::Float64, r32::Float64, s::Float64)
    p = abs(log(ratio)) / log(r21)
    isapprox(r21, r32; rtol = 1e-12) && return p
    for _ in 1:200
        q = log((r21^p - s) / (r32^p - s))
        p_next = abs(log(ratio) + q) / log(r21)
        abs(p_next - p) <= 1e-12 && return p_next
        p = p_next
    end
    throw(ArgumentError("the order iteration did not converge"))
end

"""
    grid_convergence(h::AbstractVector{<:Real}, values::AbstractVector{<:Real};
                     safety_factor::Real = 1.25) -> GridConvergence

Three-grid procedure of Celik et al. for a scalar quantity φ computed on three grids.
The levels are sorted by increasing h into fine, medium and coarse (h₁ < h₂ < h₃), with
r₂₁ = h₂/h₁, r₃₂ = h₃/h₂, ε₂₁ = φ₂ - φ₁, ε₃₂ = φ₃ - φ₂ and s = sign(ε₃₂/ε₂₁); s < 0
marks oscillatory convergence. The order solves
p = |ln|ε₃₂/ε₂₁| + q(p)| / ln r₂₁ with q(p) = ln((r₂₁ᵖ - s) / (r₃₂ᵖ - s)), by
fixed-point iteration to 10⁻¹² (at most 200 iterations; q = 0 when r₂₁ = r₃₂). Then

    φ_ext = (r₂₁ᵖ φ₁ - φ₂) / (r₂₁ᵖ - 1)
    e_a = |(φ₁ - φ₂) / φ₁|,  e_ext = |(φ_ext - φ₁) / φ_ext|
    GCI₂₁ = F_s e_a / (r₂₁ᵖ - 1),  GCI₃₂ = F_s |(φ₂ - φ₃) / φ₂| / (r₃₂ᵖ - 1)

with the safety factor F_s = `safety_factor` (1.25 for three grids, Roache 1994), and
the asymptotic ratio r₂₁ᵖ GCI₂₁ / GCI₃₂.

References: I. B. Celik, U. Ghia, P. J. Roache, C. J. Freitas, H. Coleman and
P. E. Raad, J. Fluids Eng. 130(7), 078001 (2008), doi:10.1115/1.2960953;
P. J. Roache, J. Fluids Eng. 116(3), 405–413 (1994), doi:10.1115/1.2910291.

Returns a [`GridConvergence`](@ref). Throws `ArgumentError` unless exactly three
levels with distinct, positive h are given, for F_s < 1, when the quantity does not
change between two grids, when φ₁ = 0, and when the iteration does not converge.

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
    fine, medium, coarse = sortperm(collect(h))
    h1, h2, h3 = Float64(h[fine]), Float64(h[medium]), Float64(h[coarse])
    φ1, φ2, φ3 = Float64(values[fine]), Float64(values[medium]), Float64(values[coarse])
    r21 = h2 / h1
    r32 = h3 / h2
    ε21 = φ2 - φ1
    ε32 = φ3 - φ2
    (iszero(ε21) || iszero(ε32)) &&
        throw(ArgumentError("the quantity does not change between two of the grids"))
    φ1 == 0 && throw(
        ArgumentError("the fine-grid value vanishes; the relative error is undefined"),
    )
    s = sign(ε32 / ε21)
    p = observed_order(abs(ε32 / ε21), r21, r32, s)
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
        r21^p * gci_fine / gci_medium,
        s < 0,
    )
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
