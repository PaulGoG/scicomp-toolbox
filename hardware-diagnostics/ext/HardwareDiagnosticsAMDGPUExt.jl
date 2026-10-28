module HardwareDiagnosticsAMDGPUExt

using AMDGPU: AMDGPU, ROCBackend, ROCArray
using HardwareDiagnostics: HardwareDiagnostics, AcceleratorDevice

"""
    probe_accelerator(::Val{:amdgpu}) -> Union{AcceleratorDevice, Nothing}

Profile the current HIP device when the ROCm runtime is functional.
"""
function HardwareDiagnostics.probe_accelerator(::Val{:amdgpu})
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

HardwareDiagnostics.to_device(x::AbstractArray, ::ROCBackend) = ROCArray(x)
HardwareDiagnostics.backend_label(::ROCBackend) = "AMDGPU"
HardwareDiagnostics.vendor_blas_label(::ROCBackend) = "rocBLAS"
HardwareDiagnostics.device_fingerprint(::ROCBackend) =
    AMDGPU.functional() ? sprint(io -> AMDGPU.versioninfo(io)) : ""

end
