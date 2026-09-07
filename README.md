# scicomp-toolbox

[![CI](https://github.com/PaulGoG/scicomp-toolbox/actions/workflows/ci.yml/badge.svg)](https://github.com/PaulGoG/scicomp-toolbox/actions/workflows/ci.yml)
[![Format](https://github.com/PaulGoG/scicomp-toolbox/actions/workflows/format.yml/badge.svg)](https://github.com/PaulGoG/scicomp-toolbox/actions/workflows/format.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Scientific scripting workbench in Julia. It hosts standalone utilities and self-contained
tools that do not warrant a package of their own, behind one dispatcher, one test runner
and one formatting gate.

```
scicomp-toolbox/
├── .github/
│   ├── dependabot.yml             # weekly updates of actions and Julia environments
│   └── workflows/
│       ├── ci.yml                 # test suites, standalone and dispatcher smoke runs
│       └── format.yml             # JuliaFormatter gate using formatter/
├── .JuliaFormatter.toml           # formatting rules
├── LICENSE                        # MIT
├── README.md
├── check.jl                       # pre-commit: format with formatter/, then test.jl
├── run.jl                         # dispatcher: list, run and scaffold tools
├── test.jl                        # global test runner
├── formatter/                     # pinned JuliaFormatter environment (Project + Manifest)
│   └── activate.jl
├── standalone/                    # tier 2: single-file scripts on the standard library
│   └── sysinfo.jl                 # host and runtime introspection
└── hardware-diagnostics/          # tier 1: HardwareDiagnostics package with GPU extensions
    ├── activate.jl
    ├── config.toml
    ├── hardware-diagnostics.jl    # entry point
    ├── Manifest.toml
    ├── Project.toml
    ├── README.md
    ├── ext/                       # HardwareDiagnostics{CUDA,AMDGPU,Metal,oneAPI}Ext
    ├── src/
    └── test/
```

## Two tiers

A **tier 1 tool** is a directory with its own `Project.toml` and committed `Manifest.toml`,
an `activate.jl`, a validated `config.toml`, the entry point `<name>/<name>.jl`, a test
suite under `test/` and a README. A tool that outgrows a script becomes a package inside
that directory (`name` and `uuid` in `Project.toml`, `src/<Name>.jl`); the dispatcher and
the test runner handle both forms. Tools never share an environment, so their
dependencies cannot conflict.

A **tier 2 script** in `standalone/` relies on the standard library only and runs without
instantiation.

## Requirements

Julia 1.12 through [juliaup](https://github.com/JuliaLang/juliaup); the declared floor of
every environment is `julia = "1.12"`. Linux is the primary platform. GPU packages
(`CUDA`, `AMDGPU`, `Metal`, `oneAPI`) are not dependencies of any tool: install the one
matching the hardware into the default environment and the tool resolves it through the
load path (see `hardware-diagnostics/README.md`).

## Entry points

```bash
julia run.jl --list                                     # catalog
julia run.jl sysinfo                                    # standalone script
julia run.jl hardware-diagnostics --quick --cpu-only    # tool; arguments are forwarded
julia run.jl --threads 8 hardware-diagnostics           # Julia threads of the child process
julia run.jl --new <name>                               # scaffold a tier 1 tool
julia test.jl                                           # every test suite
julia test.jl hardware-diagnostics                      # one suite
julia check.jl                                          # format in place, then test
julia check.jl --check                                  # fail on formatting differences
```

The dispatcher instantiates a tool's environment before launching it, so a fresh clone
needs no manual setup. Child processes receive `--threads` from `JULIA_NUM_THREADS`, or
`auto` when the variable is unset; `--threads N` before the tool name overrides both.

Working inside one environment:

```bash
julia --project=hardware-diagnostics                    # REPL in the tool's environment
julia --project=hardware-diagnostics -e 'using Pkg; Pkg.test()'
julia -i -e 'include("hardware-diagnostics/activate.jl")'
```

## Catalog

| Tool | Tier | Purpose | Entry point |
| :--- | :--- | :--- | :--- |
| [`sysinfo`](standalone/sysinfo.jl) | 2 | CPU topology (physical and logical), memory, thread pools, BLAS library, repository revision | `standalone/sysinfo.jl` |
| [`hardware-diagnostics`](hardware-diagnostics/) | 1 | Host and accelerator introspection; dual-GEMM throughput through a KernelAbstractions kernel and the vendor library, with thread scaling and cross-engine verification | `hardware-diagnostics/hardware-diagnostics.jl` |

## Status

| Component | State |
| :--- | :--- |
| Dispatcher, test runner, formatting gate | in use; exercised by CI on Julia 1 (current stable), Ubuntu |
| `sysinfo` | in use |
| `hardware-diagnostics`, CPU path | tested (unit tests, static QA with Aqua, JET and ExplicitImports, end-to-end run) |
| `hardware-diagnostics`, oneAPI extension | run on an Intel Arc integrated GPU (Meteor Lake) |
| `hardware-diagnostics`, CUDA, AMDGPU and Metal extensions | written against the documented package APIs, not run on hardware |

## Conventions

Run outputs go to `<tool>/data/` and are ignored by git, as are `plots/`, logs, CSV and
binary data files. Tool and formatter manifests are committed; test manifests are not.
Commits follow Conventional Commits. Formatting is enforced with the JuliaFormatter
version pinned in `formatter/Manifest.toml`.
