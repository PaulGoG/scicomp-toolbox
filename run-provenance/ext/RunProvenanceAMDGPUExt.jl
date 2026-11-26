module RunProvenanceAMDGPUExt

using AMDGPU: AMDGPU
using RunProvenance: RunProvenance

"""
    accelerator(::Val{:amdgpu}) -> Union{Dict{String, Any}, Nothing}

The current HIP device when the ROCm runtime is functional, with the keys `"backend"`,
`"device"`, `"memory_bytes"`, `"runtime_version"` and `"versioninfo"`; `nothing`
otherwise.
"""
function RunProvenance.accelerator(::Val{:amdgpu})
    AMDGPU.functional() || return nothing
    device = AMDGPU.device()
    return Dict{String, Any}(
        "backend" => "AMDGPU",
        "device" => String(AMDGPU.HIP.name(device)),
        "memory_bytes" => Int(AMDGPU.HIP.properties(device).totalGlobalMem),
        "runtime_version" => string(AMDGPU.HIP.runtime_version()),
        "versioninfo" => sprint(io -> AMDGPU.versioninfo(io)),
    )
end

end
