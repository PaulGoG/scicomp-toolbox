# Discrete error norms of a numerical solution against a reference, accumulated in at
# least double precision without a temporary of the solution's size.

const NORMS = (:L1, :L2, :Linf, :relative)

function check_norm(norm::Symbol)
    norm in NORMS || throw(
        ArgumentError("unknown norm :$norm; one of: $(join((":$n" for n in NORMS), ", "))"),
    )
    return nothing
end

"`x` in double precision, or in its own precision when that is higher."
widened(x::Real) = convert(promote_type(typeof(x), Float64), x)
widened(x::Complex) = convert(promote_type(typeof(x), ComplexF64), x)

"Magnitude of the difference of two entries, formed in at least double precision."
deviation(a::Number, b::Number) = abs(widened(a) - widened(b))

"""
    error_norm(u::AbstractArray, u_ref::AbstractArray, norm::Symbol = :L2;
               measure::Real = 1) -> Float64
    error_norm(u::Number, u_ref::Number, norm::Symbol = :L2; measure::Real = 1) -> Float64

Discrete norm of the error `u - u_ref`, for arrays of equal size or for two numbers.
With the positive cell measure μ = `measure` (h in one dimension, h² in two), `:L1` is
μ Σ |uᵢ - u_refᵢ|, `:L2` is (μ Σ |uᵢ - u_refᵢ|²)^(1/2) and `:Linf` is max |uᵢ - u_refᵢ|;
`:relative` is ‖u - u_ref‖₂ / ‖u_ref‖₂ with plain Euclidean norms, in which μ cancels.
Entries narrower than `Float64` (`ComplexF64` for complex entries) are widened to it
before the difference is formed; `BigFloat` and other wider entries keep their precision
until the norm is returned.

For two numbers every norm except `:relative` reduces to |u - u_ref|, `:relative` to
|u - u_ref| / |u_ref|; `measure` is accepted and ignored.

Returns the norm as a `Float64`. Throws `DimensionMismatch` for arrays of different
size and `ArgumentError` for an unknown norm, a measure that is not positive and finite
or a vanishing reference under `:relative`.

# Example
```julia
x = range(0, 1; length = 101)
error_norm(sin.(x) .+ 1e-3, sin.(x), :L2; measure = step(x))
```
"""
function error_norm(
    u::AbstractArray,
    u_ref::AbstractArray,
    norm::Symbol = :L2;
    measure::Real = 1,
)
    check_norm(norm)
    size(u) == size(u_ref) ||
        throw(DimensionMismatch("u has size $(size(u)), u_ref has size $(size(u_ref))"))
    (isfinite(measure) && measure > 0) ||
        throw(ArgumentError("the cell measure must be positive and finite, got $measure"))
    μ = Float64(measure)
    if norm === :L1
        return Float64(μ * sum((deviation(a, b) for (a, b) in zip(u, u_ref)); init = 0.0))
    elseif norm === :L2
        return Float64(
            sqrt(μ * sum((deviation(a, b)^2 for (a, b) in zip(u, u_ref)); init = 0.0)),
        )
    elseif norm === :Linf
        return Float64(maximum((deviation(a, b) for (a, b) in zip(u, u_ref)); init = 0.0))
    end
    reference = sqrt(sum((abs(widened(b))^2 for b in u_ref); init = 0.0))
    reference == 0 &&
        throw(ArgumentError("the reference vanishes; the relative error norm is undefined"))
    return Float64(
        sqrt(sum((deviation(a, b)^2 for (a, b) in zip(u, u_ref)); init = 0.0)) / reference,
    )
end

function error_norm(u::Number, u_ref::Number, norm::Symbol = :L2; measure::Real = 1)
    check_norm(norm)
    difference = deviation(u, u_ref)
    norm === :relative || return Float64(difference)
    u_ref == 0 &&
        throw(ArgumentError("the reference vanishes; the relative error norm is undefined"))
    return Float64(difference / abs(widened(u_ref)))
end
