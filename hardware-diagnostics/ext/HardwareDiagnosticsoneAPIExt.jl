module HardwareDiagnosticsoneAPIExt

using oneAPI: oneAPI, oneAPIBackend, oneArray
using HardwareDiagnostics: HardwareDiagnostics, AcceleratorDevice

"""
    probe_accelerator(::Val{:oneapi}) -> Union{AcceleratorDevice, Nothing}

Profile the default Level Zero device when the oneAPI runtime is functional.
"""
function HardwareDiagnostics.probe_accelerator(::Val{:oneapi})
    oneAPI.functional() || return nothing
    device = oneAPI.device()
    properties = oneAPI.oneL0.properties(device)
    memory = oneAPI.oneL0.memory_properties(device)
    driver = oneAPI.oneL0.properties(oneAPI.driver())
    execution_units =
        Int(properties.numSlices) *
        Int(properties.numSubslicesPerSlice) *
        Int(properties.numEUsPerSubslice)
    attributes = Dict{String, String}(
        "simd_width" => string(properties.physicalEUSimdWidth),
        "threads_per_eu" => string(properties.numThreadsPerEU),
        "device_id" => "0x" * string(Int(properties.deviceId); base = 16, pad = 4),
        "vendor_id" => "0x" * string(Int(properties.vendorId); base = 16, pad = 4),
        "timer_resolution_ns" => string(properties.timerResolution),
    )
    return AcceleratorDevice(
        :oneapi,
        "Intel oneAPI (Level Zero)",
        String(strip(String(properties.name))),
        string(driver.driverVersion),
        execution_units,
        execution_units * Int(properties.numThreadsPerEU),
        Int(properties.coreClockRate),
        isempty(memory) ? 0 : Int(memory[1].totalSize),
        Int(properties.maxMemAllocSize),
        oneAPIBackend(),
        attributes,
    )
end

HardwareDiagnostics.to_device(x::AbstractArray, ::oneAPIBackend) = oneArray(x)
HardwareDiagnostics.backend_label(::oneAPIBackend) = "oneAPI"
HardwareDiagnostics.vendor_blas_label(::oneAPIBackend) = "oneMKL"
HardwareDiagnostics.device_fingerprint(::oneAPIBackend) =
    oneAPI.functional() ? sprint(io -> oneAPI.versioninfo(io)) : ""

end
