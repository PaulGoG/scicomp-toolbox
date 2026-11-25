# slurm-launch

Job scripts for Julia pipelines and for wrapped native launch scripts, with the resource
request derived from the run configuration. Jobs are submitted, watched, cancelled and
located on a Slurm cluster, or run as detached local processes on a workstation. The tool opens no SSH connection: on a cluster it runs on the
login node, beside the deployed project.

```
slurm-launch/
├── activate.jl                  # environment activation
├── config.toml                  # defaults, derivation keys, clusters; validated on load
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
julia ~/scicomp-toolbox/run.jl slurm-launch submit --backend slurm --cluster hpc \
      --run-config config/run.toml --output-dir data/runs/run_0002
julia ~/scicomp-toolbox/run.jl slurm-launch submit --backend slurm --cluster hpc \
      --cases runs/sweep --run-config config.toml --parallel 4
julia ~/scicomp-toolbox/run.jl slurm-launch submit --payload launcher --backend slurm --cluster hpc \
      --cases runs/sweep_showcase --run-config run.toml --after data/runs/run_0002
julia ~/scicomp-toolbox/run.jl slurm-launch status data/runs/run_0002 runs/sweep
julia ~/scicomp-toolbox/run.jl slurm-launch cancel data/runs/run_0002
julia ~/scicomp-toolbox/run.jl slurm-launch fetch data/runs/run_0002
```

`generate`, the default verb, writes the job script and prints it. `submit` writes it, queues it with
`sbatch --parsable` (Slurm) or starts it as a detached process group (local), and writes
the submission record. `status`, `cancel` and `fetch` take submission records or the
directories that hold them. `--after JOB` adds `--dependency=afterok:JOB`, where JOB is a
job id or a submission record, so that stages sharing a run id form a chain.

## Payloads

**`julia`**: a pipeline started as

```
julia --threads=<threads> [--heap-size-hint=<heap>] <script> --config <run config> --output-dir <dir>
```

The command carries no `--project`: the script activates its own environment, as in
`include(joinpath(@__DIR__, "..", "activate.jl"))` or `@quickactivate`. A script whose
text names no activation is reported with a note, since the job would run in the default
environment. The project needs a `Project.toml`; `--script` defaults to
`scripts/run_pipeline.jl`.

**`launcher`**: an existing launch script, such as the `_launch.sh` that a native code
writes per run, run inside its own directory with `bash`. The script runs as it
stands: its `ulimit`, environment and `mpirun` line are kept, and the paths it holds must
be valid where the job runs. The job requests the resources its configuration
declares.

With `--cases DIR`, every subdirectory of `DIR` that holds the run configuration is a
case and the job is an array of them: `--array=1-<n>` on Slurm (`%K` with
`--parallel K`), one case after another locally, where every case runs and the job
fails when one of them does. `--run-config`, and for the launcher
`--script` (default `_launch.sh`), then name files inside each case directory. Each Julia
case keeps its own `--threads` and heap hint, listed in the case file of the job; the
directive block requests the largest value of every quantity over the cases and the GPU
type with the most memory among those they need.

## Resource derivation

Every quantity is read from the run configuration through the dotted keys of
`[derivation]`.

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

The launcher payload does not fix the number of nodes. `--mem` and `--gres` are per node
in Slurm, so an MPI job spread over several nodes receives them on each.

## Clusters

The site settings cannot be derived from a run: the slurm backend refuses to run until
`config.toml` holds a table for the cluster. The values below only illustrate the
format.

```toml
[clusters.hpc]
partition = "gpu"                       # required; no white space
time_limit = "1-00:00:00"               # required, [D-]HH:MM:SS
account = "my-account"                  # no white space
qos = "normal"                          # no white space
julia = "julia"                         # Julia command on the cluster (default [defaults].julia)
setup = ["module load Julia/1.12"]      # shell lines run before the payload
remote_root = "/home/me/projects"       # absolute; the project runs in remote_root/<project name>
constraint = ""                         # no white space
mail_type = "END,FAIL"                  # comma-separated sbatch mail types
mail_user = ""                          # no white space
gpu_types = { a40 = 48, a100 = 80 }     # GPU types and their memory [GB], finite and > 0
directives = ["--exclusive"]            # further sbatch options, each starting with -- and free of white space
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
job script, log, output directory, run configuration and its SHA-256 (for an array, the
hash of the hashes of its cases), commit (with the suffix `-dirty` when tracked files
were modified, absent outside git), submission time, dependency, number of cases, and
the request. `submit` refuses an output directory that already holds one. `run-index` reads
the record inside a run directory and lists its `job_id`; an array job has one record, in
the directory of its cases.

## States

Slurm jobs report the `squeue` state while queued or running and the `sacct` state
afterwards; an array reports the state its tasks share, or `MIXED` with the count of
each, which covers the tasks still in the queue while the job runs. A local job is `RUNNING` while the process that runs its script lives, then
`COMPLETED` or `FAILED` from the exit status the script records, or `TERMINATED` after a
signal.
`fetch` prints where the output of the job lies and, with `fetch_command` set, the
transfer command for it; it moves no data itself.

## Configuration

`config.toml` holds the defaults (`[defaults]`: backend, cluster, Julia command, job and
log directories, memory margin, fetch template), the keys of every derived quantity
(`[derivation.julia]`, `[derivation.launcher]`) and the clusters. Unknown keys, malformed
time limits, mail types or directives, and paths outside the project are rejected with a
message naming the key. With the slurm backend the project path on the cluster may hold
no `#`, quote or backslash, which `sbatch` reads by rules of its own in a directive.

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
