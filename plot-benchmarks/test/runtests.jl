using Test
using CSV: CSV
using DataFrames: DataFrame, nrow
using CairoMakie: Figure, Legend

include(joinpath(@__DIR__, "..", "plot-benchmarks.jl"))

const TOOL_DIR = normpath(joinpath(@__DIR__, ".."))

"Synthetic dataset with a CPU sweep at two sizes, CPU element types and one accelerator."
function synthetic_dataset()
    rows = NamedTuple[]
    record(; kwargs...) = push!(
        rows,
        (;
            device_type = "CPU",
            backend = "CPU",
            engine = "blas",
            library = "OpenBLAS (ILP64)",
            device_name = "Mock CPU",
            data_type = "Float32",
            matrix_dim = 256,
            julia_threads = 8,
            blas_threads = missing,
            exceeds_physical_cores = false,
            nominal_ops = 4.0 * 256^3,
            samples = 5,
            min_time_ms = 1.0,
            median_time_ms = 1.1,
            mad_time_ms = 0.05,
            dispersion_pct = 4.5,
            throughput_gops = 60.0,
            throughput_median_gops = 55.0,
            speedup_vs_1t = missing,
            parallel_efficiency_pct = missing,
            speedup_vs_cpu_1t = missing,
            speedup_vs_cpu_maxt = missing,
            status = "ok",
            kwargs...,
        ),
    )
    for N in (256, 512), (t, s) in ((1, 1.0), (2, 1.9), (4, 3.5), (8, 6.0), (12, 5.0))
        record(;
            matrix_dim = N,
            blas_threads = t,
            speedup_vs_1t = s,
            parallel_efficiency_pct = 100 * s / t,
            exceeds_physical_cores = t > 8,
            throughput_gops = 30.0 * s,
        )
    end
    for T in ("Float32", "Float64", "Int32"),
        (engine, gops) in (("blas", 200.0), ("ka", 20.0), ("ka_tiled", 45.0))

        record(;
            matrix_dim = 512,
            data_type = T,
            engine,
            blas_threads = engine == "blas" ? 8 : missing,
            library = engine == "blas" ? "OpenBLAS (ILP64)" : "KernelAbstractions $engine",
            throughput_gops = gops,
        )
        record(;
            device_type = "GPU",
            backend = "oneAPI",
            device_name = "Mock GPU",
            matrix_dim = 512,
            data_type = T,
            engine,
            library = engine == "blas" ? "oneMKL" : "KernelAbstractions $engine",
            throughput_gops = 3 * gops,
        )
    end
    record(;
        matrix_dim = 512,
        data_type = "Float16",
        engine = "blas",
        blas_threads = 8,
        status = "failed: unsupported",
        throughput_gops = missing,
    )
    return DataFrame(rows)
end

"""
Synthetic dataset of a second machine: a different CPU with a shorter sweep and an
accelerator whose library engine falls back to the generic path for `Int32`.
"""
function second_dataset()
    df = synthetic_dataset()
    host = df.device_type .== "CPU"
    df = df[.!(host .& (coalesce.(df.blas_threads, 0) .> 4)), :]
    host = df.device_type .== "CPU"
    df.device_name = ifelse.(host, "Other(R) Mock CPU @ 3.00GHz", "Other GPU")
    df.backend = ifelse.(host, "CPU", "CUDA")
    generic = (.!host) .& (df.engine .== "blas") .& (df.data_type .== "Int32")
    df.library = ifelse.(generic, "GPUArrays generic", df.library)
    df.throughput_gops = ifelse.(host, df.throughput_gops, 2 .* df.throughput_gops)
    return df
end

"Copy of `rows` relabelled to problem size `N`."
function at_size(rows::DataFrame, N::Integer)
    frame = DataFrame(rows)
    frame.matrix_dim .= N
    return frame
end

@testset "plot-benchmarks" begin
    @testset "Settings" begin
        settings = load_settings(joinpath(TOOL_DIR, "config.toml"))
        @test settings isa FigureSettings
        @test_throws ArgumentError load_settings(joinpath(TOOL_DIR, "missing.toml"))
        mktempdir() do dir
            chosen = joinpath(dir, "chosen.toml")
            write(
                chosen,
                """
                [input]
                dataset_directory = "datasets"
                comparison_directory = "runs"

                [figures]
                format = "svg"
                width_mm = 120.0
                px_per_unit = 3
                fontsize_pt = 8.0
                output_directory = "figures"
                """,
            )
            loaded = load_settings(chosen)
            @test loaded.dataset_directory == "datasets"
            @test loaded.comparison_directory == "runs"
            @test loaded.format == "svg"
            @test loaded.width_mm == 120.0
            @test loaded.px_per_unit == 3
            @test loaded.fontsize_pt == 8.0
            @test loaded.output_directory == "figures"
            bad = joinpath(dir, "bad.toml")
            write(bad, "[figures]\nformat = \"jpg\"\n")
            @test_throws ArgumentError load_settings(bad)
            write(bad, "[figures]\nwidth_mm = 10\n")
            @test_throws ArgumentError load_settings(bad)
            write(bad, "[figures]\ndpi = 300\n")
            @test_throws ArgumentError load_settings(bad)
            write(bad, "[figures]\nfontsize_pt = 20\n")
            @test_throws ArgumentError load_settings(bad)
            write(bad, "[figures]\nformat = \"png\"\npx_per_unit = 3\n")
            @test load_settings(bad).px_per_unit == 3
        end
    end

    @testset "Dataset discovery and reading" begin
        mktempdir() do dir
            @test latest_dataset(dir) === nothing
            @test latest_dataset(joinpath(dir, "absent")) === nothing
            CSV.write(
                joinpath(dir, "hardware_benchmark_2026-01-01_00-00-00.csv"),
                synthetic_dataset(),
            )
            CSV.write(
                joinpath(dir, "hardware_benchmark_2026-02-01_00-00-00.csv"),
                synthetic_dataset(),
            )
            write(joinpath(dir, "notes.csv"), "a,b\n1,2\n")
            @test basename(latest_dataset(dir)) ==
                  "hardware_benchmark_2026-02-01_00-00-00.csv"
            df = read_dataset(latest_dataset(dir))
            @test nrow(df) == nrow(synthetic_dataset())
            @test_throws ArgumentError read_dataset(joinpath(dir, "notes.csv"))
            @test_throws ArgumentError read_dataset(joinpath(dir, "absent.csv"))
        end
    end

    @testset "Figures" begin
        settings = load_settings(joinpath(TOOL_DIR, "config.toml"))
        df = synthetic_dataset()
        sweep = sweep_rows(df)
        @test nrow(sweep) == 10
        @test all(sweep.engine .== "blas")
        rows = throughput_rows(df, 512)
        @test all(
            r -> r.device_type != "CPU" || r.engine != "blas" || r.blas_threads == 8,
            eachrow(rows),
        )
        @test !("Float16" in rows.data_type)
        # a stage row at the top thread count supersedes the sweep row of its type
        pair = vcat(df[1:1, :], df[1:1, :])
        pair.blas_threads .= 8
        pair.speedup_vs_1t = [2.0, missing]
        kept = throughput_rows(pair, 256)
        @test nrow(kept) == 1
        @test ismissing(only(kept.speedup_vs_1t))
        lone = throughput_rows(pair[1:1, :], 256)
        @test nrow(lone) == 1
        @test only(lone.speedup_vs_1t) == 2.0
        @test thread_scaling_figure(df, settings) isa Figure
        @test throughput_figure(df, settings) isa Figure
        @test throughput_figure(df, settings; matrix_dim = 256) isa Figure
        @test throughput_figure(df, settings; matrix_dim = 4096) === nothing
        empty = DataFrame(df[1:0, :])
        @test thread_scaling_figure(empty, settings) === nothing
        @test throughput_figure(empty, settings) === nothing
        @test value_label(212.4) == "212"
        @test value_label(45.67) == "45.7"
        @test value_label(3.456) == "3.46"
        @test value_label(0.42) == "0.42"
        @test value_label(0.0042) == "0.0042"
        # rounding precedes the choice of format
        @test value_label(99.96) == "100"
        @test value_label(9.996) == "10.0"
        @test value_label(0.9996) == "1.00"
        @test value_label(1130.4) == "1130"
        @test value_label(94.26) == "94.3"
        positions, labels = decade_ticks(0.05, 2000.0)
        @test positions ≈ [0.1, 1.0, 10.0, 100.0, 1000.0]
        @test labels == ["0.1", "1", "10", "100", "1000"]
        @test string(last(decade_ticks(1.0, 1e6)[2])) == "\$10^{6}\$"
        # an axis leaving 10⁻³ to 10⁴ is labelled in powers of ten throughout, except
        # 10⁰ and 10¹
        wide = decade_ticks(1.0, 1e6)[2]
        @test wide[1] == "1" && wide[2] == "10"
        @test all(label -> !(label isa String), wide[3:end])
        @test all(label -> label isa String, decade_ticks(0.01, 1e4)[2])
        @test String.(decade_ticks(1.0, 1e6)[2]) == [
            "1",
            "10",
            "\$10^{2}\$",
            "\$10^{3}\$",
            "\$10^{4}\$",
            "\$10^{5}\$",
            "\$10^{6}\$",
        ]
        plain = decade_ticks(0.001, 10000.0)[2]
        @test all(label -> label isa String, plain)
        @test plain == ["0.001", "0.01", "0.1", "1", "10", "100", "1000", "10000"]
        # fewer than three decades: 2× and 5× intermediates
        positions, labels = log_ticks(0.15, 12.0)
        @test positions ≈ [0.2, 0.5, 1.0, 2.0, 5.0, 10.0]
        @test labels == ["0.2", "0.5", "1", "2", "5", "10"]
        @test log_ticks(50.0, 2.0e5) == decade_ticks(50.0, 2.0e5)
        # one label style per axis, with mantissas on the intermediates
        positions, labels = log_ticks(700.0, 9e4)
        @test positions ≈ [1000.0, 2000.0, 5000.0, 10000.0, 20000.0, 50000.0]
        @test String.(labels) == [
            "\$10^{3}\$",
            "\$2 \\times 10^{3}\$",
            "\$5 \\times 10^{3}\$",
            "\$10^{4}\$",
            "\$2 \\times 10^{4}\$",
            "\$5 \\times 10^{4}\$",
        ]
        positions, labels = log_ticks(4e-5, 3e-4)
        @test positions ≈ [5e-5, 1e-4, 2e-4]
        @test String.(labels) ==
              ["\$5 \\times 10^{-5}\$", "\$10^{-4}\$", "\$2 \\times 10^{-4}\$"]
        @test String.(last(log_ticks(0.7, 90.0))) == ["1", "2", "5", "10", "20", "50"]
        threads, _ = ideal_scaling(32)
        @test extrema(threads) == (1.0, 32.0)
        @test shorten_device_name("Intel(R) Core(TM) i7-10750H CPU @ 2.60GHz") ==
              "Intel Core i7-10750H"
        @test shorten_device_name("13th Gen Intel(R) Core(TM) i9-13900KS") ==
              "Intel Core i9-13900KS"
        @test shorten_device_name("AMD Ryzen 9 9950X 16-Core Processor") ==
              "AMD Ryzen 9 9950X"
        @test shorten_device_name("NVIDIA GeForce RTX 2080 Super with Max-Q Design") ==
              "NVIDIA RTX 2080 Super Max-Q"
        @test shorten_device_name("Tesla T4") == "Tesla T4"
        @test drop_vendor("NVIDIA RTX 5090") == "RTX 5090"
        @test drop_vendor("Tesla T4") == "Tesla T4"
        slow = synthetic_dataset()
        slow[(slow.device_type .== "CPU") .& (slow.engine .== "ka"), :throughput_gops] .=
            0.4
        @test throughput_figure(slow, settings) isa Figure
        @test throughput_figure(df[df.device_type .== "GPU", :], settings) isa Figure
        # a single engine draws no legend
        @test any(block -> block isa Legend, throughput_figure(df, settings).content)
        single = throughput_figure(df[df.engine .== "blas", :], settings)
        @test single isa Figure
        @test !any(block -> block isa Legend, single.content)
    end

    @testset "Cross-host comparison" begin
        settings = load_settings(joinpath(TOOL_DIR, "config.toml"))
        frames = DataFrame[synthetic_dataset(), second_dataset()]
        @test shared_size(frames, is_accelerator_row) == 512
        @test shared_size(frames, is_sweep_row) == 512
        # a dataset without rows of the requested kind does not constrain the size
        base = synthetic_dataset()
        sweep_part = base[is_sweep_row.(eachrow(base)) .& (base.matrix_dim .== 256), :]
        gpu_part = base[is_accelerator_row.(eachrow(base)), :]
        sweeps = DataFrame[at_size(sweep_part, N) for N in (1024, 2048, 4096)]
        frame_a = vcat(at_size(gpu_part, 1024), at_size(gpu_part, 2048), sweeps...)
        frame_b = vcat(sweeps...)
        @test shared_size(DataFrame[frame_a, frame_b], is_accelerator_row) == 2048
        @test shared_size(DataFrame[frame_a, frame_b], is_sweep_row) == 4096
        @test shared_size(DataFrame[frame_b], is_accelerator_row) === nothing
        accelerators = pooled_devices(frames, 512, "GPU")
        @test Set(unique(accelerators.device_name)) == Set(["Mock GPU", "Other GPU"])
        hosts = pooled_devices(frames, 512, "CPU")
        @test Set(unique(hosts.device_name)) ==
              Set(["Mock CPU", "Other(R) Mock CPU @ 3.00GHz"])
        # the same processor in two datasets contributes one series
        twice =
            pooled_devices(DataFrame[synthetic_dataset(), synthetic_dataset()], 512, "CPU")
        @test unique(twice.device_name) == ["Mock CPU"]
        @test nrow(twice) ==
              nrow(pooled_devices(DataFrame[synthetic_dataset()], 512, "CPU"))
        panel = accelerators[accelerators.device_name .== "Other GPU", :]
        positions, values, generic = engine_series(panel, "blas", ["Float32", "Int32"])
        @test positions == [1.0, 2.0]
        @test generic == [false, true]
        positions, ratios = ratio_series(panel, ["Float32", "Int32"])
        @test positions == [1.0, 2.0]
        @test all(ratios .≈ 45 / 200)
        @test accelerator_comparison_figure(frames, settings) isa Figure
        @test host_comparison_figure(frames, settings) isa Figure
        @test accelerator_comparison_figure(frames, settings; matrix_dim = 4096) === nothing
        @test host_comparison_figure(frames, settings; matrix_dim = 4096) === nothing
        cpu_only = DataFrame[df[df.device_type .== "CPU", :] for df in frames]
        @test accelerator_comparison_figure(cpu_only, settings; matrix_dim = 512) ===
              nothing
        @test accelerator_comparison_figure(cpu_only, settings) === nothing
        mktempdir() do dir
            @test_throws ArgumentError comparison_datasets(joinpath(dir, "absent"))
            @test_throws ArgumentError comparison_datasets(dir)
            for (host, frame) in
                (("first", synthetic_dataset()), ("second", second_dataset()))
                mkpath(joinpath(dir, host))
                CSV.write(
                    joinpath(dir, host, "hardware_benchmark_2026-09-11_00-00-00.csv"),
                    frame,
                )
            end
            paths = comparison_datasets(dir)
            @test length(paths) == 2
            out = joinpath(dir, "figures")
            written = main([
                "--compare",
                dir,
                "--out-dir",
                out,
                "--format",
                "png",
                "--px-per-unit",
                "1",
            ])
            @test length(written) == 2
            @test all(isfile, written)
            @test any(endswith("cross_host_accelerators_N512.png"), written)
            @test any(endswith("cross_host_hosts_N512.png"), written)
            @test_throws ArgumentError main(["--compare", dir, "--px-per-unit", "0"])
        end
    end

    @testset "Rendering and command line" begin
        mktempdir() do dir
            dataset = joinpath(dir, "hardware_benchmark_2026-03-01_00-00-00.csv")
            CSV.write(dataset, synthetic_dataset())
            out = joinpath(dir, "figures")
            written = main([
                "--input",
                dataset,
                "--out-dir",
                out,
                "--format",
                "png",
                "--config",
                joinpath(TOOL_DIR, "config.toml"),
            ])
            @test length(written) == 2
            @test all(isfile, written)
            @test all(path -> filesize(path) > 1000, written)
            @test any(endswith("_thread_scaling.png"), written)
            @test any(endswith("_throughput_N512.png"), written)
            again = main([
                "--input",
                dataset,
                "--out-dir",
                out,
                "--format",
                "png",
                "--size",
                "256",
            ])
            @test any(endswith("_throughput_N256.png"), again)
            @test any(endswith("_thread_scaling#1.png"), again)
            pdfs = main(["--input", dataset, "--out-dir", out])
            @test all(endswith(".pdf"), pdfs)
            @test_throws ArgumentError main(["--bogus"])
            @test_throws ArgumentError main([
                "--format",
                "jpg",
                "--input",
                dataset,
                "--out-dir",
                out,
            ])
            @test_throws ArgumentError main([
                "--input",
                joinpath(dir, "absent.csv"),
                "--out-dir",
                out,
            ])
            @test main(["--help"]) == String[]
        end
    end
end
