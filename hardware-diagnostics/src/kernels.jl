# The benchmark operation D = A·B + A·C on every engine, operand generation, operation
# counts and the cross-engine verification.

"""
Values of the integer operand entries, drawn with equal probability. Unit magnitude bounds
every partial sum of D (see [`integer_accumulation_bound`](@ref)).
"""
const INTEGER_ENTRIES = (-1, 1)

"""
Edge length of the square work-group and of the local-memory tiles.
"""
const TILE = 16

"""
Two-dimensional work-group of the KernelAbstractions kernels.
"""
const WORKGROUP_SIZE = (TILE, TILE)

"""
Engines that can execute the benchmark operation: the BLAS-class library through
`mul!`, the naive KernelAbstractions kernel and the tiled KernelAbstractions kernel.
"""
const ENGINES = (:blas, :ka, :ka_tiled)

"""
The KernelAbstractions engines, verified against the `mul!` reference before a run.
"""
const KERNEL_ENGINES = (:ka, :ka_tiled)

"""
    dual_gemm_kernel!(D, @Const(A), @Const(B), @Const(C))

KernelAbstractions kernel computing `D[i, j] = Σₖ A[i, k]·B[k, j] + Σₖ A[i, k]·C[k, j]`
as two accumulating products, four floating-point (or integer) operations per inner
iteration. The arithmetic is identical to the two `mul!` calls of
[`dual_gemm_blas!`](@ref), so both engines perform the same 4N³ nominal operations.
"""
@kernel function dual_gemm_kernel!(D, @Const(A), @Const(B), @Const(C))
    i, j = @index(Global, NTuple)
    acc = zero(eltype(D))
    @inbounds for k in 1:size(A, 2)
        a = A[i, k]
        acc += a * B[k, j]
        acc += a * C[k, j]
    end
    @inbounds D[i, j] = acc
end

"""
    dual_gemm_tiled_kernel!(D, @Const(A), @Const(B), @Const(C))

Tiled variant of [`dual_gemm_kernel!`](@ref) with the same arithmetic: each work-group
computes a `TILE × TILE` block of D, staging `TILE × TILE` tiles of A, B and C in local
memory and accumulating the two products tile by tile. Operands whose dimension is not
a multiple of `TILE` are zero-padded on load; the launch range is rounded up to whole
tiles and stores are guarded, so every work-item takes part in every barrier.
"""
@kernel function dual_gemm_tiled_kernel!(D, @Const(A), @Const(B), @Const(C))
    gi, gj = @index(Group, NTuple)
    li, lj = @index(Local, NTuple)
    tile_a = @localmem eltype(D) (TILE, TILE)
    tile_b = @localmem eltype(D) (TILE, TILE)
    tile_c = @localmem eltype(D) (TILE, TILE)
    acc = @private eltype(D) 1
    @inbounds acc[1] = zero(eltype(D))
    @uniform N = size(A, 2)
    @uniform n_tiles = cld(N, TILE)
    for t in 0:(n_tiles - 1)
        row = (gi - 1) * TILE + li
        col = (gj - 1) * TILE + lj
        ka = t * TILE + lj
        kb = t * TILE + li
        @inbounds tile_a[li, lj] =
            (row <= size(A, 1) && ka <= N) ? A[row, ka] : zero(eltype(D))
        @inbounds tile_b[li, lj] =
            (kb <= N && col <= size(B, 2)) ? B[kb, col] : zero(eltype(D))
        @inbounds tile_c[li, lj] =
            (kb <= N && col <= size(C, 2)) ? C[kb, col] : zero(eltype(D))
        @synchronize
        partial = zero(eltype(D))
        @inbounds for k in 1:TILE
            a = tile_a[li, k]
            partial += a * tile_b[k, lj]
            partial += a * tile_c[k, lj]
        end
        @inbounds acc[1] += partial
        @synchronize
    end
    row = (gi - 1) * TILE + li
    col = (gj - 1) * TILE + lj
    if row <= size(D, 1) && col <= size(D, 2)
        @inbounds D[row, col] = acc[1]
    end
end

"""
    launch_dual_gemm!(backend, D, A, B, C) -> D

Run [`dual_gemm_kernel!`](@ref) on `backend` over `size(D)` and synchronize.
"""
function launch_dual_gemm!(backend::KernelAbstractions.Backend, D, A, B, C)
    kernel! = dual_gemm_kernel!(backend, WORKGROUP_SIZE)
    kernel!(D, A, B, C; ndrange = size(D))
    KernelAbstractions.synchronize(backend)
    return D
end

"""
    launch_dual_gemm_tiled!(backend, D, A, B, C) -> D

Run [`dual_gemm_tiled_kernel!`](@ref) on `backend` over `size(D)` rounded up to whole
tiles and synchronize.
"""
function launch_dual_gemm_tiled!(backend::KernelAbstractions.Backend, D, A, B, C)
    kernel! = dual_gemm_tiled_kernel!(backend, WORKGROUP_SIZE)
    padded = cld.(size(D), TILE) .* TILE
    kernel!(D, A, B, C; ndrange = padded)
    KernelAbstractions.synchronize(backend)
    return D
end

"""
    dual_gemm_blas!(backend, D, A, B, C) -> D

`D = A·B` followed by `D += A·C` through `LinearAlgebra.mul!` (BLAS-class library or
generic fallback according to the element type), then synchronize `backend`.
"""
function dual_gemm_blas!(backend::KernelAbstractions.Backend, D, A, B, C)
    mul!(D, A, B)
    mul!(D, A, C, true, true)
    KernelAbstractions.synchronize(backend)
    return D
end

"""
    evaluate_engine!(engine::Symbol, backend, D, A, B, C) -> D

Execute the benchmark operation with `engine` (one of [`ENGINES`](@ref)) on `backend`.
"""
function evaluate_engine!(engine::Symbol, backend::KernelAbstractions.Backend, D, A, B, C)
    engine === :blas && return dual_gemm_blas!(backend, D, A, B, C)
    engine === :ka && return launch_dual_gemm!(backend, D, A, B, C)
    engine === :ka_tiled && return launch_dual_gemm_tiled!(backend, D, A, B, C)
    throw(ArgumentError("unknown engine :$engine; expected one of $(join(ENGINES, ", "))"))
end

"""
    nominal_ops(::Type{T}, N::Integer) -> Float64

Nominal operation count of D = A·B + A·C for N × N operands: 4N³ real operations, or
16N³ for complex element types (four real multiply-adds per complex multiply-add).
"""
nominal_ops(::Type{T}, N::Integer) where {T <: Real} = 4.0 * Float64(N)^3
nominal_ops(::Type{T}, N::Integer) where {T <: Complex} = 16.0 * Float64(N)^3

"""
    matrix_bytes(N::Integer, ::Type{T}) -> Int

Bytes of one dense N × N matrix of element type `T`.
"""
matrix_bytes(N::Integer, ::Type{T}) where {T} = Int(N) * Int(N) * sizeof(T)

"""
    footprint_bytes(N::Integer, ::Type{T}) -> Int

Bytes of the four operands A, B, C, D of one benchmark point.
"""
footprint_bytes(N::Integer, ::Type{T}) where {T} = 4 * matrix_bytes(N, T)

"""
    create_matrix(rng::AbstractRNG, ::Type{T}, N::Integer) -> Matrix{T}

N × N host operand: standard normal entries for floating-point and complex types,
entries of [`INTEGER_ENTRIES`](@ref) for integer types.
"""
create_matrix(rng::AbstractRNG, ::Type{T}, N::Integer) where {T <: AbstractFloat} =
    randn(rng, T, N, N)
create_matrix(rng::AbstractRNG, ::Type{Complex{T}}, N::Integer) where {T <: AbstractFloat} =
    randn(rng, Complex{T}, N, N)
create_matrix(rng::AbstractRNG, ::Type{T}, N::Integer) where {T <: Integer} =
    rand(rng, T.(INTEGER_ENTRIES), N, N)

"""
    operand_rng(seed::Integer, ::Type{T}, N::Integer) -> Xoshiro

Generator of the operands of element type `T` and size `N`, derived from the run seed.
Every point of that type and size, on any engine or device, multiplies the same
operands, and they do not depend on which other points the run contains.
"""
operand_rng(seed::Integer, ::Type{T}, N::Integer) where {T} =
    Xoshiro(vcat(UInt64(seed), UInt64(N), UInt64.(codeunits(string(T)))))

"""
    integer_accumulation_bound(N::Integer) -> Int

Largest magnitude a partial sum of an entry of D can reach for operands drawn from
[`INTEGER_ENTRIES`](@ref): 2N products of unit magnitude.
"""
integer_accumulation_bound(N::Integer) = 2 * Int(N)

"""
    integer_range_safe(::Type{T}, N::Integer) -> Bool

Whether the accumulation of the benchmark for size `N` stays within `typemax(T)`.
Always true for non-integer element types.
"""
integer_range_safe(::Type{T}, N::Integer) where {T <: Integer} =
    integer_accumulation_bound(N) <= typemax(T)
integer_range_safe(::Type, N::Integer) = true

"""
    accumulation_roundoff(::Type{T}, N::Integer) -> Float64

m·u for one evaluation of D = A·B + A·C in the precision of `T`: m = 2N + 2 accumulated
terms per entry (2N products and the addition of the two `mul!` results) and the unit
roundoff u = eps/2 of the real type underlying `T`.
"""
accumulation_roundoff(::Type{T}, N::Integer) where {T} =
    (2 * Int(N) + 2) * Float64(eps(real(T))) / 2

"""
    rounding_error_bound(::Type{T}, N::Integer) -> Float64

Coefficient c of the componentwise bound |D̂ − D| ≤ c·|A|(|B| + |C|) on one evaluation of
D = A·B + A·C in precision `T`, in Higham's standard model without underflow: the
inner-product constant γₘ = m·u/(1 − m·u) of [`accumulation_roundoff`](@ref), times √2
for complex types (Higham 2002, §3.1 and §3.6, doi:10.1137/1.9780898718027). The bound
holds for any summation order and with fused multiply-adds. Zero for integers, whose
arithmetic is exact within [`integer_accumulation_bound`](@ref); `ArgumentError` when
m·u ≥ 1, where no bound of this form exists.
"""
function rounding_error_bound(
    ::Type{T},
    N::Integer,
) where {T <: Union{AbstractFloat, Complex}}
    mu = accumulation_roundoff(T, N)
    mu < 1 || throw(
        ArgumentError("no rounding-error bound for $T at N = $N: (2N + 2)·u = $mu ≥ 1"),
    )
    γ = mu / (1 - mu)
    return T <: Complex ? sqrt(2) * γ : γ
end
rounding_error_bound(::Type{T}, N::Integer) where {T <: Integer} = 0.0

"""
    verify_engines(backend, ::Type{T}, N::Integer, rng::AbstractRNG;
                   engines = KERNEL_ENGINES)
        -> Vector{@NamedTuple{engine, bound_ratio, max_relative_deviation, passed}}

Run the `mul!` reference and every kernel engine in `engines` on the same operands and
compare each result with the reference on the host. Each result lies within
c·|A|(|B| + |C|) of the exact D, entry by entry ([`rounding_error_bound`](@ref)), so the
two may differ by at most twice that. `bound_ratio` is the largest
|D_engine − D_blas| / (2c·|A|(|B| + |C|)) over the entries, and an engine passes when it
is at most 1; for integers this is exact equality. `max_relative_deviation`,
max|D_engine − D_blas| / max|D_blas|, is reported alongside.
"""
function verify_engines(
    backend::KernelAbstractions.Backend,
    ::Type{T},
    N::Integer,
    rng::AbstractRNG;
    engines = KERNEL_ENGINES,
) where {T}
    Ah, Bh, Ch = (create_matrix(rng, T, N) for _ in 1:3)
    modulus(X) = Float64.(abs.(X))
    tolerance =
        2 * rounding_error_bound(T, N) .* (modulus(Ah) * (modulus(Bh) .+ modulus(Ch)))
    results = @NamedTuple{
        engine::Symbol,
        bound_ratio::Float64,
        max_relative_deviation::Float64,
        passed::Bool,
    }[]
    allocated = AbstractArray[]
    try
        A, B, C = (track!(allocated, to_device(X, backend)) for X in (Ah, Bh, Ch))
        reference = Array(dual_gemm_blas!(backend, track!(allocated, similar(A)), A, B, C))
        for engine in engines
            engine in KERNEL_ENGINES || throw(
                ArgumentError(
                    "verification applies to the kernel engines $(join(KERNEL_ENGINES, ", ")), got :$engine",
                ),
            )
            D = track!(allocated, similar(A))
            result = Array(evaluate_engine!(engine, backend, D, A, B, C))
            ratio = bound_ratio(result, reference, tolerance)
            push!(
                results,
                (;
                    engine,
                    bound_ratio = ratio,
                    max_relative_deviation = relative_deviation(result, reference),
                    passed = ratio <= 1,
                ),
            )
        end
    finally
        foreach(release_device_array!, allocated)
        reclaim_device_memory!(backend)
    end
    return results
end

widen_entry(x::Real) = Float64(x)
widen_entry(x::Complex) = ComplexF64(x)

"""
    bound_ratio(x, reference, tolerance) -> Float64

Largest |x − reference| / tolerance over the entries, differences taken in double
precision; entries that agree exactly count as 0, and a nonzero difference against a zero
tolerance as `Inf`.
"""
function bound_ratio(x::AbstractArray, reference::AbstractArray, tolerance::AbstractArray)
    ratio = 0.0
    for i in eachindex(x, reference, tolerance)
        difference = abs(widen_entry(x[i]) - widen_entry(reference[i]))
        difference == 0 || (ratio = max(ratio, difference / tolerance[i]))
    end
    return ratio
end

function relative_deviation(x::AbstractArray, reference::AbstractArray)
    scale = maximum(r -> abs(widen_entry(r)), reference)
    difference = maximum(
        i -> abs(widen_entry(x[i]) - widen_entry(reference[i])),
        eachindex(x, reference),
    )
    return scale == 0 ? difference : difference / scale
end
