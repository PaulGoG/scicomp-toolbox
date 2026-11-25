#!/usr/bin/env julia
# workspace-audit.jl — git and artifact state of every repository under a workspace root,
# with the standard library only. Reports branch, working-tree cleanliness, distance
# from the upstream branch, stashes, untracked weight and regenerable backup artifacts, so
# that unsynced work and deletable leftovers are visible in one command. On request it
# checks the root against the workspace layout below, creates what the layout lacks, and
# scans the tracked files of a repository for paths that lead outside it, listing other
# absolute, home-relative and unresolved relative paths for review.
#
# Workspace layout:
#   <workspace>/
#   ├── context/{code,knowledge}/  # input material, read-only
#   ├── <project>/                 # single git repository at the workspace root
#   ├── notes/                     # 00-index.md, worklog.md, YYYY-MM-DD-topic.md
#   ├── paper/
#   ├── showcase/                  # optional
#   ├── utilities/
#   ├── artefacts/{data,plots,runs}/
#   └── tmp/                       # scratch, empty between tasks
#
# Options: --depth N, --dirty-only, --fetch, --layout, --scaffold, --self-contained.
# --scaffold needs the workspace root as PATH, so that it writes only where pointed.
# Return values: 0, or 1 when a requested check has a finding, when git is missing or
# when the root is not a directory; 2 on invalid arguments and on a root that --layout,
# --scaffold or --self-contained cannot take.
#
# Without --scaffold the tool writes, commits and deletes nothing, and it fetches only
# with --fetch. With --scaffold it creates the missing directories and the two notes
# files of the layout; nothing that exists is modified.

using Dates: Date
using Printf: @printf, @sprintf

const BACKUP_SUFFIXES = (".backup.bundle", ".git.backup")
const LARGEST_UNTRACKED_SHOWN = 3
const LAYOUT_DIRECTORIES = (
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
const LAYOUT_OPTIONAL = ("showcase",)
const LAYOUT_FILES = ("notes/00-index.md", "notes/worklog.md")
const MAX_SCANNED_BYTES = 5 * 1024^2
const SYSTEM_ROOTS =
    ("proc", "sys", "dev", "etc", "usr", "bin", "sbin", "lib", "lib64", "tmp", "var", "run")

# Markdown note filenames referenced as standalone names in notes/00-index.md.
const NOTE_LINK_PATTERN = r"(?<![\w./-])[\w.-]+\.md\b"
# Leading ISO-date prefix identifying dated note references.
const DATED_PREFIX_PATTERN = r"^[0-9]{4}-[0-9]{2}-[0-9]{2}-"
# Dated note filename pattern YYYY-MM-DD-topic.md with captured date fields.
const DATED_NOTE_PATTERN = r"^([0-9]{4})-([0-9]{2})-([0-9]{2})-.+\.md$"
# Relative path containing one or more parent-directory climbs.
const RELATIVE_CLIMB_PATTERN = r"(?<![\w/.~-])(?:\./)*((?:\.\./)+)([\w.@+-][\w./@+-]*)?"
# Julia joinpath from @__DIR__ through quoted parent-directory arguments, across line
# breaks.
const DIR_CLIMB_PATTERN = r"@__DIR__\s*,\s*((?:\"(?:\.\./)*\.\.\"\s*,?\s*)+)"
# Julia @__DIR__ interpolated or concatenated into a string followed by "/.." segments.
const DIR_STRING_CLIMB_PATTERN = r"@__DIR__(?:\)|\s*\*\s*\")((?:/\.\.)+)"
# Quoted lone parent reference in a TOML file, as in path = "..".
const TOML_PARENT_PATTERN = r"[\"']\.\.[\"']"
# Absolute filesystem path starting a line or following a delimiter character.
const ABSOLUTE_PATH_PATTERN = r"(?<![^\s\"'`=(\[{,<>|])/([A-Za-z][\w.-]*)(/[\w.@+-]+)+"
# Path written from the home directory of the user through ~, $HOME or ${HOME}.
const HOME_PATH_PATTERN = r"(?<![\w/.-])(~|\$HOME|\$\{HOME\})/[\w.@+-]+(?:/[\w.@+-]+)*"
# Rank of each ContainmentFinding kind among findings at one position of a line.
const KIND_ORDER =
    (outside = 1, machine_path = 2, absolute_path = 3, home_path = 4, unresolved = 5)

"""
    Leftover

A regenerable backup artifact beside a project: its path, size, modification time and
whether it predates the current `HEAD` of the repository it belongs to.
"""
struct Leftover
    name::String
    path::String
    bytes::Int
    mtime::Float64
    stale::Bool
end

"""
    DirectoryReport

Audit of one immediate subdirectory of the workspace root. `is_repository` is false for a
plain directory, in which case only the leftover and size fields carry meaning.
"""
struct DirectoryReport
    name::String
    path::String
    is_repository::Bool
    branch::String
    commit::String
    tracked_changes::Int
    untracked_count::Int
    untracked_bytes::Int
    largest_untracked::Vector{Tuple{String, Int}}
    upstream::String
    has_remote::Bool
    ahead::Int
    behind::Int
    remote::String
    stashes::Int
    leftovers::Vector{Leftover}
end

"""
    LayoutFinding

One deviation from the expected workspace layout. `kind` is one of `:missing_directory`,
`:missing_file`, `:project`, `:stray`, `:tmp`, `:notes_index` or `:notes_name`; `path` is
relative to the workspace root using `/` separators (empty for `:project`).
"""
struct LayoutFinding
    kind::Symbol
    path::String
    message::String
end

"""
    ContainmentFinding

One reference to a path outside a repository, or to a path to review, in a tracked file.
`kind` is `:outside` or `:machine_path` for violations; `:absolute_path` (outside
`SYSTEM_ROOTS`), `:home_path` and `:unresolved` mark candidates listed for review, which
do not affect the exit status. `line` is 0 for a finding about a symbolic link, whose
`match` is the link target.
"""
struct ContainmentFinding
    file::String
    line::Int
    kind::Symbol
    match::String
end

"""
    git(dir, args...; strip_output = true) -> Tuple{Bool, String}

Run `git -C dir args...` with optional locks disabled, so that `git status` never writes
`index.lock`. Returns whether it succeeded and its standard output, trimmed unless
`strip_output` is false. Standard error is discarded: every call site treats failure as
"the fact is unavailable".
"""
function git(dir::AbstractString, args::AbstractString...; strip_output::Bool = true)
    out = IOBuffer()
    argv = collect(args)
    command = `git --no-optional-locks -C $dir $argv`
    ok = success(pipeline(command; stdout = out, stderr = devnull))
    output = String(take!(out))
    return ok, strip_output ? String(strip(output)) : output
end

"""
    is_repository_root(dir) -> Bool

Whether `dir` is the top level of a work tree; false for a subdirectory of one and outside
any repository.
"""
function is_repository_root(dir::AbstractString)
    ok, top = git(dir, "rev-parse", "--show-toplevel")
    ok || return false
    return realpath(top) == realpath(dir)
end

"""
    parse_status(payload::AbstractString) -> Tuple{Int, Vector{String}}

Number of tracked files with changes and the paths of the untracked ones, from the
NUL-separated output of `git status --porcelain -z -uall`. The NUL form avoids the shell
quoting that `git` otherwise applies to unusual path names. Rename and copy entries carry
a second path field, which is consumed with the entry it belongs to.
"""
function parse_status(payload::AbstractString)
    tracked = 0
    untracked = String[]
    fields = split(payload, '\0'; keepempty = false)
    i = firstindex(fields)
    while i <= lastindex(fields)
        entry = fields[i]
        if length(entry) < 4
            i += 1
            continue
        end
        status_x, status_y = entry[1], entry[2]
        path = entry[4:end]
        if status_x == '?' && status_y == '?'
            push!(untracked, path)
        else
            tracked += 1
            # a rename or copy is reported as "XY <to>\0<from>"
            (status_x in ('R', 'C') || status_y in ('R', 'C')) && (i += 1)
        end
        i += 1
    end
    return tracked, untracked
end

"""
    path_size(path) -> Int

Bytes held by a file, or by a directory and everything under it. Unreadable entries and
symbolic links count as zero, so the figure is a lower bound rather than an error.
"""
function path_size(path::AbstractString)
    islink(path) && return 0
    isfile(path) && return Int(filesize(path))
    isdir(path) || return 0
    total = 0
    for (root, _, files) in walkdir(path; onerror = _ -> nothing)
        for file in files
            full = joinpath(root, file)
            islink(full) && continue
            total += isfile(full) ? Int(filesize(full)) : 0
        end
    end
    return total
end

"""
    format_bytes(bytes) -> String

Binary-prefixed size with two decimals, e.g. `1.44 GiB`.
"""
function format_bytes(bytes::Integer)
    bytes < 1024 && return @sprintf("%d B", bytes)
    value = float(bytes)
    for unit in ("KiB", "MiB", "GiB", "TiB")
        value /= 1024
        value < 1024 && return @sprintf("%.2f %s", value, unit)
    end
    return @sprintf("%.2f PiB", value / 1024)
end

"""
    format_age(seconds) -> String

Elapsed time as days or hours, for the age of an artifact.
"""
function format_age(seconds::Real)
    days = seconds / 86400
    days >= 1 && return @sprintf("%.0f d", days)
    return @sprintf("%.0f h", seconds / 3600)
end

"""
    find_leftovers(dir, head_time) -> Vector{Leftover}

Backup artifacts sitting directly inside `dir`. `head_time` is the commit time of `HEAD`
as a Unix timestamp, or `nothing` when the directory is not a repository; an artifact
older than that commit cannot contain the current work and is reported as stale.
"""
function find_leftovers(dir::AbstractString, head_time::Union{Float64, Nothing})
    leftovers = Leftover[]
    for name in sort(readdir(dir))
        any(suffix -> endswith(name, suffix), BACKUP_SUFFIXES) || continue
        path = joinpath(dir, name)
        modified = mtime(path)
        stale = head_time !== nothing && modified < head_time
        push!(leftovers, Leftover(name, path, path_size(path), modified, stale))
    end
    return leftovers
end

"""
    audit_directory(dir; fetch = false, label = basename(dir)) -> DirectoryReport

Collect the git and artifact state of one directory. With `fetch`, the remote-tracking
refs are refreshed first, which needs the network; without it the comparison uses the refs
already stored, which may be out of date. `label` names the report; the workspace walk
passes the path relative to the root to keep same-named repositories distinct.
"""
function audit_directory(
    dir::AbstractString;
    fetch::Bool = false,
    label::AbstractString = basename(rstrip(dir, '/')),
)
    name = String(label)
    if !is_repository_root(dir)
        return DirectoryReport(
            name,
            dir,
            false,
            "",
            "",
            0,
            0,
            0,
            Tuple{String, Int}[],
            "",
            false,
            0,
            0,
            "",
            0,
            find_leftovers(dir, nothing),
        )
    end

    if fetch
        ok, _ = git(dir, "fetch", "--quiet", "--all")
        ok || println(
            stderr,
            "  warning: fetch failed in $dir; distance from upstream uses the stored ",
            "remote-tracking refs",
        )
    end

    _, branch = git(dir, "rev-parse", "--abbrev-ref", "HEAD")
    _, commit = git(dir, "rev-parse", "--short", "HEAD")

    _, status_payload =
        git(dir, "status", "--porcelain", "-z", "-uall"; strip_output = false)
    tracked_changes, untracked_paths = parse_status(status_payload)

    sized = [(path, path_size(joinpath(dir, path))) for path in untracked_paths]
    sort!(sized; by = last, rev = true)
    untracked_bytes = isempty(sized) ? 0 : sum(last, sized)
    largest = sized[1:min(LARGEST_UNTRACKED_SHOWN, length(sized))]

    has_upstream, upstream =
        git(dir, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
    ahead = 0
    behind = 0
    if has_upstream
        ok, counts = git(dir, "rev-list", "--left-right", "--count", "@{upstream}...HEAD")
        if ok
            parts = split(counts)
            if length(parts) == 2
                behind = something(tryparse(Int, parts[1]), 0)
                ahead = something(tryparse(Int, parts[2]), 0)
            end
        end
    end

    _, remote = git(dir, "remote", "get-url", "origin")
    _, remote_names = git(dir, "remote")
    has_remote = !isempty(remote_names)
    _, stash_payload = git(dir, "stash", "list")
    stashes = isempty(stash_payload) ? 0 : count(==('\n'), stash_payload) + 1

    ok_time, head_time_text = git(dir, "log", "-1", "--format=%ct")
    head_time = ok_time ? tryparse(Float64, head_time_text) : nothing

    return DirectoryReport(
        name,
        dir,
        true,
        branch,
        commit,
        tracked_changes,
        length(untracked_paths),
        untracked_bytes,
        largest,
        has_upstream ? upstream : "",
        has_remote,
        ahead,
        behind,
        remote,
        stashes,
        find_leftovers(dir, head_time),
    )
end

"""
    needs_attention(report) -> Bool

Whether the directory holds uncommitted or untracked work, commits out of step with the
upstream, stashes, a removable artifact, or a remote with no upstream configured. A clean
repository in step with its upstream, or with no remote at all, needs none.
"""
function needs_attention(report::DirectoryReport)
    isempty(report.leftovers) || return true
    report.is_repository || return false
    report.tracked_changes > 0 && return true
    report.untracked_count > 0 && return true
    report.ahead > 0 && return true
    report.behind > 0 && return true
    report.stashes > 0 && return true
    report.has_remote && isempty(report.upstream) && return true
    return false
end

"""
    subdirectories(dir) -> Vector{String}

Visible subdirectories of `dir` in name order, excluding symbolic links, which would
otherwise let the walk leave the workspace or revisit it.
"""
function subdirectories(dir::AbstractString)
    paths = String[]
    for name in sort(readdir(dir))
        startswith(name, ".") && continue
        path = joinpath(dir, name)
        isdir(path) && !islink(path) || continue
        push!(paths, path)
    end
    return paths
end

"""
    walk_area!(reports, root, dir, level, depth; fetch = false) -> Nothing

Append to `reports` the repositories and backup-artifact holders at or below `dir`. The
walk does not descend into repositories and stops `depth` levels below the root.
"""
function walk_area!(
    reports::Vector{DirectoryReport},
    root::AbstractString,
    dir::AbstractString,
    level::Integer,
    depth::Integer;
    fetch::Bool = false,
)
    label = relpath(dir, root)
    if is_repository_root(dir)
        push!(reports, audit_directory(dir; fetch, label))
        return nothing
    end
    leftovers = find_leftovers(dir, nothing)
    isempty(leftovers) || push!(reports, audit_directory(dir; fetch, label))
    if level < depth
        for path in subdirectories(dir)
            walk_area!(reports, root, path, level + 1, depth; fetch)
        end
    end
    return nothing
end

"""
    audit_workspace(root; fetch = false, depth = 2) -> Vector{DirectoryReport}

Audit the projects under `root`. Each immediate subdirectory is an area, searched `depth`
levels deep for repositories and backup artifacts; the default of two suits a workspace
whose areas each hold their repository one level down. An area with nothing of interest
beneath it yields one non-repository report. A root that is itself a repository yields
the report of that repository alone.
"""
function audit_workspace(root::AbstractString; fetch::Bool = false, depth::Integer = 2)
    isdir(root) || throw(ArgumentError("not a directory: $root"))
    depth >= 1 || throw(ArgumentError("depth must be at least 1, got $depth"))
    is_repository_root(root) && return DirectoryReport[audit_directory(root; fetch)]
    reports = DirectoryReport[]
    for area in subdirectories(root)
        before = length(reports)
        walk_area!(reports, root, area, 1, depth; fetch)
        length(reports) == before &&
            push!(reports, audit_directory(area; fetch, label = relpath(area, root)))
    end
    return reports
end

"""
    unversioned_areas(reports, root) -> Vector{String}

Names of the top-level areas under which the walk found no repository. A `notes` directory
is expected here; a directory of code is not.
"""
function unversioned_areas(reports::Vector{DirectoryReport}, root::AbstractString)
    areas = String[]
    versioned = Set{String}()
    for report in reports
        report.is_repository || continue
        push!(versioned, first(splitpath(report.name)))
    end
    for report in reports
        area = first(splitpath(report.name))
        (area in versioned || area in areas) && continue
        push!(areas, area)
    end
    return areas
end

"""
    layout_path(root, rel) -> String

Resolve a `/`-separated relative layout path `rel` under `root`.
"""
layout_path(root::AbstractString, rel::AbstractString) = joinpath(root, split(rel, '/')...)

"""
    top_layout_names() -> Set{String}

Top-level directory names reserved by `LAYOUT_DIRECTORIES` and `LAYOUT_OPTIONAL`.
"""
function top_layout_names()
    return Set{String}(
        first(split(entry, '/')) for entry in (LAYOUT_DIRECTORIES..., LAYOUT_OPTIONAL...)
    )
end

"""
    is_valid_dated_note(name) -> Bool

Whether `name` matches `YYYY-MM-DD-topic.md` with a valid calendar date.
"""
function is_valid_dated_note(name::AbstractString)
    m = match(DATED_NOTE_PATTERN, name)
    m === nothing && return false
    year = parse(Int, m.captures[1])
    month = parse(Int, m.captures[2])
    day = parse(Int, m.captures[3])
    try
        Date(year, month, day)
        return true
    catch err
        err isa ArgumentError || rethrow()
        return false
    end
end

"""
    layout_file_content(rel) -> String

Initial template text for a file in `LAYOUT_FILES`.
"""
function layout_file_content(rel::AbstractString)
    if rel == "notes/00-index.md"
        return "# Notes index\n\n" *
               "- `worklog.md` — running state: where things stand, how to resume.\n"
    end
    rel == "notes/worklog.md" && return "# Worklog\n"
    throw(ArgumentError("unknown layout file: $rel"))
end

"""
    check_layout(root) -> Vector{LayoutFinding}

Check `root` against the workspace layout and return findings in rule order. Throws
`ArgumentError` if `root` is not a directory or is itself a git repository root.
"""
function check_layout(root::AbstractString)
    isdir(root) || throw(ArgumentError("not a directory: $root"))
    is_repository_root(root) &&
        throw(ArgumentError("workspace root is a git repository: $root"))

    findings = LayoutFinding[]
    for entry in LAYOUT_DIRECTORIES
        isdir(layout_path(root, entry)) ||
            push!(findings, LayoutFinding(:missing_directory, entry, "directory missing"))
    end
    for entry in LAYOUT_FILES
        isfile(layout_path(root, entry)) ||
            push!(findings, LayoutFinding(:missing_file, entry, "file missing"))
    end

    reserved = top_layout_names()
    projects = String[]
    for dir in subdirectories(root)
        name = basename(dir)
        !(name in reserved) && is_repository_root(dir) && push!(projects, name)
    end
    sort!(projects)
    if isempty(projects)
        push!(
            findings,
            LayoutFinding(:project, "", "no project repository at the workspace root"),
        )
    elseif length(projects) >= 2
        names = join(projects, ", ")
        push!(
            findings,
            LayoutFinding(
                :project,
                "",
                "$(length(projects)) repositories at the workspace root: $names",
            ),
        )
    end

    project_set = Set{String}(projects)
    for name in sort(readdir(root))
        startswith(name, '.') && continue
        (name in reserved || name in project_set) && continue
        push!(findings, LayoutFinding(:stray, name, "not part of the workspace layout"))
    end

    tmp_dir = joinpath(root, "tmp")
    if isdir(tmp_dir)
        entries = readdir(tmp_dir)
        if !isempty(entries)
            n = length(entries)
            noun = n == 1 ? "entry" : "entries"
            push!(findings, LayoutFinding(:tmp, "tmp", "$n $noun left in tmp/"))
        end
    end

    notes_dir = joinpath(root, "notes")
    index_path = joinpath(notes_dir, "00-index.md")
    if isfile(index_path)
        text = read(index_path, String)
        listed = Set{String}()
        for m in eachmatch(NOTE_LINK_PATTERN, text)
            m.match == "00-index.md" || push!(listed, String(m.match))
        end
        present = Set{String}()
        for name in readdir(notes_dir)
            name == "00-index.md" && continue
            endswith(name, ".md") || continue
            path = joinpath(notes_dir, name)
            isfile(path) && !islink(path) && push!(present, name)
        end
        for name in sort!(collect(setdiff(present, listed)))
            push!(
                findings,
                LayoutFinding(
                    :notes_index,
                    "notes/$name",
                    "not listed in notes/00-index.md",
                ),
            )
        end
        for name in sort!(collect(setdiff(listed, present)))
            occursin(DATED_PREFIX_PATTERN, name) || continue
            push!(
                findings,
                LayoutFinding(
                    :notes_index,
                    "notes/$name",
                    "listed in notes/00-index.md but absent",
                ),
            )
        end
    end

    if isdir(notes_dir)
        for name in sort(readdir(notes_dir))
            (name == "00-index.md" || name == "worklog.md") && continue
            endswith(name, ".md") || continue
            path = joinpath(notes_dir, name)
            isfile(path) && !islink(path) || continue
            is_valid_dated_note(name) || push!(
                findings,
                LayoutFinding(
                    :notes_name,
                    "notes/$name",
                    "name is not YYYY-MM-DD-topic.md",
                ),
            )
        end
    end

    return findings
end

"""
    scaffold_layout(root) -> Vector{String}

Create missing `LAYOUT_DIRECTORIES` and `LAYOUT_FILES` under `root` without modifying
existing entries, returning the relative paths created in order. Throws `ArgumentError` if
`root` is not a directory, is a git repository root, or holds an entry of
`LAYOUT_DIRECTORIES` that is not a directory (a plain file, or a symbolic link that does
not lead to one); every entry is examined first, so that nothing is created in that case.
"""
function scaffold_layout(root::AbstractString)
    isdir(root) || throw(ArgumentError("not a directory: $root"))
    is_repository_root(root) &&
        throw(ArgumentError("workspace root is a git repository: $root"))

    for entry in LAYOUT_DIRECTORIES
        target = layout_path(root, entry)
        (ispath(target) || islink(target)) &&
            !isdir(target) &&
            throw(
                ArgumentError("cannot create directory $entry: $target is not a directory"),
            )
    end

    created = String[]
    for entry in LAYOUT_DIRECTORIES
        target = layout_path(root, entry)
        isdir(target) && continue
        mkpath(target)
        push!(created, entry)
    end

    for entry in LAYOUT_FILES
        target = layout_path(root, entry)
        (ispath(target) || islink(target)) && continue
        write(target, layout_file_content(entry))
        push!(created, entry)
    end

    return created
end

"""
    is_machine_path_word_char(c) -> Bool

Whether `c` continues a token as `[\\w.-]` does under Unicode classes: a letter, a
numeric character, `_`, `.` or `-`.
"""
function is_machine_path_word_char(c::Char)
    return isletter(c) || isnumeric(c) || c in ('_', '.', '-')
end

"""
    is_machine_path_stop(c) -> Bool

Whether `c` terminates a `:machine_path` match token.
"""
function is_machine_path_stop(c::Char)
    return isspace(c) || c in ('"', '\'', '`', ')', '>', ']', '}', ',', ';')
end

"""
    link_leaves_repository(rel, target) -> Bool

Whether a symbolic link tracked at `rel` (relative to the repository root, `/`
separators) with link text `target` leads outside the repository: an absolute target, or
a relative one that resolves above the root.
"""
function link_leaves_repository(rel::AbstractString, target::AbstractString)
    isabspath(target) && return true
    resolved = normpath(joinpath(dirname(rel), target))
    return resolved == ".." || startswith(resolved, "../")
end

"""
    tracked_paths(files) -> Set{String}

Paths of the tracked `files` (relative to the repository root, `/` separators) and of
every directory that holds one, with `"."` for the root.
"""
function tracked_paths(files::Vector{String})
    paths = Set{String}(["."])
    for file in files
        push!(paths, file)
        parts = split(file, '/')
        for k in 1:(length(parts) - 1)
            push!(paths, join(parts[1:k], '/'))
        end
    end
    return paths
end

"""
    climb_target_kind(rel, path, tracked, reserved) -> Union{Symbol, Nothing}

Judge the relative `path`, which begins with `../`, found in the file `rel`. Trailing `.`
of its last component, such as a full stop, are dropped. Resolved from the directory of
`rel` it is `:outside` when it leads above the repository root. Inside the repository it
is no finding when it names a tracked path or a path in a tracked directory, the case of a
file that a script writes beside tracked ones. Otherwise it is read from the repository
root, as a run configuration or a working directory reads it: `:outside` when its first
component below the climbs is a top-level workspace name in `reserved`, `:unresolved`
when not. Existence is judged against `tracked`, never the checkout, so the result does
not depend on untracked or ignored files.
"""
function climb_target_kind(
    rel::AbstractString,
    path::AbstractString,
    tracked::Set{String},
    reserved::Set{String},
)
    parts = split(rstrip(path, '/'), '/')
    last(parts) in (".", "..") || (parts[end] = rstrip(parts[end], '.'))
    clean = join(filter(!isempty, parts), '/')
    directory = dirname(rel)
    from_file = normpath(isempty(directory) ? clean : directory * "/" * clean)
    from_file = rstrip(from_file, '/')
    isempty(from_file) && (from_file = ".")
    (from_file == ".." || startswith(from_file, "../")) && return :outside
    from_file in tracked && return nothing
    parent = dirname(from_file)
    !isempty(parent) && parent in tracked && return nothing
    below = filter(part -> part != "..", split(normpath(clean), '/'))
    isempty(below) && return :unresolved
    return first(below) in reserved ? :outside : :unresolved
end

"""
    within_any(ranges, first_unit, last_unit) -> Bool

Whether the code-unit range `first_unit:last_unit` lies inside one of `ranges`.
"""
function within_any(ranges::Vector{UnitRange{Int}}, first_unit::Integer, last_unit::Integer)
    return any(r -> first(r) <= first_unit && last_unit <= last(r), ranges)
end

"""
    dir_climb_hits(rel, text, depth) -> (hits, ranges)

Climbs `joinpath(@__DIR__, "..", ...)` with more `..` than `depth` in the whole `text` of
the file `rel`, so that a call wrapped over several lines is seen; text that is not valid
UTF-8 elsewhere in the file does not hide them. Each hit is `(line, position, rank,
finding)`, line and position being those of `@__DIR__`; the `match` of the finding has
every run of whitespace collapsed to one space. `ranges` are the code units of every
match, hit or not, in which the per-line forms are not reported again.
"""
function dir_climb_hits(rel::AbstractString, text::String, depth::Integer)
    hits = Tuple{Int, Int, Int, ContainmentFinding}[]
    ranges = UnitRange{Int}[]
    units = codeunits(text)
    newline = UInt8('\n')
    for m in eachmatch(DIR_CLIMB_PATTERN, text)
        push!(ranges, m.offset:(m.offset + ncodeunits(m.match) - 1))
        count("..", m.captures[1]) > depth || continue
        lineno = 1 + count(==(newline), @view units[1:(m.offset - 1)])
        line_start = something(findprev(==(newline), units, m.offset - 1), 0)
        matched = String(strip(replace(m.match, r"\s+" => " ")))
        finding = ContainmentFinding(rel, lineno, :outside, matched)
        push!(hits, (lineno, m.offset - line_start, KIND_ORDER.outside, finding))
    end
    return hits, ranges
end

"""
    scan_self_containment(repo; home = homedir()) -> Vector{ContainmentFinding}

Scan the files tracked in `repo`; findings are sorted by file, line, position in the line
and the rank of `KIND_ORDER`. A text file (a plain file up to `MAX_SCANNED_BYTES` with no
NUL in the first 8000 bytes) is searched line by line, lines that are not valid UTF-8
skipped, for

  - a relative path climbing with `../`, judged by `climb_target_kind` on the whole
    path, inner `..` and `.` steps included;
  - a quoted lone `..` in a `.toml` file at the repository root: `:outside`;
  - `joinpath(@__DIR__, "..", ...)`, matched on the whole text, and `@__DIR__` joined as
    a string with `/..`: `:outside` when they climb above the root;
  - a path under `home`, when it has at least two components: `:machine_path`;
  - an absolute path outside `SYSTEM_ROOTS`: `:absolute_path`; a path written from `~`,
    `\$HOME` or `\${HOME}`: `:home_path`.

A candidate inside a `:machine_path` match of the same line is not reported. A tracked
symbolic link is not read: its target is `:outside`, with `line` 0, when absolute or when
it resolves above the root. Throws `ArgumentError` unless `repo` is a git repository root,
and when `git ls-files` fails.
"""
function scan_self_containment(repo::AbstractString; home::AbstractString = homedir())
    is_repository_root(repo) || throw(ArgumentError("not a git repository root: $repo"))

    ok, payload = git(repo, "ls-files", "-z"; strip_output = false)
    ok || throw(ArgumentError("git ls-files failed in $repo"))

    clean_home = isempty(rstrip(home, '/')) ? "" : String(rstrip(home, '/'))
    check_home = count(!isempty, split(clean_home, '/')) >= 2
    reserved = top_layout_names()

    findings = ContainmentFinding[]
    files = sort!(String.(split(payload, '\0'; keepempty = false)))
    tracked = tracked_paths(files)
    for rel in files
        full = layout_path(repo, rel)
        if islink(full)
            target = readlink(full)
            link_leaves_repository(rel, target) &&
                push!(findings, ContainmentFinding(rel, 0, :outside, target))
            continue
        end
        isfile(full) || continue
        filesize(full) <= MAX_SCANNED_BYTES || continue
        bytes = read(full)
        length(bytes) <= MAX_SCANNED_BYTES || continue
        limit = min(length(bytes), 8000)
        any(==(0x00), @view bytes[1:limit]) && continue
        # String takes over the buffer of `bytes`, which is not used afterwards
        text = String(bytes)

        depth = count(==('/'), rel)
        # a quoted lone ".." climbs one level, so only out of a file at the root
        toml_climb = endswith(rel, ".toml") && depth < 1
        hits, dir_ranges = dir_climb_hits(rel, text, depth)
        # code unit at which each line starts, to place per-line matches in `dir_ranges`
        line_starts = [1; findall(==(UInt8('\n')), codeunits(text)) .+ 1]
        for (lineno, line) in enumerate(eachline(IOBuffer(text)))
            isvalid(line) || continue
            machine_ranges = UnitRange{Int}[]

            if check_home
                idx = firstindex(line)
                while idx <= lastindex(line)
                    r = findnext(clean_home, line, idx)
                    r === nothing && break
                    after = nextind(line, last(r))
                    valid_end = if after > lastindex(line)
                        true
                    else
                        c = line[after]
                        c == '/' || !is_machine_path_word_char(c)
                    end
                    if valid_end
                        stop = after
                        while stop <= lastindex(line) && !is_machine_path_stop(line[stop])
                            stop = nextind(line, stop)
                        end
                        end_idx = prevind(line, stop)
                        # ends at the last code unit of the last character
                        push!(machine_ranges, first(r):(stop - 1))
                        finding = ContainmentFinding(
                            rel,
                            lineno,
                            :machine_path,
                            String(line[first(r):end_idx]),
                        )
                        push!(hits, (lineno, first(r), KIND_ORDER.machine_path, finding))
                        idx = stop
                    else
                        idx = nextind(line, first(r))
                    end
                end
            end

            for m in eachmatch(RELATIVE_CLIMB_PATTERN, line)
                last_unit = m.offset + ncodeunits(m.match) - 1
                # inside a joinpath from @__DIR__, which that form has judged
                start = line_starts[lineno] - 1
                within_any(dir_ranges, start + m.offset, start + last_unit) && continue
                kind = climb_target_kind(rel, m.match, tracked, reserved)
                kind === nothing && continue
                kind === :unresolved &&
                    within_any(machine_ranges, m.offset, last_unit) &&
                    continue
                finding = ContainmentFinding(rel, lineno, kind, String(m.match))
                push!(hits, (lineno, m.offset, KIND_ORDER[kind], finding))
            end

            for m in eachmatch(DIR_STRING_CLIMB_PATTERN, line)
                count("/..", m.captures[1]) > depth || continue
                finding = ContainmentFinding(rel, lineno, :outside, String(m.match))
                push!(hits, (lineno, m.offset, KIND_ORDER.outside, finding))
            end

            if toml_climb
                for m in eachmatch(TOML_PARENT_PATTERN, line)
                    finding = ContainmentFinding(rel, lineno, :outside, "..")
                    push!(hits, (lineno, m.offset + 1, KIND_ORDER.outside, finding))
                end
            end

            for m in eachmatch(ABSOLUTE_PATH_PATTERN, line)
                m.captures[1] in SYSTEM_ROOTS && continue
                last_unit = m.offset + ncodeunits(m.match) - 1
                within_any(machine_ranges, m.offset, last_unit) && continue
                finding = ContainmentFinding(rel, lineno, :absolute_path, String(m.match))
                push!(hits, (lineno, m.offset, KIND_ORDER.absolute_path, finding))
            end

            for m in eachmatch(HOME_PATH_PATTERN, line)
                last_unit = m.offset + ncodeunits(m.match) - 1
                within_any(machine_ranges, m.offset, last_unit) && continue
                finding = ContainmentFinding(rel, lineno, :home_path, String(m.match))
                push!(hits, (lineno, m.offset, KIND_ORDER.home_path, finding))
            end
        end

        sort!(hits; by = h -> (h[1], h[2], h[3]))
        for hit in hits
            push!(findings, hit[4])
        end
    end

    return findings
end

function print_report(report::DirectoryReport)
    if !report.is_repository
        println("\n", report.name)
        println("  State                : not a git repository")
    else
        flags = String[]
        report.tracked_changes > 0 && push!(flags, "dirty")
        report.untracked_count > 0 && push!(flags, "untracked")
        report.stashes > 0 && push!(flags, "stash")
        report.ahead > 0 && push!(flags, "unpushed")
        report.behind > 0 && push!(flags, "behind")
        report.has_remote && isempty(report.upstream) && push!(flags, "no upstream")
        println("\n", report.name, isempty(flags) ? "" : "  [" * join(flags, ", ") * "]")
        println("  Branch               : ", report.branch, " @ ", report.commit)
        println(
            "  Working tree         : ",
            report.tracked_changes == 0 ? "clean" :
            "$(report.tracked_changes) tracked file(s) changed",
        )
        if isempty(report.upstream)
            println("  Upstream             : none configured")
        else
            println(
                "  Upstream             : ",
                report.upstream,
                " (",
                report.ahead,
                " ahead, ",
                report.behind,
                " behind)",
            )
        end
        isempty(report.remote) || println("  Remote               : ", report.remote)
        report.stashes > 0 && println("  Stashes              : ", report.stashes)
        if report.untracked_count > 0
            println(
                "  Untracked            : ",
                report.untracked_count,
                " file(s), ",
                format_bytes(report.untracked_bytes),
            )
            for (path, bytes) in report.largest_untracked
                @printf("      %-52s %10s\n", first(path, 52), format_bytes(bytes))
            end
        end
    end
    isempty(report.leftovers) && return nothing
    println("  Backup artifacts     :")
    now_time = time()
    for leftover in report.leftovers
        @printf(
            "      %-40s %10s  %6s old%s\n",
            first(leftover.name, 40),
            format_bytes(leftover.bytes),
            format_age(now_time - leftover.mtime),
            leftover.stale ? "  [stale: predates HEAD]" : ""
        )
    end
    return nothing
end

function print_summary(reports::Vector{DirectoryReport}, root::AbstractString)
    repositories = count(r -> r.is_repository, reports)
    attention = count(needs_attention, reports)
    leftovers = reduce(vcat, (r.leftovers for r in reports); init = Leftover[])
    stale = filter(l -> l.stale, leftovers)
    unversioned = unversioned_areas(reports, root)

    println("\nSummary")
    println("  Repositories         : ", repositories)
    println("  Needing attention    : ", attention)
    if !isempty(unversioned)
        println(
            "  Areas with no repo   : ",
            length(unversioned),
            " — ",
            join(unversioned, ", "),
        )
    end
    unpushed = filter(r -> r.is_repository && r.ahead > 0, reports)
    if !isempty(unpushed)
        println(
            "  Unpushed commits     : ",
            join(("$(r.name) (+$(r.ahead))" for r in unpushed), ", "),
        )
    end
    if !isempty(leftovers)
        println(
            "  Backup artifacts     : ",
            length(leftovers),
            " holding ",
            format_bytes(sum(l -> l.bytes, leftovers)),
            ", ",
            length(stale),
            " stale",
        )
    end
    if !isempty(stale)
        println(
            "\nStale backup artifacts predate the HEAD they were taken from. To remove:",
        )
        for leftover in stale
            println("  rm -rf -- ", Base.shell_escape_posixly(leftover.path))
        end
    end
    println()
    return nothing
end

"""
    print_scaffold(created) -> Nothing

Print the `Scaffold` section listing the paths created by `scaffold_layout`.
"""
function print_scaffold(created::Vector{String})
    println("Scaffold")
    if isempty(created)
        println("  nothing to create")
    else
        for path in created
            println("  ", path)
        end
    end
    println()
    return nothing
end

"""
    print_layout(findings) -> Nothing

Print the `Layout` section summarizing deviations returned by `check_layout`.
"""
function print_layout(findings::Vector{LayoutFinding})
    println("Layout")
    if isempty(findings)
        println("  conforms to the workspace layout")
    else
        for finding in findings
            label = isempty(finding.path) ? "-" : finding.path
            @printf("  %-28s: %s\n", label, finding.message)
        end
    end
    println()
    return nothing
end

"""
    print_self_containment(results) -> Nothing

Print the `Self-containment` section, per repository grouped into violations outside the
repository (`:outside`, `:machine_path`), absolute paths to review (`:absolute_path`,
`:home_path`) and relative paths to review (`:unresolved`); an empty group is omitted. A
finding about a symbolic link (`line == 0`) prints as `<file>  -> <target>`.
"""
function print_self_containment(results::Vector{Pair{String, Vector{ContainmentFinding}}})
    println("Self-containment")
    if isempty(results)
        println("  no repositories found")
        println()
        return nothing
    end
    for (name, findings) in results
        println("\n", name)
        outside = filter(f -> f.kind === :outside || f.kind === :machine_path, findings)
        absolute = filter(f -> f.kind === :absolute_path || f.kind === :home_path, findings)
        unresolved = filter(f -> f.kind === :unresolved, findings)
        if isempty(outside) && isempty(absolute) && isempty(unresolved)
            println("  no reference outside the repository")
            continue
        end
        groups = (
            "Outside the repository" => outside,
            "Absolute paths to review" => absolute,
            "Relative paths to review" => unresolved,
        )
        for (title, group) in groups
            isempty(group) && continue
            println("  ", title)
            for f in group
                if f.line == 0
                    println("    ", f.file, "  -> ", f.match)
                else
                    println("    ", f.file, ":", f.line, "  ", f.match)
                end
            end
        end
    end
    println()
    return nothing
end

function print_help()
    println(
        """
workspace-audit — git, artifact, layout and self-containment audit of a workspace

Usage:
  julia run.jl workspace-audit [PATH] [options]

  PATH              workspace root to audit (default: the parent of this repository)
  --depth N         levels below the root to search for repositories (default: 2)
  --dirty-only      report only directories with uncommitted, unpushed or removable state
  --fetch           refresh remote-tracking refs first; needs the network and is slower
  --layout          check the root against the workspace layout below
  --scaffold        create the directories and notes files the layout lacks, then check
                    it; needs PATH
  --self-contained  scan the tracked text files of the root repository, or of the
                    repositories directly under the root, for paths that lead outside
  -h, --help

Each immediate subdirectory of the root is an area, searched --depth levels deep. The
default of two suits a workspace whose areas each hold their repository one level down;
--depth 1 treats the areas themselves as the repositories. The walk never descends into a
repository, and an area with no repository under it is reported as such.

Workspace layout (checked by --layout, completed by --scaffold):
  <workspace>/
  ├── context/            # input material, read-only
  │   ├── code/
  │   └── knowledge/
  ├── <project>/          # the git repository
  ├── notes/              # 00-index.md, worklog.md, dated notes YYYY-MM-DD-topic.md
  ├── paper/
  ├── showcase/           # optional
  ├── utilities/
  ├── artefacts/
  │   ├── data/
  │   ├── plots/
  │   └── runs/
  └── tmp/                # scratch, empty between tasks

Without --fetch the distance from the upstream branch is measured against the
remote-tracking refs already stored, which may be out of date.

--self-contained reports up to three groups per repository. Outside the repository holds
the findings: a relative path, a joinpath(@__DIR__, ...) or @__DIR__ string climb, a
quoted ".." in a root TOML file or a tracked symbolic link that leads out of the
repository, a relative path that reaches a workspace directory such as notes/ when read
from the root, and any path under the home directory of the user. Absolute paths to
review lists the other absolute paths outside the system directories and the paths
written from ~ or \$HOME, such as an example path in documentation. Relative paths to
review lists a relative path that stays within the repository but names nothing in it.
Only the first group changes the return value. The scan does not see a path assembled at
run time, a dirname chain, a path in a line that is not valid UTF-8, or a file larger
than 5 MiB.

Without --scaffold the tool writes, commits and deletes nothing, and it fetches only with
--fetch. --scaffold creates the missing directories and the two notes files of the
layout; nothing that exists is modified.

Return values:
  0  no finding of a requested check
  1  --layout, --scaffold or --self-contained has a finding; git is missing; PATH is not
     a directory
  2  usage error, --scaffold without PATH included; a root that the requested check
     cannot take (--layout on a repository, --self-contained with no repository at or
     directly under it)
""",
    )
    return nothing
end

"""
    parse_args(args) -> NamedTuple

Positional workspace root and command-line flags. Throws `ArgumentError` on an unknown
option, a second positional argument, or `--scaffold` without a root: the scaffold writes
only where the caller points.
"""
function parse_args(args::Vector{String})
    root = nothing
    dirty_only = false
    fetch = false
    layout = false
    scaffold = false
    self_contained = false
    help = false
    depth = 2
    expecting_depth = false
    for arg in args
        if expecting_depth
            parsed = tryparse(Int, arg)
            (parsed === nothing || parsed < 1) &&
                throw(ArgumentError("--depth takes a positive integer, got $arg"))
            depth = parsed
            expecting_depth = false
        elseif arg in ("-h", "--help")
            help = true
        elseif arg == "--dirty-only"
            dirty_only = true
        elseif arg == "--fetch"
            fetch = true
        elseif arg == "--layout"
            layout = true
        elseif arg == "--scaffold"
            scaffold = true
            layout = true
        elseif arg == "--self-contained"
            self_contained = true
        elseif arg == "--depth"
            expecting_depth = true
        elseif startswith(arg, "--depth=")
            parsed = tryparse(Int, last(split(arg, '=', limit = 2)))
            (parsed === nothing || parsed < 1) &&
                throw(ArgumentError("--depth takes a positive integer, got $arg"))
            depth = parsed
        elseif startswith(arg, "-")
            throw(ArgumentError("unknown option: $arg"))
        elseif root === nothing
            root = arg
        else
            throw(ArgumentError("unexpected second path argument: $arg"))
        end
    end
    expecting_depth && throw(ArgumentError("--depth takes a positive integer"))
    scaffold &&
        root === nothing &&
        throw(ArgumentError("--scaffold needs the workspace root as PATH"))
    return (; root, dirty_only, fetch, depth, layout, scaffold, self_contained, help)
end

"""
    default_root() -> String

Parent of the repository holding this script (the workspace of the toolbox), resolved
from the script location.
"""
default_root() = dirname(dirname(@__DIR__))

function main(args::Vector{String} = ARGS)
    options = try
        parse_args(args)
    catch err
        err isa ArgumentError || rethrow()
        println(stderr, "workspace-audit: ", err.msg)
        return 2
    end
    if options.help
        print_help()
        return 0
    end
    if Sys.which("git") === nothing
        println(stderr, "workspace-audit: git is not on PATH")
        return 1
    end

    root = abspath(something(options.root, default_root()))
    if !isdir(root)
        println(stderr, "workspace-audit: not a directory: $root")
        return 1
    end

    println("Workspace audit")
    println("  Root                 : ", root)
    println("  Search depth         : ", options.depth, " level(s) below the root")
    println(
        "  Upstream comparison  : ",
        options.fetch ? "refreshed (--fetch)" : "stored refs (pass --fetch to refresh)",
    )

    reports = audit_workspace(root; fetch = options.fetch, depth = options.depth)
    shown = options.dirty_only ? filter(needs_attention, reports) : reports
    if isempty(shown)
        println(
            "\n",
            options.dirty_only ? "Every directory is clean and in step with its upstream." :
            "No subdirectories found.",
        )
        println()
    else
        foreach(print_report, shown)
        print_summary(reports, root)
    end

    issue_found = false
    try
        if options.scaffold
            created = scaffold_layout(root)
            print_scaffold(created)
        end
        if options.layout || options.scaffold
            findings = check_layout(root)
            print_layout(findings)
            isempty(findings) || (issue_found = true)
        end
        if options.self_contained
            repos = if is_repository_root(root)
                [root]
            else
                filter(is_repository_root, subdirectories(root))
            end
            isempty(repos) &&
                throw(ArgumentError("no repository at or directly under $root"))
            results = Pair{String, Vector{ContainmentFinding}}[]
            for repo in repos
                label = basename(rstrip(repo, '/'))
                findings = scan_self_containment(repo)
                if any(f -> f.kind === :outside || f.kind === :machine_path, findings)
                    issue_found = true
                end
                push!(results, label => findings)
            end
            print_self_containment(results)
        end
    catch err
        err isa ArgumentError || rethrow()
        println(stderr, "workspace-audit: ", err.msg)
        return 2
    end
    return issue_found ? 1 : 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
