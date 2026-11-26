# Tests of project-scaffold. The action repositories whose tags are read are made with
# git in mktempdir(), so that GitHub is not contacted; the packages are generated into
# temporary directories and then judged by what a user would run in them: their own test
# suite, their entry points and the launch check of this workbench.

using Test: @test, @test_throws, @testset
using TOML: TOML

# Git reads neither the configuration of the user nor that of the system here.
ENV["GIT_CONFIG_GLOBAL"] = Sys.iswindows() ? "NUL" : "/dev/null"
ENV["GIT_CONFIG_NOSYSTEM"] = "1"

include(joinpath(@__DIR__, "..", "project-scaffold.jl"))

const TOOL_DIR = normpath(joinpath(@__DIR__, ".."))
const TOOLBOX = normpath(joinpath(TOOL_DIR, ".."))
const SETTINGS = load_settings(joinpath(TOOL_DIR, "config.toml"))
const ACTIONS = Dict(
    "actions/checkout" => 7,
    "julia-actions/setup-julia" => 3,
    "julia-actions/cache" => 3,
    "julia-actions/julia-buildpkg" => 1,
    "julia-actions/julia-runtest" => 1,
    "julia-actions/julia-processcoverage" => 1,
    "julia-actions/julia-docdeploy" => 1,
    "codecov/codecov-action" => 6,
)
const IDENTITY = (
    "GIT_AUTHOR_NAME" => "Test",
    "GIT_AUTHOR_EMAIL" => "test@example.invalid",
    "GIT_COMMITTER_NAME" => "Test",
    "GIT_COMMITTER_EMAIL" => "test@example.invalid",
)
const GUARD = "if: github.event.repository.visibility == 'public'"

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

git_text(dir, args...) = String(strip(read(`git -C $dir $(collect(args))`, String)))

"""
    action_host() -> Tuple{String, Dict{String, String}}

A directory holding one repository per action, each with a lightweight tag `vM.0.0` on
its first commit and an annotated tag `vM.2.3` on its second, and the pin each action
must resolve to: the commit of the annotated tag, read with the git command line.
"""
function action_host()
    host = realpath(mktempdir())
    pins = Dict{String, String}()
    for (action, major) in ACTIONS
        repo = joinpath(host, split(action, '/')...)
        mkpath(repo)
        git_run(repo, "init")
        write(joinpath(repo, "action.yml"), "name: $action\n")
        git_run(repo, "add", "-A")
        git_run(repo, "commit", "-m", "feat: first")
        git_run(repo, "tag", "v$major.0.0")
        git_run(repo, "tag", "v$major")
        write(joinpath(repo, "action.yml"), "name: $action\nruns: {}\n")
        git_run(repo, "commit", "-am", "fix: second")
        git_run(repo, "tag", "-a", "v$major.2.3", "-m", "release")
        commit = git_text(repo, "rev-parse", "v$major.2.3^{commit}")
        pins[action] = "$action@$commit # v$major.2.3"
    end
    return host, pins
end

"""
    julia_status(dir, args) -> Int

Exit status of a Julia child process started in `dir` with `args`. Its output is shown
when the status is not zero, so that a failure in the suite explains itself, unless the
failure is the expected outcome (`expected = false`).
"""
function julia_status(dir::AbstractString, args::Vector{String}; expected::Bool = true)
    command = ignorestatus(Cmd(`$(Base.julia_cmd()) --startup-file=no $args`; dir))
    output = IOBuffer()
    status =
        run(pipeline(command; stdin = devnull, stdout = output, stderr = output)).exitcode
    (status == 0 || !expected) ||
        println("julia ", join(args, ' '), " in ", dir, ":\n", String(take!(output)))
    return status
end

"Statuses of the launch check of `dir`: check id => `ok`, `FAIL`, `note` or `waived`."
function launch_statuses(dir::AbstractString, slug::AbstractString)
    script = joinpath(TOOLBOX, "launch-check", "launch-check.jl")
    command = ignorestatus(
        `$(Base.julia_cmd()) --startup-file=no $script $dir --repository $slug`,
    )
    text = read(pipeline(command; stderr = devnull), String)
    statuses = Dict{String, String}()
    for line in split(text, '\n')
        m = match(r"^(ok|FAIL|note|waived)\s+(\S+)$", line)
        m === nothing || (statuses[m.captures[2]] = m.captures[1])
    end
    return statuses
end

tracked(dir) = sort!(String.(split(git_text(dir, "ls-files"), '\n')))
project(dir, parts...) = TOML.parsefile(joinpath(dir, parts..., "Project.toml"))

const COMMON_FILES = [
    ".JuliaFormatter.toml",
    ".github/dependabot.yml",
    ".github/workflows/CI.yml",
    ".github/workflows/Format.yml",
    ".gitignore",
    "CITATION.cff",
    "LICENSE",
    "Project.toml",
    "README.md",
    "activate.jl",
    "bench/Project.toml",
    "bench/activate.jl",
    "bench/benchmarks.jl",
    "docs/Project.toml",
    "docs/activate.jl",
    "docs/make.jl",
    "docs/src/index.md",
    "src/Spectra.jl",
    "test/Project.toml",
    "test/activate.jl",
    "test/runtests.jl",
]
const PIPELINE_FILES = ["configs/minimal.toml", "scripts/run.jl"]

@testset "project-scaffold" begin
    @testset "settings" begin
        @test (SETTINGS.julia, SETTINGS.license, SETTINGS.style, SETTINGS.branch) ==
              ("1.10", "MIT", "blue", "main")
        @test SETTINGS.actions == ACTIONS
        @test SETTINGS.host == "https://github.com"
        @test SETTINGS.compat_extra == Dict("JET" => ["0.9"])
        defaults = validate_settings(Dict{String, Any}())
        @test all(
            getfield(defaults, name) == getfield(SETTINGS, name) for
            name in fieldnames(Settings)
        )
        bad(raw) = validate_settings(raw)
        @test_throws "colour" bad(Dict("package" => Dict("colour" => 1)))
        @test_throws "figures" bad(Dict("figures" => Dict()))
        @test_throws "julia" bad(Dict("package" => Dict("julia" => "1.10.2")))
        @test_throws "julia" bad(Dict("package" => Dict("julia" => 1.10)))
        @test_throws "style" bad(Dict("package" => Dict("style" => "default")))
        @test_throws "actions/checkout" bad(
            Dict("actions" => Dict("actions/checkout" => true)),
        )
        # a table in the file replaces the default one and must name every action in use
        partial = Dict("actions" => Dict("actions/checkout" => 7))
        @test_throws "is missing" bad(partial)
        moved = bad(Dict("actions" => merge(ACTIONS, Dict("actions/checkout" => 8))))
        @test moved.actions["actions/checkout"] == 8
        @test_throws "JET" bad(Dict("compat_extra" => Dict("JET" => "0.9")))
        @test_throws "host" bad(Dict("remote" => Dict("host" => 1)))
        @test_throws ArgumentError load_settings(joinpath(mktempdir(), "absent.toml"))
    end

    @testset "names and authors" begin
        @test package_name("Spectra.jl") == "Spectra"
        @test package_name("Spectra2D") == "Spectra2D"
        for text in
            ("spectra", "My-Pkg", "Spectra.jl.jl", "", "2Fast", "Spectra Kit", ".jl")
            @test_throws ArgumentError package_name(text)
        end
        @test parse_authors("Jane Doe, John Roe") == ["Jane Doe", "John Roe"]
        @test parse_authors("  Paul-Adrian Gogîță ") == ["Paul-Adrian Gogîță"]
        for text in
            ("", " , ", "Jane,,John", "Jane Doe <jane@example.org>", "jane@example.org")
            @test_throws ArgumentError parse_authors(text)
        end
        @test cff_authors(["Jane Doe"]) ==
              "  - family-names: \"Doe\"\n    given-names: \"Jane\""
        @test cff_authors(["Mary Ann Smith", "CERN"]) ==
              "  - family-names: \"Smith\"\n    given-names: \"Mary Ann\"\n  - name: \"CERN\""
    end

    @testset "pins" begin
        sha(c) = repeat(string(c), 40)
        listing = join(
            [
                "$(sha('a'))\trefs/tags/v6.0.2",
                "$(sha('b'))\trefs/tags/v7",
                "$(sha('c'))\trefs/tags/v7.0.0",
                "$(sha('d'))\trefs/tags/v7.0.9",
                "$(sha('e'))\trefs/tags/v7.0.10",
                "$(sha('f'))\trefs/tags/v7.0.10^{}",
                "$(sha('1'))\trefs/tags/v7.1.0-rc.1",
                "$(sha('2'))\trefs/tags/v8.0.0",
                "$(sha('3'))\trefs/heads/main",
                "",
            ],
            "\n",
        )
        # the highest release of the series, numerically; the commit of an annotated tag
        @test select_pin(listing, 7) == (sha('f'), "v7.0.10")
        @test select_pin(listing, 6) == (sha('a'), "v6.0.2")
        @test select_pin(listing, 8) == (sha('2'), "v8.0.0")
        @test select_pin(listing, 9) === nothing
        @test select_pin("", 7) === nothing

        host, pins = action_host()
        local_settings = Settings("1.10", "MIT", "blue", "main", ACTIONS, host, Dict())
        @test resolve_pins(local_settings) == pins
        newer = Settings(
            "1.10",
            "MIT",
            "blue",
            "main",
            Dict("actions/checkout" => 8),
            host,
            Dict(),
        )
        @test_throws "actions/checkout" resolve_pins(newer)
        absent =
            Settings("1.10", "MIT", "blue", "main", Dict("org/absent" => 1), host, Dict())
        @test_throws "org/absent" resolve_pins(absent)
    end

    @testset "compat, rendering, project files" begin
        @test compat_entry(v"1.2.3") == "1"
        @test compat_entry(v"2.0.0") == "2"
        @test compat_entry(v"0.8.19") == "0.8"
        @test compat_entry(v"0.0.3") == "0.0.3"
        @test compat_entry(v"0.13.5", ["0.9"]) == "0.9, 0.13"
        @test compat_entry(v"0.9.20", ["0.9"]) == "0.9"
        @test compat_entry(v"1.11.0", ["0.7"]) == "0.7, 1"

        version = formatter_version()
        @test occursin(r"^\d+\.\d+\.\d+$", version)
        @test occursin(
            "JuliaFormatter = \"=$version\"",
            read(joinpath(TOOLBOX, "formatter", "Project.toml"), String),
        )

        values = Dict("PKG" => "Spectra", "PIN a/b" => "a/b@0 # v1", "RAW" => "<<PKG>>")
        @test render("using <<PKG>>\n- uses: <<PIN a/b>>\n", values) ==
              "using Spectra\n- uses: a/b@0 # v1\n"
        # GitHub expressions pass, inserted text is not read again
        @test render("\${{ matrix.version }} <<RAW>>", values) ==
              "\${{ matrix.version }} <<PKG>>"
        @test_throws "MISSING" render("<<PKG>> <<MISSING>>", values)

        table = Dict{String, Any}(
            "version" => "0.1.0",
            "name" => "Spectra",
            "authors" => ["Jane Doe", "John Roe"],
            "uuid" => "00000000-0000-0000-0000-000000000001",
            "compat" => Dict("julia" => "1.10", "Aqua" => "0.8"),
            "sources" => Dict("Spectra" => Dict("path" => "..")),
            "deps" => Dict(
                "Test" => "8dfed614-e22c-5e08-85e1-65c5234f0b40",
                "Aqua" => "4c88cf16-eb10-579e-8560-4a9242c79595",
            ),
        )
        text = project_text(table)
        @test TOML.parse(text) == table
        @test endswith(text, "\"\n") && !endswith(text, "\n\n")
        order(names...) = issorted([findfirst(name, text)[1] for name in names])
        @test order(
            "name =",
            "uuid =",
            "authors =",
            "version =",
            "[deps]",
            "[sources]",
            "[compat]",
        )
        @test order("Aqua = \"4c88", "Test = \"8dfe")
        @test order("Aqua = \"0.8\"", "julia = \"1.10\"")
        @test occursin("Spectra = {path = \"..\"}", text)
        @test project_text(Dict("compat" => Dict("julia" => "1.10"), "deps" => Dict())) ==
              "[compat]\njulia = \"1.10\"\n"

        resolved = resolve_packages(["Test", "TOML"])
        before = Base.active_project()
        @test resolved["Test"][1] == "8dfed614-e22c-5e08-85e1-65c5234f0b40"
        @test resolved["TOML"][1] == "fa267f1f-6049-4f14-aa54-33bafae1ed76"
        @test resolved["TOML"][2] isa VersionNumber
        @test Base.active_project() == before == joinpath(TOOL_DIR, "Project.toml")
    end

    @testset "template values" begin
        pins = Dict(
            action => "$action@$(repeat('0', 40)) # v1.0.0" for action in keys(ACTIONS)
        )
        request = Request(
            "Spectra",
            "/tmp",
            "user",
            ["Jane Doe", "CERN"],
            "1.11",
            true,
            true,
            true,
        )
        values = template_values(request, SETTINGS, pins; stable = v"1.13.4")
        @test (values["PKG"], values["USER"], values["JULIA"]) ==
              ("Spectra", "user", "1.11")
        @test (values["BRANCH"], values["LICENSE"], values["STABLE"]) ==
              ("main", "MIT", "1.13")
        @test values["FORMATTER"] == formatter_version()
        @test occursin(r"^20\d\d$", values["YEAR"])
        @test values["AUTHORS_BIBTEX"] == "Jane Doe and CERN"
        @test values["AUTHORS_TEXT"] == "Jane Doe, CERN"
        @test values["AUTHORS_CFF"] == cff_authors(["Jane Doe", "CERN"])
        @test values["PIN actions/checkout"] == pins["actions/checkout"]
        @test values["JULIA_DIRECTORIES"] ==
              "      - \"/\"\n      - \"/test\"\n      - \"/docs\"\n      - \"/bench\""
        @test occursin("scripts/", values["TREE_SCRIPTS"])
        @test occursin("data/", values["IGNORE_RUNS"])
        bare = Request("Spectra", "/tmp", "user", ["Jane Doe"], "1.10", false, true, true)
        plain = template_values(bare, SETTINGS, pins)
        for key in (
            "TREE_SCRIPTS",
            "ENTRY_SCRIPTS",
            "FULL_TREE_CONFIGS",
            "FULL_TREE_SCRIPTS",
            "IGNORE_RUNS",
        )
            @test plain[key] == "" && !isempty(values[key])
        end
        @test plain["STABLE"] == "$(VERSION.major).$(VERSION.minor)"
        # every template renders from these values, and nothing else is asked for
        for name in readdir(joinpath(TOOL_DIR, "templates"))
            text = render(read(joinpath(TOOL_DIR, "templates", name), String), values)
            @test !occursin(r"<<[A-Z]", text)
        end
    end

    @testset "command line errors" begin
        dir = mktempdir()
        full = ["Spectra", "--dir", dir, "--user", "user", "--authors", "Jane Doe"]
        without(flag) =
            (k = findfirst(==(flag), full); full[setdiff(eachindex(full), k:(k + 1))])
        @test_throws "NAME" main(full[2:end]; io = devnull)
        @test_throws "--dir" main(without("--dir"); io = devnull)
        @test_throws "--user" main(without("--user"); io = devnull)
        @test_throws "--authors" main(without("--authors"); io = devnull)
        @test_throws ArgumentError main([full; "--colour"]; io = devnull)
        @test_throws ArgumentError main([full; "Other"]; io = devnull)
        @test_throws ArgumentError main([full; "--julia"]; io = devnull)
        @test_throws ArgumentError main([full; "--julia"; "1"]; io = devnull)
        @test_throws ArgumentError main(["spectra"; full[2:end]]; io = devnull)
        @test_throws ArgumentError main([full[1:4]; "-user-"; full[6:end]]; io = devnull)
        @test_throws ArgumentError main([full[1:6]; "Jane <j@example.org>"]; io = devnull)
        @test isempty(readdir(dir))
        io = IOBuffer()
        @test main(["--help"]; io) === nothing
        @test occursin("project-scaffold", String(take!(io)))
    end

    @testset "package with the pipeline layer, through the command line" begin
        host, pins = action_host()
        config = joinpath(mktempdir(), "config.toml")
        shipped = read(joinpath(TOOL_DIR, "config.toml"), String)
        @test occursin("\"https://github.com\"", shipped)
        write(config, replace(shipped, "\"https://github.com\"" => repr(host)))
        parent = realpath(mktempdir())
        io = IOBuffer()
        dir = withenv(IDENTITY...) do
            main(
                [
                    "Spectra.jl",
                    "--dir",
                    parent,
                    "--user",
                    "user",
                    "--authors",
                    "Jane Doe, John Roe",
                    "--config",
                    config,
                ];
                io,
            )
        end
        report = String(take!(io))
        @test dir == joinpath(parent, "Spectra")
        @test readdir(parent) == ["Spectra"]
        @test occursin("Created $dir", report)
        @test occursin("repos/user/Spectra.jl/actions/permissions", report)
        @test !occursin("note:", report)

        # one conventional commit on main holds exactly the generated files
        @test tracked(dir) == sort!([COMMON_FILES; PIPELINE_FILES])
        @test git_text(dir, "log", "--format=%s") == "chore: scaffold of Spectra.jl"
        @test git_text(dir, "branch", "--show-current") == "main"
        @test isempty(git_text(dir, "status", "--porcelain"))
        @test isfile(joinpath(dir, ".git", "hooks", "commit-msg"))
        texts = Dict(path => read(joinpath(dir, path), String) for path in tracked(dir))
        @test all(!occursin(r"<<[A-Z]", text) for text in values(texts))

        # project files
        root = project(dir)
        @test (root["name"], root["version"], root["authors"]) ==
              ("Spectra", "0.1.0", ["Jane Doe", "John Roe"])
        @test sort!(collect(keys(root["deps"]))) == ["DrWatson", "TOML"]
        @test sort!(collect(keys(root["compat"]))) == ["DrWatson", "TOML", "julia"]
        @test (root["compat"]["julia"], root["compat"]["TOML"]) == ("1.10", "1")
        test = project(dir, "test")
        @test sort!(collect(keys(test["deps"]))) == ["Aqua", "JET", "Spectra", "Test"]
        @test test["deps"]["Spectra"] == root["uuid"]
        @test test["sources"] == Dict("Spectra" => Dict("path" => ".."))
        @test sort!(collect(keys(test["compat"]))) == ["Aqua", "JET", "Test", "julia"]
        @test startswith(test["compat"]["JET"], "0.9, 0.")
        @test test["compat"]["julia"] == "1.10"
        docs = project(dir, "docs")
        @test sort!(collect(keys(docs["deps"]))) == ["Documenter", "Spectra"]
        @test docs["sources"] == test["sources"]
        @test sort!(collect(keys(docs["compat"]))) == ["Documenter", "julia"]
        bench = project(dir, "bench")
        @test sort!(collect(keys(bench["deps"]))) == ["BenchmarkTools", "Spectra"]
        @test sort!(collect(keys(bench["compat"]))) == ["BenchmarkTools", "julia"]

        # the licence names the authors and nothing else of them
        holder = only(filter(startswith("Copyright"), split(texts["LICENSE"], '\n')))
        @test occursin("Jane Doe", holder) && occursin("John Roe", holder)
        @test !occursin('@', holder)

        # workflows: the resolved pins, and every job dormant in a private repository
        ci, format =
            texts[".github/workflows/CI.yml"], texts[".github/workflows/Format.yml"]
        uses = [
            strip(split(line, "- uses:")[2]) for
            line in split(ci * format, '\n') if occursin("- uses:", line)
        ]
        @test length(uses) == 15
        @test Set(uses) == Set(values(pins))
        @test count(GUARD, ci) == 2 && count(GUARD, format) == 1
        @test occursin("version: ['min', '1']", ci)
        @test occursin("version = \"$(formatter_version())\"", format)
        bot = texts[".github/dependabot.yml"]
        @test count("open-pull-requests-limit: 0", bot) == 2
        @test occursin("      - \"/bench\"\n    schedule:", bot)
        @test occursin("data/\nplots/\n", texts[".gitignore"])
        @test startswith(
            texts["docs/make.jl"],
            "include(joinpath(@__DIR__, \"activate.jl\"))\n\nusing ",
        )
        @test occursin("Remotes.GitHub(\"user\", \"Spectra.jl\")", texts["docs/make.jl"])
        # the generated files agree with the formatter configuration they ship, and the
        # formatter stays out of the hook, a Julia script under .git
        @test occursin("\nignore = [\".git\"]\n", texts[".JuliaFormatter.toml"])
        hook = read(joinpath(dir, ".git", "hooks", "commit-msg"))
        @test julia_status(TOOLBOX, [joinpath("formatter", "format.jl"), dir, "--check"]) ==
              0
        @test julia_status(TOOLBOX, [joinpath("formatter", "format.jl"), dir]) == 0
        @test read(joinpath(dir, ".git", "hooks", "commit-msg")) == hook
        @test occursin(
            "@static if VERSION >= v\"$(VERSION.major).$(VERSION.minor)\"",
            texts["test/runtests.jl"],
        )
        @test occursin("family-names: \"Roe\"", texts["CITATION.cff"])
        @test occursin("author = {Jane Doe and John Roe}", texts["README.md"])
        @test occursin("julia scripts/run.jl", texts["README.md"])

        # the launch check fails on the launch work and on nothing else
        statuses = launch_statuses(dir, "user/Spectra.jl")
        @test length(statuses) == 19
        @test sort!([id for (id, status) in statuses if status == "FAIL"]) == ["badges", "changelog", "dependabot"]
        @test [id for (id, status) in statuses if status == "note"] == ["dependabot-cooldown"]
        @test count(==("ok"), values(statuses)) == 15

        # what the README tells a user to run
        @test julia_status(dir, ["-e", "include(\"activate.jl\"); Pkg.test()"]) == 0
        @test julia_status(dir, ["scripts/run.jl"]) == 0
        @test julia_status(dir, ["scripts/run.jl", "absent.toml"]; expected = false) != 0
        @test julia_status(dir, ["bench/benchmarks.jl"]) == 0
        @test julia_status(dir, ["docs/make.jl"]) == 0
        @test isfile(joinpath(dir, "docs", "build", "index.html"))
        # manifests and the built site are ignored: the tree is still clean
        @test isfile(joinpath(dir, "Manifest.toml"))
        @test isempty(git_text(dir, "status", "--porcelain"))

        # an existing package directory is refused before anything is written
        @test_throws ArgumentError main(
            [
                "Spectra",
                "--dir",
                parent,
                "--user",
                "user",
                "--authors",
                "Jane Doe",
                "--config",
                config,
            ];
            io = devnull,
        )
        @test isempty(git_text(dir, "status", "--porcelain"))
    end

    @testset "package without the pipeline layer, without a git identity" begin
        _, pins = action_host()
        parent = realpath(mktempdir())
        request =
            Request("Spectra", parent, "user", ["Jane Doe"], "1.11", false, true, true)
        io = IOBuffer()
        dir = scaffold(request, SETTINGS; pins, io)
        report = String(take!(io))
        @test dir == joinpath(parent, "Spectra")
        # git has no identity here, so the commit is left to the user
        @test occursin("note: the first commit was not made", report)
        @test isdir(joinpath(dir, ".git"))
        git_run(dir, "commit", "-m", "chore: scaffold of Spectra.jl")
        @test tracked(dir) == COMMON_FILES
        @test !ispath(joinpath(dir, "scripts")) && !ispath(joinpath(dir, "configs"))
        root = project(dir)
        @test !haskey(root, "deps")
        @test root["compat"] == Dict("julia" => "1.11")
        @test project(dir, "test")["compat"]["julia"] == "1.11"
        readme = read(joinpath(dir, "README.md"), String)
        @test !occursin("scripts", readme) && occursin("Julia 1.11 or later", readme)
        @test !occursin("data/", read(joinpath(dir, ".gitignore"), String))
        @test !any(
            name -> occursin("Manifest", name),
            [f for (_, _, fs) in walkdir(dir) for f in fs],
        )

        # a parent that does not exist
        gone = Request(
            "Spectra",
            joinpath(parent, "absent"),
            "user",
            ["Jane Doe"],
            "1.10",
            false,
            false,
            false,
        )
        @test_throws ArgumentError scaffold(gone, SETTINGS; pins, io = devnull)
        # neither repository nor hook when both are declined
        other = realpath(mktempdir())
        quiet = Request("Spectra", other, "user", ["Jane Doe"], "1.10", false, false, false)
        plain = scaffold(quiet, SETTINGS; pins, io = devnull)
        @test !ispath(joinpath(plain, ".git"))
    end
end
