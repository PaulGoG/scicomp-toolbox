# slurm-launch

Job scripts for Julia pipelines and for wrapped native launch scripts, with the resource
request derived from the run's own configuration so that the two cannot drift. Jobs are
submitted, watched, cancelled and located on a Slurm cluster, or run as detached local
processes on a workstation. The tool opens no SSH connection: on a cluster it runs on the
login node, beside the deployed project.

```
slurm-launch/
├── activate.jl                  # environment activation
├── config.toml                  # defaults, derivation keys, clusters; validated on load
├── Manifest.toml                # standard library only
├── Project.toml
├── README.md
├── slurm-launch.jl              # entry point and functions
└── test/
    ├── references/              # golden job scripts and case list
    └── runtests.jl              # settings, derivation, golden scripts, stub scheduler, local jobs
```

## Usage

Run from the root of the project to launch (`--project` defaults to the working
directory); every path must lie inside the project.

```bash
julia ~/scicomp-toolbox/run.jl slurm-launch --run-config config/run.toml --output-dir data/runs/run_0001
julia ~/scicomp-toolbox/run.jl slurm-launch submit --run-config config/run.toml --output-dir data/runs/run_0001
julia ~/scicomp-toolbox/run.jl slurm-launch submit --backend slurm --cluster lisa \
      --run-config config/run.toml --output-dir data/runs/run_0002
julia ~/scicomp-toolbox/run.jl slurm-launch submit --backend slurm --cluster lisa \
      --cases runs/sweep --run-config config.toml --parallel 4
julia ~/scicomp-toolbox/run.jl slurm-launch submit --payload launcher --backend slurm --cluster lisa \
      --cases runs/sweep_showcase --run-config run.toml --after data/runs/run_0002
julia ~/scicomp-toolbox/run.jl slurm-launch status data/runs/run_0002 runs/sweep
julia ~/scicomp-toolbox/run.jl slurm-launch cancel data/runs/run_0002
julia ~/scicomp-toolbox/run.jl slurm-launch fetch data/runs/run_0002
```

`generate`, the default verb, writes the job script and prints it, so the first thing to
read is the exact text that would be queued. `submit` writes it, queues it with
`sbatch --parsable` (Slurm) or starts it as a detached process group (local), and writes
the submission record. `status`, `cancel` and `fetch` take submission records or the
directories that hold them. `--after JOB` adds `--dependency=afterok:JOB`, where JOB is a
job id or a submission record, so that stages sharing a run id form a chain.

## Payloads

**`julia`**: a pipeline started as

```
julia --project=. --threads=<threads> [--heap-size-hint=<heap>] <script> --config <run config> --output-dir <dir>
```

The project needs a `Project.toml`; `--script` defaults to `scripts/run_pipeline.jl`.

**`launcher`**: an existing launch script, such as the `_launch.sh` that a native code
writes per run, run inside its own directory with `bash`. The script is wrapped, not
rewritten: its `ulimit`, environment and `mpirun` line stay as they are, and the paths it
holds must be valid where the job runs. The job requests the resources its configuration
declares.

With `--cases DIR`, every subdirectory of `DIR` that holds the run configuration is a
case and the job is an array of them: `--array=1-<n>` on Slurm (`%K` with
`--parallel K`), one case after another locally. `--run-config`, and for the launcher
`--script` (default `_launch.sh`), then name files inside each case directory. Each Julia
case keeps its own `--threads` and heap hint, listed in the case file of the job; the
directive block requests the largest value of every quantity over the cases.

## Resource derivation

Nothing about size is invented: every quantity is read from the run configuration
through the dotted keys of `[derivation]`.

| Payload | Quantity (default key) | Request |
| :--- | :--- | :--- |
| julia | `hardware.max_threads` | `--cpus-per-task`, `--threads` |
| julia | `hardware.heap_size_hint_gb` | `--heap-size-hint` |
| julia | `hardware.heap_size_hint_gb`, `safety.max_ram_gb` | `--mem`, the larger value plus `memory_margin` |
| julia | `hardware.gpu_backend` other than `"none"` | `--gres=gpu:1` |
| julia | `safety.max_vram_gb` | the smallest GPU type of the cluster with that much memory |
| launcher | `build.enable_mpi`, `simulation.mpi_ranks` | `--ntasks` |
| launcher | `simulation.omp_threads` | `--cpus-per-task` |
| launcher | `build.enable_gpu` | `--gres=gpu:1` |
| launcher | `safety.max_ram_gb` | `--mem`, plus `memory_margin` |

A quantity the slurm backend needs and the configuration lacks, the thread count, stops
the tool with the name of the key; `max_threads = "auto"` is accepted by the local
backend only. An absent memory key leaves `--mem` to the partition default, an absent
`max_vram_gb` leaves the GPU type open; both are reported as notes.

## Clusters

The site settings cannot be derived and are never guessed: the slurm backend refuses to
run until `config.toml` holds a table for the cluster. The values below only illustrate
the format.

```toml
[clusters.lisa]
partition = "gpu"                       # required
time_limit = "1-00:00:00"               # required, [D-]HH:MM:SS
account = "my-account"
qos = "normal"
julia = "julia"                         # Julia command on the cluster (default [defaults].julia)
setup = ["module load Julia/1.12"]      # shell lines run before the payload
remote_root = "/home/me/projects"       # the project runs in remote_root/<project name>
constraint = ""
mail_type = "END,FAIL"
mail_user = ""
gpu_types = { a40 = 48, a100 = 80 }     # GPU types and their memory [GB]
directives = ["--exclusive"]            # further sbatch options, verbatim
```

Without `remote_root` (or `--remote-project`), the job runs where the project is when the
script is generated.

## Files

| File | Content |
| :--- | :--- |
| `jobs/<name>_<stamp>.sbatch`, `.sh` | job script (Slurm, local) |
| `jobs/<name>_<stamp>.cases` | case list of an array job |
| `jobs/<name>_<stamp>_%j.log`, `_%A_%a.log` | Slurm log |
| `data/logs/<name>_<stamp>.log` | log of a local job |
| `jobs/<name>_<stamp>.exit` | exit status of a local job |
| `<output directory>/submission.toml` | submission record |

The job directory travels with the project, so it must be deployed to the cluster
together with the source tree; Slurm also needs it to exist for the log when the job
starts. Job scripts are never overwritten: a second job of the same name within one
second takes a `_2` suffix.

The submission record sits beside the run so that a queue job can be joined to its run
directory: job id, backend, cluster and partition, the project here and on the target,
script, log, output directory, run configuration and its SHA-256, commit and whether
tracked files were modified, submission time, dependency, number of cases, and the
request. `submit` refuses an output directory that already holds one.

## States

Slurm jobs report the `squeue` state while queued or running and the `sacct` state
afterwards. A local job is `RUNNING` while its process lives, then `COMPLETED` or
`FAILED` from the exit status its script records, or `TERMINATED` after a signal.
`fetch` prints where the output of the job lies and, with `fetch_command` set, the
transfer command for it; it moves no data itself.

## Configuration

`config.toml` holds the defaults (`[defaults]`: backend, cluster, Julia command, job and
log directories, memory margin, fetch template), the keys of every derived quantity
(`[derivation.julia]`, `[derivation.launcher]`) and the clusters. Unknown keys, malformed
time limits, mail types or directives, and paths outside the project are rejected with a
message naming the key.

## Tests

```bash
julia test.jl slurm-launch
SLURM_LAUNCH_UPDATE_REFERENCES=1 julia test.jl slurm-launch   # rewrite the golden scripts
```

The suite builds two projects in `mktempdir()`: a Julia pipeline under git with a sweep
of cases, and a native code whose cases carry a `_launch.sh` with MPI, OpenMP and GPU
switches. It checks the settings and the derivation rules, compares the generated
scripts and case list with `test/references/`, drives `submit`, `status`, `cancel` and
`fetch` against stub `sbatch`, `squeue`, `sacct` and `scancel` executables placed on
`PATH`, and runs real local jobs: a single run, an array, and a cancelled run.

No job has been submitted to a real cluster yet. The first submission has to confirm the
site directive block: partition and account names, the meaning of `--mem` there, and the
GPU type names that `--gres` accepts.
