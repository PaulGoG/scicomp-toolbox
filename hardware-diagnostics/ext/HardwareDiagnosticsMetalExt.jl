module HardwareDiagnosticsMetalExt

using Metal: Metal, MetalBackend, MtlArray
using HardwareDiagnostics.Backends: Backends, AcceleratorDevice

function __init__()
    Backends.register_backend!(:metal, probe_metal)
    return nothing
end

"""
    probe_metal() -> Union{AcceleratorDevice, Nothing}

Profile the default Metal device when the framework is functional. Metal exposes no
compute-unit count or clock; the unified memory working set stands in for device
memory.
"""
function probe_metal()
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

Backends.to_device(x::AbstractArray, ::MetalBackend) = MtlArray(x)
Backends.backend_label(::MetalBackend) = "Metal"
Backends.vendor_blas_label(::MetalBackend) = "Metal Performance Shaders"
Backends.device_fingerprint(::MetalBackend) =
    Metal.functional() ? sprint(io -> Metal.versioninfo(io)) : ""

end
