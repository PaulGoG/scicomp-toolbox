"""
The benchmark operation D = A·B + A·C on both engines, operand generation, operation
counts and the cross-engine verification.
"""
module Kernels

using KernelAbstractions: KernelAbstractions, @Const, @index, @kernel
using LinearAlgebra: mul!
using Random: AbstractRNG
using ..Backends: to_device

export dual_gemm_kernel!,
    launch_dual_gemm!,
    dual_gemm_blas!,
    nominal_ops,
    matrix_bytes,
    footprint_bytes,
    create_matrix,
    integer_accumulation_bound,
    integer_range_safe,
    verification_tolerance,
    verify_engines,
    INTEGER_ENTRY_RANGE,
    WORKGROUP_SIZE

"""
Value range of integer operand entries; bounds the accumulated sums (see
[`integer_accumulation_bound`](@ref)).
"""
const INTEGER_ENTRY_RANGE = 1:4

"""
Two-dimensional workgroup of the KernelAbstractions kernel.
"""
const WORKGROUP_SIZE = (16, 16)

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
    verify_engines(backend, ::Type{T}, N::Integer, rng::AbstractRNG)
        -> (; max_relative_deviation, tolerance, passed)

Run both engines on the same operands and compare the results on the host:
`max|D_ka − D_blas| / max|D_blas|` against [`verification_tolerance`](@ref).
"""
function verify_engines(
    backend::KernelAbstractions.Backend,
    ::Type{T},
    N::Integer,
    rng::AbstractRNG,
) where {T}
    A = to_device(create_matrix(rng, T, N), backend)
    B = to_device(create_matrix(rng, T, N), backend)
    C = to_device(create_matrix(rng, T, N), backend)
    D_ka = launch_dual_gemm!(backend, similar(A), A, B, C)
    D_blas = dual_gemm_blas!(backend, similar(A), A, B, C)
    deviation = relative_deviation(Array(D_ka), Array(D_blas))
    tolerance = verification_tolerance(T)
    return (;
        max_relative_deviation = deviation,
        tolerance,
        passed = deviation <= tolerance,
    )
end

function relative_deviation(x::AbstractArray, reference::AbstractArray)
    scale = Float64(maximum(abs, reference))
    difference = Float64(maximum(abs, x .- reference))
    return scale == 0 ? difference : difference / scale
end

end
