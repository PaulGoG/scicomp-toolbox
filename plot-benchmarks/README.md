# plot-benchmarks

Publication figures from `hardware-diagnostics` datasets. From one dataset: the CPU
thread-scaling sweep (speedup and parallel efficiency against BLAS thread count) and the
throughput of every engine per element type and device. From several (`--compare`): the
accelerators and the host processors of all of them, side by side.

```
plot-benchmarks/
├── activate.jl              # environment activation
├── config.toml              # input location and figure settings, validated on load
├── Manifest.toml            # pinned dependencies (CairoMakie, CSV, DataFrames, MathTeXEngine)
├── plot-benchmarks.jl       # entry point and plotting functions
├── Project.toml
├── README.md
└── test/
    └── runtests.jl          # settings, discovery, figures on synthetic datasets, rendering
```

## Usage

```bash
julia run.jl plot-benchmarks                                  # newest dataset of ../hardware-diagnostics/data
julia run.jl plot-benchmarks --input path/to/hardware_benchmark_<stamp>.csv
julia run.jl plot-benchmarks --format png --out-dir /tmp/figures
julia run.jl plot-benchmarks --size 1024                      # throughput figure at N = 1024
julia run.jl plot-benchmarks --compare                        # every dataset under ../reference-runs
julia run.jl plot-benchmarks --compare /scratch/runs --px-per-unit 3
```

Figures are written to `plots/` (ignored by git) as `<dataset stem>_thread_scaling.<fmt>`
and `<dataset stem>_throughput_N<N>.<fmt>`; the dataset stem carries the run timestamp,
so each figure traces back to the dataset and its provenance sidecar. With `--compare`
the names are `cross_host_accelerators_N<N>.<fmt>` and `cross_host_hosts_N<N>.<fmt>`.
Existing files are never overwritten (`#1`, `#2`, ... suffixes).

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

**Accelerators across machines** (`--compare`). Three stacked panels sharing the
element-type axis: the throughput of the library engine, the throughput of the tiled
KernelAbstractions kernel, and their ratio against a parity line, one series per
accelerator of the compared datasets. The two throughput panels share their limits, so
the vertical distance between them is the gap the portable kernel has to close. Hollow
markers in the library panel mark the element types the device has no vendor GEMM for,
which `mul!` serves from the generic GPUArrays path.

**Host processors across machines** (`--compare`). Speedup and parallel efficiency of the
library engine against the BLAS thread count, one series per host processor, with the
ideal references. Each series ends at the physical core count of its host.

Both comparison figures are drawn at the largest problem size measured in every compared
dataset, unless `--size` is given. Datasets are pooled by device: a processor or
accelerator that appears in several of them contributes one series, taken from the first
dataset that carries it.

Exports are sized at the configured printed width (178 mm double column by default), at
one point per unit for PDF and SVG and at `px_per_unit` pixels per point for PNG
(`--px-per-unit` overrides the configured value; the README figures of the repository are
rendered at 3).

## Configuration

```toml
[input]
dataset_directory = "../hardware-diagnostics/data"  # path; relative to this tool; the newest hardware_benchmark_*.csv is used unless --input is given
comparison_directory = "../reference-runs"  # path; relative to this tool; searched recursively for the datasets of --compare

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
