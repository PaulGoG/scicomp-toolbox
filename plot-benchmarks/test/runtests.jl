using Test
using CSV: CSV
using DataFrames: DataFrame, nrow
using CairoMakie: Figure

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

@testset "plot-benchmarks" begin
    @testset "Settings" begin
        settings = load_settings(joinpath(TOOL_DIR, "config.toml"))
        @test settings isa FigureSettings
        @test settings.format == "pdf"
        @test settings.width_mm == 178.0
        @test_throws ArgumentError load_settings(joinpath(TOOL_DIR, "missing.toml"))
        mktempdir() do dir
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
        positions, labels = decade_ticks(0.05, 2000.0)
        @test positions ≈ [0.1, 1.0, 10.0, 100.0, 1000.0]
        @test labels == ["0.1", "1", "10", "100", "1000"]
        @test string(last(decade_ticks(1.0, 1e6)[2])) == "\$10^{6}\$"
        slow = synthetic_dataset()
        slow[(slow.device_type .== "CPU") .& (slow.engine .== "ka"), :throughput_gops] .=
            0.4
        @test throughput_figure(slow, settings) isa Figure
        @test throughput_figure(df[df.device_type .== "GPU", :], settings) isa Figure
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
