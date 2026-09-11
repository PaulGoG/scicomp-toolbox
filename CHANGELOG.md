# Changelog

Notable changes to the workbench. The repository itself carries no version; the
`HardwareDiagnostics` package follows semantic versioning and its version is given where
a change belongs to it.

## 2026-09-11

### Added

- `workspace-audit` (tier 2): the git and artifact state of every project directory under
  a workspace root in one command — branch, working-tree cleanliness, distance from the
  upstream branch, stashes, untracked weight with the largest offenders, and
  `*.backup.bundle` / `*.git.backup` artifacts with their age and whether they predate
  `HEAD`. It only reads: no writes, no deletions, and no network unless `--fetch` is
  passed, the distance otherwise coming from the remote-tracking refs already stored.
  `--dirty-only` narrows the report to what needs attention.
- A test environment for `standalone/`, so tier 2 scripts are no longer covered by the CI
  smoke run alone. The global runner discovers it like any other suite; the scripts
  themselves still run without instantiation. `sysinfo` gains coverage of its
  `/proc/cpuinfo` parsing and its revision lookup.
- `reference-runs/`: the datasets of eight `--stress` runs on eight accelerators of four
  vendors, one directory per device, with a README recording the hardware, the shared
  configuration and the outcome of each run. They are the provenance of the README
  figures and the evidence behind the backend status table. The Apple M4 is the first
  arm64 host of the set and the only run produced off Linux.
- `Backends.vendor_blas_types(backend)`: the element types whose `mul!` reaches the vendor
  library, asked of the backend instead of read from one fixed set.
- `plot-benchmarks --compare [DIR]`: two cross-host figures from every dataset under a
  directory. The accelerator figure stacks the throughput of the library engine, the
  throughput of the tiled KernelAbstractions kernel and their ratio on one element-type
  axis, marking the types served by the generic fallback; the host figure draws the
  speedup and the parallel efficiency of every host processor on one thread axis. Devices
  are pooled across datasets and the size is the largest one measured in all of them.
- `plot-benchmarks --px-per-unit N`, overriding `[figures].px_per_unit` for one export,
  and `[input].comparison_directory` in the configuration.

### Changed

- Every GPU extension of `HardwareDiagnostics` has now run on hardware: four NVIDIA
  devices, two AMD devices, one Intel integrated GPU and one Apple M4, all three engines
  each. The cross-engine verification passed 158 comparisons with none failed; `Float64`
  is absent on Metal, so the M4 contributes 18 of them rather than 20. No unexecuted
  backend code remains.
- The README figures are the two cross-host figures; the single-host throughput figure
  they replace is no longer shipped, the per-dataset figures being the tool's default
  output.
- `plot-benchmarks`: decade tick labels keep one style per axis — plain decimals while
  the axis stays between 10⁻³ and 10⁴, powers of ten otherwise, with 10⁰ and 10¹ always
  written `1` and `10`; ranges narrower than three decades add the 2× and 5×
  intermediates.

### Fixed

- `HardwareDiagnostics` 0.3.2: the library label of a benchmark point assumed that every
  backend serves the BLAS element types and only those, which mislabels Metal twice over —
  it dispatches `Float16` to an Apple GEMM and supports no `Float64` at all. Vendor
  coverage is now a method on the backend, which the Metal extension overrides. The three
  affected fields of the `apple-m4` dataset were corrected to the value the fixed code
  emits; the `library` column is a pure function of engine, backend and element type and
  carries no measurement, so every other field of that file is unchanged.
- `plot-benchmarks`: an element type a device could not measure was joined by a straight
  segment drawn across it, which reads as a measured point at the gap; lines now break
  there. Beyond the seven hues of the palette an eighth device repeated the first one's
  colour, so the marker and the line style vary once the palette wraps, and the grouped
  legend takes one column per backend instead of overflowing the figure width.
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
