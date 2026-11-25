# Layout and self-containment checks of workspace-audit. Included from runtests.jl, which
# provides `git_run`, `make_repository` and `captured_stdout`.

# A fixture path that climbs out of a directory is assembled here, never written out: this
# file is scanned by the tool itself.
up(n) = repeat("../", n)
dirclimb(n) = "@__DIR__, " * repeat("\"..\", ", n)

kinds(findings) = [(f.kind, f.path) for f in findings]
hits(findings) = [(f.file, f.line, f.kind) for f in findings]

const EXPECTED_DIRECTORIES = (
    "context",
    "context/code",
    "context/knowledge",
    "notes",
    "paper",
    "utilities",
    "artefacts",
    "artefacts/data",
    "artefacts/plots",
    "artefacts/runs",
    "tmp",
)

# Write `lines` to `rel` below `dir`, creating subdirectories.
function write_fixture(dir::AbstractString, rel::AbstractString, lines)
    path = joinpath(dir, split(rel, "/")...)
    mkpath(dirname(path))
    write(path, join(lines, "\n") * "\n")
    return path
end

function commit_fixtures(repo::AbstractString)
    git_run(repo, "add", "-A")
    git_run(repo, "commit", "--quiet", "-m", "fixtures")
    return nothing
end

# Scaffolded workspace holding one project repository.
function conforming_workspace()
    root = mktempdir()
    scaffold_layout(root)
    make_repository(joinpath(root, "Project"))
    return root
end

# Return value and standard output of `main(args)`.
function run_main(args)
    code = Ref(-1)
    out = captured_stdout(() -> (code[] = main(args)))
    return code[], out
end

@testset "workspace-audit: layout of an empty directory" begin
    root = mktempdir()
    findings = check_layout(root)
    expected = [
        [(:missing_directory, d) for d in EXPECTED_DIRECTORIES]
        (:missing_file, "notes/00-index.md")
        (:missing_file, "notes/worklog.md")
        (:project, "")
    ]
    @test length(findings) == 14
    @test kinds(findings) == expected
    @test findings[end].message == "no project repository at the workspace root"
end

@testset "workspace-audit: scaffold" begin
    root = mktempdir()
    created = scaffold_layout(root)
    @test created ==
          [collect(EXPECTED_DIRECTORIES); "notes/00-index.md"; "notes/worklog.md"]
    @test all(isdir(joinpath(root, d)) for d in EXPECTED_DIRECTORIES)
    @test read(joinpath(root, "notes", "worklog.md"), String) == "# Worklog\n"
    index = read(joinpath(root, "notes", "00-index.md"), String)
    @test startswith(index, "# Notes index\n")
    @test occursin("worklog.md", index)
    @test kinds(check_layout(root)) == [(:project, "")]

    write(joinpath(root, "notes", "worklog.md"), "kept")
    @test scaffold_layout(root) == String[]
    @test read(joinpath(root, "notes", "worklog.md"), String) == "kept"
    @test !ispath(joinpath(root, "showcase"))

    blocked = mktempdir()
    write(joinpath(blocked, "paper"), "x")
    @test_throws ArgumentError scaffold_layout(blocked)
end

@testset "workspace-audit: conforming workspace" begin
    root = conforming_workspace()
    @test isempty(check_layout(root))
    mkdir(joinpath(root, "showcase"))
    @test isempty(check_layout(root))
    mkdir(joinpath(root, ".claude"))
    @test isempty(check_layout(root))
end

@testset "workspace-audit: project repositories" begin
    root = mktempdir()
    scaffold_layout(root)
    make_repository(joinpath(root, "Beta"))
    make_repository(joinpath(root, "Alpha"))
    findings = check_layout(root)
    @test kinds(findings) == [(:project, "")]
    @test findings[1].message == "2 repositories at the workspace root: Alpha, Beta"

    root = conforming_workspace()
    make_repository(joinpath(root, "utilities", "toolbox"))
    @test isempty(check_layout(root))
end

@testset "workspace-audit: stray entries" begin
    root = conforming_workspace()
    write(joinpath(root, "todo.txt"), "x")
    mkdir(joinpath(root, "scratch"))
    @test kinds(check_layout(root)) == [(:stray, "scratch"), (:stray, "todo.txt")]
end

@testset "workspace-audit: scratch directory" begin
    root = conforming_workspace()
    write(joinpath(root, "tmp", "a"), "x")
    mkdir(joinpath(root, "tmp", "b"))
    findings = check_layout(root)
    @test kinds(findings) == [(:tmp, "tmp")]
    @test findings[1].message == "2 entries left in tmp/"

    root = conforming_workspace()
    write(joinpath(root, "tmp", "a"), "x")
    findings = check_layout(root)
    @test kinds(findings) == [(:tmp, "tmp")]
    @test findings[1].message == "1 entry left in tmp/"
end

@testset "workspace-audit: notes" begin
    root = conforming_workspace()
    notes = joinpath(root, "notes")
    for name in (
        "2026-11-25-topic.md",
        "2026-11-25-unlisted.md",
        "draft.md",
        "2026-13-45-bad.md",
        "figure.png",
    )
        write(joinpath(notes, name), "x")
    end
    mkdir(joinpath(notes, "archive"))
    index = [
        "# Notes index",
        "",
        "- `worklog.md` — state",
        "- `2026-11-25-topic.md` — a",
        "- `draft.md` — b",
        "- `2026-13-45-bad.md` — c",
        "- `2026-01-01-gone.md` — d",
    ]
    write(joinpath(notes, "00-index.md"), join(index, "\n") * "\n")
    findings = check_layout(root)
    @test kinds(findings) == [
        (:notes_index, "notes/2026-11-25-unlisted.md"),
        (:notes_index, "notes/2026-01-01-gone.md"),
        (:notes_name, "notes/2026-13-45-bad.md"),
        (:notes_name, "notes/draft.md"),
    ]
    @test findings[1].message == "not listed in notes/00-index.md"
    @test findings[2].message == "listed in notes/00-index.md but absent"
    @test findings[3].message == "name is not YYYY-MM-DD-topic.md"
    @test findings[4].message == "name is not YYYY-MM-DD-topic.md"
end

@testset "workspace-audit: layout of a repository" begin
    repo = make_repository(mktempdir())
    @test_throws ArgumentError check_layout(repo)
    @test_throws ArgumentError scaffold_layout(repo)
    @test_throws ArgumentError check_layout(joinpath(repo, "absent"))
end

@testset "workspace-audit: paths that leave the repository" begin
    repo = make_repository(mktempdir())
    files = [
        "README.md" => ["see " * up(1) * "notes/x.md", "[guide](docs/guide.md)"],
        "docs/guide.md" => [
            "[readme](" * up(1) * "README.md)",
            "data in " * up(2) * "context/code",
            "https://example.org/a/" * up(1) * "b",
        ],
        "scripts/run.jl" => [
            "include(joinpath(" * dirclimb(1) * "\"activate.jl\"))",
            "joinpath(" * dirclimb(2) * "\"artefacts\")",
        ],
        "test/Project.toml" => ["path = \"..\"", "path = \"" * up(1) * "..\""],
        "a/b/deep.md" => [up(2) * "x", up(3) * "x", "./" * up(3) * "x"],
    ]
    for (rel, lines) in files
        write_fixture(repo, rel, lines)
    end
    commit_fixtures(repo)

    result = scan_self_containment(repo; home = "/home/nobody")
    expected = [
        ("README.md", 1, :outside),
        ("docs/guide.md", 2, :outside),
        ("scripts/run.jl", 2, :outside),
        ("test/Project.toml", 2, :outside),
        ("a/b/deep.md", 2, :outside),
        ("a/b/deep.md", 3, :outside),
    ]
    sort!(expected)
    @test length(result) == 6
    @test sort(hits(result)) == expected
    @test issorted([(f.file, f.line) for f in result])
    readme = only(f for f in result if f.file == "README.md")
    @test readme.match == up(1) * "notes/x.md"
end

@testset "workspace-audit: absolute paths" begin
    repo = make_repository(mktempdir())
    lines = [
        "root = \"/scratch/project/data\"",
        "cpuinfo = \"/proc/cpuinfo\"",
        "#!/usr/bin/env julia",
        "url = \"https://example.org/home/x/y\"",
        "ratio = 1/2/3 km/s/Mpc",
        "</details> 2>/dev/null",
        "data = \"/home/nobody/data/x.csv\"",
        "--chdir=/cluster/home/user/Pipeline",
        "julia ~/toolbox/run.jl",
        "other = \"/home/nobodyelse/x\"",
    ]
    write_fixture(repo, "config.toml", lines)
    commit_fixtures(repo)

    result = scan_self_containment(repo; home = "/home/nobody")
    @test hits(result) == [
        ("config.toml", 1, :absolute_path),
        ("config.toml", 7, :machine_path),
        ("config.toml", 8, :absolute_path),
        ("config.toml", 10, :absolute_path),
    ]
    matches = Dict(f.line => f.match for f in result)
    @test matches[1] == "/scratch/project/data"
    @test matches[7] == "/home/nobody/data/x.csv"
    @test matches[8] == "/cluster/home/user/Pipeline"
    @test matches[10] == "/home/nobodyelse/x"

    for home in ("/root", "/")
        @test all(f.kind != :machine_path for f in scan_self_containment(repo; home))
    end
end

@testset "workspace-audit: what is scanned" begin
    repo = make_repository(mktempdir())
    write_fixture(repo, "ok.md", ["fine"])
    write(joinpath(repo, "blob.bin"), "\0" * up(1) * "notes")
    git_run(repo, "add", "ok.md", "blob.bin")
    git_run(repo, "commit", "--quiet", "-m", "fixtures")
    write(joinpath(repo, "untracked.md"), up(1) * "notes")
    @test isempty(scan_self_containment(repo; home = "/home/nobody"))
    @test_throws ArgumentError scan_self_containment(mktempdir())
end

@testset "workspace-audit: options" begin
    defaults = parse_args(String[])
    @test !defaults.layout
    @test !defaults.scaffold
    @test !defaults.self_contained
    @test parse_args(["--layout"]).layout
    @test parse_args(["--scaffold"]).scaffold
    @test parse_args(["--self-contained"]).self_contained
    @test parse_args(["/tmp/a", "--fetch"]) == (;
        root = "/tmp/a",
        dirty_only = false,
        fetch = true,
        depth = 2,
        layout = false,
        scaffold = false,
        self_contained = false,
        help = false,
    )
end

@testset "workspace-audit: entry point with checks" begin
    root = mktempdir()
    code, out = run_main([root, "--layout"])
    @test code == 1
    @test occursin("Layout", out)
    @test occursin("directory missing", out)

    code, out = run_main([root, "--scaffold"])
    @test code == 1
    @test occursin("Scaffold", out)
    @test occursin("no project repository at the workspace root", out)
    _, out = run_main([root, "--scaffold"])
    @test occursin("nothing to create", out)

    project = make_repository(joinpath(root, "Project"))
    code, out = run_main([root, "--layout"])
    @test code == 0
    @test occursin("conforms to the workspace layout", out)

    code, out = run_main([root, "--layout", "--dirty-only", "--self-contained"])
    @test code == 0
    @test occursin("Self-containment", out)
    @test occursin("no reference outside the repository", out)

    write_fixture(project, "README.md", [up(1) * "notes/x.md"])
    commit_fixtures(project)
    code, out = run_main([root, "--self-contained"])
    @test code == 1
    @test occursin("Outside the repository", out)
    @test occursin("README.md:1", out)
    code, _ = run_main([project, "--self-contained"])
    @test code == 1

    repo = make_repository(mktempdir())
    write_fixture(repo, "config.toml", ["root = \"/scratch/project/data\""])
    commit_fixtures(repo)
    code, out = run_main([repo, "--self-contained"])
    @test code == 0
    @test occursin("Absolute paths to review", out)

    code, _ = run_main([make_repository(mktempdir()), "--layout"])
    @test code == 2
end
