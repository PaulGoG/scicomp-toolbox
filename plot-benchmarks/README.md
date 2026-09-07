# plot-benchmarks

Publication figures from `hardware-diagnostics` datasets: the CPU thread-scaling sweep
(speedup and parallel efficiency against BLAS thread count) and the throughput of every
engine per element type and device.

```
plot-benchmarks/
├── activate.jl              # environment activation
├── config.toml              # input location and figure settings, validated on load
├── Manifest.toml            # pinned dependencies (CairoMakie, CSV, DataFrames, MathTeXEngine)
├── plot-benchmarks.jl       # entry point and plotting functions
├── Project.toml
├── README.md
└── test/
    └── runtests.jl          # settings, discovery, figures on a synthetic dataset, rendering
```

## Usage

```bash
julia run.jl plot-benchmarks                                  # newest dataset of ../hardware-diagnostics/data
julia run.jl plot-benchmarks --input path/to/hardware_benchmark_<stamp>.csv
julia run.jl plot-benchmarks --format png --out-dir /tmp/figures
julia run.jl plot-benchmarks --size 1024                      # throughput figure at N = 1024
```

Figures are written to `plots/` (ignored by git) as `<dataset stem>_thread_scaling.<fmt>`
and `<dataset stem>_throughput_N<N>.<fmt>`; the dataset stem carries the run timestamp,
so each figure traces back to the dataset and its provenance sidecar. Existing files are
never overwritten (`#1`, `#2`, ... suffixes).

## Figures

**Thread scaling.** Two stacked panels sharing the thread axis (log₂): speedup
S(t) = t₁/t_t with the dashed ideal S = t, and parallel efficiency E(t) = S(t)/t with
the dashed 100 % reference. One series per problem size; hollow markers mark thread
counts above the physical core count when the dataset was produced with
`thread_sweep_ceiling = "logical"`.

**Throughput per element type.** One panel per device (CPU first, then accelerators) at
the largest measured problem size unless `--size` is given. Bars, one per engine and
element type, carry their value in GOP/s (10⁹ operations per second; an operation is a
flop for floating-point types) on a logarithmic axis. On the CPU the library engine is
shown at its largest thread count within the physical cores; failed and skipped points
are absent.

Exports are sized at the configured printed width (178 mm double column by default), at
one point per unit for PDF and SVG and at `px_per_unit` pixels per point for PNG.

## Configuration

```toml
[input]
dataset_directory = "../hardware-diagnostics/data"  # path; relative to this tool; the newest hardware_benchmark_*.csv is used unless --input is given

[figures]
format = "pdf"  # one of: "pdf" | "png" | "svg"
width_mm = 178.0  # float in [60, 300]; printed figure width (double column 178 to 183 mm)
px_per_unit = 5  # integer >= 1; raster export only (5 gives about 360 dpi at 178 mm)
fontsize_pt = 9.0  # float in [6, 14]
output_directory = "plots"  # path; relative to this tool
```

## Tests

```bash
julia test.jl plot-benchmarks
```
