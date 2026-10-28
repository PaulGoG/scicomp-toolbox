# hardware-diagnostics

Host and accelerator introspection with a dual-GEMM throughput benchmark. One operation,
D = A·B + A·C on dense N × N operands, is executed through three engines on every
available device: `LinearAlgebra.mul!`, which reaches the BLAS-class library of the
device (OpenBLAS or MKL on the host; oneMKL, cuBLAS, rocBLAS or Metal Performance Shaders
on accelerators), a naive KernelAbstractions kernel, and a tiled KernelAbstractions
kernel with local-memory staging. The package `HardwareDiagnostics` implements the tool;
GPU backends attach through package extensions. Figures are produced by the
`plot-benchmarks` tool.

```
hardware-diagnostics/
├── activate.jl                        # environment activation
├── config.toml                        # parameters, validated on load
├── hardware-diagnostics.jl            # entry point
├── Manifest.toml                      # pinned dependencies (KernelAbstractions and stdlib)
├── Project.toml                       # package, weak dependencies and extensions
├── README.md
├── ext/
│   ├── HardwareDiagnosticsAMDGPUExt.jl
│   ├── HardwareDiagnosticsCUDAExt.jl
│   ├── HardwareDiagnosticsMetalExt.jl
│   └── HardwareDiagnosticsoneAPIExt.jl
├── src/
│   ├── HardwareDiagnostics.jl         # module, imports, exports, includes
│   ├── backends.jl                    # accelerator probes and loading, labels
│   ├── formatting.jl                  # bytes, durations, throughputs
│   ├── kernels.jl                     # the operation on every engine, operands, verification
│   ├── sampling.jl                    # time-budgeted sampling, min/median/MAD
│   ├── config.jl                      # TOML schema, constraints, command line
│   ├── host.jl                        # CPU topology, thread sweep, host report
│   ├── reporting.jl                   # console and log sinks, progress line
│   ├── benchmark.jl                   # benchmark plan and its execution
│   ├── export.jl                      # CSV dataset, TOML sidecar, collision-free paths
│   └── driver.jl                      # orchestration
└── test/
    ├── Project.toml                   # Aqua, ExplicitImports, JET, Test
    └── runtests.jl
```

## Measurement

**Operation and operation count.** All engines perform the same arithmetic: two
accumulating products, `D = A·B` then `D += A·C`. The library path issues two `mul!`
calls; both kernels accumulate `A[i,k]·B[k,j]` and `A[i,k]·C[k,j]` separately in their
inner loop. Every point is credited with the nominal count 4N³ (16N³ for complex element
types), so throughput ratios between engines compare equal work. The naive kernel (`ka`)
is a plain triple loop reading global memory; the tiled kernel (`ka_tiled`) lets each
16 × 16 work-group stage 16 × 16 tiles of A, B and C in local memory and accumulate tile
by tile, with zero padding for dimensions that are not multiples of 16. The ratio of
either kernel to the vendor library measures the gap between a portable kernel of that
algorithmic class and a tuned library, not compiler quality.

**Verification.** Before benchmarking, every configured kernel engine and the `mul!`
reference run on the same operands of size `verification_size` for every element type on
every device, and each kernel result is compared with the reference entry by entry. In
the standard model of floating-point arithmetic each result lies within
γₘ·|A|(|B| + |C|) of the exact D, with γₘ = mu/(1 − mu), m = 2N + 2 and u the unit
roundoff of T, and within √2 times that for complex types (Higham 2002, §3.1 and §3.6,
doi:[10.1137/1.9780898718027](https://doi.org/10.1137/1.9780898718027)); the bound holds
for any summation order and with fused multiply-adds. Two correct results therefore
differ by at most twice the bound, and the log reports the largest deviation as a
fraction of it; integers must agree exactly. A deviation above the bound aborts the run.
The bound is a worst case. Observed deviations are about 1 % of it at N = 72, and for
`Float16` it is comparable to the entries of D themselves, so there the check detects
only gross errors. No bound of this form exists once (2N + 2)·u ≥ 1, which limits
`verification_size` to 1022 when `Float16` is configured. Element types the library
cannot multiply on a device are reported as unverifiable and fail as individual points.
The default `verification_size = 72` is not a multiple of the 16 × 16 tile, so the
padded edge tiles of the tiled kernel and the partial work-groups of the naive kernel
are part of the check.

**Sampling.** Each point is evaluated once for compilation and first touch, then
repeatedly until at least `min_samples` evaluations have consumed `min_sampling_time_s`
seconds, at most `max_samples` times. The dataset records the minimum, the median and
the median absolute deviation; throughput is reported from the minimum (peak) and from
the median. Before a point runs, its single-evaluation time is predicted from the
previous problem size of the same series by cubic extrapolation and the point is skipped
when the prediction exceeds `max_point_seconds`. The same cap bounds the sampling time of
a point, so a slow point may stop after a single evaluation; the warm-up evaluation is
timed, and when it alone exceeds the cap the point is recorded from that one evaluation.
A point with one sample carries no dispersion: its `mad_time_ms` and `dispersion_pct`
cells are empty. Points whose four operands exceed
`memory_safety_fraction` of the free host memory, or of the device memory, are skipped, as
are device points with one operand above the device's maximum allocation.

**Operands.** Floating-point and complex entries are standard normal, integer entries
±1 with equal probability, so every partial sum of an entry of D is bounded by 2N in
magnitude. The configuration is rejected when this bound exceeds `typemax(T)` for any
configured size: `Int8` is therefore not offered and `Int16` requires N ≤ 16383. Each
element type and size has its own generator derived from `seed`, so a point multiplies
the same operands on every engine and device, whatever other points the run contains.
Integer points through `mul!` run on the generic fallback of LinearAlgebra (host) or
GPUArrays (device), as the `library` column states; `Float16` on the host likewise.

**Stages.** The run is planned as one list of points and executed in order; the `stage`
column of the dataset names the stage of each row (`thread_sweep`, `element_types`,
`accelerator`).

1. *CPU thread scaling*: Float32 through the library engine over the thread counts of
   the sweep, powers of two up to the ceiling plus the ceiling itself. The default
   ceiling is the physical core count, the number of distinct cores in the sysfs CPU
   topology (Linux, x86 and arm64; the logical count elsewhere). With `thread_sweep_ceiling = "logical"` the sweep continues to the logical
   thread count, and points above the physical count are marked (`*` in the report,
   `exceeds_physical_cores` in the dataset) because they oversubscribe hyper-threads.
   Speedup S(p) = T₁/T_p and parallel efficiency E(p) = S(p)/p, with T_p the time at p
   threads, refer to the one-thread point of the same size and are empty when that
   point was not measured.
2. *CPU element types*: every configured type, the library engine at one thread and at
   the sweep ceiling, the kernel engines on the Julia thread pool. The pool size is fixed
   at process start (`julia run.jl --threads N ...`) and recorded in `julia_threads`.
3. *Accelerators*: every functional device, every configured engine, with speedups
   against the CPU library points of stage 2 at one thread and at the sweep ceiling.

## Accelerator backends

`Project.toml` lists `CUDA`, `AMDGPU`, `Metal` and `oneAPI` as weak dependencies. Install
the package matching the hardware into the default environment, for example

```bash
julia -e 'using Pkg; Pkg.add("oneAPI")'
```

The entry point loads the packages selected by `gpu_backend` when they are present in the
load path (`auto` tries every backend applicable to the operating system), the
corresponding extension adds the device probe of its backend, and functional devices
enter the run. A backend requested by name that is missing or not functional produces a
warning and the run continues on the remaining devices. Because the GPU package comes
from the default environment, its version is not pinned by this tool's manifest; the
provenance sidecar records the package's `versioninfo` output for that reason. The
`[compat]` entries bound each GPU package to its last series on KernelAbstractions 0.9
(CUDA 6.4, AMDGPU 2.9, Metal 1.11, oneAPI 2.9). KernelAbstractions 0.10, which the later
series require, moves the CPU backend to PoCL and is not admitted yet.

| Backend | Package | Status |
| :--- | :--- | :--- |
| NVIDIA CUDA | `CUDA` | run on an RTX 5090, an RTX 5070 Ti, an RTX 2080 Super Max-Q and a Tesla T4 |
| AMD ROCm (HIP) | `AMDGPU` | run on a Radeon Pro W7900 and a Radeon RX 7700 XT |
| Intel oneAPI (Level Zero) | `oneAPI` | run on an Intel Arc integrated GPU (Core Ultra 7 155H) |
| Apple Metal | `Metal` | run on an Apple M4; `Float64` is unsupported by the API |

Every backend has run `--stress` with all three engines, and the cross-engine
verification passed on every device: 158 comparisons, none failed. All five element types
were covered except `Float64` on Metal, which carries no double precision; a `Float64`
point there fails with the framework's own message and the remaining stages continue.
The datasets are in `reference-runs/`, whose README records the hardware, the
configuration and the outcome of each run.

Which element types reach the vendor library depends on the backend, so
`vendor_blas_types` is a method the extensions override. The BLAS-class
backends cover `Float32`, `Float64`, `ComplexF32` and `ComplexF64`; Metal dispatches
`Float16` to an Apple GEMM and has no `Float64`.

## Usage

```bash
julia run.jl hardware-diagnostics --help
julia run.jl hardware-diagnostics                              # sizes of config.toml, all engines, auto backend
julia run.jl hardware-diagnostics --quick --cpu-only           # N = 512, 1024 on the host
julia run.jl hardware-diagnostics --stress --gpu-backend oneapi
julia run.jl hardware-diagnostics --sizes 512,1024,2048 --types Float32,Float64 --engines ka,ka_tiled
julia run.jl hardware-diagnostics --threads-ceiling logical    # expose hyper-thread oversubscription
julia run.jl hardware-diagnostics --min-time 2 --max-samples 100 --seed 1
julia run.jl hardware-diagnostics --config other.toml --out-dir /scratch/runs --no-hostname
julia --project=hardware-diagnostics hardware-diagnostics/hardware-diagnostics.jl --quick   # without the dispatcher
```

Presets set the problem sizes only (`--quick`: 512, 1024; `--standard`: 1024, 2048;
`--stress`: 1024, 2048, 4096); every other parameter comes from the configuration file
and the remaining options.

## Configuration

`config.toml` next to the entry point is read by default; `--config FILE` replaces it and
the command-line options apply on top. Unknown keys are rejected.

```toml
[benchmark]
engines = ["blas", "ka", "ka_tiled"]  # non-empty subset of: "blas" | "ka" | "ka_tiled"
problem_sizes = [1024, 2048]  # positive integers, N of the N × N operands; CLI presets replace this list
target_types = ["Float16", "Float32", "Float64", "Int32", "Int64"]  # subset of: Float16 | Float32 | Float64 | ComplexF32 | ComplexF64 | Int16 | Int32 | Int64
seed = 20260907  # integer >= 0; seeds the operand generator

[sampling]
min_sampling_time_s = 0.5  # float > 0 [s]; sampling continues until this budget and min_samples are both met
min_samples = 3  # integer >= 1
max_samples = 30  # integer in [min_samples, 10000]
max_point_seconds = 60.0  # float > 0 [s]; a point predicted above this per evaluation is skipped; also caps the sampling time of a point, overriding min_samples

[hardware]
run_cpu = true  # boolean
gpu_backend = "auto"  # one of: "none" | "auto" | "oneapi" | "cuda" | "amdgpu" | "metal"
thread_sweep_ceiling = "physical"  # one of: "physical" | "logical"
verify_kernels = true  # boolean; cross-engine check against mul! before benchmarking (componentwise rounding-error bound; exact for integers)
verification_size = 72  # integer in [8, 1024], at most 1022 with Float16; not a multiple of 16, so the tiled kernel's padded edge tiles are exercised

[safety]
memory_safety_fraction = 0.75  # float in (0.0, 0.95]; usable fraction of free host memory or of device memory

[output]
export_csv = true  # boolean
export_metadata = true  # boolean
output_directory = "data"  # path; a relative path resolves against the tool directory
log_to_file = true  # boolean
record_hostname = true  # boolean
```

## Outputs

Each run writes three files named `hardware_benchmark_<timestamp>.*` into the output
directory; an existing file is never overwritten (`#1`, `#2`, ... suffixes). The sidecar
is written before the benchmark stages and the dataset grows by one row as each point
completes, so an interrupted run keeps its provenance and every measured point.

- `.log`: the report as printed to the console, without progress line or escape
  sequences: host and accelerator sections, verification, the three stages, summary.
- `.csv`: one row per planned point, skipped and failed points included, with the
  columns `stage, device_type, backend, engine, library, device_name, data_type,
  matrix_dim, julia_threads, blas_threads, exceeds_physical_cores, nominal_ops, samples,
  min_time_ms, median_time_ms, mad_time_ms, dispersion_pct, throughput_gops,
  throughput_median_gops, speedup_vs_1t, parallel_efficiency_pct, speedup_vs_cpu_1t,
  speedup_vs_cpu_maxt, status`. Undefined quantities and inapplicable thread counts are
  empty cells; `engine` is `blas`, `ka` or `ka_tiled`; `library` names what executed the
  point (the BLAS library and its integer interface, `LinearAlgebra generic`,
  `GPUArrays generic`, `KernelAbstractions naive` or `KernelAbstractions tiled`);
  `status` is `ok`, `skipped: <reason>` or `failed: <error>`. `mad_time_ms` and
  `dispersion_pct` are empty for single-sample points.
- `.toml`: provenance sidecar with the host fingerprint (CPU model, physical and logical
  counts, thread pools, BLAS library, memory, ISA flags, Julia and KernelAbstractions
  versions, toolbox commit), the effective configuration and the accelerator inventory
  including the GPU package's `versioninfo` report.

## Tests

```bash
julia test.jl hardware-diagnostics
julia --project=hardware-diagnostics -e 'using Pkg; Pkg.test()'
```

The suite runs Aqua, ExplicitImports and JET on the package, then unit tests of both
kernels (against `A*B + A*C`, including sizes that are not multiples of the tile), the
sampling rule, the configuration constraints, the command line, the host topology, the
backend probes, the benchmark plan at N = 32, the accelerator stage on a host-backed
mock device (allocation-limit skip and speedup paths) and an end-to-end run into a
temporary directory.
