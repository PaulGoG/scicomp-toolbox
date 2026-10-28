module HardwareDiagnosticsMetalExt

using Metal: Metal, MetalBackend, MtlArray
using HardwareDiagnostics: HardwareDiagnostics, AcceleratorDevice

"""
    probe_accelerator(::Val{:metal}) -> Union{AcceleratorDevice, Nothing}

Profile the default Metal device when the framework is functional. Metal exposes no
compute-unit count or clock; the unified memory working set stands in for device
memory.
"""
function HardwareDiagnostics.probe_accelerator(::Val{:metal})
    Metal.functional() || return nothing
    device = Metal.device()
    attributes = Dict{String, String}("unified_memory" => string(device.hasUnifiedMemory))
    return AcceleratorDevice(
        :metal,
        "Apple Metal",
        String(device.name),
        "Metal",
        0,
        0,
        0,
        Int(device.recommendedMaxWorkingSetSize),
        Int(device.maxBufferLength),
        MetalBackend(),
        attributes,
    )
end

HardwareDiagnostics.to_device(x::AbstractArray, ::MetalBackend) = MtlArray(x)
HardwareDiagnostics.release_device_array!(x::MtlArray) = Metal.unsafe_free!(x)
HardwareDiagnostics.backend_label(::MetalBackend) = "Metal"
HardwareDiagnostics.vendor_blas_label(::MetalBackend) = "Metal Performance Shaders"

"""
Element types that Metal.jl's `mul!` routes to MPS or MPSGraph (`MPS_VALID_MATMUL_TYPES`,
`MPSGRAPH_VALID_MATMUL_TYPES`): Float16, Float32, ComplexF32. Metal has no Float64; such
points fail.
"""
HardwareDiagnostics.vendor_blas_types(::MetalBackend) = (Float16, Float32, ComplexF32)
HardwareDiagnostics.device_fingerprint(::MetalBackend) =
    Metal.functional() ? sprint(io -> Metal.versioninfo(io)) : ""

end
