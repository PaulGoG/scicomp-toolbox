# Compute backends: the host CPU and the accelerators whose probe methods the package
# extensions add when their GPU package is loaded in the session.

"""
Backend identifiers accepted by the configuration, mapped to the package that provides
them.
"""
const ACCELERATOR_PACKAGES = Dict{Symbol, Symbol}(
    :cuda => :CUDA,
    :amdgpu => :AMDGPU,
    :metal => :Metal,
    :oneapi => :oneAPI,
)

"""
Allowed values of the `gpu_backend` setting.
"""
const BACKEND_NAMES = (:none, :auto, :cuda, :amdgpu, :metal, :oneapi)

"""
    AcceleratorDevice{B <: KernelAbstractions.Backend}

Hardware and runtime profile of one functional accelerator, produced by a package
extension probe. `hardware_threads` is the number of concurrently resident hardware
threads (execution units × threads per unit, or multiprocessors × threads per
multiprocessor); `max_alloc_bytes` is the largest single allocation the runtime
permits (0 when unknown).
"""
struct AcceleratorDevice{B <: KernelAbstractions.Backend}
    name::Symbol
    vendor_label::String
    device_name::String
    driver_version::String
    compute_units::Int
    hardware_threads::Int
    core_clock_mhz::Int
    total_memory_bytes::Int
    max_alloc_bytes::Int
    backend::B
    attributes::Dict{String, String}
end

"""
    probe_accelerator(::Val{name}) -> Union{AcceleratorDevice, Nothing}

Profile of the device that backend `name` runs on, or `nothing` when the backend is not
functional. This fallback answers `nothing`; the package extension of each backend adds
the method for its `Val{name}`.
"""
probe_accelerator(::Val) = nothing

"""
    load_accelerator_packages(requested::Symbol) -> Vector{Symbol}

Load the GPU packages that serve `requested` (`:auto` tries every backend applicable to
this operating system) when they are installed in the load path, so that their
extensions attach. Returns the backend names whose package was loaded. A backend that
was requested by name but is not installed produces a warning; a package that fails to
load raises the underlying error.
"""
function load_accelerator_packages(requested::Symbol)
    requested in BACKEND_NAMES || throw(
        ArgumentError("unknown backend :$requested; allowed: $(join(BACKEND_NAMES, ", "))"),
    )
    requested === :none && return Symbol[]
    candidates =
        requested === :auto ? sort(collect(keys(ACCELERATOR_PACKAGES))) : [requested]
    loaded = Symbol[]
    for name in candidates
        applies_to_os(name) || continue
        package = ACCELERATOR_PACKAGES[name]
        if Base.find_package(String(package)) === nothing
            requested === name &&
                @warn "Requested accelerator backend '$name' but $package is not installed in the load path; install it into the default environment with `julia -e 'using Pkg; Pkg.add(\"$package\")'`."
            continue
        end
        Base.require(Main, package)
        push!(loaded, name)
    end
    return loaded
end

"""
    applies_to_os(name::Symbol) -> Bool

Whether the backend can exist on this operating system (Metal on macOS only; the
others on any other system).
"""
applies_to_os(name::Symbol) = name === :metal ? Sys.isapple() : !Sys.isapple()

"""
    discover_accelerators(requested::Symbol) -> Vector{AcceleratorDevice}

Functional accelerators found by [`probe_accelerator`](@ref): every backend for
`:auto`, the named one otherwise, none for `:none`. A backend requested by name that is
unavailable produces a warning saying whether its extension is not loaded or the device
is not functional.
"""
function discover_accelerators(requested::Symbol)
    requested in BACKEND_NAMES || throw(
        ArgumentError("unknown backend :$requested; allowed: $(join(BACKEND_NAMES, ", "))"),
    )
    devices = AcceleratorDevice[]
    requested === :none && return devices
    names = requested === :auto ? sort(collect(keys(ACCELERATOR_PACKAGES))) : [requested]
    for name in names
        device = probe_accelerator(Val(name))
        device === nothing || push!(devices, device)
    end
    if requested !== :auto && isempty(devices)
        extension = Symbol(:HardwareDiagnostics, ACCELERATOR_PACKAGES[requested], :Ext)
        reason =
            Base.get_extension(@__MODULE__, extension) === nothing ?
            "its package extension is not loaded" : "the device is not functional"
        @warn "Requested accelerator backend '$requested' is unavailable: $reason."
    end
    return devices
end

"""
    to_device(x::AbstractArray, backend) -> AbstractArray

Copy of `x` living on `backend`. The CPU method returns `x` itself for `Array` input;
package extensions add the device array constructors.
"""
to_device(x::Array, ::CPU) = x
to_device(x::AbstractArray, ::CPU) = Array(x)

"""
    reclaim_device_memory!(backend)

Return cached allocations to the driver between benchmark points. The default runs a
host garbage collection; extensions add the device pool reclaim where the runtime has
one.
"""
function reclaim_device_memory!(::KernelAbstractions.Backend)
    GC.gc(false)
    return nothing
end

"""
    release_device_array!(x::AbstractArray)

Free the device memory of `x` now instead of at its finalizer, so that a point that
fails part-way does not leave its operands allocated. A no-op for host arrays;
extensions add the method of their array type.
"""
release_device_array!(::AbstractArray) = nothing

"""
    track!(allocated::Vector, x) -> x

Record `x` in `allocated` for a later [`release_device_array!`](@ref) and return it.
"""
track!(allocated::Vector, x) = (push!(allocated, x); x)

"""
    device_fingerprint(backend) -> String

Driver, runtime and device inventory as reported by the GPU package's `versioninfo`,
for the provenance sidecar. Empty for the CPU.
"""
device_fingerprint(::KernelAbstractions.Backend) = ""

"""
    backend_label(backend) -> String

Short backend name used in tables and datasets (`"CPU"`, `"oneAPI"`, `"CUDA"`, ...).
"""
backend_label(::CPU) = "CPU"
backend_label(b::KernelAbstractions.Backend) = string(nameof(typeof(b)))

"""
    blas_library_label() -> String

Vendor of the BLAS library loaded through libblastrampoline and its integer interface,
e.g. `"OpenBLAS (ILP64)"`.
"""
function blas_library_label()
    libraries = BLAS.get_config().loaded_libs
    isempty(libraries) && return "unknown"
    library = first(libraries)
    return string(
        blas_vendor(basename(library.libname)),
        " (",
        uppercase(string(library.interface)),
        ")",
    )
end

function blas_vendor(libname::AbstractString)
    lower = lowercase(libname)
    occursin("openblas", lower) && return "OpenBLAS"
    occursin("mkl", lower) && return "MKL"
    occursin("blis", lower) && return "BLIS"
    occursin("accelerate", lower) && return "Apple Accelerate"
    return String(libname)
end

"""
    vendor_blas_label(backend) -> String

Name of the linear algebra library that `mul!` reaches on `backend` for the element
types it supports.
"""
vendor_blas_label(::CPU) = blas_library_label()

"""
Element types for which `mul!` reaches the BLAS-class library on the host and on the
accelerators whose vendor library follows the BLAS type set; the remaining types run
through the generic fallbacks of LinearAlgebra (host) or GPUArrays (device).
"""
const BLAS_ELEMENT_TYPES = (Float32, Float64, ComplexF32, ComplexF64)

"""
    vendor_blas_types(backend) -> Tuple

Element types whose `mul!` reaches the vendor library of `backend`;
`BLAS_ELEMENT_TYPES` by default. Extensions whose library covers a different set
override it (Metal).
"""
vendor_blas_types(::KernelAbstractions.Backend) = BLAS_ELEMENT_TYPES

"""
    library_label(engine::Symbol, backend, ::Type{T}) -> String

Library that executes the benchmark point: the KernelAbstractions kernel, the vendor
library, or the generic fallback for element types the library does not cover.
"""
function library_label(
    engine::Symbol,
    backend::KernelAbstractions.Backend,
    ::Type{T},
) where {T}
    engine === :ka && return "KernelAbstractions naive"
    engine === :ka_tiled && return "KernelAbstractions tiled"
    T in vendor_blas_types(backend) && return vendor_blas_label(backend)
    return backend isa CPU ? "LinearAlgebra generic" : "GPUArrays generic"
end
