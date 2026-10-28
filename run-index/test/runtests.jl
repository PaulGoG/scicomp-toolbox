# Tests of run-index against a synthetic workspace in the shape of DrWatson projects,
# built in mktempdir() with real git history, so no fixture data is committed.

using Test
using Dates: DateTime
using TOML: TOML

include(joinpath(@__DIR__, "..", "run-index.jl"))

const TOOL_DIR = normpath(joinpath(@__DIR__, ".."))

include(joinpath(@__DIR__, "synthetic_workspace.jl"))

record_of(index, run) = only(filter(r -> r.run == run, index.records))

@testset "run-index" begin
    @testset "Settings" begin
        shipped = load_settings(joinpath(TOOL_DIR, "config.toml"))
        defaults = validate_settings(Dict{String, Any}())
        for name in fieldnames(IndexSettings)
            a, b = getfield(shipped, name), getfield(defaults, name)
            @test (a isa Regex ? a.pattern == b.pattern : a == b)
        end
        @test shipped.max_depth == 8
        @test shipped.aliases[:commit][1] == ["gitcommit"]
        bad(d) = validate_settings(d)
        @test_throws "unknown key 'extra'" bad(Dict("extra" => Dict()))
        @test_throws "unknown key 'depth'" bad(Dict("discovery" => Dict("depth" => 3)))
        @test_throws "run_id_pattern" bad(
            Dict("discovery" => Dict("run_id_pattern" => "run_(")),
        )
        @test_throws "max_depth" bad(Dict("discovery" => Dict("max_depth" => 0)))
        @test_throws "max_depth" bad(Dict("discovery" => Dict("max_depth" => true)))
        @test_throws "sidecar_names" bad(
            Dict("discovery" => Dict("sidecar_names" => String[])),
        )
        @test_throws "figure_extensions" bad(
            Dict("discovery" => Dict("figure_extensions" => ["pdf"])),
        )
        @test_throws "[fields].commit" bad(Dict("fields" => Dict("commit" => ["a..b"])))
        @test_throws "[fields].seed" bad(Dict("fields" => Dict("seed" => [1])))
        @test_throws "unknown key 'tags'" bad(Dict("fields" => Dict("tags" => ["x"])))
        @test_throws "csv_directory" bad(Dict("output" => Dict("csv_directory" => "")))
        @test_throws ArgumentError load_settings(joinpath(TOOL_DIR, "missing.toml"))
        mktempdir() do dir
            path = joinpath(dir, "broken.toml")
            write(path, "[discovery\n")
            @test_throws path load_settings(path)
        end
    end

    @testset "Provenance parsing" begin
        table = TOML.parse("""
            commit = "top"
            [provenance]
            commit = "nested"
            hostname = "node07"
            [hardware]
            cpu = { cores = 64 }
            cpu_model = "EPYC"
            [[hardware.accelerators]]
            device_name = "RTX 5090"
            """)
        entries = flatten(table)
        @test ["hardware", "accelerators", "1", "device_name"] in first.(entries)
        @test lookup(entries, [["commit"]], :text) == "top"
        @test lookup(entries, [["provenance", "commit"]], :text) == "nested"
        @test lookup(entries, [["cpu"], ["cpu_model"]], :text) == "EPYC"
        @test lookup(entries, [["device_name"]], :text) == "RTX 5090"
        @test lookup(entries, [["absent"]], :text) === nothing
        @test lookup(entries, [["hardware"]], :table) isa AbstractDict
        @test parse_time("2026-08-02 09:15:00") == DateTime(2026, 8, 2, 9, 15)
        @test parse_time("2026-09-01T08:00:00Z") == DateTime(2026, 9, 1, 8)
        @test parse_time("2026-09-01T08:00:00+02:00") == DateTime(2026, 9, 1, 8)
        @test parse_time("2026-09-11_20-23-50") == DateTime(2026, 9, 11, 20, 23, 50)
        @test parse_time("2026-09-11") == DateTime(2026, 9, 11)
        @test parse_time("yesterday") === nothing
        @test commit_reference("abc1234-dirty") == ("abc1234", true)
        @test commit_reference("v0.1.0-1-gabc1234_dirty") == ("v0.1.0-1-gabc1234", true)
        @test commit_reference(" abc1234 ") == ("abc1234", false)
        a = canonical_configuration(
            Dict("L" => 1, "seed" => 1, "solver" => Dict("rng_seed" => 5)),
            [["seed"], ["rng_seed"]],
        )
        b = canonical_configuration(
            Dict("L" => 1, "seed" => 2, "solver" => Dict("rng_seed" => 6)),
            [["seed"], ["rng_seed"]],
        )
        @test a == b == ["L" => "1"]
        @test format_duration(12.34) == "12.3 s"
        @test format_duration(245.0) == "4m 05s"
        @test format_duration(7620.0) == "2h 07m"
        @test format_duration(3 * 86400 + 4 * 3600) == "3d 04h"
        @test format_duration(NaN) == "-"
        @test format_bytes(512) == "512 B"
        @test format_bytes(4096) == "4.00 KiB"
    end

    mktempdir() do root
        ws = synthetic_workspace(root)
        settings = load_settings(joinpath(TOOL_DIR, "config.toml"))
        status_before = git_run(ws.repo, "status", "--porcelain")

        @testset "Discovery" begin
            runs = relpath.(find_runs(root, settings), root)
            @test length(runs) == 14
            @test joinpath("Curvature", "data", "sims", "N=64_seed=1") in runs
            @test joinpath("Curvature", "data", "deep", "a", "b", "c", "run_0000ffff") in
                  runs
            @test !any(contains(".trash"), runs)
            @test !any(startswith("link"), runs)
            @test !any(endswith("cache"), runs)
            @test length(find_runs(root, settings; max_depth = 6)) == 13
            @test only(find_runs(joinpath(ws.repo, "data", "run_513e903b"), settings)) ==
                  joinpath(ws.repo, "data", "run_513e903b")
            @test project_root(joinpath(ws.repo, "data", "run_513e903b"), root) == ws.repo
            @test disk_usage(joinpath(ws.repo, "data", "run_513e903b"))[2] == 3
        end

        index = build_index([root], settings)
        expected = Dict(
            "data/run_513e903b" => ["seed-replicate"],
            "data/run_513e903b_r2" => ["seed-replicate"],
            "data/run_f954868c" => ["dirty", "repeat"],
            "data/run_f954868c_r2" => ["dirty", "repeat"],
            "data/run_77aa88bb" => ["off-head"],
            "data/run_deadbeef" => ["unknown-commit"],
            "data/run_0a1b2c3d" => ["no-provenance"],
            "data/run_1234abcd" => ["unreadable-provenance"],
            "data/run_9e8d7c6b" => ["no-commit"],
            "data/run_51c2a7e0" => String[],
            "data/sims/N=64_seed=1" => ["dirty", "seed-replicate"],
            "data/sims/N=64_seed=2" => ["dirty", "seed-replicate"],
            "data/deep/a/b/c/run_0000ffff" => String[],
            "data/run_aaaa1111" => ["no-repository"],
        )

        @testset "Flags" begin
            @test length(index.records) == length(expected)
            for record in index.records
                @test record.flags == expected[record.run]
            end
        end

        @testset "Fields across provenance generations" begin
            nested = record_of(index, "data/run_513e903b")
            @test nested.project == "Curvature" && nested.provenance == "provenance.toml"
            @test nested.commit == ws.c1 && nested.resolved_commit == ws.c1
            @test nested.on_head === true && !nested.dirty
            @test nested.started == DateTime(2026, 8, 5, 14, 2, 11)
            @test nested.wall_time_s == 3605.2
            @test nested.hostname == "node07" &&
                  nested.cpu == "AMD EPYC 7763 64-Core Processor"
            @test nested.julia_version == "1.12.0" && nested.seed == "1"
            @test nested.size_bytes ==
                  4096 +
                  filesize(joinpath(nested.path, "provenance.toml")) +
                  filesize(joinpath(nested.path, "Manifest.toml"))
            @test nested.files == 3
            flat = record_of(index, "data/run_f954868c")
            @test flat.resolved_commit == ws.c2 && flat.dirty && flat.on_head === true
            @test flat.hostname == "node03" && flat.started == DateTime(2026, 8, 2, 9, 15)
            tagged = record_of(index, "data/sims/N=64_seed=1")
            @test tagged.provenance == "metadata.toml"
            @test tagged.resolved_commit == ws.c4 && tagged.dirty
            @test tagged.script == "scripts/sweep.jl#21"
            @test tagged.cpu == "Intel(R) Core(TM) Ultra 7 155H"
            @test tagged.gpu == "Intel(R) Arc(TM) Graphics"
            @test tagged.wall_time_s == 5430.0
            @test record_of(index, "data/run_77aa88bb").on_head === false
            @test record_of(index, "data/run_51c2a7e0").resolved_commit == ws.c2
            @test record_of(index, "data/deep/a/b/c/run_0000ffff").resolved_commit == ws.c5
            lone = record_of(index, "data/run_aaaa1111")
            @test lone.project == "Lone" &&
                  lone.wall_time_s == 1200.0 &&
                  lone.on_head === nothing
            @test isempty(record_of(index, "data/run_0a1b2c3d").commit)
        end

        @testset "Groups, order and projects" begin
            groups = Dict(r.run => r.group for r in index.records if !isempty(r.group))
            @test length(groups) == 6
            @test groups["data/run_513e903b"] == groups["data/run_513e903b_r2"]
            @test groups["data/run_f954868c"] == groups["data/run_f954868c_r2"]
            @test groups["data/sims/N=64_seed=1"] == groups["data/sims/N=64_seed=2"]
            @test length(unique(values(groups))) == 3
            # the earliest run of the first group opens the numbering
            @test groups["data/run_f954868c"] == "G1"
            curvature = filter(r -> r.project == "Curvature", index.records)
            starts = [r.started for r in curvature if r.started !== nothing]
            @test issorted(starts)
            @test findlast(r -> r.started !== nothing, curvature) <
                  findfirst(r -> r.started === nothing, curvature)
            @test [p.name for p in index.projects] == ["Curvature", "Lone"]
            project = first(index.projects)
            @test project.runs == 13 && project.flagged == 11
            @test project.repository.branch == "main" && project.repository.head == ws.c5
            @test project.size_bytes == sum(r.size_bytes for r in curvature)
            @test index.projects[2].repository === nothing
        end

        @testset "Figures without a run" begin
            @test [(f.path, f.run_id) for f in index.orphans] == [
                ("plots/residuals/run_dcf44792_residuals.png", "run_dcf44792"),
                ("plots/run_dcf44792_spectrum.pdf", "run_dcf44792"),
            ]
        end

        @testset "Report and CSV" begin
            io = IOBuffer()
            print_report(io, index)
            text = String(take!(io))
            @test startswith(text, "14 runs in 2 projects")
            @test occursin("12 flagged", text)
            @test occursin("git main at $(first(ws.c5, 8))", text)
            @test occursin("no git repository; 1 run, ", text)
            @test occursin("Replicate groups", text)
            @test occursin("run_513e903b (seed 1)", text)
            @test occursin("plots/run_dcf44792_spectrum.pdf (run_dcf44792)", text)
            @test !occursin("\e[", text)
            io = IOBuffer()
            print_report(io, index; flagged_only = true)
            flagged = String(take!(io))
            @test !occursin("run_51c2a7e0", flagged) && occursin("run_deadbeef", flagged)

            mktempdir() do dir
                path = write_csv(joinpath(dir, "index.csv"), index.records)
                lines = readlines(path)
                @test length(lines) == 15
                @test lines[1] == join(string.(fieldnames(RunRecord)), ",")
                row = only(filter(l -> occursin("run_f954868c_r2", l), lines))
                @test occursin("\"dirty;repeat\"", row)
                @test occursin(",true,true,", row)
                lone = only(filter(l -> occursin("run_aaaa1111", l), lines))
                @test occursin(",false,,", lone)
                @test occursin("2026-09-02T08:00:00", lone)
            end
        end

        @testset "Command line" begin
            mktempdir() do dir
                io = IOBuffer()
                csv = joinpath(dir, "index.csv")
                result = main(["--csv", csv, root]; io)
                @test result.csv == csv && isfile(csv)
                @test length(result.records) == 14
                @test occursin("Index written to $csv", String(take!(io)))
                again = main(["--csv", csv, root]; io = IOBuffer())
                @test again.csv == joinpath(dir, "index#1.csv")
                @test main(["--no-csv", "--depth", "6", root]; io = IOBuffer()).csv ===
                      nothing
                @test length(
                    main(["--no-csv", "--depth", "6", root]; io = IOBuffer()).records,
                ) == 13
                twice =
                    main(["--no-csv", root, joinpath(root, "Curvature")]; io = IOBuffer())
                @test length(twice.records) == 14
                io = IOBuffer()
                @test main(["--no-csv", dir]; io).csv === nothing
                @test occursin("No run directories", String(take!(io)))
                io = IOBuffer()
                @test main(["--help"]; io) === nothing
                @test occursin("--flagged", String(take!(io)))
                custom = joinpath(dir, "custom.toml")
                write(custom, "[discovery]\nsidecar_names = [\"run.toml\"]\n")
                only_run_toml = main(
                    ["--no-csv", "--config", custom, joinpath(root, "Lone")];
                    io = IOBuffer(),
                )
                @test only(only_run_toml.records).run == "data/run_aaaa1111"
            end
            @test_throws "unknown command-line argument" main(["--bogus"]; io = IOBuffer())
            @test_throws "--depth" main(["--depth", "0"]; io = IOBuffer())
            @test_throws "--csv requires a value" main(["--csv"]; io = IOBuffer())
            @test_throws "not a directory" main([joinpath(root, "absent")]; io = IOBuffer())
        end

        @testset "Read-only" begin
            @test git_run(ws.repo, "status", "--porcelain") == status_before
            @test !isfile(joinpath(ws.repo, ".git", "index.lock"))
        end
    end
end
