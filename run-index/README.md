# run-index

Catalogue of the run directories of DrWatson-style projects: what was run, from which
commit and configuration, on what hardware, how long it took and how much disk it
occupies. Runs that need attention are flagged, and figures whose run directory has gone
are listed. The tool only reads; git runs with optional locks disabled.

```
run-index/
├── activate.jl                  # environment activation
├── config.toml                  # discovery rules and provenance keys, validated on load
├── Manifest.toml                # pinned dependencies (PrettyTables)
├── Project.toml
├── README.md
├── run-index.jl                 # entry point and indexing functions
└── test/
    ├── runtests.jl              # settings, parsing, discovery, flags, groups, report, CSV, CLI
    └── synthetic_workspace.jl   # DrWatson-style projects with git history, built at test time
```

## Usage

```bash
julia run.jl run-index                                # runs under the working directory
julia run.jl run-index ~/projects --flagged           # only the runs that carry a flag
julia run.jl run-index ~/projects/Curvature/data --depth 3
julia run.jl run-index ~/projects --csv /tmp/runs.csv
julia run.jl run-index ~/projects --no-csv
```

Roots resolve against the working directory. The report goes to the console and the index,
one row per run, to `run-index/data/run_index_<stamp>.csv` unless `--csv FILE` or
`--no-csv` is given; an existing file is never overwritten (`#1`, `#2`, ... suffixes).

## What counts as a run

A directory whose whole name matches `run_id_pattern` (by default `run_` and eight hex
digits, with an optional `_r<k>` for a rerun), or one that holds a provenance file
(`provenance.toml` or `metadata.toml`, the first present in that order), so
savename-style directories count when they carry provenance. `run.toml` is not among
the defaults because run configurations often carry that name. The search does not descend
into a run, into hidden directories or through symbolic links, and stops `max_depth`
levels below each root. The project of a run is the nearest directory above it with a
`Project.toml`, else the top level of its git repository, else the root searched.

## Provenance files

Provenance files are TOML; nested tables are flattened into key paths. Each field is read
through the list of keys under `[fields]`, matched against the trailing components of a
path, so `commit` finds `commit`, `provenance.commit` and `git.commit`. The first key
of the list with a match wins, and among its matches the shallowest. The defaults cover
flat files, nested `[provenance]` and `[configuration]` tables as `hardware-diagnostics`
writes them, and the keys of DrWatson's `tagsave` (`gitcommit`, `gitpatch`, `script`).
Start and finish are TOML date-times or ISO 8601 strings, the clock time taken as written;
the wall time is a field in seconds or the difference of the two. Metadata stored only
inside JLD2 or BSON result files is not read, and such runs are flagged `no-provenance`.

Inside a run directory, the supplementary files of `supplementary_names` are read as
well; by default that is `submission.toml`, the record `slurm-launch` writes beside a
run when it queues the job. They do not make a directory a run. A field is taken from
the first file that has it, the run's own provenance file first, so the record adds the
`job_id` that joins the run to its queue job in the CSV index.

A recorded commit is resolved with `git rev-parse` in the repository of the project, so
hashes, tags and `git describe` output (DrWatson's `gitcommit`) are all understood. A
`-dirty` or `_dirty` suffix, or a non-empty patch, marks the run dirty.

## Flags

| Flag | Meaning |
| :--- | :--- |
| `no-provenance` | no provenance file; nothing else can be said about the run |
| `unreadable-provenance` | the provenance file is not valid TOML |
| `no-commit` | the provenance file records no commit |
| `no-repository` | a commit is recorded but the run lies in no git repository |
| `unknown-commit` | the repository does not know the recorded commit |
| `off-head` | the commit is neither HEAD nor an ancestor of it, so the checked-out code may not reproduce the run |
| `dirty` | the commit was recorded with uncommitted changes |
| `seed-replicate` | another run of the project has the same configuration apart from the seed |
| `repeat` | another run of the project has the same configuration and seed |

Runs whose configuration tables (`configuration`, `config`, `parameters` or `params`)
agree once the seed keys are removed share a group label `G1`, `G2`, ..., numbered in
the order of the report: `seed-replicate` when their seeds differ, `repeat` when they
share one.

## Example

The synthetic workspace of the tests, generated under `<root>`:

```
14 runs in 2 projects, 10.90 KiB, 12 flagged

Curvature  <root>/Curvature  (git main at 040fe03b; 13 runs, 10.83 KiB, 11 flagged)
 run                           started              wall  commit        host        size  group  flags
-----------------------------------------------------------------------------------------------------------------------
 data/run_f954868c             2026-08-02 09:15  12m 05s  00b893f9      node03     131 B  G1     dirty, repeat
 data/run_f954868c_r2          2026-08-03 10:00  12m 05s  00b893f9      node03     131 B  G1     dirty, repeat
 data/run_51c2a7e0             2026-08-04 12:00   1h 00m  00b893f9      node07     412 B
 data/run_513e903b             2026-08-05 14:02   1h 00m  73d88df7      node07  4.33 KiB  G2     seed-replicate
 data/run_513e903b_r2          2026-08-06 09:00   1h 00m  00b893f9      node07  4.30 KiB  G2     seed-replicate
 data/run_77aa88bb             2026-08-07 11:00   1h 00m  02271aa4      node07     310 B         off-head
 data/run_deadbeef             2026-08-08 08:00   1h 00m  0123456789a…  node07     310 B         unknown-commit
 data/run_9e8d7c6b             2026-08-09 08:00        -  -             -           68 B         no-commit
 data/sims/N=64_seed=1         2026-09-01 08:00   1h 30m  fcf38080      laptop     368 B  G3     dirty, seed-replicate
 data/sims/N=64_seed=2         2026-09-01 08:00   1h 30m  fcf38080      laptop     368 B  G3     dirty, seed-replicate
 data/deep/a/b/c/run_0000ffff  -                       -  040fe03b      -           20 B
 data/run_0a1b2c3d             -                       -  -             -          100 B         no-provenance
 data/run_1234abcd             -                       -  -             -           23 B         unreadable-provenance

Lone  <root>/Lone  (no git repository; 1 run, 80 B, 1 flagged)
 run                started              wall  commit   host  size  group  flags
-----------------------------------------------------------------------------------------
 data/run_aaaa1111  2026-09-02 08:00  20m 00s  abc1234  -     80 B         no-repository

Replicate groups (equal configuration apart from the seed)
  G1  Curvature: data/run_f954868c (seed 7), data/run_f954868c_r2 (seed 7)
  G2  Curvature: data/run_513e903b (seed 1), data/run_513e903b_r2 (seed 2)
  G3  Curvature: data/sims/N=64_seed=1 (seed 1), data/sims/N=64_seed=2 (seed 2)

Figures whose run has no directory
  Curvature: plots/residuals/run_dcf44792_residuals.png (run_dcf44792)
  Curvature: plots/run_dcf44792_spectrum.pdf (run_dcf44792)
```

## Configuration

`config.toml` holds the discovery rules (`[discovery]`), the provenance keys of every
field (`[fields]`) and the directory of the CSV index (`[output]`). Absent keys take the
shipped defaults; unknown keys, invalid regular expressions and out-of-range values are
rejected with a message naming the key.

## Tests

```bash
julia test.jl run-index
```

The suite builds a workspace in `mktempdir()` with `test/synthetic_workspace.jl`: one
DrWatson-style project under git, with a tag, an abandoned branch and runs carrying three
generations of provenance file, reruns, seed replicates and the figures of a deleted run;
and one project outside version control. It checks the settings validation, the parsing
of every provenance generation, the discovery rules, each flag, the replicate groups, the
report, the CSV and the command line, and that the repository is unchanged afterwards.
Nothing of the workspace is committed.
