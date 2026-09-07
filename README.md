# Scientific Computing Tooling Repository

[![CI](https://github.com/username/scripts-toolbox/actions/workflows/ci.yml/badge.svg)](https://github.com/username/scripts-toolbox/actions/workflows/ci.yml)
[![Format](https://github.com/username/scripts-toolbox/actions/workflows/format.yml/badge.svg)](https://github.com/username/scripts-toolbox/actions/workflows/format.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A unified multi-environment repository for standalone diagnostics, computational benchmarks, data conversion utilities, and HPC cluster orchestration scripts in pure Julia.

## Repository Structure

```
scripts/
├── .github/
│   └── workflows/
│       ├── ci.yml                  # Automated multi-version CI test matrix
│       └── format.yml              # JuliaFormatter code quality gate
├── .gitignore                      # Git exclusion rules
├── .JuliaFormatter.toml            # Project-wide code formatting specification
├── LICENSE                         # MIT License
├── README.md                       # Master tooling index and orchestration manual
├── activate.jl                     # Pure-Julia sub-environment activation dispatcher
└── hardware-diagnostics/           # Heterogeneous hardware profiling & benchmark suite
    ├── activate.jl                 # Dedicated silent sub-environment activator
    ├── config.toml                 # Benchmark parameters and memory safety thresholds
    ├── hardware-diag.jl            # Architecture-agnostic benchmarking executable
    ├── Manifest.toml               # Pinned dependency lockfile
    ├── Project.toml                # Isolated package dependencies & compat bounds
    ├── README.md                   # Tool-specific manual and operational guide
    └── test/
        └── runtests.jl             # Unit test suite (61 test assertions)
```

## Architecture: Multi-Environment Mono-Repo

To prevent dependency bloating and version resolution conflicts between unrelated one-off utilities, this repository adopts a **multi-environment mono-repo** architecture:
- **Zero Cross-Contamination**: Each computational tool resides in its own subdirectory with an isolated `Project.toml` and `Manifest.toml`. Adding or updating dependencies for one utility does not affect any other tool.
- **Portability Guarantee**: Exact dependency versions are pinned in `Manifest.toml` alongside dynamic path resolution (`@__DIR__`, `joinpath`), guaranteeing reproducible execution across workstations and cluster nodes without hardcoded paths.
- **Pure-Julia Orchestration**: Tool setup and activation rely strictly on the Julia `Pkg` API (`activate.jl`) rather than shell scripts.
- **Automated Continuous Integration**: GitHub Actions CI verifies environment instantiation, unit tests, and smoke tests across Julia `1.10`, `1.11`, and `1.12`.

## Sub-Environment Catalog

| Directory | Primary Purpose | Key Dependencies | Primary Entry Point | Test Suite |
| :--- | :--- | :--- | :--- | :--- |
| [`hardware-diagnostics/`](hardware-diagnostics/) | Platform profiling, multi-threaded CPU scaling, and multi-backend GPU benchmarks | `KernelAbstractions`, `oneAPI`, `LinearAlgebra` | `hardware-diagnostics/hardware-diag.jl` | `hardware-diagnostics/test/runtests.jl` |

## Quick Start

### 1. Execute a Tool Directly
Execute any tool using Julia's `--project` flag pointing to the tool's directory:

```bash
# Run hardware diagnostic preset
julia --project=hardware-diagnostics hardware-diagnostics/hardware-diag.jl --quick

# Run with custom parameters and specific accelerator backend
julia --project=hardware-diagnostics hardware-diagnostics/hardware-diag.jl --gpu-backend oneapi --engine both
```

### 2. Run the Unit Test Suite
Execute the test suite within the tool's environment:

```bash
julia --project=hardware-diagnostics hardware-diagnostics/test/runtests.jl
```

### 3. Interactive REPL Workflow
From the root of this repository, activate any sub-environment interactively:

```julia
# Inside Julia REPL:
include("hardware-diagnostics/activate.jl")
```
or via the root dispatcher:
```bash
julia activate.jl hardware-diagnostics
```

## Remote Git Setup

To synchronize this repository with a private remote host (GitHub, GitLab, or institutional forge):

```bash
# 1. Add your remote repository:
git remote add origin git@github.com:<username>/<repo-name>.git

# 2. Verify connection:
git remote -v

# 3. Push main branch and set upstream tracking:
git push -u origin main
```

## Adding New Tools

When introducing a new computational utility to this repository:

1. Create a dedicated directory:
   ```bash
   mkdir -p my-utility
   ```
2. Initialize and instantiate an isolated Julia project:
   ```bash
   julia --project=my-utility -e 'using Pkg; Pkg.add(["Dependency1", "Dependency2"])'
   ```
3. Add a dedicated silent `activate.jl`:
   ```julia
   using Pkg
   Pkg.activate(@__DIR__; io = devnull)
   Pkg.instantiate(; io = devnull)
   ```
4. Place core logic, configuration (`config.toml`), tests (`test/runtests.jl`), and documentation (`README.md`) inside the tool's directory.
5. Add test step to `.github/workflows/ci.yml` and update this catalog.

## License

This repository is licensed under the [MIT License](LICENSE).
