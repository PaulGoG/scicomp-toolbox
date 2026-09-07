module HardwareDiagnosticsCUDAExt

using CUDA: CUDA, CUDABackend, CuArray
using HardwareDiagnostics.Backends: Backends, AcceleratorDevice

function __init__()
    Backends.register_backend!(:cuda, probe_cuda)
    return nothing
end

"""
    probe_cuda() -> Union{AcceleratorDevice, Nothing}

Profile the current CUDA device when the CUDA runtime is functional.
"""
function probe_cuda()
    CUDA.functional() || return nothing
    device = CUDA.device()
    multiprocessors =
        Int(CUDA.attribute(device, CUDA.DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT))
    threads_per_multiprocessor =
        Int(CUDA.attribute(device, CUDA.DEVICE_ATTRIBUTE_MAX_THREADS_PER_MULTIPROCESSOR))
    clock_khz = Int(CUDA.attribute(device, CUDA.DEVICE_ATTRIBUTE_CLOCK_RATE))
    memory = Int(CUDA.totalmem(device))
    attributes = Dict{String, String}(
        "compute_capability" => string(CUDA.capability(device)),
        "runtime_version" => string(CUDA.runtime_version()),
        "max_threads_per_block" =>
            string(CUDA.attribute(device, CUDA.DEVICE_ATTRIBUTE_MAX_THREADS_PER_BLOCK)),
    )
    return AcceleratorDevice(
        :cuda,
        "NVIDIA CUDA",
        CUDA.name(device),
        string(CUDA.driver_version()),
        multiprocessors,
        multiprocessors * threads_per_multiprocessor,
        clock_khz ÷ 1000,
        memory,
        memory,
        CUDABackend(),
        attributes,
    )
end

Backends.to_device(x::AbstractArray, ::CUDABackend) = CuArray(x)
Backends.backend_label(::CUDABackend) = "CUDA"
Backends.vendor_blas_label(::CUDABackend) = "cuBLAS"
function Backends.reclaim_device_memory!(::CUDABackend)
    GC.gc(false)
    CUDA.reclaim()
    return nothing
end
Backends.device_fingerprint(::CUDABackend) =
    CUDA.functional() ? sprint(io -> CUDA.versioninfo(io)) : ""

end
