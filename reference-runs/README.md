# reference-runs

Datasets of the `hardware-diagnostics` runs that validate the accelerator backends and
that the two cross-host figures of the repository README are drawn from. One directory
per accelerator, holding the `.csv` of the run; the file name carries the run timestamp.

```
reference-runs/
├── apple-m4/                 # Apple M4 integrated GPU, Metal
├── arc-graphics-155h/        # Intel Arc integrated GPU, oneAPI
├── radeon-pro-w7900/         # AMD Radeon Pro W7900, ROCm
├── radeon-rx-7700-xt/        # AMD Radeon RX 7700 XT, ROCm
├── rtx-2080-super-max-q/     # NVIDIA RTX 2080 Super Max-Q, CUDA
├── rtx-5070-ti/              # NVIDIA RTX 5070 Ti, CUDA
├── rtx-5090/                 # NVIDIA RTX 5090, CUDA
└── tesla-t4/                 # NVIDIA Tesla T4, CUDA
```

All eight runs were produced on 2026-09-11 from the same source revision, command and
configuration; apart from the M4 (macOS) and the Tesla T4 (CUDA 12.9), they differ only
in hardware:

```bash
julia run.jl hardware-diagnostics --stress
```

That is `problem_sizes = [1024, 2048, 4096]` with the shipped `config.toml`: element
types `Float16, Float32, Float64, Int32, Int64`, engines `blas, ka, ka_tiled`, seed
`20260907`, memory safety fraction `0.75`, sampling at least 3 evaluations and 0.5 s per
point and at most 30, points predicted above 60 s per evaluation skipped, thread sweep up
to the physical core count, cross-engine verification at N = 64.

| Directory | Accelerator | Backend | Driver | Compute units | Device memory | Host processor | Cores / threads | BLAS threads |
| :--- | :--- | :--- | :--- | ---: | ---: | :--- | :--- | ---: |
| `rtx-5090` | NVIDIA GeForce RTX 5090 | CUDA | 13.3.0 | 170 | 31.4 GiB | AMD Ryzen 9 9950X | 16 / 32 | 16 |
| `rtx-5070-ti` | NVIDIA GeForce RTX 5070 Ti | CUDA | 13.3.0 | 70 | 15.5 GiB | Intel Core i9-13900KS | 24 / 32 | 16 |
| `radeon-pro-w7900` | AMD Radeon Pro W7900 | AMDGPU (ROCm/HIP) | 7.1.52802 | 48 | 45.0 GiB | AMD Ryzen 9 9950X | 16 / 32 | 16 |
| `radeon-rx-7700-xt` | AMD Radeon RX 7700 XT | AMDGPU (ROCm/HIP) | 7.1.52802 | 27 | 12.0 GiB | AMD Ryzen 9 5950X | 16 / 32 | 16 |
| `rtx-2080-super-max-q` | NVIDIA GeForce RTX 2080 Super Max-Q | CUDA | 13.3.0 | 48 | 7.6 GiB | Intel Core i7-10750H | 6 / 12 | 6 |
| `tesla-t4` | NVIDIA Tesla T4 | CUDA | 12.9.0 | 40 | 14.6 GiB | AMD EPYC 7551P | 32 / 64 | 32 |
| `apple-m4` | Apple M4 integrated GPU | Metal | 4.0 (MSL) | 10 ᵃ | 11.8 GiB (unified) | Apple M4 | 10 / 10 | 4 |
| `arc-graphics-155h` | Intel Arc integrated GPU | oneAPI (Level Zero) | 1.3.38308 | 128 | 28.5 GiB (shared) | Intel Core Ultra 7 155H | 16 / 22 | 11 |

ᵃ Metal exposes no compute-unit count; the GPU core count reported by `Metal.versioninfo`
stands in, and `compute_units` is `0` in the provenance sidecar.

Common to every run: Julia 1.13.0, KernelAbstractions 0.9.42, OpenBLAS (ILP64). Seven
hosts are x86_64-linux-gnu; the Apple M4 is arm64-apple-darwin25.6.0 and the only run of
the set produced off Linux. The RTX 5090 and the Radeon Pro W7900 sit in the same
workstation, so their host rows coincide; the cross-host figures keep one series per
distinct processor.

The `.toml` provenance sidecar and the `.log` report of each run are not committed: they
record host names and absolute paths of the machines they ran on. Everything the figures
need is in the `.csv`; the table above was compiled from the sidecars.

## Outcome

The cross-engine verification passed everywhere it could run: **158 comparisons, none
failed**. Both kernel engines are checked against `mul!` for every element type on the
host and on the accelerator: 20 comparisons per machine, and 18 on the M4, whose GPU has
no `Float64`. Integers agree exactly and floating-point types stay within 8·√eps(T),
the tolerance of the version that ran them; the largest deviations observed are
3.5·10⁻³ for `Float16`, 3.8·10⁻⁷ for `Float32` and 8.0·10⁻¹⁶ for `Float64`.

Every benchmark point carries `status = "ok"` apart from three groups:

- CPU points the cubic time predictor skipped at N = 4096, recorded as
  `skipped: predicted ... exceeds max_point_seconds`.
- The nine `Float64` points of the M4 (three sizes × three engines), recorded as
  `failed: Metal does not support Float64 values`. Metal has no double precision; the run
  reports the refusal per point and does not abort the stage.
- Thirty-six host points of the M4, skipped because free host memory had fallen to about
  75 MiB when the element-type stage set its budget (56.07 MiB); the machine had 1014 MiB
  free when the run started. Its thread sweep at N = 4096 is complete; its element-type
  stage is complete only at N = 1024. The M4 dataset therefore has 75 measured points of
  120, and the M4 host contributes to the thread-scaling figure but not to the throughput
  panels above N = 1024.

**Two labels were corrected in `apple-m4` after the run.** The three `Float16` rows of the
Metal device were written `GPUArrays generic` by a defect in the version that produced
them: vendor coverage came from one fixed type set that assumed every backend serves the
BLAS types and only those. Metal does not: `MPS_VALID_MATMUL_TYPES` and
`MPSGRAPH_VALID_MATMUL_TYPES` both carry the `(Float16, Float16)` pair, so `mul!` reached
an Apple GEMM, consistent with the measured 3.45 TOP/s. `vendor_blas_types` asks
the backend since 0.3.2, and those three fields now read `Metal Performance Shaders`, as
the fixed code writes them. The same defect labelled the three failed `Float64` library
rows `Metal Performance Shaders`, which has no double precision; they now read
`GPUArrays generic`, as 0.3.2 and later write them.

The corrections touch only the `library` annotation, a pure function of engine, backend
and element type that carries no measurement. Every other field of the file, timings and
throughputs included, is byte-identical to what the run wrote, and the untouched original
is kept outside this repository with the run's `.toml` and `.log`.

## Figures

```bash
julia run.jl plot-benchmarks --compare                       # PDF into plot-benchmarks/plots/
julia run.jl plot-benchmarks --compare --format png --px-per-unit 3 --out-dir /tmp/figures
cp /tmp/figures/cross_host_*_N4096.png assets/               # the figures of the README
```

`--compare` searches this directory recursively, pools the datasets by device and draws
both cross-host figures at the largest problem size measured in every dataset (4096). An
existing file is never overwritten, so the README figures are rendered elsewhere and
copied over.

In the accelerator figure the library leads the tiled kernel by 3.9 to 5.5× at `Float32`
on the six discrete cards. The two integrated GPUs bracket that range: Apple's MPS is
9.9× ahead of the portable kernel, while on the Intel Arc oneMKL is 6 % behind it. At
`Float64` the portable kernel comes within 15 % of the library on five of the seven
devices that have it and passes it on the RTX 5090 and RTX 5070 Ti, whose `Float64` rate
is 1/64 of `Float32`. rocBLAS stays a factor two ahead on both AMD cards. Metal carries no
double precision, and the M4 line has a gap there. Where `mul!` has no vendor GEMM and
falls back to the generic GPUArrays path, the portable kernel leads by 1.05 to 8.1× on the
seven devices other than the M4. On the M4, Metal routes `Float16` to an Apple GEMM (the
filled marker), and at `Int32` the generic fallback beats the tiled kernel by 8 %.
