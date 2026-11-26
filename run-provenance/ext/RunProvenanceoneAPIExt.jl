module RunProvenanceoneAPIExt

using oneAPI: oneAPI
using RunProvenance: RunProvenance

"""
    accelerator(::Val{:oneapi}) -> Union{Dict{String, Any}, Nothing}

The default Level Zero device when the oneAPI runtime is functional, with the keys
`"backend"`, `"device"`, `"memory_bytes"`, `"runtime_version"` (the driver version) and
`"versioninfo"`; `nothing` otherwise.
"""
function RunProvenance.accelerator(::Val{:oneapi})
    oneAPI.functional() || return nothing
    device = oneAPI.device()
    properties = oneAPI.oneL0.properties(device)
    memory = oneAPI.oneL0.memory_properties(device)
    driver = oneAPI.oneL0.properties(oneAPI.driver())
    return Dict{String, Any}(
        "backend" => "oneAPI",
        "device" => String(strip(String(properties.name))),
        "memory_bytes" => isempty(memory) ? 0 : Int(memory[1].totalSize),
        "runtime_version" => string(driver.driverVersion),
        "versioninfo" => sprint(io -> oneAPI.versioninfo(io)),
    )
end

end
