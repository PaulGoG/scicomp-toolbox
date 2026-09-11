# Test suite of the standalone scripts. They are plain scripts rather than packages, so
# each is included and its functions exercised directly; the repositories the audit reads
# are built with `git init` inside `mktempdir()`, so no fixture data is committed.

using Test: @test, @test_throws, @testset

const STANDALONE_DIR = dirname(@__DIR__)

include(joinpath(STANDALONE_DIR, "workspace-audit.jl"))
include(joinpath(STANDALONE_DIR, "sysinfo.jl"))

"""
    git_run(dir, args...)

Run a git command in `dir`, failing the test run if git itself fails. Identity and default
branch are pinned per invocation so the suite does not depend on the user's global
configuration.
"""
function git_run(dir::AbstractString, args::AbstractString...)
    argv = collect(args)
    run(
        pipeline(
            `git -C $dir -c user.name=Test -c user.email=test@example.invalid -c init.defaultBranch=main -c commit.gpgsign=false $argv`;
            stdout = devnull,
            stderr = devnull,
        ),
    )
    return nothing
end

"""
    make_repository(dir; content = "x") -> String

Initialise a repository in `dir` with one committed file and return `dir`.
"""
function make_repository(dir::AbstractString; content::AbstractString = "x")
    mkpath(dir)
    git_run(dir, "init", "--quiet", "--initial-branch=main")
    write(joinpath(dir, "tracked.txt"), content)
    git_run(dir, "add", "tracked.txt")
    git_run(dir, "commit", "--quiet", "-m", "initial")
    return dir
end

@testset "standalone" begin
    @testset "workspace-audit: porcelain parsing" begin
        # "XY <path>" entries, NUL separated; a rename carries a second path field
        @test parse_status("") == (0, String[])
        @test parse_status("?? new.txt\0") == (0, ["new.txt"])
        @test parse_status(" M a.jl\0") == (1, String[])
        @test parse_status("A  a.jl\0?? b.jl\0") == (1, ["b.jl"])
        tracked, untracked = parse_status("R  new.jl\0old.jl\0?? c.jl\0")
        @test tracked == 1
        @test untracked == ["c.jl"]
        # the source path of a rename must not be counted as a further entry
        @test first(parse_status("R  new.jl\0old.jl\0")) == 1
        # a path containing a space survives, which is why the NUL form is used
        @test parse_status("?? a file.txt\0") == (0, ["a file.txt"])
        # short or malformed fields are skipped rather than throwing
        @test parse_status("x\0") == (0, String[])
    end

    @testset "workspace-audit: formatting" begin
        @test format_bytes(0) == "0 B"
        @test format_bytes(512) == "512 B"
        @test format_bytes(1024) == "1.00 KiB"
        @test format_bytes(1024^2) == "1.00 MiB"
        @test format_bytes(3 * 1024^3) == "3.00 GiB"
        @test occursin("TiB", format_bytes(2 * 1024^4))
        @test format_age(3600) == "1 h"
        @test format_age(86400) == "1 d"
        @test format_age(5 * 86400) == "5 d"
    end

    @testset "workspace-audit: path sizes" begin
        mktempdir() do dir
            @test path_size(joinpath(dir, "absent")) == 0
            write(joinpath(dir, "a.bin"), zeros(UInt8, 2048))
            @test path_size(joinpath(dir, "a.bin")) == 2048
            mkpath(joinpath(dir, "nested", "deeper"))
            write(joinpath(dir, "nested", "deeper", "b.bin"), zeros(UInt8, 1024))
            @test path_size(dir) == 3072
        end
    end

    @testset "workspace-audit: argument parsing" begin
        options = parse_args(String[])
        @test options.root === nothing
        @test !options.dirty_only
        @test !options.fetch
        @test !options.help
        @test parse_args(["--dirty-only"]).dirty_only
        @test parse_args(["--fetch"]).fetch
        @test parse_args(["-h"]).help
        @test parse_args(["--help"]).help
        @test parse_args(["/tmp/somewhere"]).root == "/tmp/somewhere"
        @test parse_args(["/tmp/a", "--fetch"]) ==
              (; root = "/tmp/a", dirty_only = false, fetch = true, help = false)
        @test_throws ArgumentError parse_args(["--unknown"])
        @test_throws ArgumentError parse_args(["/tmp/a", "/tmp/b"])
    end

    @testset "workspace-audit: default root is the parent of the repository" begin
        # standalone/ sits in the repository, whose parent is the workspace
        @test default_root() == dirname(dirname(STANDALONE_DIR))
        @test isdir(default_root())
    end

    @testset "workspace-audit: a plain directory is not a repository" begin
        mktempdir() do dir
            plain = joinpath(dir, "plain")
            mkpath(plain)
            report = audit_directory(plain)
            @test !report.is_repository
            @test report.name == "plain"
            @test isempty(report.leftovers)
            @test !needs_attention(report)
        end
    end

    @testset "workspace-audit: clean, dirty and untracked states" begin
        mktempdir() do dir
            repo = make_repository(joinpath(dir, "project"))
            report = audit_directory(repo)
            @test report.is_repository
            @test report.branch == "main"
            @test !isempty(report.commit)
            @test report.tracked_changes == 0
            @test report.untracked_count == 0
            # no upstream is configured, which is itself worth reporting
            @test isempty(report.upstream)
            @test needs_attention(report)

            write(joinpath(repo, "tracked.txt"), "changed")
            write(joinpath(repo, "untracked.bin"), zeros(UInt8, 4096))
            dirty = audit_directory(repo)
            @test dirty.tracked_changes == 1
            @test dirty.untracked_count == 1
            @test dirty.untracked_bytes == 4096
            @test first(dirty.largest_untracked) == ("untracked.bin", 4096)
            @test needs_attention(dirty)
        end
    end

    @testset "workspace-audit: ahead of and behind the upstream" begin
        mktempdir() do dir
            origin = joinpath(dir, "origin.git")
            mkpath(origin)
            git_run(origin, "init", "--bare", "--quiet", "--initial-branch=main")

            work = make_repository(joinpath(dir, "work"))
            git_run(work, "remote", "add", "origin", origin)
            git_run(work, "push", "--quiet", "-u", "origin", "main")

            synced = audit_directory(work)
            @test synced.upstream == "origin/main"
            @test synced.ahead == 0
            @test synced.behind == 0
            @test occursin("origin.git", synced.remote)
            @test !needs_attention(synced)

            write(joinpath(work, "tracked.txt"), "second")
            git_run(work, "commit", "--quiet", "-am", "second")
            ahead = audit_directory(work)
            @test ahead.ahead == 1
            @test ahead.behind == 0
            @test needs_attention(ahead)

            # a second clone pushes, so the first falls behind once its refs are refreshed
            other = joinpath(dir, "other")
            git_run(dir, "clone", "--quiet", origin, other)
            write(joinpath(other, "tracked.txt"), "from other")
            git_run(other, "commit", "--quiet", "-am", "from other")
            git_run(other, "push", "--quiet", "origin", "main")

            git_run(work, "fetch", "--quiet", "origin")
            diverged = audit_directory(work)
            @test diverged.ahead == 1
            @test diverged.behind == 1
        end
    end

    @testset "workspace-audit: stashes are counted" begin
        mktempdir() do dir
            repo = make_repository(joinpath(dir, "project"))
            @test audit_directory(repo).stashes == 0
            write(joinpath(repo, "tracked.txt"), "wip")
            git_run(repo, "stash", "push", "--quiet", "-m", "first")
            write(joinpath(repo, "tracked.txt"), "wip again")
            git_run(repo, "stash", "push", "--quiet", "-m", "second")
            report = audit_directory(repo)
            @test report.stashes == 2
            @test report.tracked_changes == 0
            @test needs_attention(report)
        end
    end

    @testset "workspace-audit: backup artifacts and staleness" begin
        mktempdir() do dir
            repo = make_repository(joinpath(dir, "project"))
            fresh = joinpath(repo, "project.backup.bundle")
            write(fresh, zeros(UInt8, 1024))
            mkpath(joinpath(repo, "project.git.backup"))
            write(joinpath(repo, "project.git.backup", "blob"), zeros(UInt8, 2048))

            report = audit_directory(repo)
            @test length(report.leftovers) == 2
            names = sort([l.name for l in report.leftovers])
            @test names == ["project.backup.bundle", "project.git.backup"]
            @test all(l -> l.bytes > 0, report.leftovers)
            # both were written after HEAD, so neither is stale yet
            @test !any(l -> l.stale, report.leftovers)
            @test needs_attention(report)

            # an artifact predating HEAD cannot hold the current work; moving the commit
            # forward is steadier than rewriting the file's timestamp
            withenv("GIT_COMMITTER_DATE" => "2099-01-01T00:00:00+0000") do
                git_run(repo, "commit", "--quiet", "--allow-empty", "-m", "later")
            end
            stale_report = audit_directory(repo)
            @test all(l -> l.stale, stale_report.leftovers)

            # a directory that is not a repository still reports its artifacts
            plain = joinpath(dir, "plain")
            mkpath(plain)
            write(joinpath(plain, "old.backup.bundle"), zeros(UInt8, 16))
            plain_report = audit_directory(plain)
            @test length(plain_report.leftovers) == 1
            # staleness is undefined without a HEAD to compare against
            @test !first(plain_report.leftovers).stale
            @test needs_attention(plain_report)
        end
    end

    @testset "workspace-audit: the workspace walk is one level deep" begin
        mktempdir() do dir
            make_repository(joinpath(dir, "alpha"))
            make_repository(joinpath(dir, "beta"))
            # a repository nested deeper must not appear as its own entry
            make_repository(joinpath(dir, "alpha", "inner"))
            mkpath(joinpath(dir, ".hidden"))
            write(joinpath(dir, "loose.txt"), "not a directory")

            reports = audit_workspace(dir)
            @test [r.name for r in reports] == ["alpha", "beta"]
            @test all(r -> r.is_repository, reports)
            @test_throws ArgumentError audit_workspace(joinpath(dir, "absent"))
        end
    end

    @testset "workspace-audit: entry point" begin
        mktempdir() do dir
            make_repository(joinpath(dir, "project"))
            @test main(["--help"]) == 0
            @test main([dir]) == 0
            @test main([dir, "--dirty-only"]) == 0
            @test main(["--unknown"]) == 2
            @test main([joinpath(dir, "absent")]) == 1
        end
    end

    @testset "sysinfo: physical core count" begin
        count, source = physical_core_count()
        @test count >= 1
        @test count <= Sys.CPU_THREADS
        @test !isempty(source)
        if Sys.islinux() && isfile("/proc/cpuinfo")
            @test source == "/proc/cpuinfo"
        end
    end

    @testset "sysinfo: repository revision" begin
        mktempdir() do dir
            @test repository_revision(dir) === nothing
            repo = make_repository(joinpath(dir, "project"))
            revision = repository_revision(repo)
            @test revision !== nothing
            @test revision[1] == "main"
            @test !isempty(revision[2])
        end
    end
end
