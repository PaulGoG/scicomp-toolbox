module HardwareDiagnosticsAMDGPUExt

using AMDGPU: AMDGPU, ROCBackend, ROCArray
using HardwareDiagnostics.Backends: Backends, AcceleratorDevice

function __init__()
    Backends.register_backend!(:amdgpu, probe_amdgpu)
    return nothing
end

"""
    probe_amdgpu() -> Union{AcceleratorDevice, Nothing}

Profile the current HIP device when the ROCm runtime is functional.
"""
function probe_amdgpu()
    AMDGPU.functional() || return nothing
    device = AMDGPU.device()
    properties = AMDGPU.HIP.properties(device)
    compute_units = Int(properties.multiProcessorCount)
    memory = Int(properties.totalGlobalMem)
    attributes = Dict{String, String}(
        "architecture" => String(AMDGPU.HIP.gcn_arch(device)),
        "wavefront_size" => string(AMDGPU.HIP.wavefrontsize(device)),
    )
    return AcceleratorDevice(
        :amdgpu,
        "AMD ROCm (HIP)",
        String(AMDGPU.HIP.name(device)),
        string(AMDGPU.HIP.runtime_version()),
        compute_units,
        compute_units * Int(properties.maxThreadsPerMultiProcessor),
        Int(properties.clockRate) ÷ 1000,
        memory,
        memory,
        ROCBackend(),
        attributes,
    )
end

Backends.to_device(x::AbstractArray, ::ROCBackend) = ROCArray(x)
Backends.backend_label(::ROCBackend) = "AMDGPU"
Backends.vendor_blas_label(::ROCBackend) = "rocBLAS"
Backends.device_fingerprint(::ROCBackend) =
    AMDGPU.functional() ? sprint(io -> AMDGPU.versioninfo(io)) : ""

end
