"""
    HardwareDiagnostics

Host and accelerator introspection together with a dual-GEMM throughput benchmark
executed through two engines: a portable KernelAbstractions kernel and the linear
algebra library reached through `LinearAlgebra.mul!` (OpenBLAS or MKL on the host,
the vendor library on accelerators). GPU backends attach through the package
extensions `HardwareDiagnostics{CUDA,AMDGPU,Metal,oneAPI}Ext`, which activate when the
corresponding package is loaded in the session.
"""
module HardwareDiagnostics

include("Backends.jl")
using .Backends
export AcceleratorDevice, discover_accelerators, load_accelerator_packages

include("Formatting.jl")
using .Formatting
export format_bytes, format_seconds, format_throughput

include("Kernels.jl")
using .Kernels
export dual_gemm_kernel!,
    launch_dual_gemm!,
    dual_gemm_blas!,
    nominal_ops,
    footprint_bytes,
    create_matrix,
    integer_range_safe,
    verify_engines

include("Sampling.jl")
using .Sampling
export SamplingPolicy, TimingSummary, sample_timings, summarize_timings

include("Config.jl")
using .Config
export BenchmarkConfig, validate_config, load_config, parse_cli_args, usage_text

include("Host.jl")
using .Host
export HostInfo, host_info, physical_core_count, thread_sweep

include("Reporting.jl")
using .Reporting
export Reporter

include("Benchmark.jl")
using .Benchmark
export BenchmarkRecord, run_cpu_thread_sweep, run_cpu_multitype, run_accelerator_benchmarks

include("Export.jl")
using .Export
export export_records_to_csv, export_metadata_to_toml, safe_filepath

include("Driver.jl")
using .Driver
export configure, run_diagnostics

end
