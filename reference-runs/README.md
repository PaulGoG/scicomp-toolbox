# reference-runs

Datasets of the `hardware-diagnostics` runs that validate the accelerator backends and
that the two cross-host figures of the repository README are drawn from. One directory
per accelerator, holding the `.csv` of the run; the file name carries the run timestamp.

```
reference-runs/
├── arc-graphics-155h/        # Intel Arc integrated GPU, oneAPI
├── radeon-pro-w7900/         # AMD Radeon Pro W7900, ROCm
├── rtx-2080-super-max-q/     # NVIDIA RTX 2080 Super Max-Q, CUDA
├── rtx-5070-ti/              # NVIDIA RTX 5070 Ti, CUDA
├── rtx-5090/                 # NVIDIA RTX 5090, CUDA
└── tesla-t4/                 # NVIDIA Tesla T4, CUDA
```

All six runs were produced on 2026-09-11 from the same source revision, with the same
command and the same configuration, so the datasets differ only in hardware:

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
| `rtx-2080-super-max-q` | NVIDIA GeForce RTX 2080 Super Max-Q | CUDA | 13.3.0 | 48 | 7.6 GiB | Intel Core i7-10750H | 6 / 12 | 6 |
| `tesla-t4` | NVIDIA Tesla T4 | CUDA | 12.9.0 | 40 | 14.6 GiB | AMD EPYC 7551P | 32 / 64 | 32 |
| `arc-graphics-155h` | Intel Arc integrated GPU | oneAPI (Level Zero) | 1.3.38308 | 128 | 28.5 GiB (shared) | Intel Core Ultra 7 155H | 16 / 22 | 11 |

Common to every run: Julia 1.13.0, KernelAbstractions 0.9.42, OpenBLAS (ILP64),
x86_64-linux-gnu. The RTX 5090 and the Radeon Pro W7900 sit in the same workstation, which
is why their host rows coincide; the cross-host figures keep one series per distinct
processor.

The `.toml` provenance sidecar and the `.log` report of each run are not committed: they
record host names and absolute paths of the machines they ran on. Everything the figures
and the tables above need is in the `.csv`.

## Outcome

Every point of every run carries `status = "ok"` except CPU points the time predictor
skipped at N = 4096 (recorded as `skipped: predicted ... exceeds max_point_seconds`); no
point failed. The cross-engine verification passed on all six machines, 20 comparisons
each: both kernel engines against `mul!` for the five element types on the host and on
the accelerator, exact equality for integers and a relative deviation at most 8·√eps(T)
for floating-point types (largest observed: 2.9·10⁻³ for `Float16`, 3.8·10⁻⁷ for
`Float32`, 7.4·10⁻¹⁶ for `Float64`).

## Figures

```bash
julia run.jl plot-benchmarks --compare                       # PDF into plot-benchmarks/plots/
julia run.jl plot-benchmarks --compare --format png --px-per-unit 3 --out-dir /tmp/figures
cp /tmp/figures/cross_host_*_N4096.png assets/               # the figures of the README
```

`--compare` searches this directory recursively, pools the datasets by device and draws
both cross-host figures at the largest problem size measured in every dataset (4096). An
existing file is never overwritten, which is why the README figures are rendered
elsewhere and copied over.
