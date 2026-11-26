# launch-check

Checks a Julia repository against the conventions of a public launch: the licence holder
line, the citation metadata and the README section on citing, untracked manifests,
bounded `[compat]` entries, the Dependabot configuration, GitHub Actions workflows pinned
by commit SHA with declared permissions and a concurrency group that cancels superseded
runs, a CI matrix over named Julia channels, the formatter, the changelog, the README
file tree and badge row, the documentation build, coverage upload, self-containment and
the commit history. It also generates the badge row the repository warrants. The tool
reads the tracked files and asks git; it writes nothing to the repository. It is a
conventions check, not a security scanner of workflows: zizmor (https://docs.zizmor.sh)
does that. Repository settings held by GitHub, such as branch protection and topics, are
outside its reach.

```
launch-check/
├── activate.jl                  # environment activation
├── config.toml                  # Julia channels, Dependabot ecosystems, README tree limits; validated on load
├── launch-check.jl              # entry point, checks and badge generation
├── Project.toml                 # TOML and YAML; Test serves the test suite only
├── README.md
└── test/
    └── runtests.jl              # repositories written at test time; checks, badges, options, CLI
```

## Usage

```bash
julia run.jl launch-check [PATH] [--only ID,...] [--waive ID,...] [--verbose] [OPTIONS]
julia run.jl launch-check badges [PATH] [OPTIONS]
julia run.jl launch-check --list
julia run.jl launch-check --help
```

with the options `--repository USER/REPO`, `--branch NAME`, `--project-file FILE`,
`--platform TEXT`, `--platform-logo SLUG` and `--config PATH`. `PATH` is the top level of
a git work tree and defaults to the working directory. The GitHub slug comes from
`--repository`, else from `.launch-check.toml`, else from the URL of the remote `origin`;
the branch from `--branch`, else from `.launch-check.toml`, else from `origin/HEAD`, else
from the current branch, else it is `main`.

```
launch-check: /tmp/Spectra.jl (user/Spectra.jl, branch main)
ok      license
FAIL    workflow-pins
        .github/workflows/CI.yml:21: actions/checkout@v4 is not pinned by a commit SHA
note    dependabot-cooldown
        updates[1] (julia): no cooldown
waived  docs
        documentation follows with the first release
...
19 checks: 16 ok, 1 failed, 1 waived, 1 note
```

`--only` runs the named checks; `--waive` skips them and reports them as waived with the
reason `waived on the command line`. `--verbose` prints the generated badge row after the
summary. `badges` prints the generated row alone, one badge per line, ready to paste under
the README title. `--list` prints the check ids with a short description.

## Checks

Files count only when git tracks them. Workflows are the files
`.github/workflows/*.yml` and `*.yaml`.

| Check | What must hold |
| :--- | :--- |
| `license` | `LICENSE`, `LICENSE.md` or `LICENSE.txt` at the root has a `Copyright` holder line; no holder line holds an e-mail address or the placeholders of a licence template (`[yyyy]`, `<year>`) |
| `citation` | `CITATION.cff` at the root is a YAML mapping with `cff-version`, a non-empty `message` and `title`, and `authors` as a non-empty list of mappings |
| `cite-section` | a README heading on citing, outside code blocks, with a fenced BibTeX entry before the next heading of the same or a higher level |
| `manifest` | no `Manifest.toml`, `JuliaManifest.toml` or versioned manifest is tracked |
| `compat` | every `Project.toml` and `JuliaProject.toml` has a `[compat]` entry for `julia` and for every name of `[deps]`, `[weakdeps]` and `[extras]` (exempt: a name with a `[sources]` path, and a package of this repository, recognised by its UUID); every entry is one the parser of Pkg accepts and has an upper bound, so `>= 1.2` and `≥ 1.2` fail as unbounded, `*` and an empty string as invalid |
| `dependabot` | `.github/dependabot.yml` has an update entry for every ecosystem of `[dependabot].ecosystems`, each with a schedule interval, none with `open-pull-requests-limit: 0` |
| `dependabot-cooldown` | every update entry has a `cooldown`; reported as a note, never a failure |
| `workflow-pins` | a workflow exists; in the workflows and in the composite actions of the repository (`action.yml`), every `uses` value is local, a Docker image pinned by `@sha256:` digest, or pinned by a 40-digit commit SHA with a release comment (`# v4.2.2`) on its line |
| `workflow-permissions` | every workflow declares `permissions` at the top level or in every job; none grants `write-all` |
| `workflow-concurrency` | every workflow has a `concurrency` group with `cancel-in-progress` true or an expression, at the top level or in every job |
| `ci-matrix` | a job matrix lists Julia versions under a key of `version_keys`; every version of a matrix, of its `include` entries and of a literal `with: version:` of `julia-actions/setup-julia` is a name of `required_versions` or `optional_versions`, and one matrix holds all of `required_versions` |
| `format` | `.JuliaFormatter.toml` at the root and a workflow file whose name starts with `format`, in any case |
| `changelog` | `CHANGELOG.md` at the root |
| `readme-tree` | the first code block of `README.md` is a file tree of at most `tree_max_lines` lines, opening by line `tree_within_lines` |
| `badges` | the badge row under the README title equals the generated one, in its image and link URLs and their order |
| `docs` | `docs/make.jl` is tracked and a workflow runs `julia-docdeploy` or `docs/make.jl` |
| `coverage` | workflows use `julia-actions/julia-processcoverage` and `codecov/codecov-action` |
| `self-contained` | `workspace-audit --self-contained` of this toolbox finds no path leading out of the repository |
| `history` | `commit-guard log` of this toolbox finds no attribution trailer, attribution line or session URL in the commit messages |

A version written as a number in the matrix, such as `1.10` unquoted, is loaded by YAML as
the number 1.1 and reported as such; a quoted release number is reported as pinned.

The README is read as Markdown: a fenced code block closes as in CommonMark (same
character, at least the length of the opening fence), and the lines of an HTML comment
that starts a line count neither as headings nor as badges. The limit of twenty lines on
the file tree is `tree_max_lines` of `config.toml`.

The verdict describes the checkout, not a commit. Tracked files are read as they are in
the work tree, so an uncommitted edit counts. Where `origin/HEAD` is not set, the badge
row is generated for the current branch: name the default branch in `.launch-check.toml`.
The stable documentation badge needs the release tags, which a shallow clone without tags
does not have. A failed `self-contained` or `history` check prints the command that
lists its findings.

## Badges

The row follows the order below; a badge appears only when its condition holds.

| Badge | Condition |
| :--- | :--- |
| Docs (stable) | `docs/make.jl` is tracked and a tag `vX.Y.Z` exists |
| CI | a workflow `CI.yml` |
| Further workflows | one per other workflow, by file name, except `Format*` and the housekeeping workflows of `[workflows].housekeeping`; the alternative text is the workflow `name` |
| Coverage | a workflow uses `codecov/codecov-action` |
| Aqua | `Aqua` in `[deps]` or `[extras]` of a project file |
| JET | `JET` in `[deps]` or `[extras]` of a project file |
| Code style | `style = "blue"` or `style = "sciml"` in `.JuliaFormatter.toml` |
| JuliaFormatter | a workflow `Format*.yml` |
| Julia | a project file: `project_file` of `.launch-check.toml` or `--project-file`, else the root `Project.toml`; the badge reads its `compat.julia` from the default branch |
| DOI | one per DOI of `CITATION.cff`: the top-level `doi`, the `identifiers` of type `doi`, `preferred-citation.doi`; a DOI of the Journal of Open Source Software (`10.21105/joss.…`) gets the status badge of the journal instead |
| arXiv | one per `identifiers` entry of type `other` whose value is `arXiv:NNNN.NNNNN` |
| Platform | `platform` given, with `platform_logo` as the Simple Icons slug when set |

Only the Blue and SciML styles have a badge; the default style and the others get none.
A DOI and an arXiv number each get a badge, also when they belong to the same paper.
Parentheses in a DOI are percent-encoded, since they would end the Markdown link.
Every badge needs the GitHub slug, so `badges` and the `badges` check fail while the
repository is unknown.

## Repository options

A tracked `.launch-check.toml` at the root of the audited repository records what git
cannot tell and the checks that do not apply. Every key is optional; unknown keys, values
that are not strings, waivers of unknown checks or without a reason, and a `project_file`
that is not tracked are errors. The command-line options override the file.

```toml
repository = "user/Spectra.jl"      # GitHub slug USER/REPO
branch = "main"                     # default branch
project_file = "Project.toml"       # tracked project file read by the Julia badge
platform = "Linux x86_64"           # platform constraint of the platform badge
platform_logo = "linux"             # Simple Icons slug of the platform badge

[waive]
docs = "documentation follows with the first release"
```

## Return values

The exit status is 0 when no check fails, 1 when one does, and 2 for an invalid argument,
configuration or `.launch-check.toml`, or for a path that is not the top level of a git
work tree. Notes and waived checks never fail. Status 3 means that the tool itself failed
and says nothing about the repository.

## Tests

```bash
julia test.jl launch-check
```
