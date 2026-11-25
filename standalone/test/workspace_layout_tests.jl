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
    @test index ==
          "# Notes index\n\n" *
          "- `worklog.md` — running state: where things stand, how to resume.\n"
    @test kinds(check_layout(root)) == [(:project, "")]

    write(joinpath(root, "notes", "worklog.md"), "kept")
    @test scaffold_layout(root) == String[]
    @test read(joinpath(root, "notes", "worklog.md"), String) == "kept"
    @test !ispath(joinpath(root, "showcase"))

    blocked = mktempdir()
    write(joinpath(blocked, "paper"), "x")
    @test_throws ArgumentError scaffold_layout(blocked)
    @test readdir(blocked) == ["paper"]
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
        "x" => ["x"],
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
        "admin = \"/root/projects/x\"",
    ]
    write_fixture(repo, "config.toml", lines)
    commit_fixtures(repo)

    result = scan_self_containment(repo; home = "/home/nobody")
    @test hits(result) == [
        ("config.toml", 1, :absolute_path),
        ("config.toml", 7, :machine_path),
        ("config.toml", 8, :absolute_path),
        ("config.toml", 9, :home_path),
        ("config.toml", 10, :absolute_path),
        ("config.toml", 11, :absolute_path),
    ]
    matches = Dict(f.line => f.match for f in result)
    @test matches[1] == "/scratch/project/data"
    @test matches[7] == "/home/nobody/data/x.csv"
    @test matches[8] == "/cluster/home/user/Pipeline"
    @test matches[9] == "~/toolbox/run.jl"
    @test matches[10] == "/home/nobodyelse/x"
    @test matches[11] == "/root/projects/x"

    for home in ("/root", "/")
        result = scan_self_containment(repo; home)
        @test all(f.kind != :machine_path for f in result)
        @test (11, :absolute_path) in [(f.line, f.kind) for f in result]
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
    @test_throws ArgumentError parse_args(["--scaffold"])
    @test parse_args(["/tmp/a", "--scaffold"]).scaffold
    @test parse_args(["/tmp/a", "--scaffold"]).layout
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
    code, _ = run_main([mktempdir(), "--self-contained"])
    @test code == 2
end

@testset "workspace-audit: unicode in notes and paths" begin
    root = conforming_workspace()
    notes = joinpath(root, "notes")
    write(joinpath(notes, "２０２６-１１-２５-x.md"), "x")
    index =
        ["# Notes index", "", "- `worklog.md` — state", "- `２０２６-１１-２５-x.md` — a"]
    write(joinpath(notes, "00-index.md"), join(index, "\n") * "\n")
    @test kinds(check_layout(root)) == [(:notes_name, "notes/２０２６-１１-２５-x.md")]

    repo = make_repository(mktempdir())
    write_fixture(repo, "a.md", ["see /home/joé/x"])
    commit_fixtures(repo)
    result = scan_self_containment(repo; home = "/home/jo")
    @test hits(result) == [("a.md", 1, :absolute_path)]

    repo = make_repository(mktempdir())
    write_fixture(repo, "a.md", ["p = \"/home/nobody/café\""])
    commit_fixtures(repo)
    result = scan_self_containment(repo; home = "/home/nobody")
    @test length(result) == 1
    @test result[1].kind == :machine_path
    @test result[1].match == "/home/nobody/café"
end

@testset "workspace-audit: climbs in Julia source" begin
    repo = make_repository(mktempdir())
    files = [
        "scripts/wrapped.jl" =>
            ["x = joinpath(", "    @__DIR__" * ",", "    \"..\",", "    \"..\",", ")"],
        "scripts/inside.jl" => [
            "x = joinpath(",
            "    @__DIR__" * ",",
            "    \"..\",",
            "    \"data\",",
            ")",
        ],
        "src/interp.jl" => ["p = \"\$(@__DIR__)/" * up(2) * "x\""],
        "src/concat.jl" => ["q = @__DIR__ * \"" * "/.." * "\""],
        "src/concat2.jl" => ["q = @__DIR__ * \"/" * up(1) * "..\""],
    ]
    for (rel, lines) in files
        write_fixture(repo, rel, lines)
    end
    commit_fixtures(repo)

    result = scan_self_containment(repo; home = "/home/nobody")
    expected = [
        ("scripts/wrapped.jl", 2, :outside),
        ("src/interp.jl", 1, :outside),
        ("src/concat2.jl", 1, :outside),
    ]
    @test sort(hits(result)) == sort(expected)
    wrapped = only(f for f in result if f.file == "scripts/wrapped.jl")
    @test wrapped.match == strip(dirclimb(2))
end

@testset "workspace-audit: parent references in TOML" begin
    repo = make_repository(mktempdir())
    lines = ["[sources]", "X = {path = \"..\"}"]
    write_fixture(repo, "Project.toml", lines)
    write_fixture(repo, "test/Project.toml", lines)
    commit_fixtures(repo)
    result = scan_self_containment(repo; home = "/home/nobody")
    @test hits(result) == [("Project.toml", 2, :outside)]
end

@testset "workspace-audit: symbolic links" begin
    repo = make_repository(mktempdir())
    write_fixture(repo, "README.md", ["readme"])
    write_fixture(repo, "docs/a.md", ["a"])
    symlink(up(2) * "notes", joinpath(repo, "link"))
    symlink(up(1) * "README.md", joinpath(repo, "docs", "inner"))
    symlink("/somewhere/else", joinpath(repo, "abs"))
    commit_fixtures(repo)
    result = scan_self_containment(repo; home = "/home/nobody")
    @test sort(hits(result)) == [("abs", 0, :outside), ("link", 0, :outside)]
    link = only(f for f in result if f.file == "link")
    @test link.match == up(2) * "notes"
end

@testset "workspace-audit: paths read from the repository root" begin
    repo = make_repository(mktempdir())
    files = [
        "README.md" => ["readme"],
        "configs/run.toml" => [
            "output_dir = \"" * up(1) * "artefacts/runs\"",
            "input = \"" * up(1) * "data/in.csv\"",
            "readme = \"" * up(1) * "README.md\"",
        ],
        "docs/guide.md" =>
            ["See " * up(1) * "README.md.", "notes in " * up(1) * "notes/x.md"],
    ]
    for (rel, lines) in files
        write_fixture(repo, rel, lines)
    end
    commit_fixtures(repo)
    result = scan_self_containment(repo; home = "/home/nobody")
    expected = [
        ("configs/run.toml", 1, :outside),
        ("configs/run.toml", 2, :unresolved),
        ("docs/guide.md", 2, :outside),
    ]
    @test sort(hits(result)) == sort(expected)

    repo = make_repository(mktempdir())
    write_fixture(repo, "artefacts/runs/keep", ["x"])
    line = "output_dir = \"" * up(1) * "artefacts/runs\""
    write_fixture(repo, "configs/run.toml", [line])
    commit_fixtures(repo)
    @test isempty(scan_self_containment(repo; home = "/home/nobody"))
end

@testset "workspace-audit: home written with a tilde or a variable" begin
    repo = make_repository(mktempdir())
    write_fixture(repo, "README.md", ["~/ws/notes/x.md", "\$HOME/ws/x", "\${HOME}/ws/x"])
    commit_fixtures(repo)
    result = scan_self_containment(repo; home = "/home/nobody")
    @test hits(result) == [
        ("README.md", 1, :home_path),
        ("README.md", 2, :home_path),
        ("README.md", 3, :home_path),
    ]
    code, out = run_main([repo, "--self-contained"])
    @test code == 0
    @test occursin("Absolute paths to review", out)
end

@testset "workspace-audit: order within a line" begin
    repo = make_repository(mktempdir())
    write_fixture(repo, "order.md", [up(1) * "a /scratch/b/c"])
    commit_fixtures(repo)
    result = scan_self_containment(repo; home = "/home/nobody")
    @test [f.kind for f in result] == [:outside, :absolute_path]
end

@testset "workspace-audit: exit status of a home-directory path" begin
    repo = make_repository(mktempdir())
    write_fixture(repo, "a.md", ["data in /home/nobody/data/x.csv"])
    commit_fixtures(repo)
    status = withenv("HOME" => "/home/nobody") do
        run_main([repo, "--self-contained"])
    end
    code, out = status
    @test code == 1
    @test occursin("Outside the repository", out)
end

# Cases of the review of the fix round (2026-11-25); the expected kinds follow from
# resolving each path with normpath from the file and from the repository root.
@testset "workspace-audit: climbs with inner steps and tracked targets" begin
    # inner `.` and `..` steps are resolved over the whole path
    repo = make_repository(mktempdir())
    write_fixture(
        repo,
        "configs/run.toml",
        [
            "a = \"" * up(1) * "./..\"",
            "b = \"" * up(1) * "./notes/x.md\"",
            "c = \"" * up(1) * "configs/" * up(2) * "notes/x.md\"",
        ],
    )
    commit_fixtures(repo)
    @test hits(scan_self_containment(repo; home = "/home/nobody")) == [
        ("configs/run.toml", 1, :outside),
        ("configs/run.toml", 2, :outside),
        ("configs/run.toml", 3, :outside),
    ]

    # a byte that is not UTF-8 on one line hides no joinpath climb on another
    repo = make_repository(mktempdir())
    mkpath(joinpath(repo, "src"))
    write(
        joinpath(repo, "src", "a.jl"),
        "x = joinpath(@__DIR__" * ", \"..\", \"..\")\n# " * String([0xff]) * "\n",
    )
    commit_fixtures(repo)
    @test hits(scan_self_containment(repo; home = "/home/nobody")) ==
          [("src/a.jl", 1, :outside)]

    # a file to be written into a tracked directory named like the workspace layout is
    # listed for review: read from the repository root, it leads into the workspace;
    # into an untracked one it is a finding; into another tracked directory, nothing
    repo = make_repository(mktempdir())
    write_fixture(repo, "paper/.gitkeep", String[])
    write_fixture(repo, "results/.gitkeep", String[])
    write_fixture(
        repo,
        "scripts/plot.jl",
        [
            "save(\"" * up(1) * "paper/fig.pdf\", f)",
            "save(\"" * up(1) * "results/fig.pdf\", f)",
        ],
    )
    commit_fixtures(repo)
    @test hits(scan_self_containment(repo; home = "/home/nobody")) ==
          [("scripts/plot.jl", 1, :unresolved)]
    repo = make_repository(mktempdir())
    write_fixture(repo, "scripts/plot.jl", ["save(\"" * up(1) * "paper/fig.pdf\", f)"])
    commit_fixtures(repo)
    @test hits(scan_self_containment(repo; home = "/home/nobody")) ==
          [("scripts/plot.jl", 1, :outside)]

    # existence is judged on tracked paths: an untracked directory does not hide a climb
    repo = make_repository(mktempdir())
    write_fixture(repo, "configs/run.toml", ["out = \"" * up(1) * "artefacts/runs\""])
    commit_fixtures(repo)
    mkpath(joinpath(repo, "artefacts", "runs"))
    @test hits(scan_self_containment(repo; home = "/home/nobody")) ==
          [("configs/run.toml", 1, :outside)]

    # one climb, one finding: the quoted argument of a joinpath is not read twice
    repo = make_repository(mktempdir())
    write_fixture(
        repo,
        "scripts/run.jl",
        ["p = joinpath(@__DIR__" * ", \"" * up(1) * "..\", \"x\")"],
    )
    commit_fixtures(repo)
    result = scan_self_containment(repo; home = "/home/nobody")
    @test hits(result) == [("scripts/run.jl", 1, :outside)]
    @test startswith(only(result).match, "@__DIR__")
end

# Cases of the third review (2026-11-25).
@testset "workspace-audit: full stops, the root as a directory, CRLF" begin
    # `..` followed by a full stop keeps its climb
    repo = make_repository(mktempdir())
    write_fixture(
        repo,
        "docs/guide.md",
        ["root is " * up(1) * "...", "see " * up(1) * "notes/..."],
    )
    commit_fixtures(repo)
    @test hits(scan_self_containment(repo; home = "/home/nobody")) ==
          [("docs/guide.md", 1, :outside)]

    # the root is no tracked directory that excuses a bare layout name
    repo = make_repository(mktempdir())
    write_fixture(repo, "configs/run.toml", ["out = \"" * up(1) * "notes\""])
    commit_fixtures(repo)
    @test hits(scan_self_containment(repo; home = "/home/nobody")) ==
          [("configs/run.toml", 1, :outside)]

    # a wrapped joinpath after a multi-byte character, lines ended by CRLF: one finding,
    # at the line of @__DIR__, and the quoted argument on line 4 is not read again
    repo = make_repository(mktempdir())
    mkpath(joinpath(repo, "scripts"))
    write(
        joinpath(repo, "scripts", "run.jl"),
        "# é\r\nx = joinpath(\r\n    @__DIR__" * ",\r\n    \"" * up(1) * "..\",\r\n)\r\n",
    )
    commit_fixtures(repo)
    @test hits(scan_self_containment(repo; home = "/home/nobody")) ==
          [("scripts/run.jl", 3, :outside)]
end
