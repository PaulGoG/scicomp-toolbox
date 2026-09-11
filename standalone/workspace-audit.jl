#!/usr/bin/env julia
# workspace-audit.jl — git and artifact state of every project directory under a workspace
# root, with the standard library only. Reports branch, working-tree cleanliness, distance
# from the upstream branch, stashes, untracked weight and regenerable backup artifacts, so
# that unsynced work and deletable leftovers are visible in one command.
#
# The tool never writes and never deletes: it prints the candidates and the command that
# would remove them.

using Printf: @printf, @sprintf

const BACKUP_SUFFIXES = (".backup.bundle", ".git.backup")
const LARGEST_UNTRACKED_SHOWN = 3

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
    ahead::Int
    behind::Int
    remote::String
    stashes::Int
    leftovers::Vector{Leftover}
end

"""
    git(dir, args...) -> Tuple{Bool, String}

Run `git -C dir args...`, returning whether it succeeded and its trimmed standard output.
Standard error is discarded: every call site treats failure as "the fact is unavailable".
"""
function git(dir::AbstractString, args::AbstractString...)
    out = IOBuffer()
    argv = collect(args)
    ok = success(pipeline(`git -C $dir $argv`; stdout = out, stderr = devnull))
    return ok, strip(String(take!(out)))
end

"""
    is_repository_root(dir) -> Bool

Whether `dir` is itself the top level of a work tree, rather than a subdirectory of one or
no repository at all.
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
            (status_x == 'R' || status_x == 'C') && (i += 1)
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

Binary-prefixed size with three significant figures, e.g. `1.44 GiB`.
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
    audit_directory(dir; fetch = false) -> DirectoryReport

Collect the git and artifact state of one directory. With `fetch`, the remote-tracking
refs are refreshed first, which needs the network; without it the comparison uses the refs
already stored, which may be out of date.
"""
function audit_directory(dir::AbstractString; fetch::Bool = false)
    name = basename(rstrip(dir, '/'))
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
            0,
            0,
            "",
            0,
            find_leftovers(dir, nothing),
        )
    end

    fetch && git(dir, "fetch", "--quiet", "--all")

    _, branch = git(dir, "rev-parse", "--abbrev-ref", "HEAD")
    _, commit = git(dir, "rev-parse", "--short", "HEAD")

    _, status_payload = git(dir, "status", "--porcelain", "-z", "-uall")
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
        ahead,
        behind,
        remote,
        stashes,
        find_leftovers(dir, head_time),
    )
end

"""
    needs_attention(report) -> Bool

Whether the directory holds work that is not committed, not pushed, or an artifact that
could be removed. A clean repository in step with its upstream needs none.
"""
function needs_attention(report::DirectoryReport)
    isempty(report.leftovers) || return true
    report.is_repository || return false
    report.tracked_changes > 0 && return true
    report.untracked_count > 0 && return true
    report.ahead > 0 && return true
    report.behind > 0 && return true
    report.stashes > 0 && return true
    isempty(report.upstream) && return true
    return false
end

"""
    audit_workspace(root; fetch = false) -> Vector{DirectoryReport}

Audit every immediate subdirectory of `root`, in name order. The walk is one level deep:
a workspace holds projects, and descending further would report their internals.
"""
function audit_workspace(root::AbstractString; fetch::Bool = false)
    isdir(root) || throw(ArgumentError("not a directory: $root"))
    reports = DirectoryReport[]
    for name in sort(readdir(root))
        startswith(name, ".") && continue
        path = joinpath(root, name)
        isdir(path) && !islink(path) || continue
        push!(reports, audit_directory(path; fetch))
    end
    return reports
end

function print_report(report::DirectoryReport)
    if !report.is_repository
        println("\n", report.name)
        println("  State                : not a git repository")
    else
        flags = String[]
        report.tracked_changes > 0 && push!(flags, "dirty")
        report.ahead > 0 && push!(flags, "unpushed")
        report.behind > 0 && push!(flags, "behind")
        isempty(report.upstream) && push!(flags, "no upstream")
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

function print_summary(reports::Vector{DirectoryReport})
    repositories = count(r -> r.is_repository, reports)
    attention = count(needs_attention, reports)
    leftovers = reduce(vcat, (r.leftovers for r in reports); init = Leftover[])
    stale = filter(l -> l.stale, leftovers)

    println("\nSummary")
    println("  Directories          : ", length(reports), " (", repositories, " git)")
    println("  Needing attention    : ", attention)
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
            println("  rm -rf ", leftover.path)
        end
    end
    println()
    return nothing
end

function print_help()
    println(
        """
workspace-audit — git and artifact state of the projects under a workspace

Usage:
  julia run.jl workspace-audit [PATH] [options]

  PATH             workspace root to audit (default: the parent of this repository)
  --dirty-only     report only directories with uncommitted, unpushed or removable state
  --fetch          refresh remote-tracking refs first; needs the network and is slower
  -h, --help

Without --fetch the distance from the upstream branch is measured against the
remote-tracking refs already stored, which may be out of date.

The tool only reads: it never writes, commits, fetches without being asked, or deletes.
""",
    )
    return nothing
end

"""
    parse_args(args) -> NamedTuple

Positional workspace root and the two flags. Throws `ArgumentError` on an unknown option
or a second positional argument.
"""
function parse_args(args::Vector{String})
    root = nothing
    dirty_only = false
    fetch = false
    help = false
    for arg in args
        if arg in ("-h", "--help")
            help = true
        elseif arg == "--dirty-only"
            dirty_only = true
        elseif arg == "--fetch"
            fetch = true
        elseif startswith(arg, "-")
            throw(ArgumentError("unknown option: $arg"))
        elseif root === nothing
            root = arg
        else
            throw(ArgumentError("unexpected second path argument: $arg"))
        end
    end
    return (; root, dirty_only, fetch, help)
end

"""
    default_root() -> String

Parent of the repository holding this script, which is the workspace the toolbox lives in.
Resolved from the script location so that no absolute path is baked in.
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
    println(
        "  Upstream comparison  : ",
        options.fetch ? "refreshed (--fetch)" : "stored refs (pass --fetch to refresh)",
    )

    reports = audit_workspace(root; fetch = options.fetch)
    shown = options.dirty_only ? filter(needs_attention, reports) : reports
    if isempty(shown)
        println(
            "\n",
            options.dirty_only ? "Every directory is clean and in step with its upstream." :
            "No subdirectories found.",
        )
        println()
        return 0
    end
    foreach(print_report, shown)
    print_summary(reports)
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
