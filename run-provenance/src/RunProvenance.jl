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

# Absolute path of the script Julia was started with, "" in an interactive session.
# `PROGRAM_FILE` is relative to the directory Julia was started in, so it is resolved
# when the package is loaded and not when a record is taken, after a possible `cd`.
const PROGRAM = Ref("")

function __init__()
    PROGRAM[] = isempty(PROGRAM_FILE) ? "" : abspath(PROGRAM_FILE)
    return nothing
end

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
        "total_memory_bytes" => Int64(Sys.total_memory()),
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

The default root of the relative paths of a record, as an absolute path with symbolic
links resolved: `project` itself when it is a directory, the directory of the project
file otherwise.
"""
function default_root(project::AbstractString)
    # through a symbolic link: the root is where the project is, not where the link is
    path = ispath(project) ? realpath(project) : abspath(project)
    return isdir(path) ? path : dirname(path)
end

"""
    relative_path(path::AbstractString, root::AbstractString) -> String

`path` relative to the directory `root`, both resolved through symbolic links, with `/`
as separator on every platform. Throws `ArgumentError` when `root` is not an existing
directory.
"""
function relative_path(path::AbstractString, root::AbstractString)
    isdir(root) || throw(ArgumentError("root is not an existing directory: $root"))
    relative = relpath(realpath(path), realpath(root))
    return replace(relative, Base.Filesystem.path_separator => "/")
end

"""
    manifest_path(project::AbstractString) -> Union{String, Nothing}

The manifest that Julia resolves for the project file `project`, as an absolute path:
its own `Manifest-v<major>.<minor>.toml` before `Manifest.toml`, the file named by a
`manifest` key, the manifest of the workspace for a member project. Returns `nothing`
when there is none or it is not an existing file. The rule is Julia's own
(`Base.project_file_manifest_path`), so that the record cannot name another manifest
than the one the session loads; a Julia release without that function is an error.
"""
function manifest_path(project::AbstractString)
    isdefined(Base, :project_file_manifest_path) || error(
        "Base.project_file_manifest_path is not defined in Julia $VERSION: " *
        "the manifest of a project cannot be resolved as Julia does",
    )
    path = Base.project_file_manifest_path(abspath(project))
    (path === nothing || !isfile(path)) && return nothing
    return String(path)
end

"""
    environment_record(project::AbstractString;
                       root::AbstractString = default_root(project)) -> Dict{String, Any}

The Julia environment of the run. `project` is a project file or a directory holding
`JuliaProject.toml` or `Project.toml`; `root` defaults to that directory. Keys:
`"project_file"`, the project file relative to `root`, and, when Julia resolves an
existing manifest for the project, `"manifest_file"` (relative to `root`) and
`"manifest_sha256"`. The manifest is the one the running Julia release takes: its own
`Manifest-v<major>.<minor>.toml` before `Manifest.toml`, the manifest of the workspace
for a member project. Throws `ArgumentError` when the project file cannot be found.
"""
function environment_record(
    project::AbstractString;
    root::AbstractString = default_root(project),
)
    file = project_file(project)
    record = Dict{String, Any}("project_file" => relative_path(file, root))
    manifest = manifest_path(file)
    if manifest !== nothing
        record["manifest_file"] = relative_path(manifest, root)
        record["manifest_sha256"] = sha256_hex(manifest)
    end
    return record
end

"""
    untracked_sources(repo, sources, root) -> Vector{String}

Those of the files `sources` that lie in the work tree of `repo` and that the
repository does not track: new, ignored, or inside a nested repository, whose files it
does not see. Paths are relative to `root`. A source is the file that holds the code, so
a symbolic link is followed; a file outside the work tree is no source of this
repository.
"""
function untracked_sources(repo::LibGit2.GitRepo, sources, root::AbstractString)
    found = String[]
    top = realpath(LibGit2.workdir(repo))
    outside = LibGit2.Consts.STATUS_WT_NEW | LibGit2.Consts.STATUS_IGNORED
    for source in sources
        isfile(source) || continue
        inside = relpath(realpath(source), top)
        (isabspath(inside) || first(splitpath(inside)) == "..") && continue
        flags = LibGit2.status(repo, replace(inside, Base.Filesystem.path_separator => "/"))
        # no status at all: the file exists, but in a repository of its own
        (flags === nothing || flags & outside != 0) || continue
        path = relative_path(source, root)
        path in found || push!(found, path)
    end
    return found
end

"""
    git_record(root::AbstractString; sources = String[]) -> Dict{String, Any}

The source revision of the repository that holds `root`, searched upwards from `root`
as DrWatson does. Key `"gitcommit"`: the hash of HEAD, followed by `-dirty` when the work
tree or the index differs from that commit; untracked files do not count. Key
`"untracked_sources"`, present when not empty: those of the files `sources` that lie in
the repository and are not tracked, so that a commit is not taken for the code of a
script or project it does not hold; see [`untracked_sources`](@ref). Empty when `root`
is in no repository, or the repository is bare or has no commit; any other failure of
git is thrown.
"""
function git_record(root::AbstractString; sources = String[])
    record = Dict{String, Any}()
    repo = try
        LibGit2.GitRepoExt(String(root))
    catch err
        (err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND) || rethrow()
        return record
    end
    try
        # a bare repository has no work tree that a run could have used
        LibGit2.isbare(repo) && return record
        commit = try
            string(LibGit2.head_oid(repo))
        catch err
            unborn = err isa LibGit2.GitError && err.code == LibGit2.Error.EUNBORNBRANCH
            unborn || rethrow()
            return record
        end
        # compared with the commit just read, not with whatever HEAD is by then
        dirty = LibGit2.isdiff(repo, commit)
        record["gitcommit"] = dirty ? commit * "-dirty" : commit
        untracked = untracked_sources(repo, sources, root)
        isempty(untracked) || (record["untracked_sources"] = untracked)
        return record
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
    return Dict{String, Any}(
        "path" => relative_path(path, root),
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
               root::AbstractString = default_root(project), inputs = String[],
               git::Bool = true, session::Bool = true) -> Dict{String, Any}

The provenance of a run as one flat record: the keys of [`host_record`](@ref),
[`julia_record`](@ref), [`environment_record`](@ref) and [`git_record`](@ref), together
with `"timestamp_utc"` (when the record was taken; ISO 8601, seconds, `Z` suffix),
`"inputs"`, one [`input_record`](@ref) per path of the iterable `inputs`, and
`"accelerators"`, the result of [`accelerator_records`](@ref). Both vectors are present
also when empty. `project` is a project file or a directory, and `root` defaults to the
directory of the project. Relative paths of the record are relative to `root`.

The commit, the manifest and the inputs are read when the function is called: call it
when the run starts, before the computation, so that a commit or a package update made
while it runs does not enter the record.

With `git = false` the record carries neither `"gitcommit"` nor `"untracked_sources"`,
for a dictionary that DrWatson's `tagsave` tags itself: it adds no git information to
one that already holds the key. With `session = false` it carries neither the keys of
[`julia_record`](@ref) nor `"accelerators"`, and the script Julia was started with is
no source: these describe the Julia session that calls, which is the run only when the
run itself calls.

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
    session::Bool = true,
)
    file = project_file(project)
    record = Dict{String, Any}()
    merge!(record, host_record(), environment_record(file; root))
    if session
        merge!(record, julia_record())
        record["accelerators"] = accelerator_records()
    end
    if git
        # the project file, and the script that runs when the caller is the run
        sources = String[file]
        (session && isfile(PROGRAM[])) && push!(sources, PROGRAM[])
        merge!(record, git_record(root; sources))
    end
    stamp = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS")
    record["timestamp_utc"] = stamp * "Z"
    record["inputs"] = Dict{String, Any}[input_record(path; root) for path in inputs]
    return record
end

"""
    write_new(path::AbstractString, content) -> Nothing

Create the file `path` with `content`. The file is created exclusively, so that one
made by another process since any earlier test is not truncated; an existing `path`
throws `ArgumentError`.
"""
function write_new(path::AbstractString, content)
    flags =
        Base.Filesystem.JL_O_WRONLY | Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_EXCL
    file = try
        Base.Filesystem.open(path, flags, 0o644)
    catch err
        (err isa Base.IOError && err.code == Base.UV_EEXIST) || rethrow()
        throw(ArgumentError("refusing to overwrite existing file: $path"))
    end
    written = false
    try
        write(file, content)
        written = true
    finally
        close(file)
        # created here and not completed: left in place, it would block every later attempt
        written || rm(path; force = true)
    end
    return nothing
end

"""
    write_provenance(path::AbstractString, record::AbstractDict) -> String

Write `record` as TOML with sorted keys to `path` and return `abspath(path)`. Throws
`ArgumentError` when `path` exists, which is never overwritten, or when its directory
does not exist. The text is complete before the file is created: a record that TOML
cannot print leaves no file behind.
"""
function write_provenance(path::AbstractString, record::AbstractDict)
    ispath(path) && throw(ArgumentError("refusing to overwrite existing file: $path"))
    directory = dirname(abspath(path))
    isdir(directory) || throw(ArgumentError("directory does not exist: $directory"))
    text = sprint(io -> TOML.print(io, record; sorted = true))
    write_new(path, text)
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
from the manifest. Give every run a directory of its own: a second run with another
manifest is refused in a shared one.
"""
function snapshot_manifest(
    directory::AbstractString;
    project::AbstractString = active_project(),
)
    isdir(directory) || throw(ArgumentError("not an existing directory: $directory"))
    source = manifest_path(project_file(project))
    source === nothing && return nothing
    bytes = read(source)
    target = joinpath(directory, basename(source))
    if !ispath(target)
        try
            write_new(target, bytes)
            return target
        catch err
            # another process made the file in the meantime: compared below
            err isa ArgumentError || rethrow()
        end
    end
    (isfile(target) && read(target) == bytes) && return target
    throw(ArgumentError("$target exists and differs from the manifest $source"))
end

"""
    usage(io::IO = stdout) -> Nothing

Print the command-line help to `io`.
"""
function usage(io::IO = stdout)
    print(
        io,
        """
        run-provenance — host, environment, source and input provenance of a project

        What a run started here would record, without the keys of its Julia session
        (version, threads, BLAS, GPU): a run records those itself, with provenance().
        The manifest is the one this Julia release resolves for the project.

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
    # the Julia session here is that of this tool, not of a run
    record = provenance(; project = project_path, root = root_path, inputs, session = false)
    if out === nothing
        TOML.print(io, record; sorted = true)
    else
        path = write_provenance(out, record)
        println(io, "Provenance written to ", path)
    end
    return record
end

end
