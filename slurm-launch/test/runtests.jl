# Tests of slurm-launch without a cluster: synthetic projects of both payload shapes
# built in mktempdir(), stub sbatch/squeue/sacct/scancel executables on PATH, golden
# job scripts under test/references/, and real detached local jobs.

using Test
using Dates: DateTime
using TOML: TOML

include(joinpath(@__DIR__, "..", "slurm-launch.jl"))

const TOOL_DIR = normpath(joinpath(@__DIR__, ".."))
const REFERENCES = joinpath(@__DIR__, "references")
const UPDATE_REFERENCES = get(ENV, "SLURM_LAUNCH_UPDATE_REFERENCES", "") == "1"
const STAMP = DateTime(2026, 10, 29, 9, 30, 0)

"""
    check_reference(name, text; root)

Compare `text`, with the temporary `root` written as `<root>`, against the golden file
`test/references/<name>`; with `SLURM_LAUNCH_UPDATE_REFERENCES=1` the file is rewritten.
"""
function check_reference(name::AbstractString, text::AbstractString; root::AbstractString)
    normalized = replace(text, root => "<root>")
    path = joinpath(REFERENCES, name)
    if UPDATE_REFERENCES || !isfile(path)
        mkpath(REFERENCES)
        write(path, normalized)
        @info "reference written: $path"
    end
    expected = read(path, String)
    normalized == expected || println("--- $name differs:\n", normalized)
    @test normalized == expected
end

function git_run(dir::AbstractString, args::AbstractString...)
    command = `git -C $dir -c user.name=Test -c user.email=test@example.invalid -c init.defaultBranch=main -c commit.gpgsign=false $(collect(args))`
    return String(strip(read(pipeline(command; stderr = devnull), String)))
end

const PIPELINE = """
    # stand-in for scripts/run_pipeline.jl: echoes its arguments and the thread count
    config = ARGS[findfirst(==("--config"), ARGS) + 1]
    output = ARGS[findfirst(==("--output-dir"), ARGS) + 1]
    m = match(r"sleep_s\\s*=\\s*([0-9.]+)", read(config, String))
    m === nothing || sleep(parse(Float64, m.captures[1]))
    mkpath(output)
    write(joinpath(output, "result.txt"), "threads \$(Threads.nthreads())\\n")
    println("pipeline done: ", config)
    """

pipeline_config(threads; heap = 24, extra = "") = """
    [hardware]
    max_threads = $threads
    heap_size_hint_gb = $heap
    gpu_backend = "cuda"

    [safety]
    max_ram_gb = 32
    max_vram_gb = 20
    $extra
    """

"""
    synthetic_projects(root) -> NamedTuple

`Pipeline/`, a Julia project in the shape of the DrWatson pipelines (`scripts/`,
`config/run.toml`, a sweep of three cases differing in threads and heap), committed to
git; and `Nbody/`, a native code whose cases carry a generated `_launch.sh` and a
`run.toml` with MPI, OpenMP and GPU switches.
"""
function synthetic_projects(root::AbstractString)
    pipeline = joinpath(root, "Pipeline")
    mkpath(joinpath(pipeline, "scripts"))
    mkpath(joinpath(pipeline, "config"))
    write(joinpath(pipeline, "Project.toml"), "name = \"Pipeline\"\n")
    write(joinpath(pipeline, "scripts", "run_pipeline.jl"), PIPELINE)
    write(joinpath(pipeline, "config", "run.toml"), pipeline_config(8))
    write(
        joinpath(pipeline, "config", "slow.toml"),
        pipeline_config(1; extra = "sleep_s = 60"),
    )
    write(joinpath(pipeline, "config", "auto.toml"), "[hardware]\nmax_threads = \"auto\"\n")
    for (i, (threads, heap)) in enumerate(((1, 2), (4, 1.5), (16, 8)))
        case = joinpath(pipeline, "runs", "sweep", @sprintf("%03d_threads=%d", i, threads))
        mkpath(case)
        write(joinpath(case, "config.toml"), pipeline_config(threads; heap))
    end
    mkpath(joinpath(pipeline, "runs", "sweep", "notes"))
    write(joinpath(pipeline, ".gitignore"), "jobs/\ndata/\nruns/\n")
    git_run(pipeline, "init", "--quiet", "--initial-branch=main")
    git_run(pipeline, "add", ".")
    git_run(pipeline, "commit", "--quiet", "-m", "pipeline")
    commit = git_run(pipeline, "rev-parse", "HEAD")

    nbody = joinpath(root, "Nbody")
    for (i, e) in enumerate((0.1, 0.5))
        case = joinpath(
            nbody,
            "runs",
            "sweep_showcase",
            @sprintf("%03d_orbit-eccentricity=%.1f_seed=1", i, e)
        )
        mkpath(case)
        write(
            joinpath(case, "_launch.sh"),
            "#!/bin/bash\nulimit -s unlimited\nexport OMP_NUM_THREADS=8\nmpirun --bind-to none -np 4 nbody6 < run.inp > run.out 2> run.err\n",
        )
        write(
            joinpath(case, "run.toml"),
            "[build]\nenable_mpi = true\nenable_gpu = true\n\n[simulation]\nmpi_ranks = 4\nomp_threads = $(4 * i)\n\n[safety]\nmax_ram_gb = 64\n",
        )
    end
    return (; pipeline, nbody, commit)
end

const CLUSTER = """
    [clusters.testsite]
    partition = "gpu"
    account = "proj123"
    qos = "normal"
    time_limit = "1-00:00:00"
    setup = ["module load Julia/1.12"]
    remote_root = "/cluster/home/user"
    mail_type = "END,FAIL"
    mail_user = "user@example.invalid"
    gpu_types = { a100 = 80, a40 = 48 }
    directives = ["--exclusive"]
    """

function tool_config(dir; julia = "julia", fetch = "")
    path = joinpath(dir, "tool.toml")
    write(path, "[defaults]\njulia = \"$julia\"\nfetch_command = \"$fetch\"\n\n" * CLUSTER)
    return path
end

"""
    with_stubs(f, dir)

Run `f(log)` with stub `sbatch`, `squeue`, `sacct` and `scancel` first on `PATH`; every
call is appended to `log`. Job 4242 is running, job 4243 has completed.
"""
function with_stubs(f, dir)
    bin = mkpath(joinpath(dir, "bin"))
    log = joinpath(dir, "calls.log")
    stubs = Dict(
        "sbatch" => "echo \"sbatch \$*\" >> \"\$STUB_LOG\"\necho \"4242;testsite\"",
        "squeue" => "echo \"squeue \$*\" >> \"\$STUB_LOG\"\ncase \"\$*\" in *\"-j 4242 \"*) echo \"RUNNING|1:23|node07\";; esac",
        "sacct" => "echo \"sacct \$*\" >> \"\$STUB_LOG\"\ncase \"\$*\" in *\"-j 4243 \"*) echo \"COMPLETED|0:0|00:10:00\";; esac",
        "scancel" => "echo \"scancel \$*\" >> \"\$STUB_LOG\"",
    )
    for (name, body) in stubs
        path = joinpath(bin, name)
        write(path, "#!/bin/bash\n$body\n")
        chmod(path, 0o755)
    end
    withenv("PATH" => bin * ":" * ENV["PATH"], "STUB_LOG" => log) do
        f(log)
    end
end

function wait_for(record_path, states; timeout = 180)
    t0 = time()
    while time() - t0 < timeout
        state = first(job_state(read_record(record_path)))
        state in states && return state
        sleep(0.5)
    end
    return first(job_state(read_record(record_path)))
end

@testset "slurm-launch" begin
    @testset "Settings" begin
        shipped = load_settings(joinpath(TOOL_DIR, "config.toml"))
        @test shipped.backend == "local" && isempty(shipped.clusters)
        @test shipped.job_directory == "jobs" && shipped.log_directory == "data/logs"
        defaults = validate_settings(Dict{String, Any}())
        @test defaults.derivation == shipped.derivation
        @test shipped.derivation["julia"][:memory_gb] ==
              ["hardware.heap_size_hint_gb", "safety.max_ram_gb"]
        mktempdir() do dir
            cluster = load_settings(tool_config(dir)).clusters["testsite"]
            @test cluster.gpu_types == ["a40" => 48.0, "a100" => 80.0]
            @test cluster.mail_type == "END,FAIL" &&
                  cluster.setup == ["module load Julia/1.12"]
        end
        site(changes...) = Dict(
            "clusters" => Dict(
                "s" => merge(
                    Dict{String, Any}("partition" => "p", "time_limit" => "02:00:00"),
                    Dict{String, Any}(changes...),
                ),
            ),
        )
        bad(raw) = validate_settings(raw)
        @test_throws "unknown key 'extra'" bad(Dict("extra" => 1))
        @test_throws "[defaults].backend" bad(Dict("defaults" => Dict("backend" => "pbs")))
        @test_throws "memory_margin" bad(Dict("defaults" => Dict("memory_margin" => 2)))
        @test_throws "job_directory" bad(
            Dict("defaults" => Dict("job_directory" => "/abs")),
        )
        @test_throws "log_directory" bad(
            Dict("defaults" => Dict("log_directory" => "../up")),
        )
        @test_throws "[defaults].cluster 'lisa'" bad(
            Dict("defaults" => Dict("cluster" => "lisa")),
        )
        @test_throws "[derivation.julia].threads" bad(
            Dict("derivation" => Dict("julia" => Dict("threads" => "a..b"))),
        )
        @test_throws "unknown key 'cores'" bad(
            Dict("derivation" => Dict("launcher" => Dict("cores" => "x"))),
        )
        @test_throws "partition" bad(
            Dict("clusters" => Dict("s" => Dict("time_limit" => "01:00:00"))),
        )
        @test_throws "time_limit" bad(site("time_limit" => "two hours"))
        @test_throws "remote_root" bad(site("remote_root" => "relative/path"))
        @test_throws "mail_type" bad(site("mail_type" => "SOMETIMES"))
        @test_throws "gpu_types" bad(site("gpu_types" => Dict("a100" => 0)))
        @test_throws "directives" bad(site("directives" => ["exclusive"]))
        @test_throws "spaces" bad(site("account" => "my account"))
        @test_throws "cluster name" bad(Dict("clusters" => Dict("bad name" => Dict())))
        @test validate_settings(site("time_limit" => "3-12:00:00")).clusters["s"].time_limit ==
              "3-12:00:00"
    end

    @testset "Resource derivation" begin
        settings = validate_settings(TOML.parse(CLUSTER))
        cluster = settings.clusters["testsite"]
        config = TOML.parse(pipeline_config(8))
        r = derive_resources("julia", config, "run.toml", settings, "slurm", cluster)
        @test (r.cpus_per_task, r.tasks, r.gpus, r.gpu_type) == (8, 1, 1, "a40")
        @test r.memory_gb == ceil(Int, 32 * 1.2) &&
              r.threads == "8" &&
              r.heap_size_hint == "24G"
        local_run =
            derive_resources("julia", config, "run.toml", settings, "local", nothing)
        @test local_run.memory_gb == 0 &&
              local_run.gpu_type == "" &&
              local_run.threads == "8"
        @test heap_hint(1.5) == "1536M" && heap_hint(24) == "24G"
        auto = TOML.parse("[hardware]\nmax_threads = \"auto\"\n")
        @test derive_resources("julia", auto, "a.toml", settings, "local", nothing).threads ==
              "auto"
        @test_throws "derives --cpus-per-task" derive_resources(
            "julia",
            auto,
            "a.toml",
            settings,
            "slurm",
            cluster,
        )
        @test_throws "no hardware.max_threads" derive_resources(
            "julia",
            Dict{String, Any}(),
            "a.toml",
            settings,
            "slurm",
            cluster,
        )
        bare = TOML.parse("[hardware]\nmax_threads = 2\ngpu_backend = \"none\"\n")
        plain = derive_resources("julia", bare, "b.toml", settings, "slurm", cluster)
        @test plain.gpus == 0 && plain.memory_gb == 0 && plain.heap_size_hint == ""
        @test any(contains("--mem omitted"), plain.notes)
        @test_throws "exceeds every GPU type" derive_resources(
            "julia",
            TOML.parse(
                "[hardware]\nmax_threads = 2\ngpu_backend = \"cuda\"\n[safety]\nmax_vram_gb = 96\n",
            ),
            "c.toml",
            settings,
            "slurm",
            cluster,
        )
        @test_throws "max_threads must be an integer" derive_resources(
            "julia",
            TOML.parse("[hardware]\nmax_threads = 0\n"),
            "d.toml",
            settings,
            "local",
            nothing,
        )
        launcher = TOML.parse(
            "[build]\nenable_mpi = true\nenable_gpu = true\n[simulation]\nmpi_ranks = 4\nomp_threads = 8\n",
        )
        n = derive_resources("launcher", launcher, "run.toml", settings, "slurm", cluster)
        @test (n.tasks, n.cpus_per_task, n.gpus, n.gpu_type) == (4, 8, 1, "")
        serial = TOML.parse("[build]\nenable_mpi = false\n[simulation]\nomp_threads = 2\n")
        @test derive_resources("launcher", serial, "s.toml", settings, "slurm", cluster).tasks ==
              1
        @test_throws "MPI is enabled" derive_resources(
            "launcher",
            TOML.parse("[build]\nenable_mpi = true\n[simulation]\nomp_threads = 2\n"),
            "m.toml",
            settings,
            "slurm",
            cluster,
        )
        @test_throws "must be a boolean" derive_resources(
            "launcher",
            TOML.parse("[build]\nenable_gpu = \"yes\"\n[simulation]\nomp_threads = 2\n"),
            "g.toml",
            settings,
            "slurm",
            cluster,
        )
        both = combine([r, plain])
        @test (both.cpus_per_task, both.memory_gb, both.gpus) == (8, 39, 1)
        @test shell_quote("a/b_c.toml") == "a/b_c.toml" &&
              shell_quote("it's") == "'it'\\''s'"
    end

    mktempdir() do root
        projects = synthetic_projects(root)
        golden = tool_config(root)
        run_config = joinpath(projects.pipeline, "config", "run.toml")

        @testset "Golden job scripts" begin
            cd(projects.pipeline) do
                single = main(
                    [
                        "generate",
                        "--backend",
                        "slurm",
                        "--cluster",
                        "testsite",
                        "--run-config",
                        "config/run.toml",
                        "--output-dir",
                        "data/runs/run_0001",
                        "--config",
                        golden,
                    ];
                    io = IOBuffer(),
                    timestamp = STAMP,
                )
                text = read(single.script, String)
                check_reference(
                    "slurm_julia_single.sbatch.txt",
                    replace(text, projects.commit => "<commit>");
                    root,
                )
                @test occursin("--chdir=/cluster/home/user/Pipeline", text)
                @test single.spec.commit == projects.commit && !single.spec.dirty

                sweep = main(
                    [
                        "--backend",
                        "slurm",
                        "--cluster",
                        "testsite",
                        "--cases",
                        "runs/sweep",
                        "--run-config",
                        "config.toml",
                        "--parallel",
                        "2",
                        "--name",
                        "sweep",
                        "--config",
                        golden,
                    ];
                    io = IOBuffer(),
                    timestamp = STAMP,
                )
                @test length(sweep.spec.cases) == 3
                @test sweep.spec.resources.cpus_per_task == 16
                check_reference(
                    "slurm_julia_array.sbatch.txt",
                    replace(read(sweep.script, String), projects.commit => "<commit>");
                    root,
                )
                check_reference(
                    "slurm_julia_array.cases.txt",
                    read(
                        joinpath(
                            projects.pipeline,
                            cases_file(sweep.spec, load_settings(golden)),
                        ),
                        String,
                    );
                    root,
                )

                local_run = main(
                    [
                        "--run-config",
                        "config/run.toml",
                        "--output-dir",
                        "data/runs/run_0002",
                        "--config",
                        golden,
                    ];
                    io = IOBuffer(),
                    timestamp = STAMP,
                )
                @test endswith(local_run.script, ".sh")
                same_second = main(
                    [
                        "--run-config",
                        "config/run.toml",
                        "--output-dir",
                        "data/runs/run_0002",
                        "--config",
                        golden,
                    ];
                    io = IOBuffer(),
                    timestamp = STAMP,
                )
                @test same_second.spec.stem == local_run.spec.stem * "_2"
                check_reference(
                    "local_julia_single.sh.txt",
                    replace(read(local_run.script, String), projects.commit => "<commit>");
                    root,
                )
            end
            cd(projects.nbody) do
                launcher = main(
                    [
                        "--payload",
                        "launcher",
                        "--backend",
                        "slurm",
                        "--cluster",
                        "testsite",
                        "--cases",
                        "runs/sweep_showcase",
                        "--run-config",
                        "run.toml",
                        "--after",
                        "4242",
                        "--remote-project",
                        "/scratch/user/Nbody",
                        "--config",
                        golden,
                    ];
                    io = IOBuffer(),
                    timestamp = STAMP,
                )
                @test launcher.spec.resources.tasks == 4 &&
                      launcher.spec.resources.cpus_per_task == 8
                @test launcher.spec.commit == "unavailable"
                check_reference(
                    "slurm_launcher_array.sbatch.txt",
                    read(launcher.script, String);
                    root,
                )
            end
        end

        @testset "Specification errors" begin
            settings = load_settings(golden)
            spec(args...) =
                build_spec(Dict{String, String}(args...), settings; timestamp = STAMP)
            cd(projects.pipeline) do
                @test_throws "--run-config is required" spec("output-dir" => "data/x")
                @test_throws "--output-dir is required" spec(
                    "run-config" => "config/run.toml",
                )
                @test_throws "outside the project" spec(
                    "run-config" => joinpath(
                        root,
                        "Nbody",
                        "runs",
                        "sweep_showcase",
                        "001_orbit-eccentricity=0.1_seed=1",
                        "run.toml",
                    ),
                    "output-dir" => "data/x",
                )
                @test_throws "needs a cluster" spec(
                    "backend" => "slurm",
                    "run-config" => "config/run.toml",
                    "output-dir" => "data/x",
                )
                @test_throws "no [clusters.lisa]" spec(
                    "backend" => "slurm",
                    "cluster" => "lisa",
                    "run-config" => "config/run.toml",
                    "output-dir" => "data/x",
                )
                @test_throws "needs the slurm backend" spec(
                    "run-config" => "config/run.toml",
                    "output-dir" => "data/x",
                    "after" => "12",
                )
                @test_throws "a job id or a submission record" spec(
                    "backend" => "slurm",
                    "cluster" => "testsite",
                    "run-config" => "config/run.toml",
                    "output-dir" => "data/x",
                    "after" => "soon",
                )
                @test_throws "file name inside each case" spec(
                    "cases" => "runs/sweep",
                    "run-config" => "x/config.toml",
                )
                @test_throws "no subdirectory" spec(
                    "cases" => "runs/sweep",
                    "run-config" => "absent.toml",
                )
                @test_throws "--name may hold" spec(
                    "run-config" => "config/run.toml",
                    "output-dir" => "data/x",
                    "name" => "a b",
                )
                @test_throws "--script" spec(
                    "run-config" => "config/run.toml",
                    "output-dir" => "data/x",
                    "script" => "scripts/absent.jl",
                )
                @test_throws "--payload must be" spec("payload" => "python")
                write(
                    joinpath(projects.pipeline, "Project.toml"),
                    "name = \"Pipeline\"\n# edited\n",
                )
                @test spec("run-config" => "config/run.toml", "output-dir" => "data/x").dirty
            end
            cd(projects.nbody) do
                @test_throws "holds no Project.toml" spec("run-config" => "x.toml")
                @test_throws "launch script" spec(
                    "payload" => "launcher",
                    "run-config" => "runs/sweep_showcase/001_orbit-eccentricity=0.1_seed=1/run.toml",
                )
            end
            @test_throws "unknown command-line argument" parse_options(["--bogus", "1"])
            @test_throws "--parallel must be" parse_options(["--parallel", "0"])
            @test_throws "given twice" parse_options(["--name", "a", "--name", "b"])
            @test_throws "requires a value" parse_options(["--name"])
            io = IOBuffer()
            @test main(["--help"]; io) === nothing
            @test occursin("--run-config", String(take!(io)))
        end

        @testset "Slurm verbs on stub commands" begin
            with_stubs(root) do calls
                cd(projects.pipeline) do
                    io = IOBuffer()
                    submitted = @test_logs (:warn, r"the job runs in") main(
                        [
                            "submit",
                            "--backend",
                            "slurm",
                            "--cluster",
                            "testsite",
                            "--run-config",
                            "config/run.toml",
                            "--output-dir",
                            "data/runs/run_0003",
                            "--config",
                            golden,
                        ];
                        io,
                    )
                    @test submitted.job_id == "4242"
                    @test occursin("submitted slurm job 4242", String(take!(io)))
                    record = read_record(submitted.record)
                    @test record["job_id"] == "4242" && record["cluster"] == "testsite"
                    @test record["commit"] == projects.commit
                    @test record["resources"]["memory_gb"] == 39
                    @test record["config_hash"] == bytes2hex(sha256(read(run_config)))
                    @test record["output_directory"] == "data/runs/run_0003"
                    @test occursin(
                        "sbatch --parsable $(submitted.script)",
                        read(calls, String),
                    )
                    @test_throws "already records job 4242" main(
                        [
                            "submit",
                            "--backend",
                            "slurm",
                            "--cluster",
                            "testsite",
                            "--run-config",
                            "config/run.toml",
                            "--output-dir",
                            "data/runs/run_0003",
                            "--config",
                            golden,
                        ];
                        io = IOBuffer(),
                    )

                    chained = main(
                        [
                            "submit",
                            "--backend",
                            "slurm",
                            "--cluster",
                            "testsite",
                            "--remote-project",
                            projects.pipeline,
                            "--run-config",
                            "config/run.toml",
                            "--output-dir",
                            "data/runs/run_0004",
                            "--after",
                            "data/runs/run_0003",
                            "--config",
                            golden,
                        ];
                        io = IOBuffer(),
                    )
                    @test chained.spec.after == "4242"
                    @test occursin(
                        "--dependency=afterok:4242",
                        read(chained.script, String),
                    )

                    io = IOBuffer()
                    status = main(["status", "data/runs/run_0003", "--config", golden]; io)
                    @test only(status).state == "RUNNING"
                    @test occursin("RUNNING (elapsed 1:23, node07)", String(take!(io)))
                    finished = joinpath(
                        projects.pipeline,
                        "data",
                        "runs",
                        "run_0003",
                        "submission.toml",
                    )
                    write(
                        finished,
                        replace(
                            read(finished, String),
                            "job_id = \"4242\"" => "job_id = \"4243\"",
                        ),
                    )
                    @test only(
                        main(["status", finished, "--config", golden]; io = IOBuffer()),
                    ).state == "COMPLETED"
                    write(
                        finished,
                        replace(
                            read(finished, String),
                            "job_id = \"4243\"" => "job_id = \"4244\"",
                        ),
                    )
                    @test only(
                        main(["status", finished, "--config", golden]; io = IOBuffer()),
                    ).state == "UNKNOWN"

                    io = IOBuffer()
                    main(["cancel", "data/runs/run_0004", "--config", golden]; io)
                    @test occursin("scancel 4242", String(take!(io)))
                    @test occursin("scancel 4242", read(calls, String))

                    fetching = tool_config(
                        mkpath(joinpath(root, "fetch"));
                        fetch = "pull {project}/{output_directory}",
                    )
                    io = IOBuffer()
                    main(["fetch", "data/runs/run_0004", "--config", fetching]; io)
                    text = String(take!(io))
                    @test occursin("is RUNNING", text)
                    @test occursin(
                        "fetch with: pull $(projects.pipeline)/data/runs/run_0004",
                        text,
                    )
                end
            end
            withenv("PATH" => "/nonexistent") do
                @test_throws "sbatch not found" submit_job(
                    build_spec(
                        Dict(
                            "backend" => "slurm",
                            "cluster" => "testsite",
                            "project" => projects.pipeline,
                            "run-config" => run_config,
                            "output-dir" => joinpath(projects.pipeline, "data", "x"),
                        ),
                        load_settings(golden),
                    ),
                    load_settings(golden),
                    "job.sbatch",
                )
            end
        end

        @testset "Local backend" begin
            config = tool_config(
                mkpath(joinpath(root, "local"));
                julia = joinpath(Sys.BINDIR, "julia"),
            )
            cd(projects.pipeline) do
                single = main(
                    [
                        "submit",
                        "--run-config",
                        "config/run.toml",
                        "--output-dir",
                        "data/runs/local_single",
                        "--config",
                        config,
                    ];
                    io = IOBuffer(),
                )
                @test occursin(r"^\d+$", single.job_id)
                @test wait_for(single.record, ("COMPLETED", "FAILED", "TERMINATED")) ==
                      "COMPLETED"
                @test read(
                    joinpath(
                        projects.pipeline,
                        "data",
                        "runs",
                        "local_single",
                        "result.txt",
                    ),
                    String,
                ) == "threads 8\n"
                log = joinpath(projects.pipeline, read_record(single.record)["log"])
                @test occursin("pipeline done: config/run.toml", read(log, String))

                sweep = main(
                    [
                        "submit",
                        "--cases",
                        "runs/sweep",
                        "--run-config",
                        "config.toml",
                        "--name",
                        "sweep",
                        "--config",
                        config,
                    ];
                    io = IOBuffer(),
                )
                @test wait_for(sweep.record, ("COMPLETED", "FAILED", "TERMINATED")) ==
                      "COMPLETED"
                results = [
                    read(
                        joinpath(projects.pipeline, "runs", "sweep", c, "result.txt"),
                        String,
                    ) for c in ("001_threads=1", "002_threads=4", "003_threads=16")
                ]
                @test results == ["threads 1\n", "threads 4\n", "threads 16\n"]

                slow = main(
                    [
                        "submit",
                        "--run-config",
                        "config/slow.toml",
                        "--output-dir",
                        "data/runs/local_slow",
                        "--config",
                        config,
                    ];
                    io = IOBuffer(),
                )
                @test wait_for(slow.record, ("RUNNING",); timeout = 30) == "RUNNING"
                io = IOBuffer()
                main(["cancel", slow.record, "--config", config]; io)
                @test occursin("SIGTERM to process group $(slow.job_id)", String(take!(io)))
                @test wait_for(
                    slow.record,
                    ("TERMINATED", "FAILED", "COMPLETED");
                    timeout = 60,
                ) == "TERMINATED"
                @test !isfile(
                    joinpath(projects.pipeline, "data", "runs", "local_slow", "result.txt"),
                )
                @test_throws "is not running" main(
                    ["cancel", slow.record, "--config", config];
                    io = IOBuffer(),
                )

                auto = main(
                    [
                        "--run-config",
                        "config/auto.toml",
                        "--output-dir",
                        "data/runs/auto",
                        "--config",
                        config,
                    ];
                    io = IOBuffer(),
                )
                @test occursin("--threads=auto", read(auto.script, String))
            end
        end
    end
end
