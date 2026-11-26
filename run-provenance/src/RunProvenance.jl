"""
    RunProvenance

Platform, environment, source and input provenance of a run as one flat
`Dict{String, Any}`: host and CPU, Julia and BLAS configuration, the project and its
manifest, the git commit of the source, SHA-256 digests of the inputs and the active
GPU devices. The record prints as TOML and merges into a DrWatson result dictionary.
"""
module RunProvenance

using Dates: Dates, @dateformat_str
using Distributed: Distributed
using InteractiveUtils: InteractiveUtils
using LibGit2: LibGit2
using LinearAlgebra: LinearAlgebra
using SHA: SHA
using TOML: TOML

export provenance, write_provenance, snapshot_manifest

"""
    sha256_hex(path::AbstractString) -> String

Lower-case hexadecimal SHA-256 digest of the file at `path`, read as a stream so that a
large file is not held in memory.
"""
sha256_hex(path::AbstractString) = bytes2hex(open(SHA.sha256, path))

"""
    host_record() -> Dict{String, Any}

The machine the run executes on, with the keys `"hostname"`, `"os"`, `"arch"`,
`"machine"`, `"cpu_model"` (left out when the CPU cannot be queried), `"cpu_threads"`
(logical cores) and `"total_memory_bytes"`.
"""
function host_record()
    record = Dict{String, Any}(
        "hostname" => gethostname(),
        "os" => string(Sys.KERNEL),
        "arch" => string(Sys.ARCH),
        "machine" => Sys.MACHINE,
        "cpu_threads" => Sys.CPU_THREADS,
        "total_memory_bytes" => Int(Sys.total_memory()),
    )
    cpus = Sys.cpu_info()
    isempty(cpus) || (record["cpu_model"] = String(strip(cpus[1].model)))
    return record
end

"""
    julia_record() -> Dict{String, Any}

The Julia session, with the keys `"julia_version"`, `"julia_commit"` (short hash of the
Julia build), `"julia_threads"` and `"julia_interactive_threads"` (threads of the
default and interactive pools), `"distributed_workers"` (worker processes besides the
master), `"blas_threads"`, `"blas_libraries"` (base names of the libraries loaded into
libblastrampoline) and `"versioninfo"` (the text of `InteractiveUtils.versioninfo`).
"""
function julia_record()
    libraries = LinearAlgebra.BLAS.get_config().loaded_libs
    return Dict{String, Any}(
        "julia_version" => string(VERSION),
        "julia_commit" => Base.GIT_VERSION_INFO.commit_short,
        "julia_threads" => Threads.nthreads(:default),
        "julia_interactive_threads" => Threads.nthreads(:interactive),
        "distributed_workers" => Distributed.nprocs() - 1,
        "blas_threads" => LinearAlgebra.BLAS.get_num_threads(),
        "blas_libraries" => String[basename(library.libname) for library in libraries],
        "versioninfo" => sprint(InteractiveUtils.versioninfo),
    )
end

"""
    active_project() -> String

Project file of the active environment. Throws `ArgumentError` when Julia has none, as
under `JULIA_LOAD_PATH` without a project entry.
"""
function active_project()
    project = Base.active_project()
    project === nothing &&
        throw(ArgumentError("no active project; pass the keyword `project`"))
    return project
end

"""
    project_file(project::AbstractString) -> String

The project file named by `project`: `project` itself when it is a file, or the first
existing of `JuliaProject.toml` and `Project.toml` in it when it is a directory. Throws
`ArgumentError` when `project` does not exist or the directory holds neither file.
"""
function project_file(project::AbstractString)
    isfile(project) && return String(project)
    if isdir(project)
        for name in ("JuliaProject.toml", "Project.toml")
            candidate = joinpath(project, name)
            isfile(candidate) && return candidate
        end
        throw(ArgumentError("no JuliaProject.toml or Project.toml in $project"))
    end
    throw(ArgumentError("project not found: $project"))
end

"""
    default_root(project::AbstractString) -> String

The default root of the relative paths of a record: `project` itself when it is a
directory, the directory of the project file otherwise.
"""
function default_root(project::AbstractString)
    return isdir(project) ? String(project) : String(dirname(project))
end

"""
    manifest_path(project::AbstractString) -> Union{String, Nothing}

The manifest that Julia resolves for the project file `project`, through
`Base.project_file_manifest_path` where it is defined and otherwise as the first existing
of `JuliaManifest-v<major>.<minor>.toml`, `Manifest-v<major>.<minor>.toml`,
`JuliaManifest.toml` and `Manifest.toml` beside the project file. Returns `nothing` when
there is none or it is not an existing file.
"""
function manifest_path(project::AbstractString)
    if isdefined(Base, :project_file_manifest_path)
        path = Base.project_file_manifest_path(String(project))
    else
        directory = dirname(abspath(project))
        version = "v$(VERSION.major).$(VERSION.minor)"
        path = nothing
        for name in (
            "JuliaManifest-$version.toml",
            "Manifest-$version.toml",
            "JuliaManifest.toml",
            "Manifest.toml",
        )
            candidate = joinpath(directory, name)
            if isfile(candidate)
                path = candidate
                break
            end
        end
    end
    (path === nothing || !isfile(path)) && return nothing
    return String(path)
end

"""
    environment_record(project::AbstractString; root::AbstractString = dirname(project))
        -> Dict{String, Any}

The Julia environment of the run. `project` is a project file or a directory holding
`JuliaProject.toml` or `Project.toml`; when it is a directory, `root` defaults to it.
Keys: `"project_file"`, the project file relative to `root`, and, when the project has a
manifest, `"manifest_file"` (relative to `root`) and `"manifest_sha256"`. Throws
`ArgumentError` when the project file cannot be found.
"""
function environment_record(
    project::AbstractString;
    root::AbstractString = default_root(project),
)
    file = project_file(project)
    base = abspath(root)
    record = Dict{String, Any}("project_file" => relpath(abspath(file), base))
    manifest = manifest_path(file)
    if manifest !== nothing
        record["manifest_file"] = relpath(abspath(manifest), base)
        record["manifest_sha256"] = sha256_hex(manifest)
    end
    return record
end

"""
    git_record(root::AbstractString) -> Dict{String, Any}

The source revision of the repository that holds `root`, searched upwards from `root`
as DrWatson does. Key `"gitcommit"`: the hash of HEAD, followed by `-dirty` when tracked
files differ from it (untracked files do not count). Empty when `root` is in no
repository or the repository has no commit.
"""
function git_record(root::AbstractString)
    repo = try
        LibGit2.GitRepoExt(root)
    catch err
        err isa LibGit2.GitError || rethrow()
        return Dict{String, Any}()
    end
    try
        commit = try
            string(LibGit2.head_oid(repo))
        catch err
            err isa LibGit2.GitError || rethrow()
            return Dict{String, Any}()
        end
        LibGit2.isdirty(repo) && (commit *= "-dirty")
        return Dict{String, Any}("gitcommit" => commit)
    finally
        close(repo)
    end
end

"""
    input_record(path::AbstractString; root::AbstractString) -> Dict{String, Any}

An external input of the run, with the keys `"path"` (relative to `root`, with `/` as
separator on every platform), `"bytes"` and `"sha256"`. Throws `ArgumentError` naming
`path` when it is not an existing file.
"""
function input_record(path::AbstractString; root::AbstractString)
    isfile(path) || throw(ArgumentError("input file not found: $path"))
    relative = relpath(abspath(path), abspath(root))
    return Dict{String, Any}(
        "path" => replace(relative, Base.Filesystem.path_separator => "/"),
        "bytes" => filesize(path),
        "sha256" => sha256_hex(path),
    )
end

"""
    accelerator(::Val) -> Nothing

Record of the active device of a GPU backend. This fallback returns `nothing`; the
package extensions add the methods for `Val(:cuda)`, `Val(:amdgpu)`, `Val(:oneapi)` and
`Val(:metal)`, which return a `Dict{String, Any}` with the keys `"backend"`, `"device"`,
`"memory_bytes"`, `"runtime_version"` (not for Metal), `"versioninfo"` and, for CUDA,
`"driver_version"`, or `nothing` when the backend is not functional.
"""
accelerator(::Val) = nothing

"""
    accelerator_records() -> Vector{Dict{String, Any}}

The records of the functional GPU backends whose packages are loaded, in the order
CUDA, AMDGPU, oneAPI, Metal; see [`accelerator`](@ref).
"""
function accelerator_records()
    records = Dict{String, Any}[]
    for name in (:cuda, :amdgpu, :oneapi, :metal)
        record = accelerator(Val(name))
        record === nothing || push!(records, record)
    end
    return records
end

"""
    provenance(; project::AbstractString = active_project(),
               root::AbstractString = dirname(project), inputs = String[],
               git::Bool = true) -> Dict{String, Any}

The provenance of a run as one flat record: the keys of [`host_record`](@ref),
[`julia_record`](@ref), [`environment_record`](@ref) and [`git_record`](@ref), together
with `"timestamp_utc"` (ISO 8601, seconds, `Z` suffix), `"inputs"`, one
[`input_record`](@ref) per path of the iterable `inputs`, and `"accelerators"`, the
result of [`accelerator_records`](@ref). Both vectors are present also when empty.
`project` is a project file or a directory; when it is a directory, `root` defaults to
it. Relative paths of the record are relative to `root`. With `git = false` the record
carries no `"gitcommit"`, for a dictionary that DrWatson's `tagsave` tags itself: it adds
no git information to one that already holds the key.

# Example
```julia
record = provenance(; inputs = ["data/catalogue.csv"])
record["inputs"][1]["sha256"]
```
"""
function provenance(;
    project::AbstractString = active_project(),
    root::AbstractString = default_root(project),
    inputs = String[],
    git::Bool = true,
)
    record = Dict{String, Any}()
    merge!(record, host_record(), julia_record(), environment_record(project; root))
    git && merge!(record, git_record(root))
    stamp = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS")
    record["timestamp_utc"] = stamp * "Z"
    record["inputs"] = Dict{String, Any}[input_record(path; root) for path in inputs]
    record["accelerators"] = accelerator_records()
    return record
end

"""
    write_provenance(path::AbstractString, record::AbstractDict) -> String

Write `record` as TOML with sorted keys to `path` and return `abspath(path)`. Throws
`ArgumentError` when `path` exists, which is never overwritten, or when its directory
does not exist.
"""
function write_provenance(path::AbstractString, record::AbstractDict)
    ispath(path) && throw(ArgumentError("refusing to overwrite existing file: $path"))
    directory = dirname(abspath(path))
    isdir(directory) || throw(ArgumentError("directory does not exist: $directory"))
    open(path, "w") do io
        TOML.print(io, record; sorted = true)
    end
    return abspath(path)
end

"""
    snapshot_manifest(directory::AbstractString;
                      project::AbstractString = active_project())
        -> Union{String, Nothing}

Copy the manifest of `project` (a project file or a directory, resolved as in
[`environment_record`](@ref)) into `directory` under its own base name and return the
path of the copy; `nothing` when the project has no manifest. A file of that name with
the same bytes as the manifest is left in place and its path returned. Throws
`ArgumentError` when `directory` is not an existing directory or the file there differs
from the manifest.
"""
function snapshot_manifest(
    directory::AbstractString;
    project::AbstractString = active_project(),
)
    isdir(directory) || throw(ArgumentError("not an existing directory: $directory"))
    source = manifest_path(project_file(project))
    source === nothing && return nothing
    target = joinpath(directory, basename(source))
    if ispath(target)
        isfile(target) && read(target) == read(source) && return target
        throw(ArgumentError("$target exists and differs from the manifest $source"))
    end
    cp(source, target; follow_symlinks = true)
    return target
end

"""
    usage(io::IO = stdout) -> Nothing

Print the command-line help to `io`.
"""
function usage(io::IO = stdout)
    print(
        io,
        """
        run-provenance — platform, environment, source and input provenance of a run

        Usage:
          julia run.jl run-provenance [options]

          --project PATH          project file or directory (default: the project found
                                  upwards from the working directory)
          --root DIR              root of the relative paths of the record (default: the
                                  directory of the project)
          --input FILE            input file to record with its size and SHA-256; may be
                                  repeated
          --out FILE              write the record as TOML to FILE, which must not exist
                                  (default: print it)
          -h, --help
        """,
    )
    return nothing
end

"""
    option_value(args::Vector{String}, i::Int, flag::AbstractString) -> String

The value that follows the option `flag` at position `i` of `args`. Throws
`ArgumentError` when it is missing.
"""
function option_value(args::Vector{String}, i::Int, flag::AbstractString)
    i < length(args) || throw(ArgumentError("$flag requires a value"))
    return args[i + 1]
end

"""
    working_project() -> String

The project file found upwards from the working directory. Throws `ArgumentError` when
there is none.
"""
function working_project()
    project = Base.current_project(pwd())
    project === nothing &&
        throw(ArgumentError("no project found from the working directory; pass --project"))
    return project
end

"""
    main(args::Vector{String} = ARGS; io::IO = stdout) -> Union{Dict{String, Any}, Nothing}

Parse the command line (see `--help`), assemble the [`provenance`](@ref) record and
print it to `io` as TOML with sorted keys or, with `--out FILE`, write it through
[`write_provenance`](@ref) and print the path. Returns the record; `nothing` after
`--help`. Unknown options, missing values and positional arguments throw an
`ArgumentError`.
"""
function main(args::Vector{String} = ARGS; io::IO = stdout)
    project = nothing
    root = nothing
    inputs = String[]
    out = nothing
    i = 1
    while i <= length(args)
        argument = args[i]
        if argument in ("-h", "--help")
            usage(io)
            return nothing
        elseif argument == "--project"
            project = option_value(args, i, argument)
            i += 1
        elseif argument == "--root"
            root = option_value(args, i, argument)
            i += 1
        elseif argument == "--input"
            push!(inputs, option_value(args, i, argument))
            i += 1
        elseif argument == "--out"
            out = option_value(args, i, argument)
            i += 1
        elseif startswith(argument, "-")
            throw(ArgumentError("unknown command-line argument '$argument'; see --help"))
        else
            throw(ArgumentError("unexpected positional argument '$argument'; see --help"))
        end
        i += 1
    end
    project_path = project === nothing ? working_project() : project
    root_path = root === nothing ? default_root(project_path) : root
    record = provenance(; project = project_path, root = root_path, inputs)
    if out === nothing
        TOML.print(io, record; sorted = true)
    else
        path = write_provenance(out, record)
        println(io, "Provenance written to ", path)
    end
    return record
end

end
