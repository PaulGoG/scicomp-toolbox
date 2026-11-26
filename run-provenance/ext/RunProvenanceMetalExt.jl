module RunProvenanceMetalExt

using Metal: Metal
using RunProvenance: RunProvenance

"""
    accelerator(::Val{:metal}) -> Union{Dict{String, Any}, Nothing}

The default Metal device when the framework is functional, with the keys `"backend"`,
`"device"`, `"memory_bytes"` (the recommended working set of the unified memory) and
`"versioninfo"`; `nothing` otherwise. Metal reports no runtime version.
"""
function RunProvenance.accelerator(::Val{:metal})
    Metal.functional() || return nothing
    device = Metal.device()
    return Dict{String, Any}(
        "backend" => "Metal",
        "device" => String(device.name),
        "memory_bytes" => Int64(device.recommendedMaxWorkingSetSize),
        "versioninfo" => sprint(io -> Metal.versioninfo(io)),
    )
end

end
