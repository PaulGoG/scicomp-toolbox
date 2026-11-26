# Tests of launch-check. The repositories it reads are written into mktempdir(), so no
# fixture is committed. Most checks read a `Repository` built by hand from a table of
# files; the reader itself and the two checks that start child processes run on
# repositories made with `git init`. The expected badge row is written out from the badge
# table of the conventions, not taken from the generator.

using Test: @test, @test_throws, @testset

# Git reads neither the configuration of the user nor that of the system here. A
# `core.hooksPath` set globally would run foreign hooks on every test commit.
ENV["GIT_CONFIG_GLOBAL"] = Sys.iswindows() ? "NUL" : "/dev/null"
ENV["GIT_CONFIG_NOSYSTEM"] = "1"

include(joinpath(@__DIR__, "..", "launch-check.jl"))

const TOOL_DIR = normpath(joinpath(@__DIR__, ".."))
const SETTINGS = load_settings(joinpath(TOOL_DIR, "config.toml"))
const NO_OPTIONS = RepositoryOptions("", "", "", "", "", Dict{String, String}())
const PLATFORM =
    RepositoryOptions("", "Linux x86_64", "linux", "", "", Dict{String, String}())
const CHILD_CHECKS = ["self-contained", "history"]
const SHA = "3d3c42e5aac5ba805825da76410c181273ba90b1"

const CI_WORKFLOW = raw"""
name: CI

on:
  push:
    branches: [main]
    tags: ['*']
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ startsWith(github.ref, 'refs/pull/') }}

jobs:
  test:
    name: Julia ${{ matrix.version }}
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        version: ['min', '1']
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: julia-actions/setup-julia@da908477b5db94c10ffce8cfea9f2b3b9d5db687 # v3.0.3
        with:
          version: ${{ matrix.version }}
      - uses: julia-actions/julia-runtest@1111111111111111111111111111111111111111 # v1.11.0
      - uses: julia-actions/julia-processcoverage@2222222222222222222222222222222222222222 # v1.2.2
      - uses: codecov/codecov-action@3333333333333333333333333333333333333333 # v6.0.0
  docs:
    name: Documentation
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: julia-actions/julia-docdeploy@4444444444444444444444444444444444444444 # v1.3.1
"""

const FORMAT_WORKFLOW = raw"""
name: Format
on:
  push:
    branches: [main]
permissions:
  contents: read
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  format:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - run: julia -e 'using JuliaFormatter; format(".")' && git diff --exit-code
"""

const DEPENDABOT = """
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    cooldown:
      default-days: 7
  - package-ecosystem: "julia"
    directory: "/"
    schedule:
      interval: "weekly"
    cooldown:
      default-days: 7
"""

const CITATION = """
cff-version: 1.2.0
message: "If you use this software, please cite it using these metadata."
title: "Pkg.jl"
authors:
  - family-names: Doe
    given-names: Jane
doi: 10.5281/zenodo.1234567
identifiers:
  - type: other
    value: "arXiv:2401.01234"
"""

# the row of the badge table for the repository user/Pkg.jl on main: stable docs, CI,
# coverage, Aqua, JET, Blue style, format workflow, Julia version, DOI, arXiv, platform
const BADGE_ROW = [
    "[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://user.github.io/Pkg.jl/stable/)",
    "[![CI](https://github.com/user/Pkg.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/user/Pkg.jl/actions/workflows/CI.yml?query=branch%3Amain)",
    "[![Coverage](https://codecov.io/gh/user/Pkg.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/user/Pkg.jl)",
    "[![Aqua QA](https://juliatesting.github.io/Aqua.jl/dev/assets/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)",
    "[![JET](https://img.shields.io/badge/%F0%9F%9B%A9%EF%B8%8F_tested_with-JET.jl-233f9a)](https://github.com/aviatesk/JET.jl)",
    "[![Code Style: Blue](https://img.shields.io/badge/code%20style-blue-4495d1.svg)](https://github.com/JuliaDiff/BlueStyle)",
    "[![Format](https://github.com/user/Pkg.jl/actions/workflows/Format.yml/badge.svg?branch=main)](https://github.com/user/Pkg.jl/actions/workflows/Format.yml?query=branch%3Amain)",
    "[![Julia](https://img.shields.io/badge/dynamic/toml?url=https%3A%2F%2Fraw.githubusercontent.com%2Fuser%2FPkg.jl%2Fmain%2FProject.toml&query=%24.compat.julia&label=julia&logo=julia&color=9558b2)](https://julialang.org/downloads/)",
    "[![DOI](https://img.shields.io/badge/DOI-10.5281%2Fzenodo.1234567-blue?logo=doi)](https://doi.org/10.5281/zenodo.1234567)",
    "[![arXiv](https://img.shields.io/badge/arXiv-2401.01234-b31b1b?logo=arxiv)](https://arxiv.org/abs/2401.01234)",
    "[![Platform](https://img.shields.io/badge/platform-Linux%20x86__64-lightgrey?logo=linux)](#requirements)",
]
const BADGE_KINDS = [
    "docs",
    "ci",
    "coverage",
    "aqua",
    "jet",
    "style",
    "format",
    "julia",
    "doi",
    "arxiv",
    "platform",
]

readme(badges = BADGE_ROW) = """
# Pkg.jl

$(join(badges, "\n"))

Solves the thing.

```
Pkg.jl/
├── src/
├── test/
└── README.md
```

## How to cite

```bibtex
@software{pkg,
  title = {Pkg.jl},
}
```
"""

"""
    conforming_files() -> Dict{String, String}

Files of a repository that passes every check: path relative to the root => content.
"""
conforming_files() = Dict{String, String}(
    "LICENSE" => "MIT License\n\nCopyright (c) 2026 Jane Doe\n\nPermission is hereby granted.\n",
    "CITATION.cff" => CITATION,
    "CHANGELOG.md" => "# Changelog\n",
    "README.md" => readme(),
    "Project.toml" => """
        name = "Pkg"
        uuid = "00000000-0000-0000-0000-000000000001"
        version = "1.0.0"

        [deps]
        Printf = "de0858da-6303-5e67-8744-51eddeeeb8d7"

        [compat]
        Printf = "1"
        julia = "1.10"
        """,
    "test/Project.toml" => """
        [deps]
        Aqua = "4c88cf16-eb10-579e-8560-4a9242c79595"
        JET = "c3a54625-cd67-489e-a8e7-0a5a0ff4e31b"
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

        [compat]
        Aqua = "0.8"
        JET = "0.12, 0.13"
        Test = "1"
        julia = "1.10"
        """,
    ".JuliaFormatter.toml" => "style = \"blue\"\n",
    ".github/dependabot.yml" => DEPENDABOT,
    ".github/workflows/CI.yml" => CI_WORKFLOW,
    ".github/workflows/Format.yml" => FORMAT_WORKFLOW,
    "docs/make.jl" => "using Documenter\n",
    "src/Pkg.jl" => "module Pkg\nend\n",
)

"""
    write_files(root, files) -> Vector{String}

Write `files` below `root` and return the sorted relative paths.
"""
function write_files(root::AbstractString, files::AbstractDict)
    for (path, content) in files
        target = joinpath(root, split(path, '/')...)
        mkpath(dirname(target))
        write(target, content)
    end
    return sort!(collect(keys(files)))
end

"""
    fixture(changes...; slug, branch, tags) -> Repository

The conforming repository with `changes` applied (`path => content`, or `path => nothing`
to leave a file out), written into a temporary directory and described by hand, without
git.
"""
function fixture(changes::Pair...; slug = "user/Pkg.jl", branch = "main", tags = ["v1.0.0"])
    files = conforming_files()
    for (path, content) in changes
        content === nothing ? delete!(files, path) : (files[path] = content)
    end
    root = mktempdir()
    return Repository(root, write_files(root, files), slug, branch, tags)
end

check(id, repo; options = PLATFORM, settings = SETTINGS) =
    Dict(CHECKS)[id](repo, settings, options)
fails(id, repo; kw...) = check(id, repo; kw...).status == :fail
passes(id, repo; kw...) = check(id, repo; kw...).status == :ok
detail(id, repo; kw...) = join(check(id, repo; kw...).details, "\n")
quoted_text(repo) = read(joinpath(repo.root, ".github", "workflows", "CI.yml"), String)
workflow(changes::Pair...; kw...) =
    ".github/workflows/CI.yml" => replace(CI_WORKFLOW, changes...; kw...)

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
    git_repository(files; message, remote) -> String

Repository made with `git init` holding `files` in one commit; returns its real path.
"""
function git_repository(
    files::AbstractDict = conforming_files();
    message = "feat: first version",
    remote = "https://github.com/user/Pkg.jl.git",
)
    root = realpath(mktempdir())
    git_run(root, "init")
    write_files(root, files)
    git_run(root, "add", "-A")
    git_run(root, "commit", "-m", message)
    remote === nothing || git_run(root, "remote", "add", "origin", remote)
    return root
end

@testset "launch-check" begin
    @testset "settings" begin
        @test SETTINGS.required_versions == ["min", "1"]
        @test SETTINGS.optional_versions == ["lts", "pre", "nightly"]
        @test SETTINGS.version_keys == ["version", "julia-version"]
        @test SETTINGS.ecosystems == ["julia", "github-actions"]
        @test (SETTINGS.tree_max_lines, SETTINGS.tree_within_lines) == (20, 40)
        defaults = validate_settings(Dict{String, Any}())
        @test all(
            getfield(defaults, name) == getfield(SETTINGS, name) for
            name in fieldnames(Settings)
        )
        bad(raw) = validate_settings(raw)
        @test_throws "colour" bad(Dict("readme" => Dict("colour" => 1)))
        @test_throws "figures" bad(Dict("figures" => Dict()))
        @test_throws "tree_max_lines" bad(Dict("readme" => Dict("tree_max_lines" => 4)))
        @test_throws "tree_max_lines" bad(Dict("readme" => Dict("tree_max_lines" => 61)))
        @test_throws "tree_max_lines" bad(Dict("readme" => Dict("tree_max_lines" => true)))
        @test_throws "tree_within_lines" bad(
            Dict("readme" => Dict("tree_within_lines" => 2.5)),
        )
        @test_throws "required_versions" bad(
            Dict("workflows" => Dict("required_versions" => String[])),
        )
        @test_throws "ecosystems" bad(
            Dict("dependabot" => Dict("ecosystems" => ["julia", 1])),
        )
        @test_throws ArgumentError load_settings(joinpath(mktempdir(), "absent.toml"))
    end

    @testset "conforming repository" begin
        ids = filter(!in(CHILD_CHECKS), CHECK_IDS)
        results = launch_checks(fixture(), SETTINGS, PLATFORM; only = ids)
        @test [r.id for r in results] == ids
        @test all(r.status == :ok && isempty(r.details) for r in results)
        @test length(CHECK_IDS) == 19
        @test CHECK_IDS[1] == "license" && CHECK_IDS[end] == "history"
    end

    @testset "license" begin
        @test fails("license", fixture("LICENSE" => nothing))
        @test passes(
            "license",
            fixture("LICENSE" => nothing, "LICENSE.md" => "Copyright Jane\n"),
        )
        @test fails("license", fixture("LICENSE" => "MIT License\n\nPermission granted.\n"))
        mail = "MIT License\n\nCopyright (c) 2026 Jane Doe <jane@example.org>\n"
        @test occursin("LICENSE:3", detail("license", fixture("LICENSE" => mail)))
        # an address outside the holder line is not the holder's
        elsewhere = "Copyright (c) 2026 Jane Doe\n\nReport defects to bugs@example.org.\n"
        @test passes("license", fixture("LICENSE" => elsewhere))
        @test passes(
            "license",
            fixture("LICENSE" => "copyright 2026 Jane\nThe above copyright notice\n"),
        )
    end

    @testset "citation" begin
        cff(changes::Pair...) = fixture("CITATION.cff" => replace(CITATION, changes...))
        @test fails("citation", fixture("CITATION.cff" => nothing))
        @test fails("citation", fixture("CITATION.cff" => "a: [1, 2\nb: }\n"))
        @test fails("citation", fixture("CITATION.cff" => "- a\n- b\n"))
        @test occursin("cff-version", detail("citation", cff("cff-version: 1.2.0\n" => "")))
        @test occursin("message", detail("citation", cff(r"message: .*\n" => "")))
        @test occursin(
            "title",
            detail("citation", cff("title: \"Pkg.jl\"" => "title: \"\"")),
        )
        no_authors = cff("authors:\n  - family-names: Doe\n    given-names: Jane\n" => "")
        @test occursin("authors", detail("citation", no_authors))
        @test fails(
            "citation",
            cff(
                "authors:\n  - family-names: Doe\n    given-names: Jane\n" => "authors: []\n",
            ),
        )
        @test fails(
            "citation",
            cff("  - family-names: Doe\n    given-names: Jane\n" => "  - Jane Doe\n"),
        )
    end

    @testset "cite-section" begin
        text = readme()
        with_readme(changes::Pair...) = fixture("README.md" => replace(text, changes...))
        @test fails("cite-section", with_readme("## How to cite" => "## Reference"))
        @test passes("cite-section", with_readme("## How to cite" => "### Citation"))
        @test passes("cite-section", with_readme("## How to cite" => "## Citing Pkg.jl"))
        @test fails("cite-section", with_readme("@software{pkg," => "software pkg"))
        # the entry lies under a later section of the same level
        moved = with_readme("```bibtex" => "Cite the paper.\n\n## Example\n\n```bibtex")
        @test fails("cite-section", moved)
        # a subsection belongs to the section on citing
        nested = with_readme("```bibtex" => "### BibTeX\n\n```bibtex")
        @test passes("cite-section", nested)
        # a heading inside a code block is not a heading
        fenced = "# Pkg.jl\n\n```\n## How to cite\n```\n\n```bibtex\n@software{pkg,}\n```\n"
        @test fails("cite-section", fixture("README.md" => fenced))
        @test fails("cite-section", fixture("README.md" => nothing))
    end

    @testset "manifest" begin
        @test passes("manifest", fixture("test/fixtures/Manifest.txt" => "x"))
        repo = fixture(
            "Manifest.toml" => "",
            "docs/Manifest-v1.12.toml" => "",
            "JuliaManifest.toml" => "",
        )
        result = check("manifest", repo)
        @test result.status == :fail && length(result.details) == 3
        @test occursin("docs/Manifest-v1.12.toml", join(result.details, "\n"))
    end

    @testset "compat" begin
        project(body) = fixture("Project.toml" => body)
        base = "[deps]\nA = \"00000000-0000-0000-0000-00000000000a\"\n"
        @test passes(
            "compat",
            project(base * "[compat]\nA = \"1.2 - 1.9\"\njulia = \"1.10\"\n"),
        )
        @test passes(
            "compat",
            project(
                base *
                "[compat]\nA = \"0.4, 0.5, ^1.2, ~2.1, =3.0.1, < 5\"\njulia = \"1.10\"\n",
            ),
        )
        @test occursin(
            "A has no [compat] entry",
            detail("compat", project(base * "[compat]\njulia = \"1.10\"\n")),
        )
        @test occursin(
            "julia has no [compat] entry",
            detail("compat", project(base * "[compat]\nA = \"1\"\n")),
        )
        @test occursin(
            "no upper bound",
            detail(
                "compat",
                project(base * "[compat]\nA = \">= 1.2\"\njulia = \"1.10\"\n"),
            ),
        )
        @test occursin(
            "is not a compat entry Pkg accepts",
            detail(
                "compat",
                project(base * "[compat]\nA = \"1, > 2\"\njulia = \"1.10\"\n"),
            ),
        )
        @test occursin(
            "is not a compat entry Pkg accepts",
            detail("compat", project(base * "[compat]\nA = \"*\"\njulia = \"1.10\"\n")),
        )
        @test occursin(
            "is not a compat entry Pkg accepts",
            detail("compat", project(base * "[compat]\nA = \"\"\njulia = \"1.10\"\n")),
        )
        weak = "[weakdeps]\nW = \"00000000-0000-0000-0000-00000000000b\"\n[compat]\njulia = \"1.10\"\n"
        @test occursin("W has no [compat] entry", detail("compat", project(weak)))
        extra = "[extras]\nE = \"00000000-0000-0000-0000-00000000000c\"\n[compat]\njulia = \"1.10\"\n"
        @test occursin("E has no [compat] entry", detail("compat", project(extra)))
        # the package under test, taken by path, has no version to bound
        sourced = base * "[sources]\nA = {path = \"..\"}\n[compat]\njulia = \"1.10\"\n"
        @test passes("compat", project(sourced))
        by_url =
            base *
            "[sources]\nA = {url = \"https://example.org/A.jl\"}\n[compat]\njulia = \"1.10\"\n"
        @test fails("compat", project(by_url))
        @test occursin("not valid TOML", detail("compat", project("[deps\n")))
        @test occursin(
            "docs/Project.toml",
            detail("compat", fixture("docs/Project.toml" => base)),
        )
        @test fails(
            "compat",
            fixture("Project.toml" => nothing, "test/Project.toml" => nothing),
        )
    end

    @testset "dependabot" begin
        bot(changes::Pair...; kw...) =
            fixture(".github/dependabot.yml" => replace(DEPENDABOT, changes...; kw...))
        @test fails("dependabot", fixture(".github/dependabot.yml" => nothing))
        moved = fixture(
            ".github/dependabot.yml" => nothing,
            ".github/dependabot.yaml" => DEPENDABOT,
        )
        @test passes("dependabot", moved)
        @test fails("dependabot", fixture(".github/dependabot.yml" => "updates: [\n"))
        @test fails("dependabot", fixture(".github/dependabot.yml" => "version: 2\n"))
        @test occursin("'julia'", detail("dependabot", bot("\"julia\"" => "\"pip\"")))
        limited = bot(
            "directory: \"/\"\n    schedule" => "directory: \"/\"\n    open-pull-requests-limit: 0\n    schedule";
            count = 1,
        )
        @test occursin(
            "updates[1] (github-actions): open-pull-requests-limit is 0",
            detail("dependabot", limited),
        )
        @test passes(
            "dependabot",
            bot(
                "directory: \"/\"\n    schedule" => "directory: \"/\"\n    open-pull-requests-limit: 5\n    schedule",
            ),
        )
        unscheduled = bot("    schedule:\n      interval: \"weekly\"\n" => ""; count = 1)
        @test occursin(
            "updates[1] (github-actions): no schedule interval",
            detail("dependabot", unscheduled),
        )

        @test passes("dependabot-cooldown", fixture())
        bare = bot("    cooldown:\n      default-days: 7\n" => ""; count = 1)
        note = check("dependabot-cooldown", bare)
        @test note.status == :note
        @test note.details == ["updates[1] (github-actions): no cooldown"]
        @test passes("dependabot", bare)
        @test passes("dependabot-cooldown", fixture(".github/dependabot.yml" => nothing))
    end

    @testset "workflow-pins" begin
        pin = "actions/checkout@$SHA # v7.0.1"
        pins(replacement) = fixture(workflow(pin => replacement; count = 1))
        line = findfirst(contains(pin), split(CI_WORKFLOW, '\n'))
        @test occursin(
            "CI.yml:$line: actions/checkout@v7 is not pinned by a commit SHA",
            detail("workflow-pins", pins("actions/checkout@v7")),
        )
        @test occursin(
            "is not pinned by a commit SHA",
            detail("workflow-pins", pins("actions/checkout")),
        )
        @test occursin(
            "is not pinned by a commit SHA",
            detail("workflow-pins", pins("actions/checkout@$(SHA[1:39])")),
        )
        @test occursin(
            "CI.yml:$line: actions/checkout@$SHA has no release comment",
            detail("workflow-pins", pins("actions/checkout@$SHA")),
        )
        @test occursin(
            "has no release comment",
            detail("workflow-pins", pins("actions/checkout@$SHA # checkout")),
        )
        quoted = fixture(workflow(pin => "\"actions/checkout@$SHA\" # 7.0.1"))
        @test passes("workflow-pins", quoted)
        @test count("\"actions/checkout@", quoted_text(quoted)) == 2
        @test passes("workflow-pins", pins("./.github/actions/setup"))
        digest = "docker://ghcr.io/org/tool@sha256:" * "ab"^32
        @test passes("workflow-pins", pins(digest))
        @test occursin(
            "is not pinned by a digest",
            detail("workflow-pins", pins("docker://ghcr.io/org/tool:1.2")),
        )
        # a job that calls a reusable workflow
        reusable = fixture(
            workflow(
                "  docs:\n" => "  call:\n    uses: org/repo/.github/workflows/build.yml@v1\n  docs:\n",
            ),
        )
        @test occursin(
            "org/repo/.github/workflows/build.yml@v1 is not pinned",
            detail("workflow-pins", reusable),
        )
        # the text of a script is not a step
        script = fixture(
            workflow(
                "    steps:\n" => "    steps:\n      - run: |\n          echo 'see'\n          uses: actions/unpinned@v1\n";
                count = 1,
            ),
        )
        @test passes("workflow-pins", script)
        @test occursin(
            "no workflow",
            detail(
                "workflow-pins",
                fixture(
                    ".github/workflows/CI.yml" => nothing,
                    ".github/workflows/Format.yml" => nothing,
                ),
            ),
        )
        @test occursin(
            "CI.yml: not valid YAML",
            detail("workflow-pins", fixture(".github/workflows/CI.yml" => "jobs: [\n")),
        )
        # a workflow outside .github/workflows is not one
        @test passes(
            "workflow-pins",
            fixture(
                "docs/workflows/x.yml" => "jobs:\n  a:\n    steps:\n      - uses: a/b@v1\n",
            ),
        )
    end

    @testset "workflow-permissions" begin
        top = "permissions:\n  contents: read\n\n"
        @test occursin(
            "job 'test' declares none",
            detail("workflow-permissions", fixture(workflow(top => ""))),
        )
        @test occursin(
            "job 'docs' declares none",
            detail("workflow-permissions", fixture(workflow(top => ""))),
        )
        # a key without a value declares nothing
        @test fails("workflow-permissions", fixture(workflow(top => "permissions:\n\n")))
        @test passes(
            "workflow-permissions",
            fixture(workflow(top => "permissions: {}\n\n")),
        )
        per_job = workflow(
            top => "",
            "    runs-on: ubuntu-latest\n" => "    runs-on: ubuntu-latest\n    permissions:\n      contents: read\n",
        )
        @test passes("workflow-permissions", fixture(per_job))
        @test occursin(
            "write-all (workflow)",
            detail(
                "workflow-permissions",
                fixture(workflow(top => "permissions: write-all\n\n")),
            ),
        )
        job_all = workflow(
            "  docs:\n    name: Documentation\n" => "  docs:\n    name: Documentation\n    permissions: write-all\n",
        )
        @test occursin(
            "write-all (job 'docs')",
            detail("workflow-permissions", fixture(job_all)),
        )
    end

    @testset "workflow-concurrency" begin
        cancel = "cancel-in-progress: \${{ startsWith(github.ref, 'refs/pull/') }}"
        group = "concurrency:\n  group: \${{ github.workflow }}-\${{ github.ref }}\n  $cancel\n"
        @test occursin(group, CI_WORKFLOW)
        @test occursin(
            "CI.yml: no concurrency group",
            detail("workflow-concurrency", fixture(workflow(group => ""))),
        )
        @test fails(
            "workflow-concurrency",
            fixture(workflow(cancel => "cancel-in-progress: false")),
        )
        @test passes(
            "workflow-concurrency",
            fixture(workflow(cancel => "cancel-in-progress: true")),
        )
        @test fails(
            "workflow-concurrency",
            fixture(workflow(group => "concurrency: ci-\${{ github.ref }}\n")),
        )
        @test fails("workflow-concurrency", fixture(workflow("  $cancel\n" => "")))
        per_job = workflow(
            group => "",
            "    runs-on: ubuntu-latest\n" => "    runs-on: ubuntu-latest\n    concurrency:\n      group: x\n      cancel-in-progress: true\n",
        )
        @test passes("workflow-concurrency", fixture(per_job))
    end

    @testset "ci-matrix" begin
        versions(text) = fixture(workflow("version: ['min', '1']" => text))
        @test passes(
            "ci-matrix",
            versions("version: ['min', '1', 'pre', 'lts', 'nightly']"),
        )
        @test passes("ci-matrix", versions("julia-version: [min, '1']"))
        @test occursin(
            "job 'test': version '1.10' is pinned",
            detail("ci-matrix", versions("version: ['min', '1', '1.10']")),
        )
        # YAML reads an unquoted 1.10 as the number 1.1
        @test occursin(
            "is a number",
            detail("ci-matrix", versions("version: [min, '1', 1.10]")),
        )
        @test occursin("is a number", detail("ci-matrix", versions("version: [min, 1]")))
        @test occursin(
            "no matrix holds all of: min, 1",
            detail("ci-matrix", versions("version: ['1']")),
        )
        @test occursin(
            "no Julia version matrix",
            detail("ci-matrix", versions("os: [ubuntu-latest]")),
        )
        none = fixture(
            workflow(
                "    strategy:\n      fail-fast: false\n      matrix:\n        version: ['min', '1']\n" => "",
            ),
        )
        @test occursin("no Julia version matrix", detail("ci-matrix", none))
    end

    @testset "format, changelog, docs, coverage" begin
        @test occursin(
            ".JuliaFormatter.toml",
            detail("format", fixture(".JuliaFormatter.toml" => nothing)),
        )
        @test occursin(
            "no format workflow",
            detail("format", fixture(".github/workflows/Format.yml" => nothing)),
        )
        renamed = fixture(
            ".github/workflows/Format.yml" => nothing,
            ".github/workflows/format-check.yaml" => FORMAT_WORKFLOW,
        )
        @test passes("format", renamed)
        @test fails("changelog", fixture("CHANGELOG.md" => nothing))
        @test fails(
            "changelog",
            fixture("CHANGELOG.md" => nothing, "docs/CHANGELOG.md" => "x"),
        )
        @test occursin("docs/make.jl", detail("docs", fixture("docs/make.jl" => nothing)))
        no_deploy =
            fixture(workflow(r"      - uses: julia-actions/julia-docdeploy.*\n" => ""))
        @test occursin("no workflow builds the documentation", detail("docs", no_deploy))
        by_script = fixture(
            workflow(
                r"      - uses: julia-actions/julia-docdeploy.*\n" => "      - run: julia --project=docs docs/make.jl\n",
            ),
        )
        @test passes("docs", by_script)
        @test occursin(
            "julia-processcoverage",
            detail(
                "coverage",
                fixture(
                    workflow(
                        r"      - uses: julia-actions/julia-processcoverage.*\n" => "",
                    ),
                ),
            ),
        )
        @test occursin(
            "codecov-action",
            detail(
                "coverage",
                fixture(workflow(r"      - uses: codecov/codecov-action.*\n" => "")),
            ),
        )
    end

    @testset "readme-tree" begin
        text = readme()
        with_readme(changes::Pair...) = fixture("README.md" => replace(text, changes...))
        @test fails("readme-tree", fixture("README.md" => nothing))
        @test occursin(
            "no code block",
            detail("readme-tree", fixture("README.md" => "# Pkg.jl\n\nText.\n")),
        )
        first_block = with_readme(
            "Solves the thing.\n" => "Solves the thing.\n\n```bash\njulia run.jl\n```\n",
        )
        @test occursin(
            "the first code block is not a file tree",
            detail("readme-tree", first_block),
        )
        long = with_readme("├── src/\n" => "├── src/\n"^20)
        opening = findfirst(==("```"), split(text, '\n'))
        @test occursin(
            "README.md:$opening: the tree has 23 lines, more than 20",
            detail("readme-tree", long),
        )
        late = with_readme("Solves the thing.\n" => "Solves the thing.\n" * "\nMore.\n"^15)
        @test occursin("the tree opens after line 40", detail("readme-tree", late))
        tilde = with_readme(
            "```\nPkg.jl/" => "~~~\nPkg.jl/",
            "README.md\n```" => "README.md\n~~~",
        )
        @test passes("readme-tree", tilde)
    end

    @testset "badge helpers" begin
        @test shields_escape("Linux x86_64") == "Linux%20x86__64"
        @test shields_escape("10.1000/a-b_c") == "10.1000%2Fa--b__c"
        @test url_encode("https://raw.githubusercontent.com/u/r/main/Project.toml") ==
              "https%3A%2F%2Fraw.githubusercontent.com%2Fu%2Fr%2Fmain%2FProject.toml"
        @test url_encode("a-b.c_d~e é") == "a-b.c_d~e%20%C3%A9"
        badge = Badge("ci", "CI", "https://example.org/b.svg", "https://example.org")
        @test markdown(badge) == "[![CI](https://example.org/b.svg)](https://example.org)"

        parsed = readme_badges(readme())
        @test markdown.(parsed) == BADGE_ROW
        @test all(isempty(b.kind) for b in parsed)
        # several badges on one line, blank lines under the title, and the end of the row
        one_line = "# T\n\n\n$(BADGE_ROW[1]) $(BADGE_ROW[2])\n$(BADGE_ROW[3])\nText $(BADGE_ROW[4])\n"
        @test markdown.(readme_badges(one_line)) == BADGE_ROW[1:3]
        @test isempty(readme_badges("$(BADGE_ROW[1])\n"))
        @test isempty(readme_badges("# T\n\nText first.\n\n$(BADGE_ROW[1])\n"))
        @test isempty(readme_badges("# T\n\n![figure](a.png)\n"))
    end

    @testset "expected badges" begin
        row(repo; options = PLATFORM) = expected_badges(repo, SETTINGS, options)
        badges = row(fixture())
        @test markdown.(badges) == BADGE_ROW
        @test [b.kind for b in badges] == BADGE_KINDS
        kinds(repo; kw...) = [b.kind for b in row(repo; kw...)]
        # stable docs need the docs and a release tag
        @test "docs" ∉ kinds(fixture(; tags = String[]))
        @test "docs" ∉ kinds(fixture(; tags = ["v1.0.0-rc.1", "paper/abc", "1.0.0"]))
        @test "docs" ∉ kinds(fixture("docs/make.jl" => nothing))
        @test kinds(fixture(); options = NO_OPTIONS) == BADGE_KINDS[1:10]
        bare = RepositoryOptions("", "CUDA", "", "", "", Dict{String, String}())
        @test last(row(fixture(); options = bare)).image ==
              "https://img.shields.io/badge/platform-CUDA-lightgrey"
        # further workflows between CI and coverage, housekeeping left out
        more = fixture(
            ".github/workflows/Nightly.yml" => "name: GPU nightly\non: workflow_dispatch\njobs: {}\n",
            ".github/workflows/Downstream.yml" => "on: workflow_dispatch\njobs: {}\n",
            ".github/workflows/TagBot.yml" => "name: TagBot\non: workflow_dispatch\njobs: {}\n",
        )
        extra = row(more)
        @test [b.kind for b in extra][1:5] == ["docs", "ci", "workflow", "workflow", "coverage"]
        @test [b.alt for b in extra][3:4] == ["Downstream", "GPU nightly"]
        @test extra[4].image ==
              "https://github.com/user/Pkg.jl/actions/workflows/Nightly.yml/badge.svg?branch=main"
        @test extra[4].link ==
              "https://github.com/user/Pkg.jl/actions/workflows/Nightly.yml?query=branch%3Amain"
        # what the repository does not carry gets no badge
        @test "coverage" ∉
              kinds(fixture(workflow(r"      - uses: codecov/codecov-action.*\n" => "")))
        @test "aqua" ∉ kinds(
            fixture(
                "test/Project.toml" => "[deps]\nJET = \"c3a54625-cd67-489e-a8e7-0a5a0ff4e31b\"\n",
            ),
        )
        @test "jet" ∉ kinds(
            fixture(
                "test/Project.toml" => "[extras]\nAqua = \"4c88cf16-eb10-579e-8560-4a9242c79595\"\n",
            ),
        )
        @test "aqua" ∈ kinds(
            fixture(
                "test/Project.toml" => "[extras]\nAqua = \"4c88cf16-eb10-579e-8560-4a9242c79595\"\n",
            ),
        )
        @test "style" ∉ kinds(fixture(".JuliaFormatter.toml" => "indent = 4\n"))
        @test "style" ∉ kinds(fixture(".JuliaFormatter.toml" => "style = \"yas\"\n"))
        sciml = filter(
            b -> b.kind == "style",
            row(fixture(".JuliaFormatter.toml" => "style = \"sciml\"\n")),
        )
        @test markdown(only(sciml)) ==
              "[![SciML Code Style](https://img.shields.io/static/v1?label=code%20style&message=SciML&color=9558b2&labelColor=389826)](https://github.com/SciML/SciMLStyle)"
        @test "format" ∉ kinds(fixture(".github/workflows/Format.yml" => nothing))
        @test "julia" ∉ kinds(fixture("Project.toml" => nothing))
        nested =
            RepositoryOptions("test/Project.toml", "", "", "", "", Dict{String, String}())
        julia = only(
            filter(
                b -> b.kind == "julia",
                row(fixture("Project.toml" => nothing); options = nested),
            ),
        )
        @test julia.image ==
              "https://img.shields.io/badge/dynamic/toml?url=https%3A%2F%2Fraw.githubusercontent.com%2Fuser%2FPkg.jl%2Fmain%2Ftest%2FProject.toml&query=%24.compat.julia&label=julia&logo=julia&color=9558b2"
        # identifiers: every DOI once, an arXiv number without its version
        cff =
            CITATION *
            "  - type: doi\n    value: 10.5281/zenodo.1234567\n  - type: doi\n    value: 10.1000/x_y-z\n  - type: other\n    value: \"arxiv:2402.5678v3\"\n  - type: url\n    value: \"https://example.org\"\npreferred-citation:\n  type: article\n  doi: 10.1103/PhysRevD.1.1\n"
        papers =
            filter(b -> b.kind in ("doi", "arxiv"), row(fixture("CITATION.cff" => cff)))
        @test [b.link for b in papers] == [
            "https://doi.org/10.5281/zenodo.1234567",
            "https://doi.org/10.1000/x_y-z",
            "https://doi.org/10.1103/PhysRevD.1.1",
            "https://arxiv.org/abs/2401.01234",
            "https://arxiv.org/abs/2402.5678",
        ]
        @test papers[2].image ==
              "https://img.shields.io/badge/DOI-10.1000%2Fx__y--z-blue?logo=doi"
        @test isempty(
            filter(
                b -> b.kind in ("doi", "arxiv"),
                row(fixture("CITATION.cff" => nothing)),
            ),
        )
        @test isempty(
            filter(
                b -> b.kind in ("doi", "arxiv"),
                row(fixture("CITATION.cff" => "a: [\n")),
            ),
        )
        # another owner, repository and branch
        other = row(fixture(; slug = "org/Tool", branch = "trunk"); options = NO_OPTIONS)
        @test other[1].link == "https://org.github.io/Tool/stable/"
        @test other[2].image ==
              "https://github.com/org/Tool/actions/workflows/CI.yml/badge.svg?branch=trunk"
        @test other[3].image ==
              "https://codecov.io/gh/org/Tool/branch/trunk/graph/badge.svg"
        @test_throws ArgumentError row(fixture(; slug = ""))
    end

    @testset "badges check" begin
        with_row(badges) = fixture("README.md" => readme(badges))
        @test passes("badges", fixture())
        # the alternative text is free
        @test passes("badges", with_row(replace.(BADGE_ROW, r"^\[!\[[^\]]*\]" => "[![x]")))
        missing_one = detail("badges", with_row(BADGE_ROW[[1:2; 4:11]]))
        @test occursin("missing coverage: " * BADGE_ROW[3], missing_one)
        @test !occursin("unexpected", missing_one) && !occursin("order", missing_one)
        stray = "[![Stars](https://img.shields.io/github/stars/user/Pkg.jl)](https://github.com/user/Pkg.jl)"
        extra = detail("badges", with_row([BADGE_ROW; stray]))
        @test occursin("unexpected: " * stray, extra) && !occursin("missing", extra)
        swapped = detail("badges", with_row(BADGE_ROW[[2; 1; 3:11]]))
        @test occursin("order: expected " * join(BADGE_KINDS, ", "), swapped)
        @test !occursin("missing", swapped) && !occursin("unexpected", swapped)
        # the old JET badge without the aeroplane
        old = replace.(BADGE_ROW, "%F0%9F%9B%A9%EF%B8%8F_tested_with" => "tested%20with")
        @test occursin("missing jet", detail("badges", with_row(old)))
        @test occursin("repository unknown", detail("badges", fixture(; slug = "")))
        @test fails("badges", fixture("README.md" => nothing))
        @test fails("badges", fixture(); options = NO_OPTIONS)
    end

    @testset "waivers and selection" begin
        broken = fixture("docs/make.jl" => nothing, "CHANGELOG.md" => nothing)
        waived = RepositoryOptions(
            "",
            "Linux x86_64",
            "linux",
            "",
            "",
            Dict("docs" => "one-file tools"),
        )
        ids = filter(!in(CHILD_CHECKS), CHECK_IDS)
        results =
            Dict(r.id => r for r in launch_checks(broken, SETTINGS, waived; only = ids))
        @test results["docs"].status == :waived
        @test results["docs"].details == ["one-file tools"]
        @test results["changelog"].status == :fail
        some = launch_checks(broken, SETTINGS, waived; only = ["changelog", "license"])
        @test [r.id for r in some] == ["license", "changelog"]
        @test_throws ArgumentError launch_checks(
            broken,
            SETTINGS,
            waived;
            only = ["licence"],
        )
    end

    @testset "repository options" begin
        options(text) = load_repository_options(fixture(".launch-check.toml" => text))
        absent = load_repository_options(fixture())
        @test all(isempty(getfield(absent, name)) for name in fieldnames(RepositoryOptions))
        full = options("""
            project_file = "test/Project.toml"
            platform = "Linux x86_64"
            platform_logo = "linux"
            repository = "org/Tool"
            branch = "trunk"

            [waive]
            docs = "one-file tools"
            coverage = "scripts started as child processes"
            """)
        @test (full.project_file, full.platform, full.platform_logo) ==
              ("test/Project.toml", "Linux x86_64", "linux")
        @test (full.repository, full.branch) == ("org/Tool", "trunk")
        @test full.waive == Dict(
            "docs" => "one-file tools",
            "coverage" => "scripts started as child processes",
        )
        @test_throws "colour" options("colour = \"red\"\n")
        @test_throws "platform" options("platform = 3\n")
        @test_throws "licence" options("[waive]\nlicence = \"x\"\n")
        @test_throws "docs" options("[waive]\ndocs = \"\"\n")
        @test_throws "project_file" options("project_file = \"lib/Project.toml\"\n")
        @test_throws ArgumentError options("platform = \n")
    end

    @testset "reading a repository" begin
        root = git_repository()
        git_run(root, "tag", "v1.0.0")
        git_run(root, "tag", "paper/abc")
        write(joinpath(root, "untracked.txt"), "x")
        repo = read_repository(root)
        @test repo.root == root
        @test repo.tracked == sort!(collect(keys(conforming_files())))
        @test (repo.slug, repo.branch) == ("user/Pkg.jl", "main")
        @test sort(repo.tags) == ["paper/abc", "v1.0.0"]
        @test read_tracked(repo, "CHANGELOG.md") == "# Changelog\n"
        @test read_tracked(repo, "untracked.txt") === nothing
        @test read_tracked(repo, "absent.txt") === nothing
        for remote in (
            "git@github.com:user/Pkg.jl.git",
            "https://github.com/user/Pkg.jl",
            "ssh://git@github.com/user/Pkg.jl.git",
            "https://github.com/user/Pkg.jl/",
        )
            git_run(root, "remote", "set-url", "origin", remote)
            @test read_repository(root).slug == "user/Pkg.jl"
        end
        git_run(root, "remote", "set-url", "origin", "https://gitlab.com/user/Pkg.jl.git")
        @test read_repository(root).slug == ""
        chosen = read_repository(root; repository = "org/Tool", branch = "trunk")
        @test (chosen.slug, chosen.branch) == ("org/Tool", "trunk")
        @test_throws ArgumentError read_repository(root; repository = "org")
        @test_throws ArgumentError read_repository(root; repository = "org/Tool/extra")
        @test_throws ArgumentError read_repository(joinpath(root, "src"))
        @test_throws ArgumentError read_repository(mktempdir())
        @test_throws ArgumentError read_repository(joinpath(root, "absent"))
        local_only = read_repository(git_repository(; remote = nothing))
        @test (local_only.slug, local_only.branch) == ("", "main")
    end

    @testset "child checks" begin
        clean = read_repository(git_repository())
        @test passes("self-contained", clean)
        @test passes("history", clean)
        files = conforming_files()
        # a path that leaves the repository, assembled here so that the scan of this
        # repository does not meet it written out
        outside = join(["..", "..", "notes", "worklog.md"], "/")
        files["docs/setup.md"] = "The run log is in `$outside`.\n"
        message = "feat: first version\n\nCo-authored-by: Claude <noreply@anthropic.com>"
        dirty = read_repository(git_repository(files; message))
        @test occursin("exited with status 1", detail("self-contained", dirty))
        @test occursin("exited with status 1", detail("history", dirty))
    end

    @testset "command line" begin
        root = git_repository()
        git_run(root, "tag", "v1.0.0")
        output(args) =
            (io = IOBuffer(); result = main(args; io); (result, String(take!(io))))
        fast = "license,changelog,badges,docs"
        result, text = output([
            root,
            "--only",
            fast,
            "--platform",
            "Linux x86_64",
            "--platform-logo",
            "linux",
        ])
        @test !result.failed
        @test [r.id for r in result.results] == ["license", "changelog", "badges", "docs"]
        @test occursin("user/Pkg.jl", text) && occursin("branch main", text)
        @test occursin("4 checks: 4 ok, 0 failed, 0 waived, 0 notes", text)
        _, one = output([root, "--only", "license"])
        @test occursin("1 check: 1 ok, 0 failed, 0 waived, 0 notes", one)
        # without the platform the README carries one badge too many
        result, text = output([root, "--only", fast])
        @test result.failed
        @test occursin(r"FAIL\s+badges", text) &&
              occursin("unexpected: " * BADGE_ROW[11], text)
        @test occursin("4 checks: 3 ok, 1 failed, 0 waived, 0 notes", text)
        result, text = output([root, "--only", fast, "--waive", "badges"])
        @test !result.failed
        @test occursin(r"waived\s+badges", text) &&
              occursin("waived on the command line", text)
        result, text = output([root, "--only", "badges", "--repository", "org/Tool"])
        @test result.failed && occursin("org/Tool", text)

        result, text = output([
            "badges",
            root,
            "--platform",
            "Linux x86_64",
            "--platform-logo",
            "linux",
        ])
        @test !result.failed
        @test markdown.(result.badges) == BADGE_ROW
        @test split(strip(text), '\n') == BADGE_ROW
        result, text = output([
            "badges",
            root,
            "--branch",
            "trunk",
            "--project-file",
            "test/Project.toml",
        ])
        @test occursin("branch=trunk", text) &&
              occursin("trunk%2Ftest%2FProject.toml", text)

        result, text = output(["--list"])
        @test result === nothing
        @test all(occursin(id, text) for id in CHECK_IDS)
        @test count(==('\n'), text) >= length(CHECK_IDS)
        result, text = output(["--help"])
        @test result === nothing && occursin("launch-check", text)

        @test_throws ArgumentError main([root, "--colour"]; io = devnull)
        @test_throws ArgumentError main([root, root]; io = devnull)
        @test_throws ArgumentError main([root, "--only"]; io = devnull)
        @test_throws ArgumentError main([root, "--only", "licence"]; io = devnull)
        @test_throws ArgumentError main([root, "--waive", "licence"]; io = devnull)
        @test_throws ArgumentError main([root, "--repository", "org"]; io = devnull)
        @test_throws ArgumentError main(
            [root, "--project-file", "lib/Project.toml"];
            io = devnull,
        )
        @test_throws ArgumentError main([mktempdir()]; io = devnull)
        @test_throws ArgumentError main(
            ["--config", joinpath(root, "absent.toml"), root];
            io = devnull,
        )

        # the file in the repository supplies what the command line leaves out
        files = conforming_files()
        files[".launch-check.toml"] = "platform = \"Linux x86_64\"\nplatform_logo = \"linux\"\n\n[waive]\ndocs = \"none yet\"\n"
        configured = git_repository(files)
        git_run(configured, "tag", "v1.0.0")
        result, text = output([configured])
        @test !result.failed
        @test length(result.results) == length(CHECK_IDS)
        @test count(r -> r.status == :waived, result.results) == 1
        @test occursin("19 checks: 18 ok, 0 failed, 1 waived, 0 notes", text)

        script = joinpath(TOOL_DIR, "launch-check.jl")
        # ignorestatus wraps the command, not the pipeline: Julia 1.12 has no method for
        # the latter
        function status(args)
            command = ignorestatus(`$(Base.julia_cmd()) --startup-file=no $script $args`)
            return run(pipeline(command; stdout = devnull, stderr = devnull)).exitcode
        end
        @test status([root, "--only", "license"]) == 0
        @test status([root, "--only", "badges"]) == 1
        @test status([root, "--colour"]) == 2
    end

    @testset "review of the first round" begin
        # compat entries are judged by the parser of Pkg
        project(entry) = fixture(
            "Project.toml" =>
                "[deps]\nA = \"00000000-0000-0000-0000-00000000000a\"\n" *
                "[compat]\nA = \"$entry\"\njulia = \"1.10\"\n",
        )
        for entry in ("≥ 1.2", "≥1.2, 2", ">= 0.3")
            @test occursin("no upper bound", detail("compat", project(entry)))
        end
        for entry in ("<= 2", "1.x", "latest")
            @test occursin(
                "is not a compat entry Pkg accepts",
                detail("compat", project(entry)),
            )
        end
        for entry in ("0", "^0.2", "< 5", "1 - 2", "~1.2.3", "=1.2.3", "0.4, 0.5")
            @test passes("compat", project(entry))
        end
        # a project that lists a package of this repository, developed by path
        docs(uuid) =
            "[deps]\nDocumenter = \"e30172f5-a6a5-5a46-863b-614d45cd2de4\"\n" *
            "Pkg = \"$uuid\"\n[compat]\nDocumenter = \"1\"\njulia = \"1.10\"\n"
        own = "00000000-0000-0000-0000-000000000001"
        @test passes("compat", fixture("docs/Project.toml" => docs(own)))
        foreign = "00000000-0000-0000-0000-00000000000f"
        @test occursin(
            "docs/Project.toml: Pkg has no [compat] entry",
            detail("compat", fixture("docs/Project.toml" => docs(foreign))),
        )

        # composite actions of the repository are read like workflows
        action(uses) =
            ".github/actions/setup/action.yml" => "name: Setup\nruns:\n  using: composite\n  steps:\n    - uses: $uses\n"
        local_step = workflow(
            "actions/checkout@$SHA # v7.0.1" => "./.github/actions/setup";
            count = 1,
        )
        @test occursin(
            ".github/actions/setup/action.yml:5: actions/cache@v4 is not pinned by a commit SHA",
            detail("workflow-pins", fixture(local_step, action("actions/cache@v4"))),
        )
        @test passes(
            "workflow-pins",
            fixture(local_step, action("actions/cache@$SHA # v4.2.0")),
        )
        @test occursin(
            "has no release comment",
            detail("workflow-pins", fixture(local_step, action("actions/cache@$SHA"))),
        )
        @test occursin(
            "action.yml: not valid YAML",
            detail(
                "workflow-pins",
                fixture(".github/actions/setup/action.yml" => "runs: [\n"),
            ),
        )

        # a pinned and commented value in other YAML forms
        line = "      - uses: actions/checkout@$SHA # v7.0.1"
        forms(text) = fixture(workflow(line => text))
        @test count(line, CI_WORKFLOW) == 2
        # an anchor on the first step, its alias on the second
        anchored =
            replace(CI_WORKFLOW, line => replace(line, "uses: " => "uses: &co "); count = 1)
        anchored = replace(anchored, line => "      - uses: *co")
        @test count("actions/checkout@", anchored) == 1
        @test passes("workflow-pins", fixture(".github/workflows/CI.yml" => anchored))
        @test passes(
            "workflow-pins",
            forms("      - {uses: actions/checkout@$SHA} # v7.0.1"),
        )
        @test passes(
            "workflow-pins",
            forms("      - \"uses\": actions/checkout@$SHA # v7.0.1"),
        )
        bare = detail("workflow-pins", forms("      - {uses: actions/checkout@$SHA}"))
        @test occursin("has no release comment", bare) && !occursin("CI.yml:0:", bare)
        # an owner path of several components
        longer = forms("      - {uses: org/actions/checkout@$SHA} # v1.0.0")
        @test passes("workflow-pins", longer)

        # versions outside the matrix list
        versions(text) = fixture(workflow("version: ['min', '1']" => text))
        included = "version: ['min', '1']\n        include:\n          - version: '1.10'\n            os: windows-latest"
        @test occursin(
            "job 'test': version '1.10' is pinned",
            detail("ci-matrix", versions(included)),
        )
        @test passes("ci-matrix", versions(replace(included, "'1.10'" => "'pre'")))
        @test occursin(
            "is a number",
            detail("ci-matrix", versions(replace(included, "'1.10'" => "1.10"))),
        )
        literal(text) =
            fixture(workflow("version: \${{ matrix.version }}" => "version: $text"))
        @test passes("ci-matrix", fixture())
        @test passes("ci-matrix", literal("'1'"))
        @test occursin(
            "job 'test': version '1.12' is pinned",
            detail("ci-matrix", literal("'1.12'")),
        )
        @test occursin("is a number", detail("ci-matrix", literal("1.12")))

        # Markdown: fences close as in CommonMark, comments hide their lines
        citing(text) = check("cite-section", fixture("README.md" => text)).status
        entry = "```bibtex\n@software{x,}\n```\n"
        @test citing("# T\n\n## How to cite\n\n$entry") == :ok
        @test citing("# T\n\n````markdown\n```\n## How to cite\n$entry````\n") == :fail
        @test citing("# T\n\n~~~\n```\n## How to cite\n$entry~~~\n") == :fail
        @test citing(
            "# T\n\n```julia\nx = 1\n```\n\n## How to cite\n\n````bibtex\n@software{x,}\n````\n",
        ) == :ok
        @test citing("# T\n\n<!--\n## How to cite\n\n$entry-->\n") == :fail
        @test citing("# T\n\n<!-- note -->\n\n## How to cite\n\n$entry") == :ok
        @test citing("# T\n\n## Citations\n\n$entry") == :ok
        @test citing("# T\n\n## Citing and cited works\n\n$entry") == :ok
        @test citing("# T\n\n## Excitation spectra\n\n$entry") == :fail
        tree = "```\nPkg/\n├── src/\n└── test/\n```\n"
        @test passes(
            "readme-tree",
            fixture("README.md" => "# T\n\n<!--\n```\nnot a tree\n```\n-->\n\n$tree"),
        )
        row = BADGE_ROW[1:2]
        @test markdown.(
            readme_badges(
                "Pkg.jl\n======\n\n$(join(row, "\n"))\n\n```bash\n# install\n```\n",
            ),
        ) == row
        @test markdown.(
            readme_badges("# Pkg.jl\n\n<!-- badges -->\n$(join(row, "\n"))\n"),
        ) == row
        @test markdown.(
            readme_badges("```bash\n# not the title\n```\n\n# Pkg.jl\n\n$(row[1])\n"),
        ) == row[1:1]
        @test isempty(readme_badges("```\n# only in code\n$(row[1])\n```\n"))

        # a DOI with parentheses gives a badge that the README reader takes back
        cff(doi) = fixture(
            "CITATION.cff" => replace(CITATION, "10.5281/zenodo.1234567" => doi),
            "README.md" => readme(),
        )
        papers(repo) = filter(
            b -> b.kind in ("doi", "joss"),
            expected_badges(repo, SETTINGS, PLATFORM),
        )
        sici = only(
            papers(
                cff("\"10.1002/(SICI)1097-0142(19960101)77:1<1::AID-CNCR1>3.0.CO;2-Z\""),
            ),
        )
        @test !occursin('(', sici.image * sici.link) &&
              !occursin(')', sici.image * sici.link)
        @test startswith(sici.link, "https://doi.org/10.1002/%28SICI%291097")
        @test only(readme_badges("# T\n\n$(markdown(sici))\n")).link == sici.link
        joss = only(papers(cff("10.21105/joss.01234")))
        @test markdown(joss) ==
              "[![JOSS](https://joss.theoj.org/papers/10.21105/joss.01234/status.svg)](https://doi.org/10.21105/joss.01234)"

        # the placeholders of a licence template are no holder
        apache = "Copyright [yyyy] [name of copyright owner]\n"
        @test occursin(
            "LICENSE:1: the holder line is the unedited template",
            detail("license", fixture("LICENSE" => apache)),
        )
        @test fails(
            "license",
            fixture("LICENSE" => "Copyright (c) <year> <copyright holders>\n"),
        )
        @test passes(
            "license",
            fixture("LICENSE" => "Copyright (c) 2026 Jane Doe [CERN]\n"),
        )

        # where a failed child check sends the reader
        files = conforming_files()
        files["docs/setup.md"] = "The run log is in `$(join(["..", "..", "notes", "x.md"], "/"))`.\n"
        dirty = read_repository(git_repository(files))
        @test occursin(
            "workspace-audit $(dirty.root) --self-contained",
            detail("self-contained", dirty),
        )

        # a configuration that cannot be read is an invalid argument
        if !Sys.iswindows()
            config = joinpath(mktempdir(), "config.toml")
            write(config, "[readme]\n")
            chmod(config, 0o000)
            # the superuser reads the file whatever its mode
            isreadable = try
                read(config, String)
                true
            catch err
                err isa SystemError || rethrow()
                false
            end
            isreadable || @test_throws ArgumentError load_settings(config)
        end
    end
end
