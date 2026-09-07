"""
The benchmark operation D = A·B + A·C on every engine, operand generation, operation
counts and the cross-engine verification.
"""
module Kernels

using KernelAbstractions:
    KernelAbstractions, @Const, @index, @kernel, @localmem, @private, @synchronize, @uniform
using LinearAlgebra: mul!
using Random: AbstractRNG
using ..Backends: to_device

export dual_gemm_kernel!,
    dual_gemm_tiled_kernel!,
    launch_dual_gemm!,
    launch_dual_gemm_tiled!,
    dual_gemm_blas!,
    evaluate_engine!,
    nominal_ops,
    matrix_bytes,
    footprint_bytes,
    create_matrix,
    integer_accumulation_bound,
    integer_range_safe,
    verification_tolerance,
    verify_engines,
    INTEGER_ENTRY_RANGE,
    WORKGROUP_SIZE,
    TILE,
    ENGINES,
    KERNEL_ENGINES

"""
Value range of integer operand entries; bounds the accumulated sums (see
[`integer_accumulation_bound`](@ref)).
"""
const INTEGER_ENTRY_RANGE = 1:4

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
uniform integers in [`INTEGER_ENTRY_RANGE`](@ref) for integer types.
"""
create_matrix(rng::AbstractRNG, ::Type{T}, N::Integer) where {T <: AbstractFloat} =
    randn(rng, T, N, N)
create_matrix(rng::AbstractRNG, ::Type{Complex{T}}, N::Integer) where {T <: AbstractFloat} =
    randn(rng, Complex{T}, N, N)
create_matrix(rng::AbstractRNG, ::Type{T}, N::Integer) where {T <: Integer} =
    rand(rng, T(first(INTEGER_ENTRY_RANGE)):T(last(INTEGER_ENTRY_RANGE)), N, N)

"""
    integer_accumulation_bound(N::Integer) -> Int

Largest value an entry of D can reach for integer operands drawn from
[`INTEGER_ENTRY_RANGE`](@ref): two products of at most `last(range)²` summed over N.
"""
integer_accumulation_bound(N::Integer) = 2 * last(INTEGER_ENTRY_RANGE)^2 * Int(N)

"""
    integer_range_safe(::Type{T}, N::Integer) -> Bool

Whether the accumulation of the benchmark for size `N` stays within `typemax(T)`.
Always true for non-integer element types.
"""
integer_range_safe(::Type{T}, N::Integer) where {T <: Integer} =
    integer_accumulation_bound(N) <= typemax(T)
integer_range_safe(::Type, N::Integer) = true

"""
    verification_tolerance(::Type{T}) -> Float64

Relative tolerance of the cross-engine comparison: `8·√eps(T)` for floating-point and
complex types (summation-order differences), exact equality for integers.
"""
verification_tolerance(::Type{T}) where {T <: AbstractFloat} = 8 * sqrt(Float64(eps(T)))
verification_tolerance(::Type{Complex{T}}) where {T <: AbstractFloat} =
    8 * sqrt(Float64(eps(T)))
verification_tolerance(::Type{T}) where {T <: Integer} = 0.0

"""
    verify_engines(backend, ::Type{T}, N::Integer, rng::AbstractRNG;
                   engines = KERNEL_ENGINES)
        -> Vector{@NamedTuple{engine, max_relative_deviation, tolerance, passed}}

Run the `mul!` reference and every kernel engine in `engines` on the same operands and
compare each result with the reference on the host:
`max|D_engine − D_blas| / max|D_blas|` against [`verification_tolerance`](@ref).
"""
function verify_engines(
    backend::KernelAbstractions.Backend,
    ::Type{T},
    N::Integer,
    rng::AbstractRNG;
    engines = KERNEL_ENGINES,
) where {T}
    A = to_device(create_matrix(rng, T, N), backend)
    B = to_device(create_matrix(rng, T, N), backend)
    C = to_device(create_matrix(rng, T, N), backend)
    reference = Array(dual_gemm_blas!(backend, similar(A), A, B, C))
    tolerance = verification_tolerance(T)
    results = @NamedTuple{
        engine::Symbol,
        max_relative_deviation::Float64,
        tolerance::Float64,
        passed::Bool,
    }[]
    for engine in engines
        engine in KERNEL_ENGINES || throw(
            ArgumentError(
                "verification applies to the kernel engines $(join(KERNEL_ENGINES, ", ")), got :$engine",
            ),
        )
        result = Array(evaluate_engine!(engine, backend, similar(A), A, B, C))
        deviation = relative_deviation(result, reference)
        push!(
            results,
            (;
                engine,
                max_relative_deviation = deviation,
                tolerance,
                passed = deviation <= tolerance,
            ),
        )
    end
    return results
end

function relative_deviation(x::AbstractArray, reference::AbstractArray)
    scale = Float64(maximum(abs, reference))
    difference = Float64(maximum(abs, x .- reference))
    return scale == 0 ? difference : difference / scale
end

end
