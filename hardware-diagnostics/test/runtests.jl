#!/usr/bin/env julia
# ==============================================================================
# Unit Test Suite: Hardware Diagnostics & High-Intensity Benchmark Suite
# ==============================================================================

using Test
using LinearAlgebra
using TOML
using KernelAbstractions

# Include the source implementation without executing main()
include(joinpath(@__DIR__, "..", "hardware-diag.jl"))

@testset "Hardware Diagnostics & Benchmark Suite" begin

    @testset "Formatting Utilities" begin
        # IEC Byte conversions
        @test format_bytes(0) == "0.00 B"
        @test format_bytes(1023) == "1023.00 B"
        @test format_bytes(1024) == "1.00 KiB"
        @test format_bytes(1024^2) == "1.00 MiB"
        @test format_bytes(1024^3) == "1.00 GiB"
        @test format_bytes(1024^4) == "1.00 TiB"

        # Duration formatting
        @test format_seconds(0.5) == "0.500 s"
        @test format_seconds(65.0) == "01m 05s"
        @test format_seconds(125.0) == "02m 05s"
        @test format_seconds(-1.0) == "--:--"
        @test format_seconds(NaN) == "--:--"
        @test format_seconds(Inf) == "--:--"

        # Throughput formatting
        @test occursin("GFLOPS", format_throughput(500.0, Float32))
        @test occursin("TFLOPS", format_throughput(1500.0, Float32))
        @test occursin("GOP/s", format_throughput(500.0, Int32))
        @test occursin("TOP/s", format_throughput(1500.0, Int64))
    end

    @testset "Configuration & Constraint Validation" begin
        valid_dict = Dict{String, Any}(
            "benchmark" => Dict{String, Any}(
                "mode" => "standard",
                "compute_engine" => "both",
                "problem_sizes" => [512, 1024],
                "trials" => 3,
                "target_types" => ["Float32", "Float64"],
                "run_cpu" => true,
                "run_gpu" => false,
                "gpu_backend" => "auto"
            ),
            "safety" => Dict{String, Any}(
                "memory_safety_fraction" => 0.75
            ),
            "output" => Dict{String, Any}(
                "export_csv" => true,
                "export_metadata" => true,
                "output_directory" => ".",
                "log_to_file" => false
            )
        )

        cfg = validate_config(valid_dict)
        @test cfg isa BenchmarkConfig
        @test cfg.problem_sizes == [1024, 2048] # standard preset defaults
        @test cfg.trials == 3
        @test cfg.compute_engine == "both"

        # Constraint violations
        bad_mode = deepcopy(valid_dict)
        bad_mode["benchmark"]["mode"] = "invalid_mode"
        @test_throws ArgumentError validate_config(bad_mode)

        bad_engine = deepcopy(valid_dict)
        bad_engine["benchmark"]["compute_engine"] = "invalid_engine"
        @test_throws ArgumentError validate_config(bad_engine)

        bad_backend = deepcopy(valid_dict)
        bad_backend["benchmark"]["gpu_backend"] = "invalid_backend"
        @test_throws ArgumentError validate_config(bad_backend)

        bad_trials = deepcopy(valid_dict)
        bad_trials["benchmark"]["mode"] = "custom"
        bad_trials["benchmark"]["trials"] = 0
        @test_throws ArgumentError validate_config(bad_trials)

        bad_sizes = deepcopy(valid_dict)
        bad_sizes["benchmark"]["problem_sizes"] = [-512]
        @test_throws ArgumentError validate_config(bad_sizes)

        bad_mem = deepcopy(valid_dict)
        bad_mem["safety"]["memory_safety_fraction"] = 1.5
        @test_throws ArgumentError validate_config(bad_mem)
    end

    @testset "CLI Argument Parsing" begin
        base_dir = joinpath(@__DIR__, "..")

        # Preset parsing
        cfg_quick = parse_cli_args(["--quick"], base_dir)
        @test cfg_quick.mode == "quick"
        @test cfg_quick.problem_sizes == [512, 1024]
        @test cfg_quick.trials == 2

        cfg_ka = parse_cli_args(["--ka-only"], base_dir)
        @test cfg_ka.compute_engine == "ka"

        cfg_blas = parse_cli_args(["--engine", "blas"], base_dir)
        @test cfg_blas.compute_engine == "blas"

        cfg_backend = parse_cli_args(["--gpu-backend", "oneapi"], base_dir)
        @test cfg_backend.gpu_backend == "oneapi"

        cfg_custom = parse_cli_args(["--sizes", "256,512", "--trials", "4"], base_dir)
        @test cfg_custom.problem_sizes == [256, 512]
        @test cfg_custom.trials == 4

        cfg_cpu = parse_cli_args(["--cpu-only"], base_dir)
        @test cfg_cpu.run_cpu == true
        @test cfg_cpu.run_gpu == false

        cfg_gpu = parse_cli_args(["--gpu-only"], base_dir)
        @test cfg_gpu.run_cpu == false
        @test cfg_gpu.run_gpu == true

        @test_throws ArgumentError parse_cli_args(["--unknown-flag"], base_dir)
    end

    @testset "Memory Footprint & Arithmetic Operations" begin
        # 4 matrices of size N x N x sizeof(T)
        @test estimate_matrix_bytes(1024, Float32) == 4 * 1024 * 1024 * 4
        @test estimate_matrix_bytes(512, Float64) == 4 * 512 * 512 * 8
        @test estimate_matrix_bytes(512, Int8) == 4 * 512 * 512 * 1

        # 4 * N^3 operations for dual GEMM accumulation
        @test arithmetic_ops(Float32, 1024) == 4.0 * 1024^3
        @test arithmetic_ops(Float64, 512) == 4.0 * 512^3
        @test arithmetic_ops(ComplexF32, 512) == 16.0 * 512^3
    end

    @testset "KernelAbstractions CPU Numerical Correctness" begin
        cpu_b = KernelAbstractions.CPU()
        N = 64

        # 1. Float32 test
        A_f32 = create_matrix(Float32, N)
        B_f32 = create_matrix(Float32, N)
        C_f32 = create_matrix(Float32, N)
        D_f32 = similar(A_f32)

        k_f32! = gemm_accum_kernel!(cpu_b, (16, 16))
        k_f32!(D_f32, A_f32, B_f32, C_f32, N; ndrange=(N, N))
        KernelAbstractions.synchronize(cpu_b)

        expected_f32 = A_f32 * (B_f32 + C_f32)
        @test isapprox(D_f32, expected_f32; rtol=1e-5, atol=1e-5)

        # 2. Float64 test
        A_f64 = create_matrix(Float64, N)
        B_f64 = create_matrix(Float64, N)
        C_f64 = create_matrix(Float64, N)
        D_f64 = similar(A_f64)

        k_f64! = gemm_accum_kernel!(cpu_b, (16, 16))
        k_f64!(D_f64, A_f64, B_f64, C_f64, N; ndrange=(N, N))
        KernelAbstractions.synchronize(cpu_b)

        expected_f64 = A_f64 * (B_f64 + C_f64)
        @test isapprox(D_f64, expected_f64; rtol=1e-12, atol=1e-12)

        # 3. Integer test
        A_i32 = create_matrix(Int32, N)
        B_i32 = create_matrix(Int32, N)
        C_i32 = create_matrix(Int32, N)
        D_i32 = similar(A_i32)

        k_i32! = gemm_accum_kernel!(cpu_b, (16, 16))
        k_i32!(D_i32, A_i32, B_i32, C_i32, N; ndrange=(N, N))
        KernelAbstractions.synchronize(cpu_b)

        expected_i32 = A_i32 * (B_i32 + C_i32)
        @test D_i32 == expected_i32
    end

    @testset "Hardware Discovery Sanity" begin
        # System scan outputs to buffer without error
        buf = IOBuffer()
        @test (scan_cpu_and_system(buf); true)
        output_str = String(take!(buf))
        @test occursin("CPU Architecture", output_str)
        @test occursin("Julia Version", output_str)
        @test occursin("BLAS Configuration", output_str)

        # GPU probe runs without error
        gpus = probe_all_gpus(buf, "auto")
        @test gpus isa Vector{GpuDeviceInfo}
    end

    @testset "Data Exporters & File Safekeeping" begin
        mktempdir() do tmp_dir
            # Test record export
            rec = BenchmarkRecord(
                "CPU", "OpenBLAS", "VendorBLAS", "Mock CPU", "Float32", 512, 4,
                536870912.0, 4.5, 4.6, 4.65, 0.1, 2.5, 119.3, 1.0, 100.0, 1.0, 1.0
            )
            csv_path = joinpath(tmp_dir, "test_output.csv")
            export_records_to_csv([rec], csv_path)
            @test isfile(csv_path)

            lines = readlines(csv_path)
            @test length(lines) == 2
            @test occursin("device_type", lines[1])
            @test occursin("VendorBLAS", lines[2])

            # Test metadata export
            cfg = parse_cli_args(["--quick"], joinpath(@__DIR__, ".."))
            toml_path = joinpath(tmp_dir, "test_meta.toml")
            export_metadata_to_toml(cfg, GpuDeviceInfo[], toml_path)
            @test isfile(toml_path)
            parsed_toml = TOML.parsefile(toml_path)
            @test haskey(parsed_toml, "provenance")
            @test haskey(parsed_toml, "configuration")

            # Safekeeping check (collision appends #1)
            f1 = joinpath(tmp_dir, "test_file.log")
            write(f1, "data")
            f2 = get_safe_filepath(f1)
            @test f2 == joinpath(tmp_dir, "test_file#1.log")
        end
    end

end
