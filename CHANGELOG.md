# Changelog

Notable changes to the workbench. The repository itself carries no version; the
`HardwareDiagnostics` package follows semantic versioning and its version is given where
a change belongs to it.

## 2026-09-11

### Added

- `reference-runs/`: the datasets of six `--stress` runs on six accelerators of three
  vendors, one directory per device, with a README recording the hardware, the shared
  configuration and the outcome of each run. They are the provenance of the README
  figures and the evidence behind the backend status table.
- `plot-benchmarks --compare [DIR]`: two cross-host figures from every dataset under a
  directory. The accelerator figure stacks the throughput of the library engine, the
  throughput of the tiled KernelAbstractions kernel and their ratio on one element-type
  axis, marking the types served by the generic fallback; the host figure draws the
  speedup and the parallel efficiency of every host processor on one thread axis. Devices
  are pooled across datasets and the size is the largest one measured in all of them.
- `plot-benchmarks --px-per-unit N`, overriding `[figures].px_per_unit` for one export,
  and `[input].comparison_directory` in the configuration.

### Changed

- The CUDA, AMDGPU and oneAPI extensions of `HardwareDiagnostics` have now run on
  hardware: four NVIDIA devices, one AMD device and one Intel integrated GPU, all three
  engines each, cross-engine verification passed (120 comparisons). Only the Metal
  extension remains unexecuted.
- The README figures are the two cross-host figures; the single-host throughput figure
  they replace is no longer shipped, the per-dataset figures being the tool's default
  output.
- `plot-benchmarks`: decade tick labels keep one style per axis — plain decimals while
  the axis stays between 10⁻³ and 10⁴, powers of ten otherwise, with 10⁰ and 10¹ always
  written `1` and `10`; ranges narrower than three decades add the 2× and 5×
  intermediates.

### Fixed

- `plot-benchmarks`: the ideal reference S = t of the thread-scaling figure was drawn as
  a two-point segment on a logarithmic thread axis, on which it is a chord and not the
  reference; it is now sampled along the axis.

## 2026-09-10

### Fixed

- `plot-benchmarks`: the throughput axis raised a `DomainError` when a measured point fell
  below 1 GOP/s, because decade tick labels were built from an integer power of ten; ticks
  below unity now read `0.1`, `0.01`, `0.001`, and bar labels keep three significant
  digits below 1.
- `hardware-diagnostics`: a configuration file whose section is not a table
  (`benchmark = 3`) combined with a command-line override is rejected with an
  `ArgumentError` naming the section instead of a `MethodError`.
- The tool scaffold (`run.jl --new`) declares `TOML`, which the generated entry point
  uses, in the generated `Project.toml`.

### Changed

- `HardwareDiagnostics` 0.3.1: the `CUDA` weak dependency admits the 6.x series; every
  name the extension uses was checked against the CUDA.jl 6.3 sources (the extension
  remains unexecuted on hardware).
- Manifests resolved with Julia 1.13.0, the current stable release; the compat floor
  stays at 1.12.
- `hardware-diagnostics` datasets: a CPU problem size or element type skipped for memory
  or predicted time is recorded at every engine and thread count of its stage, so every
  planned point has a row and the CSV is a complete grid.
- `plot-benchmarks`: the headroom above the throughput bars grows with the axis span, so
  value labels stay clear of the panel caption on wide ranges.

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
