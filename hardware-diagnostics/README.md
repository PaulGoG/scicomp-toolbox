# Hardware Diagnostics & High-Intensity Benchmark Suite

Platform introspection, hardware capability profiling, and heterogeneous compute benchmarking suite for Julia.

## Directory Structure

```
hardware-diagnostics/
├── activate.jl         # Pure-Julia silent environment activator
├── config.toml         # TOML runtime configuration and safety parameters
├── hardware-diag.jl    # Self-contained diagnostic and benchmarking executable
├── Manifest.toml       # Pinned dependency lockfile
├── Project.toml        # Isolated package dependencies & compat bounds
├── README.md           # Documentation and operational manual
└── test/
    └── runtests.jl     # Unit test suite (61 assertions across utilities, config, and CPU kernels)
```

## Overview

The suite profiles host system hardware and benchmarks dual General Matrix Multiply-Accumulate (GEMM) operations across host CPU threads and attached GPU accelerators:

$$\mathbf{D} \leftarrow \mathbf{A}\mathbf{B} + \mathbf{A}\mathbf{C} = \mathbf{A}(\mathbf{B} + \mathbf{C})$$

Each test evaluation executes $4N^3$ arithmetic operations ($2N^3$ floating-point or integer operations per matrix product) using pre-allocated buffers to achieve zero runtime heap allocations in benchmark loops.

### Architecture-Agnostic Computing with `KernelAbstractions.jl`

The benchmark suite implements a completely backend-agnostic computational kernel using `KernelAbstractions.jl`:

```julia
@kernel function gemm_accum_kernel!(D, @Const(A), @Const(B), @Const(C), N)
    i, j = @index(Global, NTuple)
    acc = zero(eltype(D))
    for k in 1:N
        @inbounds acc += A[i, k] * (B[k, j] + C[k, j])
    end
    @inbounds D[i, j] = acc
end
```

This single kernel definition is compiled natively across all supported hardware backends without any architecture-specific branching:

| Target Platform | Accelerator Package | KernelAbstractions Backend | Vendor BLAS Engine |
| :--- | :--- | :--- | :--- |
| **Host CPU** | `Base.Threads` | `KernelAbstractions.CPU()` | OpenBLAS / MKL (`LinearAlgebra.mul!`) |
| **Intel Arc / Data Center** | `oneAPI.jl` | `oneAPI.oneAPIBackend()` | Intel oneMKL (`oneArray`) |
| **NVIDIA CUDA** | `CUDA.jl` | `CUDA.CUDABackend()` | NVIDIA cuBLAS (`CuArray`) |
| **AMD ROCm / HIP** | `AMDGPU.jl` | `AMDGPU.ROCBackend()` | AMD rocBLAS (`ROCArray`) |
| **Apple Silicon Metal** | `Metal.jl` | `Metal.MetalBackend()` | Metal Performance Shaders (`MtlArray`) |

### Dual Compute Engines (`--engine both | ka | blas`)

1. **`KernelAbstractions` (`ka`)**: Pure portable Julia kernels compiled via LLVM/SPIR-V/PTX/MetalIR across CPU and GPU backends. Particularly effective for integer arithmetic (`Int8`, `Int16`) and custom mathematical structures.
2. **`VendorBLAS` (`blas`)**: Hardware vendor assembly-tuned libraries (`oneMKL`, `cuBLAS`, `rocBLAS`, `MPS`, `OpenBLAS`).
3. **`both` (default)**: Evaluates both engines side-by-side, providing compiler efficiency ratios ($\eta = \text{GFLOPS}_{\text{KA}} / \text{GFLOPS}_{\text{BLAS}} \times 100\%$) and cross-device speedup metrics.

### Key Capabilities

- **Deep Hardware Discovery**:
  - **CPU**: Topology, physical cores, logical threads, instantaneous clock rates, Linux vector instruction sets (`fma`, `avx`, `avx2`, `sse4_2`), threadpool distribution, system RAM, and linear algebra engine (`LBTConfig`, ILP64/LP64).
  - **GPU**: Device identification, compute units (EUs, SMs, or CUs), concurrent hardware thread capacity, clock frequency, VRAM / unified memory capacity, maximum buffer allocation limits, timer resolution, and driver/toolkit versions.
  - **KernelAbstractions.jl**: Active abstraction backend mappings (`oneAPIBackend`, `CUDABackend`, `ROCBackend`, `MetalBackend`).
- **In-Place GEMM Kernels**: Pre-allocated device and host buffers eliminate garbage collector latency and memory reallocation overhead.
- **CPU Parallel Scaling**: Evaluates scaling across powers of 2 up to maximum logical threads, computing speedup factor $S(t) = t_1 / t_t$ and parallel efficiency $E(t) = S(t) / t$.
- **Multi-Precision & Multi-Type Evaluation**: Evaluates `Float16`, `Float32`, `Float64`, `Int8`, `Int16`, `Int32`, and `Int64` on CPU and GPU.
- **Memory Safety Guard**: Pre-flight memory footprint check prevents out-of-memory terminations by skipping configurations that exceed a specified fraction of available RAM or GPU buffer limits.
- **Structured Multi-Format Exports**: Emits formatted human-readable `.log` reports, tidy `.csv` datasets for downstream analysis, and structured `.toml` metadata recording platform provenance.

## Command-Line Usage

```bash
# Display help and options
julia --project=. hardware-diag.jl --help

# Fast diagnostic run (dimensions: 512, 1024 | 2 trials)
julia --project=. hardware-diag.jl --quick

# Standard benchmark (dimensions: 1024, 2048 | 3 trials) [default]
julia --project=. hardware-diag.jl

# Exhaustive stress test (dimensions: 1024, 2048, 4096 | 5 trials)
julia --project=. hardware-diag.jl --stress

# Select compute engine
julia --project=. hardware-diag.jl --engine ka         # Pure KernelAbstractions.jl native kernels
julia --project=. hardware-diag.jl --engine blas       # Vendor-optimized BLAS libraries
julia --project=. hardware-diag.jl --engine both       # Benchmark both side-by-side [default]

# Select specific GPU accelerator backend
julia --project=. hardware-diag.jl --gpu-backend oneapi
julia --project=. hardware-diag.jl --gpu-backend cuda
julia --project=. hardware-diag.jl --gpu-backend amdgpu
julia --project=. hardware-diag.jl --gpu-backend metal
julia --project=. hardware-diag.jl --gpu-backend all

# Custom problem dimensions and repetitions
julia --project=. hardware-diag.jl --sizes 512,1024,2048 --trials 3

# Target specific numeric data types
julia --project=. hardware-diag.jl --types Float32,Float64

# Isolate execution target
julia --project=. hardware-diag.jl --cpu-only
julia --project=. hardware-diag.jl --gpu-only

# Specify external configuration file
julia --project=. hardware-diag.jl --config config.toml
```

## Running the Unit Test Suite

```bash
julia --project=. test/runtests.jl
```

## Configuration (`config.toml`)

Parameters can be specified via `config.toml` in the script directory or passed via `--config`:

```toml
[benchmark]
mode = "standard"  # one of: "quick" | "standard" | "stress" | "custom"
compute_engine = "both"  # one of: "both" | "ka" | "blas"
problem_sizes = [1024, 2048]  # list of positive integers (N × N matrix dimension)
trials = 3  # integer in [1, 50] (measurement repetitions per test point)
target_types = ["Float16", "Float32", "Float64", "Int8", "Int16", "Int32", "Int64"]  # subset of supported Julia numeric types
run_cpu = true  # boolean
run_gpu = true  # boolean
gpu_backend = "auto"  # one of: "auto" | "all" | "oneapi" | "cuda" | "amdgpu" | "metal"

[safety]
memory_safety_fraction = 0.75  # float in (0.0, 0.95] (fraction of available memory ceiling)

[output]
export_csv = true  # boolean
export_metadata = true  # boolean
output_directory = "."  # destination path string
log_to_file = true  # boolean
```

## Output Files

Each execution creates timestamped provenance-backed artifacts:
- `hardware_benchmark_<timestamp>.log`: Detailed formatted text report containing system topology, GPU discovery details, thread scaling tables, side-by-side engine metrics, and speedup ratios.
- `hardware_benchmark_<timestamp>.csv`: Tidy tabular dataset with columns: `device_type,backend,kernel_engine,device_name,data_type,matrix_dim,num_threads,total_ops,min_time_ms,median_time_ms,mean_time_ms,std_time_ms,jitter_pct,throughput_gflops,speedup_vs_1t,parallel_efficiency_pct,speedup_vs_cpu_1t,speedup_vs_cpu_maxt`.
- `hardware_benchmark_<timestamp>.toml`: Structured machine-readable provenance metadata (Julia version, commit, BLAS engine, KernelAbstractions version, hardware topology, GPU driver/hardware specs, and run configuration).
