"""
Compute-backend registry: the host CPU backend plus the accelerator probes registered
by the package extensions when their GPU package is loaded in the session.
"""
module Backends

using KernelAbstractions: KernelAbstractions, CPU
using LinearAlgebra: BLAS

export AcceleratorDevice,
    register_backend!,
    discover_accelerators,
    load_accelerator_packages,
    to_device,
    reclaim_device_memory!,
    device_fingerprint,
    backend_label,
    vendor_blas_label,
    vendor_blas_types,
    library_label,
    blas_library_label,
    ACCELERATOR_PACKAGES,
    BACKEND_NAMES

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
Registry of accelerator probes, populated by the extensions' `__init__`. Each probe is
a zero-argument function returning an [`AcceleratorDevice`](@ref) or `nothing`.
"""
const BACKEND_PROBES = Vector{Pair{Symbol, Function}}()

"""
    register_backend!(name::Symbol, probe::Function)

Register an accelerator probe under `name`. Called from the package extensions.
"""
function register_backend!(name::Symbol, probe::Function)
    any(p -> first(p) === name, BACKEND_PROBES) || push!(BACKEND_PROBES, name => probe)
    return nothing
end

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

Functional accelerators among the registered probes: all of them for `:auto`, the
named one otherwise, none for `:none`. A backend requested by name that is not
functional produces a warning.
"""
function discover_accelerators(requested::Symbol)
    requested in BACKEND_NAMES || throw(
        ArgumentError("unknown backend :$requested; allowed: $(join(BACKEND_NAMES, ", "))"),
    )
    devices = AcceleratorDevice[]
    requested === :none && return devices
    for (name, probe) in BACKEND_PROBES
        (requested === :auto || requested === name) || continue
        device = probe()
        device === nothing || push!(devices, device)
    end
    if requested !== :auto && isempty(devices)
        @warn "Requested accelerator backend '$requested' is not functional or its package extension is not active." registered_probes =
            first.(BACKEND_PROBES)
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

Element types whose `mul!` reaches the vendor library of `backend`. The coverage is a
property of the backend, not of the element type: Metal carries no `Float64` at all and
routes `Float16` through Apple's own GEMM, so a backend whose library departs from
[`BLAS_ELEMENT_TYPES`](@ref) overrides this method in its extension.
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

end
