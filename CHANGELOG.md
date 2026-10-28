# Changelog

Notable changes to the workbench. The repository itself carries no version; the
`HardwareDiagnostics` package follows semantic versioning and its version is given where
a change belongs to it.

## 2026-10-28

### Added

- `run-index`: catalogue of DrWatson-style run directories. For each run it reports the
  commit, configuration, hardware, wall time and disk usage read from its TOML provenance
  file through configurable key aliases, so earlier key layouts are understood. It flags
  missing or unreadable provenance, commits that are unknown, dirty or off HEAD, seed
  replicates and repeats, and lists the figures whose run directory has gone. Read-only;
  tested against a synthetic workspace with real git history built at test time.

### Changed

- `HardwareDiagnostics` 0.4.0: one module instead of eleven submodules, the source files
  being plain includes. The extensions add `probe_accelerator(::Val{name})` methods
  instead of registering closures from `__init__`; a backend requested by name that
  yields no device is reported as not loaded or not functional.
- `HardwareDiagnostics` 0.4.0: the benchmark is a plan of `BenchmarkPoint`s
  (`benchmark_plan`) executed by `run_benchmark_plan`, which replace
  `run_cpu_thread_sweep`, `run_cpu_multitype` and `run_accelerator_benchmarks`. The
  dataset gains a leading `stage` column (`thread_sweep`, `element_types`,
  `accelerator`). Every point is extrapolated from the previous size of its own series,
  so the sweep no longer drops a size at every thread count when only its one-thread
  point is predicted too slow. Accelerator speedups refer to the element-type stage for
  every type, `Float32` included.
- `HardwareDiagnostics` 0.4.0: integer operands are ±1, which bounds the partial sums by
  2N instead of 32N and admits `Int16` up to N = 16383. The operands come from one
  generator per element type and size, derived from the seed, so they do not depend on
  the size list and are the same on every engine and device.
- `HardwareDiagnostics` 0.4.0: the cross-engine verification requires each kernel to
  agree with `mul!` within twice the componentwise rounding-error bound
  γ(2N+2)·|A|(|B| + |C|), with √2 for complex types (Higham 2002,
  doi:10.1137/1.9780898718027), instead of a normwise 8·√eps(T). The log reports the
  deviation as a fraction of the bound. `verification_size` is at most 1022 with
  `Float16`.
- `hardware-diagnostics` and `sysinfo` count physical cores from the sysfs CPU topology
  (`core_cpus_list`, or `thread_siblings_list` before Linux 5.3), which covers arm64.
- `plot-benchmarks` classifies rows by the `stage` column when the dataset has one.
- `plot-benchmarks` on CSV 1.1 and CairoMakie 0.15.16; `standalone` declares its
  `Printf` and `Test` compat.
- The device-level reading of the accelerator figure moved from the README to
  `reference-runs/README.md`.

### Fixed

- `HardwareDiagnostics` 0.4.0: the device operands of a point or a verification that
  fails are released at once, through `release_device_array!` and each package's
  `unsafe_free!`, instead of being left to the finalizers.
- `reference-runs`: the three failed `Float64` library rows of `apple-m4` read
  `GPUArrays generic`, as the code writes them since 0.3.2; no other field changed.

## 2026-10-26

### Added

- `formatter/format.jl`: the formatting program shared by `check.jl` and the CI gate, with
  `--check` to report differences without applying them.
- CI tests the declared Julia 1.12 floor alongside the current release.
- `hardware-diagnostics` tests run the accelerator stage on a host-backed mock device
  (allocation-limit skip and speedup paths) and `discover_accelerators` on a registered
  probe.
- `plot-benchmarks` validates `--size` against the measured sizes and names the flag of a
  value that does not parse.
- `workspace-audit` flags `untracked` and `stash`, and warns when `--fetch` fails instead
  of silently using the stored refs.

### Changed

- `run.jl --new` is removed; a new tool starts as a pruned copy of `plot-benchmarks/`.
  The dispatcher no longer instantiates a tool's environment in a separate process, the
  entry points doing so themselves.
- `hardware-diagnostics`: `verification_size` defaults to 72, so the padded edge tiles of
  the tiled kernel and the partial work-groups of the naive kernel are part of the
  cross-engine check. `Int8` is no longer offered, its accumulation bound exceeding
  `typemax(Int8)` at every admissible size. A command-line value that does not parse
  names its flag; a TOML syntax error, a missing default `config.toml` and duplicate
  sizes or types are rejected with an `ArgumentError`. `--out-dir` resolves against the
  working directory.
- `plot-benchmarks`: one builder draws both thread-scaling figures, so the per-dataset
  and the cross-host figure share layout, palette fallback and notation
  (S(p) = T₁/T_p). Each cross-host figure chooses its problem size from the rows it
  draws. The throughput figure prefers the element-type stage row over the sweep row at
  the top thread count, shortens device names and omits the legend for a single engine.
  Paths given on the command line resolve against the working directory.
- Dependabot watches `standalone/`; the test environment of `hardware-diagnostics`
  declares its `julia` compat, which stops the spurious stdlib bounds it proposed.
- Manifests resolved on Julia 1.13.3 with KernelAbstractions 0.9.45; actions pinned to
  julia-actions/cache 3.5.0 and setup-julia 3.0.3.
- `hardware-diagnostics` writes its TOML sidecar before the benchmark stages and its CSV
  dataset one row per completed point, flushed as it goes, so a run interrupted by a
  signal, an OOM kill or a scheduler limit keeps its provenance and every measured point.
- KernelAbstractions stays on 0.9 (0.9.45): 0.10 replaces the CPU backend by an OpenCL
  backend on PoCL, which changes what the host kernel engines measure, so adopting it is a
  migration to be decided rather than a bump; Dependabot ignores its minor updates. The
  GPU weak dependencies are bounded to their last series on 0.9 (CUDA 6.4, AMDGPU 2.9,
  Metal 1.11, oneAPI 2.9), the later ones requiring 0.10.

### Fixed

- The three root scripts reported a child killed by a signal as passed, `exitcode` being
  0 for a signalled process; they now test `success` and exit with 128 plus the signal.
- `hardware-diagnostics`: a point stopped by `max_point_seconds` after one sample
  reported a median absolute deviation and a dispersion of 0; both are now empty for
  single-sample points. Datasets written before this version carry 0 there. The warm-up
  evaluation is timed and bounds the cost of a point; an N = 4096 kernel point could run
  four times past the cap.
- `plot-benchmarks`: intermediate ticks of a logarithmic axis outside 10⁻³ to 10⁴ were
  labelled with the nearest power of ten, 2×10⁴ reading 10⁴; labels now carry their
  mantissa in one style per axis. Value labels showed four significant digits near
  100 and 10. A comparison set without accelerator rows aborted instead of skipping the
  figure. The caption of the host figure claimed Float32 and complete sweeps whatever
  the data.
- `workspace-audit`: the porcelain status output was stripped before parsing, so the
  first entry of a dirty repository could be lost and the repository reported clean.
  Git runs with `--no-optional-locks`, so the tool no longer writes `index.lock`. The
  suggested removal command is shell-quoted. A repository without a remote is no longer
  flagged for having no upstream.
- `sysinfo` labels the revision it reports as that of the toolbox checkout.

### Removed

- `TimingSummary.mean_s`, the dead `NON_TOOL_ENVIRONMENTS` of `test.jl` and
  `SuiteResult.exit_code`.

## 2026-09-12

### Changed

- `workspace-audit` searches two levels below the root by default, with `--depth N` to
  choose another; the one-level walk assumed each project directory was itself a
  repository and found nothing in a layout that keeps the repository one level down. The
  walk stops at every repository it meets and reports each entry by its path relative to
  the root, so repositories of the same name are distinguished. An area with no
  repository beneath it is named in the summary.
- The `authors` field of `HardwareDiagnostics` gives the name without an e-mail address,
  matching the copyright line of the LICENSE.

## 2026-09-11

### Added

- `workspace-audit` (tier 2): the git and artifact state of every project directory under
  a workspace root in one command — branch, working-tree cleanliness, distance from the
  upstream branch, stashes, untracked weight with the largest offenders, and
  `*.backup.bundle` / `*.git.backup` artifacts with their age and whether they predate
  `HEAD`. It writes and deletes nothing and uses the network only when `--fetch` is
  passed; otherwise the distance comes from the remote-tracking refs already stored.
  `--dirty-only` narrows the report to what needs attention.
- A test environment for `standalone/`, so tier 2 scripts are no longer covered by the CI
  smoke run alone. The global runner discovers it like any other suite; the scripts
  themselves still run without instantiation. `sysinfo` gains coverage of its
  `/proc/cpuinfo` parsing and its revision lookup.
- `reference-runs/`: the datasets of eight `--stress` runs on eight accelerators of four
  vendors, one directory per device, with a README recording the hardware, the shared
  configuration and the outcome of each run. They are the provenance of the README
  figures and the evidence behind the backend status table. The Apple M4 is the only
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
  is absent on Metal, so the M4 contributes 18 of them rather than 20.
- The README figures are the two cross-host figures; the single-host throughput figure
  they replace is no longer shipped. Per-dataset figures remain the tool's default output.
- `plot-benchmarks`: decade tick labels keep one style per axis — plain decimals while
  the axis stays between 10⁻³ and 10⁴, powers of ten otherwise, with 10⁰ and 10¹ always
  written `1` and `10`; ranges narrower than three decades add the 2× and 5×
  intermediates.

### Fixed

- `HardwareDiagnostics` 0.3.2: the library label of a benchmark point assumed that every
  backend serves the BLAS element types and only those. Metal dispatches `Float16` to an
  Apple GEMM and supports no `Float64`, so both were mislabelled. Vendor coverage is now a
  method on the backend, which the Metal extension overrides. The three affected fields of
  the `apple-m4` dataset were corrected to the value the fixed code emits; the `library`
  column carries no measurement, and every other field of that file is unchanged.
- `plot-benchmarks`: an element type a device could not measure was bridged by a straight
  segment, as if it had been measured; lines now break there. Beyond the seven hues of
  the palette an eighth device repeated the first one's colour; the marker and the line
  style now vary once the palette wraps. The grouped legend takes one column per backend
  instead of overflowing the figure width.
- `plot-benchmarks`: the ideal reference S = t of the thread-scaling figure was drawn as
  a two-point segment, a chord of the curve on the logarithmic thread axis; it is now
  sampled along the axis.

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
