# run-provenance

Provenance of a run as one flat record: the host and its CPU, the Julia session and its
BLAS configuration, the project and the SHA-256 of its manifest, the git commit of the
source, the size and SHA-256 of every input file, and the active GPU devices. The record
is a `Dict{String, Any}` with string keys and values that TOML can hold, so it prints as
TOML and merges into a DrWatson result dictionary. A key whose value cannot be
determined is left out. The package `RunProvenance` implements the tool and is meant to
be called from the pipeline that produces the run, when the run starts.

```
run-provenance/
├── activate.jl                  # environment activation
├── run-provenance.jl            # entry point
├── Project.toml                 # package
├── README.md
├── ext/
│   ├── RunProvenanceCUDAExt.jl  # NVIDIA device record
│   ├── RunProvenanceAMDGPUExt.jl
│   ├── RunProvenanceoneAPIExt.jl
│   └── RunProvenanceMetalExt.jl
├── src/
│   └── RunProvenance.jl         # records, TOML output, manifest snapshot, command line
└── test/
    ├── Project.toml             # Aqua, ExplicitImports, JET, SHA, TOML, Test
    └── runtests.jl
```

## Use in a project

The package is not registered and needs Julia 1.12 or later. A project takes it from the
repository through `[sources]` in its `Project.toml`:

```toml
[deps]
RunProvenance = "a0efa9c0-8026-4cb3-9947-af67d164c70a"

[sources]
RunProvenance = {url = "https://github.com/PaulGoG/scicomp-toolbox", subdir = "run-provenance"}
```

or adds it once from the REPL:

```julia
using Pkg
Pkg.add(url = "https://github.com/PaulGoG/scicomp-toolbox", subdir = "run-provenance")
```

With DrWatson, the record is merged into the result before it is saved:

```julia
using DrWatson, RunProvenance

name = savename(parameters)
rundir = mkpath(datadir("runs", name))
record = provenance(; inputs = [datadir("exp_raw", "catalogue.csv")])  # before the computation
snapshot_manifest(rundir)

energy = simulate(parameters)

result = Dict{String, Any}("energy" => energy, "Δt" => parameters.Δt)
safesave(joinpath(rundir, "result.jld2"), merge(result, record))
```

The record is taken when the run starts: the commit, the manifest and the inputs are
read at the call, so a commit or a package update made while the run computes would
otherwise be recorded as its own. Each run has a directory of its own, because
`snapshot_manifest` refuses to put a second, different manifest beside the first.

`result` needs string keys: merged with a dictionary keyed by symbols, the record would
yield a dictionary of mixed key types. The record carries the commit itself, as the full
hash with `-dirty` when tracked or staged files differ from it, so `safesave` is enough.
`tagsave` adds no git information to a dictionary that already holds `gitcommit` and
warns about it; where its `gitpatch` or `script` entries are wanted, leave the commit to
it:

```julia
tagsave(datadir("runs", name * ".jld2"), merge(result, provenance(; git = false)))
```

`write_provenance(path, record)` writes the record as a TOML sidecar instead and never
overwrites an existing file. `snapshot_manifest` copies the resolved manifest of the
active project into a run directory and leaves an identical copy already there in place.

The record names the machine: the host name, and in `versioninfo` the `JULIA_*`
environment variables of the session, which can hold paths under a home directory. Read
it before a dataset that carries it is published.

What the record does not hold:

- Untracked files do not make the commit `-dirty`. When the project file or the script
  that runs is itself untracked or ignored, `untracked_sources` names it; other
  untracked code that the run includes leaves no trace. The script is the one Julia was
  started with, resolved when the package is loaded: load the package before any `cd`.
- Only the manifest of the project is recorded. A package loaded from another
  environment of the load path, such as the default environment, is not in it, and a
  package developed by path appears in the manifest without a tree hash.
- `timestamp_utc` is the time of the call, not the start of the process.

## Keys

Paths are relative to `root`, by default the directory of the project.

| Key | Value | Source |
|---|---|---|
| `hostname` | host name | `gethostname()` |
| `os`, `arch`, `machine` | kernel, architecture, target triple | `Sys.KERNEL`, `Sys.ARCH`, `Sys.MACHINE` |
| `cpu_model` | CPU model, absent when it cannot be queried | `Sys.cpu_info()` |
| `cpu_threads` | logical cores | `Sys.CPU_THREADS` |
| `total_memory_bytes` | memory the process may use [B]: the physical memory, or a lower limit set by a control group | `Sys.total_memory()` |
| `julia_version`, `julia_commit` | Julia version and short commit of the build | `VERSION`, `Base.GIT_VERSION_INFO` |
| `julia_threads`, `julia_interactive_threads` | threads of the default and interactive pools | `Threads.nthreads` |
| `distributed_workers` | worker processes besides the master | `Distributed.nprocs() - 1` |
| `blas_threads` | BLAS threads | `BLAS.get_num_threads()` |
| `blas_libraries` | base names of the BLAS libraries loaded | `BLAS.get_config()` |
| `versioninfo` | text of `versioninfo()` | `InteractiveUtils` |
| `project_file` | project file | the keyword `project`, by default `Base.active_project()`; on the command line `--project`, by default the project found upwards from the working directory |
| `manifest_file`, `manifest_sha256` | the manifest Julia resolves for the project (of its own release first, of the workspace for a member, or the one a `manifest` key names) and its SHA-256; absent without a manifest | `Base.project_file_manifest_path` |
| `gitcommit` | hash of HEAD, `-dirty` when the work tree or the index differs from it; absent outside a repository, in a bare one, or without a commit | `LibGit2` |
| `untracked_sources` | the project file and the script Julia was started with, when the repository does not track them (new, ignored, or in a nested repository); absent otherwise | `LibGit2.status` |
| `timestamp_utc` | time of the record, `yyyy-mm-ddTHH:MM:SSZ` | `Dates.now(UTC)` |
| `inputs` | one table per input file: `path`, `bytes`, `sha256` | `filesize`, `SHA.sha256` |
| `accelerators` | one table per functional GPU backend: `backend`, `device`, `memory_bytes`, `runtime_version`, `versioninfo` | package extensions |

`inputs` and `accelerators` are present also when empty. With `session = false` the
record has none of the keys from `julia_version` to `versioninfo` and no `accelerators`;
with `git = false`, neither `gitcommit` nor `untracked_sources`. A git failure other than "no repository" or "no
commit", such as a repository owned by another user, is thrown and not passed over. A
CUDA record carries
`driver_version` in addition; a Metal record has no `runtime_version`, and its
`memory_bytes` is the recommended working set of the unified memory.

## Command line

```bash
julia run.jl run-provenance --help
julia run.jl run-provenance                                       # project of the working directory
julia run.jl run-provenance --project myproject --input data/catalogue.csv
julia run.jl run-provenance --input a.csv --input b.csv --out project.toml
julia run-provenance/run-provenance.jl --root .                   # without the dispatcher
```

The command line describes a project on this host: what a run started here would
record, without the keys of a Julia session. The session it runs in is that of the tool,
with its own thread count and without any GPU package, so those keys would say nothing
about a run; a run records them by calling `provenance()` itself. The manifest named is
the one the Julia release running the tool resolves, which for a project that keeps
`Manifest-v1.12.toml` is another file under Julia 1.13.

`--project` takes a project file or a directory; without it the project is the one Julia
finds upwards from the working directory, and the tool stops when there is none.
`--root` sets the directory the paths are relative to and in which the git repository is
searched; it defaults to the directory of the project. `--input` may be repeated. The
record is printed as TOML with sorted keys, or written with `--out FILE` to a file that
must not exist yet. An unknown option, a missing value or a positional argument stops
the tool with exit status 2.

## Accelerators

The GPU records come from four package extensions, each loaded when its backend package
is loaded in the session: `RunProvenanceCUDAExt` (CUDA.jl), `RunProvenanceAMDGPUExt`
(AMDGPU.jl), `RunProvenanceoneAPIExt` (oneAPI.jl) and `RunProvenanceMetalExt`
(Metal.jl). A loaded backend that is not functional on the host contributes no record.
Without any of them, `accelerators` is empty. The status table of the repository states
which backends have been run on hardware.
