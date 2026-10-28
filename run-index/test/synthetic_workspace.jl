# Generator of the synthetic workspace of the run-index tests: DrWatson-style projects
# with real git history and several generations of provenance files.

function git_run(dir::AbstractString, args::AbstractString...)
    out = IOBuffer()
    command = `git -C $dir -c user.name=Test -c user.email=test@example.invalid -c init.defaultBranch=main -c commit.gpgsign=false -c tag.gpgsign=false $(collect(args))`
    run(pipeline(command; stdout = out, stderr = devnull))
    return String(strip(String(take!(out))))
end

function commit!(repo::AbstractString, file::AbstractString, text::AbstractString, message)
    path = joinpath(repo, file)
    mkpath(dirname(path))
    write(path, text)
    git_run(repo, "add", file)
    git_run(repo, "commit", "--quiet", "-m", message)
    return git_run(repo, "rev-parse", "HEAD")
end

function write_run(dir::AbstractString, files::Pair...)
    mkpath(dir)
    for (name, content) in files
        write(joinpath(dir, name), content)
    end
    return dir
end

"""
    synthetic_workspace(root) -> NamedTuple

Two DrWatson-style projects under `root`, mimicking the layout and the provenance files
that accumulate in practice:

- `Curvature/`: a git repository (`Project.toml`, `scripts/`, tag `v0.1.0`, five commits
  on `main`, one on an abandoned branch `experiment`) with `data/` and `plots/` ignored.
  Its runs carry three generations of provenance file: a flat early one, a nested
  `[provenance]`/`[configuration]` one, and DrWatson `tagsave` keys (`gitcommit` from
  `git describe --dirty`, `gitpatch`, `script`) in `metadata.toml` beside savename-style
  directories. Reruns (`_r2`), seed replicates, a commit off HEAD, an unknown commit, a
  run without provenance, an unreadable provenance file, a run without commit and
  figures of a deleted run are included.
- `Lone/`: a project outside version control.

Hidden directories and a symbolic link back into `Curvature/` must be skipped.
"""
function synthetic_workspace(root::AbstractString)
    repo = joinpath(root, "Curvature")
    mkpath(repo)
    git_run(repo, "init", "--quiet", "--initial-branch=main")
    c1 = commit!(repo, "Project.toml", "name = \"Curvature\"\n", "initial")
    commit!(repo, ".gitignore", "data/\nplots/\n", "ignore outputs")
    c2 = commit!(repo, "scripts/run.jl", "# solver\n", "solver")
    git_run(repo, "tag", "v0.1.0")
    git_run(repo, "checkout", "--quiet", "-b", "experiment")
    c3 = commit!(repo, "scripts/run.jl", "# experimental solver\n", "experiment")
    git_run(repo, "checkout", "--quiet", "main")
    c4 = commit!(repo, "scripts/sweep.jl", "# sweep\n", "sweep script")
    c5 = commit!(repo, "README.md", "Curvature\n", "readme")
    data = joinpath(repo, "data")

    nested(commit, stamp, seed; L = 128, extra = "") = """
        [provenance]
        commit = "$commit"
        timestamp = $stamp
        hostname = "node07"
        cpu_model = "AMD EPYC 7763 64-Core Processor"
        julia_version = "1.12.0"
        wall_time_s = 3605.2
        $extra
        [configuration]
        L = $L
        dt = 0.005
        seed = $seed

        [configuration.solver]
        method = "Tsit5"
        abstol = 1e-10
        """
    flat(commit, stamp, seed) = """
        commit = "$commit"
        timestamp = "$stamp"
        host = "node03"
        wall_time_s = 725.0

        [config]
        L = 64
        dt = 0.01
        seed = $seed
        """
    tagsave(seed) = """
        gitcommit = "v0.1.0-1-g$(first(c4, 7))-dirty"
        gitpatch = "diff --git a/scripts/sweep.jl b/scripts/sweep.jl"
        script = "scripts/sweep.jl#21"
        started = "2026-09-01T08:00:00Z"
        finished = "2026-09-01T09:30:30Z"

        [parameters]
        N = 64
        seed = $seed

        [hardware]
        hostname = "laptop"
        cpu = "Intel(R) Core(TM) Ultra 7 155H"

        [[hardware.accelerators]]
        device_name = "Intel(R) Arc(TM) Graphics"
        """
    write_run(
        joinpath(data, "run_513e903b"),
        "provenance.toml" => nested(c1, "2026-08-05T14:02:11", 1),
        "result.jld2" => zeros(UInt8, 4096),
        "Manifest.toml" => "# copy of the resolved manifest\n",
    )
    write_run(
        joinpath(data, "run_513e903b_r2"),
        "provenance.toml" => nested(c2, "2026-08-06T09:00:00", 2),
        "result.jld2" => zeros(UInt8, 4096),
    )
    write_run(
        joinpath(data, "run_f954868c"),
        "provenance.toml" => flat("$(first(c2, 7))-dirty", "2026-08-02 09:15:00", 7),
    )
    write_run(
        joinpath(data, "run_f954868c_r2"),
        "provenance.toml" => flat("$(first(c2, 7))-dirty", "2026-08-03 10:00:00", 7),
    )
    write_run(
        joinpath(data, "run_77aa88bb"),
        "provenance.toml" => nested(c3, "2026-08-07T11:00:00", 1; L = 256),
    )
    write_run(
        joinpath(data, "run_deadbeef"),
        "provenance.toml" => nested(
            "0123456789abcdef0123456789abcdef01234567",
            "2026-08-08T08:00:00",
            1;
            L = 512,
        ),
    )
    write_run(joinpath(data, "run_0a1b2c3d"), "result.jld2" => zeros(UInt8, 100))
    write_run(
        joinpath(data, "run_1234abcd"),
        "provenance.toml" => "[provenance\ncommit = 1\n",
    )
    write_run(
        joinpath(data, "run_9e8d7c6b"),
        "provenance.toml" => "[provenance]\ntimestamp = 2026-08-09T08:00:00\n[configuration]\nL = 32\n",
    )
    write_run(
        joinpath(data, "run_51c2a7e0"),
        "provenance.toml" => nested("v0.1.0", "2026-08-04T12:00:00", 3; L = 1024),
    )
    write_run(joinpath(data, "sims", "N=64_seed=1"), "metadata.toml" => tagsave(1))
    write_run(joinpath(data, "sims", "N=64_seed=2"), "metadata.toml" => tagsave(2))
    write_run(
        joinpath(data, "deep", "a", "b", "c", "run_0000ffff"),
        "run.toml" => "commit = \"$(first(c5, 8))\"\n",
    )
    write_run(joinpath(data, "cache"), "interpolant.bin" => zeros(UInt8, 10))
    write(joinpath(data, "notes.txt"), "scratch\n")
    write_run(
        joinpath(data, ".trash", "run_ffff0000"),
        "provenance.toml" => "commit = \"$c1\"\n",
    )

    plots = joinpath(repo, "plots")
    write_run(
        plots,
        "run_513e903b_convergence.pdf" => "%PDF",
        "run_dcf44792_spectrum.pdf" => "%PDF",
        "overview.pdf" => "%PDF",
        "run_0a1b2c3d_draft.svg" => "<svg/>",
        "run_cafe0001.txt" => "not a figure",
    )
    write_run(joinpath(plots, "residuals"), "run_dcf44792_residuals.png" => "PNG")

    lone = joinpath(root, "Lone")
    mkpath(lone)
    write(joinpath(lone, "Project.toml"), "name = \"Lone\"\n")
    write_run(
        joinpath(lone, "data", "run_aaaa1111"),
        "run.toml" => "commit = \"abc1234\"\nstarted = 2026-09-02T08:00:00\nfinished = 2026-09-02T08:20:00\n",
    )
    symlink(repo, joinpath(root, "link"))
    return (; repo, lone, c1, c2, c3, c4, c5)
end
