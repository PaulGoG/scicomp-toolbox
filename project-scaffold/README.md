# project-scaffold

Generates a new Julia package that follows the conventions of this workbench from the
first commit: an activation script in every environment, test, documentation and
benchmark environments that take the package by path, an optional DrWatson pipeline
layer, citation metadata, and GitHub workflows and a Dependabot configuration that are in
place but stay dormant until the public launch. PkgTemplates makes the skeleton; the tool
then writes the project files, renders its own templates over the skeleton, removes the
manifests and formats the tree. It writes only below `--dir`. It needs the network: the
dependencies are resolved against the registry, and the action pins are read from the
action repositories with `git ls-remote`.

```
project-scaffold/
├── activate.jl                  # environment activation
├── config.toml                  # compat floor, licence, style, branch, action series; validated on load
├── project-scaffold.jl          # entry point, generation and rendering
├── Project.toml                 # Dates, Pkg, PkgTemplates, TOML; Test serves the test suite only
├── README.md
├── templates/                   # the files rendered into the package, with <<KEY>> placeholders
└── test/
    └── runtests.jl              # settings, pins, rendering; packages generated at test time and run
```

## Usage

```bash
julia run.jl project-scaffold NAME --dir DIR --user USER --authors "Name One, Name Two"
                              [--julia X.Y] [--no-pipeline] [--no-commit] [--no-hook]
                              [--config PATH]
julia run.jl project-scaffold --help
```

`NAME` is the package name, with or without `.jl`: an upper-case letter followed by
letters and digits. The package directory `DIR/NAME` must not exist; `DIR` must, and is
made absolute. `--user` is the GitHub user or organisation the URLs of the README, the
documentation and the citation metadata point to. `--authors` takes names only, separated
by commas; an e-mail address is refused, since the licence holder line carries the names.
`--julia` sets the compat floor and defaults to `[package].julia` of the configuration.
`--no-pipeline` leaves out the DrWatson layer, `--no-commit` the git repository and its
first commit, `--no-hook` the commit-guard hook. The four required arguments are checked
before anything is fetched or written.

```
Created /home/user/workspace/Spectra
Next steps:
  julia run.jl workspace-audit /home/user/workspace --scaffold
      lays out the workspace around the package
  gh api -X PUT repos/user/Spectra.jl/actions/permissions -F enabled=false
      switches Actions off once a private remote exists; the workflow jobs are skipped in a private repository in any case
  julia run.jl launch-check /home/user/workspace/Spectra
      the launch check; it fails on changelog, badges and dependabot until the launch work is done
```

The steps, in order: the action pins are resolved; PkgTemplates generates the skeleton
with the plugins `ProjectFile`, `Tests` (with its own project), `License`, `Formatter`
and `Documenter{GitHubActions}`, its `Git`, `Readme`, `TagBot` and `Dependabot` plugins
switched off; the versions of the dependencies are resolved in a temporary environment;
the project files are written; the templates are rendered; every manifest is removed;
the tree is formatted with the pinned formatter of the workbench against the package's
own `.JuliaFormatter.toml`; with the commit, `git init`, `git add -A` and
`git commit -m "chore: scaffold of NAME.jl"` are run; with the hook, `commit-guard install`.
A commit that fails because git has no identity configured leaves the repository without
a commit and prints a note; a hook that is not installed prints a note as well.

## What is generated

```
Spectra/
├── .github/
│   ├── dependabot.yml      # weekly updates of actions and Julia environments; off until the launch
│   └── workflows/
│       ├── CI.yml          # tests on the compat floor and the stable release, coverage, documentation
│       └── Format.yml      # JuliaFormatter gate with the pinned version
├── .gitignore              # manifests, documentation build, coverage; data/ and plots/ with the pipeline
├── .JuliaFormatter.toml
├── CITATION.cff
├── LICENSE
├── Project.toml            # with the pipeline: DrWatson and TOML in [deps] and [compat]
├── README.md               # short tree, setup, entry points, status, citation, full tree
├── activate.jl
├── bench/
│   ├── Project.toml        # BenchmarkTools and the package by path
│   ├── activate.jl
│   └── benchmarks.jl
├── configs/                # pipeline only
│   └── minimal.toml
├── docs/
│   ├── Project.toml        # Documenter and the package by path
│   ├── activate.jl
│   ├── make.jl
│   └── src/
│       └── index.md
├── scripts/                # pipeline only
│   └── run.jl
├── src/
│   └── Spectra.jl          # with the pipeline: load_configuration and run_directory
└── test/
    ├── Project.toml        # Aqua, JET, Test and the package by path
    ├── activate.jl
    └── runtests.jl         # Aqua, JET from the current release series, unit tests
```

Without the pipeline layer, `configs/` and `scripts/` are absent, the root `Project.toml`
has no dependencies, `src/Spectra.jl` is the empty module of PkgTemplates, and the README
and `.gitignore` carry no pipeline lines.

Every `[compat]` entry of a dependency names the release series of the version resolved
at generation time (`"1"`, `"0.8"`), preceded by the series of `[compat_extra]`. JET,
whose release series follow the Julia release, thus reads `"0.9, 0.13"` and still
installs on a compat floor of 1.10. The
auxiliary environments take the package through `[sources]`, which Julia reads from 1.11
on; their `activate.jl` develops the package by path on older releases. No manifest is
written, and none is tracked.

## Before the launch

Every job of `CI.yml` and `Format.yml` carries
`if: github.event.repository.visibility == 'public'`, so a private repository runs
nothing; the jobs start once the repository is public. `dependabot.yml` sets
`open-pull-requests-limit: 0` on each update entry, which keeps version updates off;
removing that line is the one change it needs at the launch. The actions are pinned by
commit SHA with the release as a comment, resolved at generation time as the highest
release `vX.Y.Z` within the major series of `[actions]`; Dependabot keeps them current
once it is switched on. `launch-check` names what is left: on a fresh package it fails
on `changelog`, `badges` and `dependabot` until the launch work is done.

## Settings

`config.toml` next to the tool, or the file given with `--config`. Every key is
optional and takes the default shown; unknown sections and keys, values of the wrong
type, a `julia` that is not `MAJOR.MINOR`, a `style` outside the four names, a major that
is not an integer of at least 0, and a `[compat_extra]` value that is not a list of
non-empty strings are errors naming the key. An `[actions]` table replaces the default
table as a whole and must list every action the templates pin; the keys of
`[compat_extra]` are added to the default `JET` entry or replace it.

```toml
[package]
julia = "1.10"                 # compat floor of the generated package; MAJOR.MINOR
license = "MIT"                # licence name as PkgTemplates knows it
style = "blue"                 # "blue" | "sciml" | "yas" | "nostyle"
branch = "main"                # default branch

[actions]                      # major series of each pinned action
"actions/checkout" = 7
"julia-actions/setup-julia" = 3
"julia-actions/cache" = 3
"julia-actions/julia-buildpkg" = 1
"julia-actions/julia-runtest" = 1
"julia-actions/julia-processcoverage" = 1
"julia-actions/julia-docdeploy" = 1
"codecov/codecov-action" = 6

[remote]
host = "https://github.com"    # where the action repositories are read with git ls-remote

[compat_extra]                 # earlier release series added to a derived [compat] entry
JET = ["0.9"]
```

The JuliaFormatter version of `Format.yml` is not a setting: it is the exact version
pinned in `formatter/Project.toml` of the workbench, so that the workflow and the local
formatter agree.

## Return values

The exit status is 0 when the package was generated, also when the first commit could
not be made or the hook not installed, and 2 for an invalid argument or configuration,
an existing package directory, a pin that cannot be resolved, or a missing formatter
entry. Status 1 means that the generation itself failed, for instance in PkgTemplates,
the resolution of the dependencies, the formatter or `git init`; the package directory
may then be incomplete and is left for inspection.
