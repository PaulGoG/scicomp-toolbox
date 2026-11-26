module RunProvenanceCUDAExt

using CUDA: CUDA
using RunProvenance: RunProvenance

"""
    accelerator(::Val{:cuda}) -> Union{Dict{String, Any}, Nothing}

The current CUDA device when the CUDA runtime is functional, with the keys `"backend"`,
`"device"`, `"memory_bytes"`, `"runtime_version"`, `"driver_version"` and
`"versioninfo"`; `nothing` otherwise.
"""
function RunProvenance.accelerator(::Val{:cuda})
    CUDA.functional() || return nothing
    device = CUDA.device()
    return Dict{String, Any}(
        "backend" => "CUDA",
        "device" => CUDA.name(device),
        "memory_bytes" => Int64(CUDA.totalmem(device)),
        "runtime_version" => string(CUDA.runtime_version()),
        "driver_version" => string(CUDA.driver_version()),
        "versioninfo" => sprint(io -> CUDA.versioninfo(io)),
    )
end

end
