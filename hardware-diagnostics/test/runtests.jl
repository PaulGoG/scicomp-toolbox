using HardwareDiagnostics
using Test
using Aqua
using ExplicitImports
using JET
using KernelAbstractions: KernelAbstractions, CPU
using LinearAlgebra: BLAS
using Random: Xoshiro
using TOML: TOML

const HD = HardwareDiagnostics
const TOOL_DIR = normpath(joinpath(@__DIR__, ".."))

"Configuration dictionary of a fast CPU-only run on 32 × 32 operands."
function base_config_dict()
    return Dict{String, Any}(
        "benchmark" => Dict{String, Any}(
            "engines" => ["blas", "ka", "ka_tiled"],
            "problem_sizes" => [32],
            "target_types" => ["Float32", "Int32"],
            "seed" => 7,
        ),
        "sampling" => Dict{String, Any}(
            "min_sampling_time_s" => 1e-3,
            "min_samples" => 2,
            "max_samples" => 4,
            "max_point_seconds" => 10.0,
        ),
        "hardware" => Dict{String, Any}(
            "run_cpu" => true,
            "gpu_backend" => "none",
            "thread_sweep_ceiling" => "physical",
            "verify_kernels" => true,
            "verification_size" => 16,
        ),
        "safety" => Dict{String, Any}("memory_safety_fraction" => 0.5),
        "output" => Dict{String, Any}(
            "export_csv" => true,
            "export_metadata" => true,
            "output_directory" => ".",
            "log_to_file" => true,
            "record_hostname" => false,
        ),
    )
end

function altered(mutate!)
    dictionary = base_config_dict()
    mutate!(dictionary)
    return dictionary
end

"Run `f` with stdout captured to a string."
function capture_stdout(f)
    return mktempdir() do dir
        path = joinpath(dir, "stdout.txt")
        result = open(path, "w") do io
            redirect_stdout(f, io)
        end
        return result, read(path, String)
    end
end

@testset "HardwareDiagnostics" begin
    @testset "Static QA" begin
        Aqua.test_all(HardwareDiagnostics)
        @test ExplicitImports.check_no_implicit_imports(HardwareDiagnostics) === nothing
        @test ExplicitImports.check_no_stale_explicit_imports(HardwareDiagnostics) ===
              nothing
        for submodule in (
            HD.Backends,
            HD.Formatting,
            HD.Kernels,
            HD.Sampling,
            HD.Config,
            HD.Host,
            HD.Reporting,
            HD.Benchmark,
            HD.Export,
            HD.Driver,
        )
            @test ExplicitImports.check_no_implicit_imports(submodule) === nothing
            @test ExplicitImports.check_no_stale_explicit_imports(submodule) === nothing
        end
        @test ExplicitImports.check_all_explicit_imports_via_owners(HardwareDiagnostics) ===
              nothing
        report = JET.report_package(
            HardwareDiagnostics;
            target_modules = (
                HardwareDiagnostics,
                HD.Backends,
                HD.Formatting,
                HD.Kernels,
                HD.Sampling,
                HD.Config,
                HD.Host,
                HD.Reporting,
                HD.Benchmark,
                HD.Export,
                HD.Driver,
            ),
        )
        # The launch of a KernelAbstractions kernel on a GPU backend has no method until a
        # GPU package is loaded (the backend packages define it), so JET reports the GPU
        # branch of the `Kernel{<:Backend}` union split in `launch_dual_gemm!` as a missing
        # method. That branch is unreachable without a loaded backend and is the one
        # accepted artifact per kernel engine.
        reports = filter(JET.get_reports(report)) do r
            !(
                r isa JET.MethodErrorReport &&
                occursin("KernelAbstractions.Kernel", sprint(show, r))
            )
        end
        isempty(reports) || show(stdout, MIME"text/plain"(), report)
        @test isempty(reports)
        @test length(JET.get_reports(report)) <= length(HD.Kernels.KERNEL_ENGINES)
    end

    @testset "Formatting" begin
        @test format_bytes(0) == "0.00 B"
        @test format_bytes(1023) == "1023.00 B"
        @test format_bytes(1024) == "1.00 KiB"
        @test format_bytes(1024^2) == "1.00 MiB"
        @test format_bytes(1024^3) == "1.00 GiB"
        @test format_bytes(1024^4) == "1.00 TiB"
        @test format_seconds(0.5) == "0.500 s"
        @test format_seconds(65.0) == "01m 05s"
        @test format_seconds(125.0) == "02m 05s"
        @test format_seconds(-1.0) == "--:--"
        @test format_seconds(NaN) == "--:--"
        @test format_seconds(Inf) == "--:--"
        @test format_throughput(500.0, Float32) == "500.00 GFLOP/s"
        @test format_throughput(1500.0, Float64) == "1.50 TFLOP/s"
        @test format_throughput(500.0, Int32) == "500.00 GOP/s"
        @test format_throughput(1500.0, Int64) == "1.50 TOP/s"
        @test format_throughput(2.0, ComplexF32) == "2.00 GFLOP/s"
    end

    @testset "Kernels and operation counts" begin
        @test nominal_ops(Float32, 1024) == 4.0 * 1024^3
        @test nominal_ops(ComplexF32, 512) == 16.0 * 512^3
        @test footprint_bytes(1024, Float32) == 4 * 1024 * 1024 * 4
        @test footprint_bytes(512, Int8) == 4 * 512 * 512
        @test HD.Kernels.integer_accumulation_bound(1000) == 32_000
        @test integer_range_safe(Int16, 1023)
        @test !integer_range_safe(Int16, 1024)
        @test integer_range_safe(Int8, 3)
        @test !integer_range_safe(Int8, 4)
        @test integer_range_safe(Int32, 4096)
        @test integer_range_safe(Float16, 100_000)

        rng = Xoshiro(1)
        cpu = CPU()
        for (T, N, rtol) in ((Float32, 64, 1e-4), (Float64, 64, 1e-10), (Float32, 50, 1e-4))
            A, B, C = (create_matrix(rng, T, N) for _ in 1:3)
            reference = A * B + A * C
            @test isapprox(launch_dual_gemm!(cpu, similar(A), A, B, C), reference; rtol)
            @test isapprox(
                launch_dual_gemm_tiled!(cpu, similar(A), A, B, C),
                reference;
                rtol,
            )
            @test isapprox(dual_gemm_blas!(cpu, similar(A), A, B, C), reference; rtol)
        end
        for (T, N) in ((Int32, 64), (Int64, 40), (Int32, 17), (Int64, 100))
            A, B, C = (create_matrix(rng, T, N) for _ in 1:3)
            reference = A * B + A * C
            @test launch_dual_gemm!(cpu, similar(A), A, B, C) == reference
            @test launch_dual_gemm_tiled!(cpu, similar(A), A, B, C) == reference
            @test evaluate_engine!(:ka_tiled, cpu, similar(A), A, B, C) == reference
            @test dual_gemm_blas!(cpu, similar(A), A, B, C) == reference
        end
        for T in (Float16, Float32, Float64, ComplexF32, ComplexF64, Int32, Int64)
            results = verify_engines(cpu, T, 64, rng)

            @test length(results) == 2

            @test [r.engine for r in results] == [:ka, :ka_tiled]

            @test all(r -> r.passed && r.max_relative_deviation <= r.tolerance, results)
        end
        @test HD.Kernels.verification_tolerance(Int32) == 0.0
        @test HD.Kernels.TILE == 16
        @test_throws ArgumentError verify_engines(cpu, Float32, 32, rng; engines = (:blas,))
        @test_throws ArgumentError evaluate_engine!(
            :cublas,
            cpu,
            zeros(2, 2),
            zeros(2, 2),
            zeros(2, 2),
            zeros(2, 2),
        )
        @test length(verify_engines(cpu, Float64, 40, rng; engines = (:ka_tiled,))) == 1
        @test HD.Kernels.verification_tolerance(Float64) ≈ 8 * sqrt(eps(Float64))
        @test HD.Kernels.verification_tolerance(ComplexF32) ≈ 8 * sqrt(eps(Float32))
        @test all(1 .<= create_matrix(rng, Int8, 16) .<= 4)
        @test eltype(create_matrix(rng, ComplexF64, 4)) === ComplexF64
    end

    @testset "Sampling" begin
        policy = SamplingPolicy(;
            min_sampling_time_s = 1e-6,
            min_samples = 3,
            max_samples = 10,
            max_point_seconds = 10.0,
        )
        @test 3 <= length(sample_timings(() -> nothing, policy)) <= 10
        capped = SamplingPolicy(;
            min_sampling_time_s = 100.0,
            min_samples = 1,
            max_samples = 4,
            max_point_seconds = 100.0,
        )
        @test length(sample_timings(() -> nothing, capped)) == 4
        budget = SamplingPolicy(;
            min_sampling_time_s = 100.0,
            min_samples = 50,
            max_samples = 100,
            max_point_seconds = 0.02,
        )
        @test length(sample_timings(() -> sleep(0.011), budget)) <= 3
        summary = summarize_timings([1.0, 2.0, 3.0, 4.0, 100.0])
        @test summary.samples == 5
        @test summary.min_s == 1.0
        @test summary.median_s == 3.0
        @test summary.mad_s == 1.0
        @test summary.mean_s == 22.0
        @test_throws ArgumentError summarize_timings(Float64[])
        @test_throws ArgumentError SamplingPolicy(;
            min_sampling_time_s = 0.0,
            min_samples = 1,
            max_samples = 1,
            max_point_seconds = 1.0,
        )
        @test_throws ArgumentError SamplingPolicy(;
            min_sampling_time_s = 1.0,
            min_samples = 5,
            max_samples = 4,
            max_point_seconds = 1.0,
        )
    end

    @testset "Configuration" begin
        config = validate_config(base_config_dict())
        @test config isa BenchmarkConfig
        @test config.problem_sizes == [32]
        @test config.preset == "config"
        @test config.engines == [:blas, :ka, :ka_tiled]
        @test config.target_types == [Float32, Int32]
        @test config.gpu_backend === :none
        @test config.sampling.max_samples == 4
        @test config.output_directory == "."
        @test !config.record_hostname

        @test_throws ArgumentError validate_config(
            altered(d -> d["benchmark"]["engines"] = ["cuda"]),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> d["benchmark"]["engines"] = String[]),
        )
        @test validate_config(altered(d -> d["benchmark"]["engines"] = ["ka", "KA"])).engines ==
              [:ka]
        @test_throws ArgumentError validate_config(
            altered(d -> d["hardware"]["gpu_backend"] = "all"),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> d["benchmark"]["problem_sizes"] = [-512]),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> d["benchmark"]["problem_sizes"] = Int[]),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> d["benchmark"]["problem_sizes"] = [512.5]),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> d["benchmark"]["target_types"] = ["Float128"]),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> d["benchmark"]["seed"] = -1),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> d["sampling"]["max_samples"] = 1),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> d["sampling"]["min_sampling_time_s"] = 0.0),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> d["safety"]["memory_safety_fraction"] = 1.5),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> d["hardware"]["run_cpu"] = "yes"),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> d["hardware"]["thread_sweep_ceiling"] = "all"),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> d["hardware"]["verification_size"] = 4),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> d["hardware"]["run_cpu"] = false),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> d["benchmark"]["trials"] = 3),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> d["extra"] = Dict{String, Any}()),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> d["benchmark"]["target_types"] = ["Int8"]),
        )
        @test_throws ArgumentError validate_config(
            altered(d -> begin
                d["benchmark"]["target_types"] = ["Int16"]
                d["benchmark"]["problem_sizes"] = [1024]
            end),
        )
        @test validate_config(
            altered(d -> begin
                d["benchmark"]["target_types"] = ["Int16"]
                d["benchmark"]["problem_sizes"] = [1000]
            end),
        ) isa BenchmarkConfig
        @test validate_config(altered(d -> begin
            d["hardware"]["run_cpu"] = false
            d["hardware"]["gpu_backend"] = "auto"
        end)).run_cpu == false

        shipped = load_config(joinpath(TOOL_DIR, "config.toml"))
        @test shipped.problem_sizes == [1024, 2048]
        @test shipped.gpu_backend === :auto
        @test shipped.output_directory == "data"
        @test_throws ArgumentError load_config(joinpath(TOOL_DIR, "missing.toml"))
    end

    @testset "Command line" begin
        @test parse_cli_args(["--quick"], TOOL_DIR).problem_sizes == [512, 1024]
        @test parse_cli_args(["--quick"], TOOL_DIR).preset == "quick"
        @test parse_cli_args(["--standard"], TOOL_DIR).preset == "standard"
        @test parse_cli_args(["--stress"], TOOL_DIR).problem_sizes == [1024, 2048, 4096]
        @test parse_cli_args(String[], TOOL_DIR).preset == "config"
        custom = parse_cli_args(
            [
                "--sizes",
                "256, 512",
                "--max-samples",
                "7",
                "--min-samples",
                "2",
                "--min-time",
                "0.25",
                "--max-point-seconds",
                "5",
                "--seed",
                "3",
            ],
            TOOL_DIR,
        )
        @test custom.problem_sizes == [256, 512]
        @test custom.preset == "custom"
        @test custom.sampling.max_samples == 7
        @test custom.sampling.min_samples == 2
        @test custom.sampling.min_sampling_time_s == 0.25
        @test custom.sampling.max_point_seconds == 5.0
        @test custom.seed == 3
        @test parse_cli_args(["--ka-only"], TOOL_DIR).engines == [:ka, :ka_tiled]
        @test parse_cli_args(["--blas-only"], TOOL_DIR).engines == [:blas]
        @test parse_cli_args(["--engines", "blas, ka_tiled"], TOOL_DIR).engines ==
              [:blas, :ka_tiled]
        @test_throws ArgumentError parse_cli_args(["--engines", "cublas"], TOOL_DIR)
        @test parse_cli_args(["--gpu-backend", "oneapi"], TOOL_DIR).gpu_backend === :oneapi
        cpu_only = parse_cli_args(["--cpu-only"], TOOL_DIR)
        @test cpu_only.run_cpu && cpu_only.gpu_backend === :none
        gpu_only = parse_cli_args(["--gpu-only"], TOOL_DIR)
        @test !gpu_only.run_cpu && gpu_only.gpu_backend === :auto
        @test parse_cli_args(["--types", "Float32,Int32"], TOOL_DIR).target_types ==
              [Float32, Int32]
        @test parse_cli_args(["--threads-ceiling", "logical"], TOOL_DIR).thread_sweep_ceiling ===
              :logical
        @test !parse_cli_args(["--no-verify"], TOOL_DIR).verify_kernels
        flags = parse_cli_args(
            [
                "--no-csv",
                "--no-metadata",
                "--no-log",
                "--no-hostname",
                "--out-dir",
                "/tmp/x",
            ],
            TOOL_DIR,
        )
        @test !flags.export_csv && !flags.export_metadata && !flags.log_to_file
        @test !flags.record_hostname && flags.output_directory == "/tmp/x"
        @test_throws ArgumentError parse_cli_args(["--unknown-flag"], TOOL_DIR)
        @test_throws ArgumentError parse_cli_args(["--sizes"], TOOL_DIR)
        @test_throws ArgumentError parse_cli_args(["--sizes", "abc"], TOOL_DIR)
        @test_throws ArgumentError parse_cli_args(["--cpu-only", "--gpu-only"], TOOL_DIR)
        @test_throws ArgumentError parse_cli_args(
            ["--config", joinpath(TOOL_DIR, "missing.toml")],
            TOOL_DIR,
        )
        mktempdir() do dir
            path = joinpath(dir, "alternative.toml")
            write(
                path,
                "[benchmark]\nproblem_sizes = [128]\n[hardware]\ngpu_backend = \"none\"\n",
            )
            alternative = parse_cli_args(["--config", path], TOOL_DIR)
            @test alternative.problem_sizes == [128]
            @test alternative.gpu_backend === :none
            @test alternative.output_directory == "data"
            @test parse_cli_args(["--config", path, "--quick"], TOOL_DIR).problem_sizes ==
                  [512, 1024]
        end
        @test occursin("--gpu-backend", usage_text())
        result, text = capture_stdout(() -> configure(["--help"], TOOL_DIR))
        @test result === nothing
        @test occursin("Usage", text)
        @test configure(["--cpu-only", "--sizes", "16"], TOOL_DIR).problem_sizes == [16]
    end

    @testset "Host" begin
        physical, source = physical_core_count()
        @test 1 <= physical <= Sys.CPU_THREADS
        @test !isempty(source)
        @test thread_sweep(16, 22, :physical) == [1, 2, 4, 8, 16]
        @test thread_sweep(16, 22, :logical) == [1, 2, 4, 8, 16, 22]
        @test thread_sweep(6, 12, :physical) == [1, 2, 4, 6]
        @test thread_sweep(6, 12, :logical) == [1, 2, 4, 6, 8, 12]
        @test thread_sweep(1, 1, :physical) == [1]
        @test thread_sweep(8, 8, :logical) == [1, 2, 4, 8]
        @test_throws ArgumentError thread_sweep(4, 8, :all)
        @test_throws ArgumentError thread_sweep(0, 8, :physical)
        host = host_info(; record_hostname = false)
        @test host.hostname == ""
        @test host_info().hostname == gethostname()
        @test host.physical_cores == physical
        @test host.logical_threads == Sys.CPU_THREADS
        @test host.julia_threads == Threads.nthreads()
        @test host.total_memory_bytes > 0
        @test host.kernel_abstractions_version == string(pkgversion(KernelAbstractions))
        report = sprint(HD.Host.print_host_report, host)
        @test occursin("Physical cores", report)
        @test occursin("BLAS", report)
        @test !occursin("Hostname", report)
        @test occursin("Hostname", sprint(HD.Host.print_host_report, host_info()))
    end

    @testset "Backends" begin
        @test discover_accelerators(:none) == AcceleratorDevice[]
        @test discover_accelerators(:auto) isa Vector{AcceleratorDevice}
        @test_throws ArgumentError discover_accelerators(:all)
        @test load_accelerator_packages(:none) == Symbol[]
        @test_throws ArgumentError load_accelerator_packages(:all)
        if Base.find_package("CUDA") === nothing && !Sys.isapple()
            @test (@test_logs (:warn, r"not installed") load_accelerator_packages(:cuda)) ==
                  Symbol[]
        end
        @test HD.Backends.backend_label(CPU()) == "CPU"
        @test occursin("(", HD.Backends.blas_library_label())
        @test HD.Backends.library_label(:ka, CPU(), Float32) == "KernelAbstractions naive"
        @test HD.Backends.library_label(:ka_tiled, CPU(), Float32) ==
              "KernelAbstractions tiled"
        @test HD.Backends.library_label(:blas, CPU(), Float32) ==
              HD.Backends.vendor_blas_label(CPU())
        @test HD.Backends.library_label(:blas, CPU(), Int32) == "LinearAlgebra generic"
        @test HD.Backends.library_label(:blas, CPU(), Float16) == "LinearAlgebra generic"
        @test HD.Backends.blas_vendor("libopenblas64_.so") == "OpenBLAS"
        @test HD.Backends.blas_vendor("libmkl_rt.so") == "MKL"
        @test HD.Backends.blas_vendor("libcustom.so") == "libcustom.so"
        x = rand(Float32, 4, 4)
        @test HD.Backends.to_device(x, CPU()) === x
        @test HD.Backends.to_device(view(x, 1:2, 1:2), CPU()) isa Matrix{Float32}
        @test HD.Backends.device_fingerprint(CPU()) == ""
        @test HD.Backends.reclaim_device_memory!(CPU()) === nothing
        @test HD.Backends.applies_to_os(:metal) == Sys.isapple()
    end

    @testset "Benchmark stages on the host (N = 32)" begin
        config = validate_config(base_config_dict())
        host = host_info(; record_hostname = false)
        rng = Xoshiro(config.seed)
        total = HD.Benchmark.plan_total_steps(config, host, 0)
        reporter = Reporter(IO[devnull]; total, console = devnull)
        counts = thread_sweep(host.physical_cores, host.logical_threads, :physical)
        reference = unique([1, last(counts)])
        @test total == length(counts) + 2 * (length(reference) + 2)

        sweep = run_cpu_thread_sweep(config, host, rng, reporter)
        @test length(sweep) == length(counts)
        @test all(r -> r.status == "ok", sweep)
        @test all(
            r -> r.engine == "blas" && r.data_type == "Float32" && r.matrix_dim == 32,
            sweep,
        )
        @test sweep[1].blas_threads == 1
        @test sweep[1].speedup_vs_1t ≈ 1.0
        @test sweep[1].parallel_efficiency_pct ≈ 100.0
        @test all(r -> isnan(r.speedup_vs_cpu_1t) && isnan(r.speedup_vs_cpu_maxt), sweep)
        @test all(r -> r.throughput_gops > 0 && r.samples >= 2, sweep)
        @test all(r -> !r.exceeds_physical_cores, sweep)
        @test BLAS.get_num_threads() == host.blas_threads

        multitype = run_cpu_multitype(config, host, rng, reporter)
        @test length(multitype) == 2 * (length(reference) + 2)
        ka = filter(r -> r.engine in ("ka", "ka_tiled"), multitype)
        @test length(ka) == 4
        @test all(r -> r.blas_threads == 0 && r.julia_threads == Threads.nthreads(), ka)
        @test all(r -> startswith(r.library, "KernelAbstractions"), ka)
        @test count(r -> r.library == "KernelAbstractions tiled", ka) == 2
        @test any(
            r -> r.library == "LinearAlgebra generic" && r.data_type == "Int32",
            multitype,
        )
        @test all(
            r -> isnan(r.speedup_vs_1t) && isnan(r.parallel_efficiency_pct),
            multitype,
        )
        @test HD.Benchmark.cpu_reference_time_ms(multitype, Float32, 32, 1) > 0
        @test isnan(HD.Benchmark.cpu_reference_time_ms(multitype, Float64, 32, 1))
        @test reporter.progress.current == total

        tight = validate_config(altered(d -> d["safety"]["memory_safety_fraction"] = 1e-12))
        skipped = run_cpu_thread_sweep(
            tight,
            host,
            rng,
            Reporter(IO[devnull]; total = 1, console = devnull),
        )
        @test length(skipped) == 1
        @test startswith(skipped[1].status, "skipped")
        @test skipped[1].samples == 0 && isnan(skipped[1].min_time_ms)
        @test HD.Benchmark.prediction_reason((32, 2.0), 64, 10.0) !== nothing
        @test HD.Benchmark.prediction_reason((32, 1.0), 64, 10.0) === nothing
        @test HD.Benchmark.prediction_reason(nothing, 64, 10.0) === nothing
        @test HD.Benchmark.memory_reason(32, Float32, 1.0) !== nothing
        @test HD.Benchmark.memory_reason(32, Float32, Inf) === nothing
        summary, status =
            HD.Benchmark.try_measure(:ka, CPU(), Float32, 16, rng, config.sampling)
        @test summary isa TimingSummary && status == "ok"
        @test_throws ArgumentError HD.Benchmark.measure_point(
            :none,
            CPU(),
            Float32,
            16,
            rng,
            config.sampling,
        )
    end

    @testset "Export" begin
        config = validate_config(base_config_dict())
        host = host_info(; record_hostname = false)
        measured = BenchmarkRecord(;
            device_type = "CPU",
            backend = "CPU",
            engine = "blas",
            library = "OpenBLAS (ILP64)",
            device_name = "Mock, CPU",
            data_type = "Float32",
            matrix_dim = 64,
            julia_threads = 4,
            blas_threads = 2,
            nominal_ops = nominal_ops(Float32, 64),
            summary = summarize_timings([0.002, 0.003, 0.0025]),
            speedup_vs_1t = 1.5,
            parallel_efficiency_pct = 75.0,
        )
        skipped = BenchmarkRecord(;
            device_type = "CPU",
            backend = "CPU",
            engine = "ka",
            library = "KernelAbstractions",
            device_name = "Mock",
            data_type = "Int32",
            matrix_dim = 64,
            julia_threads = 4,
            nominal_ops = nominal_ops(Int32, 64),
            status = "skipped: test",
        )
        @test measured.throughput_gops ≈ nominal_ops(Float32, 64) / 0.002 / 1e9
        @test measured.dispersion_pct ≈ 100 * 0.0005 / 0.0025
        @test isnan(skipped.min_time_ms) && skipped.samples == 0
        mktempdir() do dir
            path = joinpath(dir, "records.csv")
            export_records_to_csv([measured, skipped], path)
            lines = readlines(path)
            @test length(lines) == 3
            @test lines[1] == join(string.(fieldnames(BenchmarkRecord)), ",")
            @test occursin("\"Mock, CPU\"", lines[2])
            @test occursin(",,", lines[3])
            @test !occursin("NaN", lines[3])
            @test count(==(','), lines[3]) == length(fieldnames(BenchmarkRecord)) - 1

            metadata = joinpath(dir, "metadata.toml")
            export_metadata_to_toml(
                config,
                host,
                AcceleratorDevice[],
                metadata;
                loaded_backends = Symbol[],
                toolbox_commit = "abc1234",
            )
            text = read(metadata, String)
            @test !occursin("0x", text)
            parsed = TOML.parsefile(metadata)
            @test parsed["provenance"]["toolbox_commit"] == "abc1234"
            @test parsed["provenance"]["hostname"] == ""
            @test parsed["provenance"]["total_memory_bytes"] == host.total_memory_bytes
            @test parsed["provenance"]["physical_cores"] == host.physical_cores
            @test parsed["provenance"]["julia_threads"] == Threads.nthreads()
            @test parsed["configuration"]["sampling"]["max_samples"] == 4
            @test parsed["configuration"]["gpu_backend"] == "none"
            @test parsed["configuration"]["target_types"] == ["Float32", "Int32"]
            @test parsed["accelerators"] == []

            existing = joinpath(dir, "run.log")
            write(existing, "x")
            @test safe_filepath(existing) == joinpath(dir, "run#1.log")
            write(joinpath(dir, "run#1.log"), "y")
            @test safe_filepath(existing) == joinpath(dir, "run#2.log")
            @test safe_filepath(joinpath(dir, "fresh.log")) == joinpath(dir, "fresh.log")
        end
        @test HD.Export.repository_commit(TOOL_DIR) isa String
        @test HD.Export.repository_commit(tempdir()) == "unavailable"
    end

    @testset "End-to-end run on the host (N = 32)" begin
        mktempdir() do dir
            raw = base_config_dict()
            raw["output"]["output_directory"] = dir
            config = validate_config(raw)
            records, console =
                capture_stdout(() -> run_diagnostics(config; base_dir = TOOL_DIR))
            @test !isempty(records)
            @test all(r -> r.status == "ok", records)
            @test occursin("Cross-engine verification", console)
            @test occursin("CPU thread scaling", console)
            @test occursin("throughput", console)
            @test occursin("Completed in", console)
            @test !occursin("\e[", console)
            files = readdir(dir)
            @test count(endswith(".log"), files) == 1
            @test count(endswith(".csv"), files) == 1
            @test count(endswith(".toml"), files) == 1
            log_text = read(joinpath(dir, only(filter(endswith(".log"), files))), String)
            @test occursin("CPU thread scaling", log_text)
            @test !occursin("\e[", log_text)
            csv_lines = readlines(joinpath(dir, only(filter(endswith(".csv"), files))))
            @test length(csv_lines) == length(records) + 1
            metadata = TOML.parsefile(joinpath(dir, only(filter(endswith(".toml"), files))))
            @test metadata["configuration"]["preset"] == "config"
            @test metadata["provenance"]["hostname"] == ""
        end
        mktempdir() do dir
            raw = base_config_dict()
            raw["output"]["output_directory"] = dir
            raw["output"]["log_to_file"] = false
            raw["output"]["export_csv"] = false
            raw["output"]["export_metadata"] = false
            raw["hardware"]["verify_kernels"] = false
            raw["benchmark"]["engines"] = ["ka"]
            records, console = capture_stdout(
                () -> run_diagnostics(validate_config(raw); base_dir = TOOL_DIR),
            )
            @test occursin("min [ms]", console)
            @test !occursin("Cross-engine verification", console)
            @test all(
                r -> r.engine == "ka",
                filter(r -> r.matrix_dim == 32 && r.data_type == "Int32", records),
            )
            @test isempty(readdir(dir))
        end
    end
end
