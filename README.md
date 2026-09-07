# scicomp-toolbox

[![CI](https://github.com/PaulGoG/scicomp-toolbox/actions/workflows/ci.yml/badge.svg)](https://github.com/PaulGoG/scicomp-toolbox/actions/workflows/ci.yml)
[![Format](https://github.com/PaulGoG/scicomp-toolbox/actions/workflows/format.yml/badge.svg)](https://github.com/PaulGoG/scicomp-toolbox/actions/workflows/format.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A personal scientific computing scripting workbench in pure Julia. Designed to host, orchestrate, and maintain standalone computational utilities, hardware diagnostics, numerical experiments, data processing scripts, and HPC automation workflows that do not warrant individual full-blown packages.

## Repository Layout

```
scicomp-toolbox/
├── .github/
│   └── workflows/
│       ├── ci.yml                  # Automated CI test matrix & smoke tests
│       └── format.yml              # JuliaFormatter code quality gate
├── .gitignore                      # Git exclusion rules
├── .JuliaFormatter.toml            # Project-wide code formatting specification
├── LICENSE                         # MIT License
├── README.md                       # Master tooling index and orchestration manual
├── run.jl                          # Universal CLI dispatcher & tool scaffolding
├── test.jl                         # Global test runner discovering all sub-environments
├── check.jl                        # Pre-commit QA runner (formatting + test verification)
├── activate.jl                     # Pure-Julia interactive environment activator
├── standalone/                     # Tier 2: Single-file lightweight utilities
│   └── sysinfo.jl                  # Fast host platform & runtime topology inspector
└── hardware-diagnostics/           # Tier 1: Heterogeneous hardware profiling & benchmarks
    ├── activate.jl                 # Dedicated silent sub-environment activator
    ├── config.toml                 # Benchmark parameters and memory safety thresholds
    ├── hardware-diag.jl            # Architecture-agnostic benchmarking executable
    ├── Manifest.toml               # Pinned dependency lockfile
    ├── Project.toml                # Isolated package dependencies & compat bounds
    ├── README.md                   # Tool-specific manual and operational guide
    └── test/
        └── runtests.jl             # Unit test suite (61 test assertions)
```

## Architecture: Dual-Tier Scripting

To maximize convenience while eliminating dependency conflicts, the workbench supports two tiers of scripts:

### Tier 1: Isolated Sub-Environments
For complex scripts with specialized external dependencies (GPU backends, Makie visualization, HDF5, tabular I/O).
* Each tool has its own directory with dedicated `Project.toml` and `Manifest.toml`.
* Guaranteed zero dependency cross-contamination across tools.
* Pinned lockfiles and relative path resolution guarantee exact reproducibility across nodes.

### Tier 2: Standalone Lightweight Scripts (`standalone/`)
For self-contained utilities and one-off tasks relying on Julia standard libraries (`LinearAlgebra`, `Statistics`, `Printf`, `TOML`, `DelimitedFiles`).
* Stored directly in `standalone/`.
* Instant execution without package instantiation or dependency management.

---

## Universal CLI Dispatcher (`run.jl`)

The root `run.jl` script provides a unified interface to list, execute, and scaffold scripts across the entire repository.

### 1. View Catalog
List all registered sub-environments and standalone scripts:
```bash
julia run.jl --list
```

### 2. Execute a Script or Sub-Environment
Run any utility directly by name; all additional arguments are forwarded to the script:
```bash
# Execute standalone utility (Tier 2)
julia run.jl sysinfo

# Execute isolated sub-environment tool (Tier 1)
julia run.jl hardware-diagnostics --quick
julia run.jl hardware-diagnostics --gpu-backend oneapi --engine both
```

### 3. Scaffold a New Sub-Environment Tool
Generate a standardized, committable sub-environment in one command:
```bash
julia run.jl --new my-tool
```
This generates:
* `my-tool/Project.toml` (with fresh UUID and compat bounds)
* `my-tool/activate.jl` (silent Pkg activator)
* `my-tool/config.toml` (parameter configuration)
* `my-tool/my-tool.jl` (executable entry point with CLI handling)
* `my-tool/test/runtests.jl` (unit test suite)
* `my-tool/README.md` (documentation template)

---

## Testing & Quality Assurance

### Run Global Test Suite
Executes unit tests across all discovered sub-environments in isolated subprocesses:
```bash
julia test.jl

# Or target a single sub-environment:
julia test.jl hardware-diagnostics
```

### Run Pre-Commit Verification
Formats all code against `.JuliaFormatter.toml` and executes the full test suite:
```bash
julia check.jl
```

---

## Script Catalog

### System & Hardware Diagnostics
| Tool | Tier | Purpose | Entry Point | Test Suite |
| :--- | :--- | :--- | :--- | :--- |
| [`sysinfo`](standalone/sysinfo.jl) | Tier 2 | Rapid host architecture, memory, and BLAS inspection | `standalone/sysinfo.jl` | Smoke tested |
| [`hardware-diagnostics`](hardware-diagnostics/) | Tier 1 | Heterogeneous accelerator profiling, multi-threaded CPU scaling, unified `KernelAbstractions.jl` GEMM benchmarks | `hardware-diagnostics/hardware-diag.jl` | `hardware-diagnostics/test/runtests.jl` |

---

## License

This repository is licensed under the [MIT License](LICENSE).
