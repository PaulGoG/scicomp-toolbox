# Changelog

Notable changes to the workbench. The repository itself carries no version; the
`HardwareDiagnostics` package follows semantic versioning and its version is given where
a change belongs to it.

## 2026-09-07

### Added

- `plot-benchmarks` tool: thread-scaling (speedup and parallel efficiency) and throughput
  figures from `hardware-diagnostics` datasets with CairoMakie, sized for print.
- `HardwareDiagnostics` 0.3.0: tiled local-memory KernelAbstractions kernel as the engine
  `ka_tiled`, with the same arithmetic as the naive kernel and the library path; the
  `[benchmark].engines` list selects any subset of `blas`, `ka`, `ka_tiled`; the
  cross-engine verification checks every configured kernel engine against `mul!`.
- `HardwareDiagnostics` 0.2.0: the tool becomes a package with CUDA, AMDGPU, Metal and
  oneAPI package extensions; time-budgeted sampling with minimum, median and median
  absolute deviation; thread sweep bounded by the physical core count; integer element
  types validated against the accumulation bound; dataset columns for the executing
  library, thread counts and a per-point status; provenance sidecar with thread pools,
  repository commit and the GPU package's version report.
- Pinned formatter environment (`formatter/`) used by `check.jl` and CI; `check.jl --check`.
- Dependabot for GitHub Actions and the Julia environments; workflows with read-only
  token permissions and actions pinned by commit.
- `CHANGELOG.md`.

### Changed

- The dispatcher instantiates a tool's environment before launching it, propagates the
  child's exit status, forwards the Julia thread count and looks for standalone scripts
  in `standalone/` only; the test runner instantiates each environment and runs packages
  through `Pkg.test`.
- `sysinfo` reports physical cores from `/proc/cpuinfo`, the BLAS library by name and
  the repository revision of the script's own checkout.
- Ignore patterns restricted to generated outputs and test manifests.

### Removed

- The root `activate.jl`, the script `hardware-diag.jl` and its Manifest (replaced by the
  package and the entry point `hardware-diagnostics.jl`); the `compute_engine` and
  `mode`/`trials` configuration keys (replaced by `engines`, command-line presets and the
  `[sampling]` table).
