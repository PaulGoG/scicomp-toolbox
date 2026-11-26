# run-provenance

Provenance of a run as one flat record: the host and its CPU, the Julia session and its
BLAS configuration, the project and the SHA-256 of its manifest, the git commit of the
source, the size and SHA-256 of every input file, and the active GPU devices. The record
is a `Dict{String, Any}` with string keys and values that TOML can hold, so it prints as
TOML and merges into a DrWatson result dictionary. A key whose value cannot be
determined is left out. The package `RunProvenance` implements the tool and is meant to
be called from the pipeline that produces the run.

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

The package is not registered. A project on Julia 1.11 or later takes it from the
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

result = Dict{String, Any}("energy" => energy, "Δt" => Δt)
name = savename(parameters)
record = provenance(; inputs = [datadir("exp_raw", "catalogue.csv")])
safesave(datadir("runs", name * ".jld2"), merge(result, record))
snapshot_manifest(datadir("runs"))
```

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

## Keys

Paths are relative to `root`, by default the directory of the project.

| Key | Value | Source |
|---|---|---|
| `hostname` | host name | `gethostname()` |
| `os`, `arch`, `machine` | kernel, architecture, target triple | `Sys.KERNEL`, `Sys.ARCH`, `Sys.MACHINE` |
| `cpu_model` | CPU model, absent when it cannot be queried | `Sys.cpu_info()` |
| `cpu_threads` | logical cores | `Sys.CPU_THREADS` |
| `total_memory_bytes` | physical memory [B] | `Sys.total_memory()` |
| `julia_version`, `julia_commit` | Julia version and short commit of the build | `VERSION`, `Base.GIT_VERSION_INFO` |
| `julia_threads`, `julia_interactive_threads` | threads of the default and interactive pools | `Threads.nthreads` |
| `distributed_workers` | worker processes besides the master | `Distributed.nprocs() - 1` |
| `blas_threads` | BLAS threads | `BLAS.get_num_threads()` |
| `blas_libraries` | base names of the BLAS libraries loaded | `BLAS.get_config()` |
| `versioninfo` | text of `versioninfo()` | `InteractiveUtils` |
| `project_file` | project file | `--project`, `Base.active_project()` |
| `manifest_file`, `manifest_sha256` | resolved manifest and its SHA-256, absent without a manifest | `Base.project_file_manifest_path` |
| `gitcommit` | hash of HEAD, `-dirty` when tracked files differ; absent outside a repository or without a commit | `LibGit2` |
| `timestamp_utc` | time of the record, `yyyy-mm-ddTHH:MM:SSZ` | `Dates.now(UTC)` |
| `inputs` | one table per input file: `path`, `bytes`, `sha256` | `filesize`, `SHA.sha256` |
| `accelerators` | one table per functional GPU backend: `backend`, `device`, `memory_bytes`, `runtime_version`, `versioninfo` | package extensions |

`inputs` and `accelerators` are present also when empty. A CUDA record carries
`driver_version` in addition; a Metal record has no `runtime_version`, and its
`memory_bytes` is the recommended working set of the unified memory.

## Command line

```bash
julia run.jl run-provenance --help
julia run.jl run-provenance                                       # project of the working directory
julia run.jl run-provenance --project myproject --input data/catalogue.csv
julia run.jl run-provenance --input a.csv --input b.csv --out provenance.toml
julia run-provenance/run-provenance.jl --root .                   # without the dispatcher
```

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
