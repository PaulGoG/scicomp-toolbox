#!/usr/bin/env -S julia --startup-file=no --compile=min
# commit-guard hook
# commit-guard.jl — check of commit messages against the commit conventions, with the
# standard library only: a Conventional Commits header, a blank line after it, no
# Co-authored-by or Signed-off-by trailers, no attribution to an AI tool or model and no
# link to an AI session. Serves as a commit-msg hook, as a check of a message file and as
# a check of the history. The hook is a byte-for-byte copy of this file; the marker on the
# second line tells a hook installed from here apart from someone else's. It is written
# into the hooks directory of one repository, never into a directory that
# core.hooksPath shares between repositories.
#
# The interpreter line asks for --compile=min because the hook runs once per commit:
# interpreted, the script takes 0.3 s, against 2 s when Julia compiles it first.
#
# Usage:
#   julia run.jl commit-guard check FILE [--rules LIST]
#   julia run.jl commit-guard log [RANGE] [--repo DIR] [--rules LIST]
#   julia run.jl commit-guard install [REPO] [--force]
#   julia run.jl commit-guard --help
#   <git dir>/hooks/commit-msg FILE            # as installed: git passes the message file
#
# Return values: 0 when no message has a finding (or the hook is in place), 1 when one
# has, 2 on invalid arguments, an unreadable file, a git failure or a refused install.

"""
    MessageFinding

One violation of the commit conventions in a message. `rule` is one of `RULES`; `line` is
the 1-based line of the original message (0 for `:empty`); `text` is the offending line,
stripped (empty for `:empty`).
"""
struct MessageFinding
    rule::Symbol
    line::Int
    text::String
end

const RULES = (:empty, :header, :separator, :trailer, :attribution, :session_url)
const TYPES = (
    "feat",
    "fix",
    "refactor",
    "docs",
    "test",
    "perf",
    "chore",
    "build",
    "ci",
    "style",
    "revert",
)

const EXPLANATIONS = Dict{Symbol, String}(
    :empty => "the message is empty",
    :header =>
        "the first line must read <type>[(scope)][!]: <description>, with type one of: " *
        join(TYPES, ", "),
    :separator => "the line after the header must be blank",
    :trailer => "Co-authored-by and Signed-off-by trailers are not used",
    :attribution => "a commit message carries no attribution to an AI tool or model",
    :session_url => "a commit message carries no link to an AI session",
)

# Header prefixes that git writes itself for merges, reverts and autosquash commits.
const GIT_HEADER_PREFIXES = ("Merge ", "Revert \"", "fixup! ", "squash! ", "amend! ")
# Marker line, second line of this script, identifying a hook installed from it.
const HOOK_MARKER = "# commit-guard hook"
# Robot face, a common signature of generated messages.
const ROBOT_FACE = '\U1F916'

# Scissors line below which git discards the message in a commit-msg file.
const SCISSORS_PATTERN = r"^# -+ >8 -+$"
# Conventional Commits header: type of TYPES, optional scope, optional breaking mark. A
# scope may list several parts of the code base, as in `fix(solver, io): ...`.
const HEADER_PATTERN =
    Regex("^(" * join(TYPES, "|") * raw")(\([^()]*[^()\s][^()]*\))?!?: \S.*$")
# Co-author and sign-off trailers.
const TRAILER_PATTERN = r"^\s*(co-authored-by|signed-off-by)\s*:"i
# Prose crediting an AI tool or model with having written the change.
const ATTRIBUTION_PATTERN = Regex(
    raw"\b(generated|written|created|authored|produced|assisted|co-?authored)\b" *
    raw"[^.]*?\b(with|by)\b.*" *
    raw"\b(claude|anthropic|gemini|copilot|chatgpt|openai|codex|cursor|antigravity|" *
    raw"aider|llm|ai)\b",
    "i",
)
# Attribution trailers naming an assisting or generating tool.
const ATTRIBUTION_TRAILER_PATTERN = r"^\s*(assisted-by|generated-by|ai-assisted(-by)?)\s*:"i
# Address that Anthropic tools put in co-author trailers.
const ANTHROPIC_ADDRESS_PATTERN = r"noreply@anthropic\.com"i
# Link to a session of a hosted AI assistant.
const SESSION_URL_PATTERN = Regex(
    raw"https?://(www\.)?(claude\.ai|claude\.com|chatgpt\.com|chat\.openai\.com|" *
    raw"gemini\.google\.com|g\.co/gemini|aistudio\.google\.com|" *
    raw"copilot\.microsoft\.com|cursor\.com|jules\.google\.com|antigravity\.google)" *
    raw"(/|\b)",
)

# Options of each command; --repo and --rules take a value.
const COMMAND_OPTIONS =
    Dict("check" => ("--rules",), "log" => ("--repo", "--rules"), "install" => ("--force",))
const OPTIONS = ("--repo", "--rules", "--force")

const USAGE = """
commit-guard — check of commit messages against the commit conventions

Usage:
  julia run.jl commit-guard check FILE [--rules LIST]
  julia run.jl commit-guard log [RANGE] [--repo DIR] [--rules LIST]
  julia run.jl commit-guard install [REPO] [--force]
  <git dir>/hooks/commit-msg FILE

  check FILE      check a message file as git hands it to the hook: comment lines and
                  everything from the scissors line on are ignored
  log [RANGE]     check the message of every commit in RANGE (default: HEAD)
  install [REPO]  install this script as the commit-msg hook of REPO (default: the
                  working directory), in the hooks directory of that repository;
                  refused when core.hooksPath is set, since git then runs the hooks
                  of that directory instead
  --repo DIR      repository for log (default: the working directory)
  --rules LIST    comma-separated subset of: empty, header, separator, trailer,
                  attribution, session_url
  --force         replace a commit-msg hook not installed by commit-guard, keeping it
                  as commit-msg.backup
  -h, --help

A header reads <type>[(scope)][!]: <description>, with type one of: feat, fix,
refactor, docs, test, perf, chore, build, ci, style, revert; headers that git writes
itself (Merge, Revert, fixup!, squash!, amend!) pass. The line after the header is
blank. Co-authored-by and Signed-off-by trailers, attribution to an AI tool or model
and links to an AI session are refused.

Return values:
  0  no finding; the hook is installed, updated or already current
  1  a message has a finding
  2  usage error, missing or unreadable file, git failure or refused install
"""

"""
    git(dir, args...) -> Tuple{Bool, String}

Run `git -C dir args...`. Returns whether it succeeded and, trimmed, its standard output
on success or its standard error on failure, so that a caller can pass git's reason on.
"""
function git(dir::AbstractString, args::AbstractString...)
    Sys.which("git") === nothing && throw(ArgumentError("git is not on PATH"))
    out = IOBuffer()
    errors = IOBuffer()
    argv = String[arg for arg in args]
    ok = success(pipeline(`git -C $dir $argv`; stdout = out, stderr = errors))
    output = String(take!(ok ? out : errors))
    return ok, String(strip(output))
end

"""
    validate_rules(rules) -> Nothing

Throw `ArgumentError` naming the first element of `rules` that is not in `RULES`.
"""
function validate_rules(rules)
    for rule in rules
        rule in RULES ||
            throw(ArgumentError("unknown rule: $rule; one of: $(join(RULES, ", "))"))
    end
    return nothing
end

"""
    is_blank(line) -> Bool

Whether `line` holds no character other than whitespace.
"""
is_blank(line::AbstractString) = all(isspace, line)

"""
    is_conventional(header) -> Bool

Whether the stripped `header` is a Conventional Commits header or one that git writes
itself. The latter pass because merges, reverts and autosquash commits carry headers that
no author types.
"""
function is_conventional(header::AbstractString)
    occursin(HEADER_PATTERN, header) && return true
    return any(prefix -> startswith(header, prefix), GIT_HEADER_PREFIXES)
end

"""
    is_attribution(line) -> Bool

Whether `line` credits an AI tool or model: the robot face, a phrase such as
"generated with Claude", an attribution trailer, or Anthropic's no-reply address.
"""
function is_attribution(line::AbstractString)
    occursin(ROBOT_FACE, line) && return true
    occursin(ATTRIBUTION_PATTERN, line) && return true
    occursin(ATTRIBUTION_TRAILER_PATTERN, line) && return true
    return occursin(ANTHROPIC_ADDRESS_PATTERN, line)
end

"""
    line_rule(line; header = false) -> Union{Symbol, Nothing}

The first of `:trailer`, `:attribution` and `:session_url` that `line` violates, or
`nothing`. The header is not tested for trailers, since a header that looks like one is
already a header finding.
"""
function line_rule(line::AbstractString; header::Bool = false)
    !header && occursin(TRAILER_PATTERN, line) && return :trailer
    is_attribution(line) && return :attribution
    occursin(SESSION_URL_PATTERN, line) && return :session_url
    return nothing
end

"""
    check_message(message; comments = false, rules = RULES) -> Vector{MessageFinding}

Findings of `message` sorted by line, restricted to `rules`. With `comments`, the message
is read as git hands it to the hook: every line from the scissors line on and every line
starting with `#` is discarded. Line numbers count the lines of the original text, so
that they point into the file the author edits. Throws `ArgumentError` for a rule not in
`RULES`.

# Example
```julia
check_message("Update stuff")  # [MessageFinding(:header, 1, "Update stuff")]
```
"""
function check_message(message::AbstractString; comments::Bool = false, rules = RULES)
    validate_rules(rules)
    kept = Tuple{Int, String}[]
    for (number, raw) in enumerate(split(message, '\n'))
        line = String(chopsuffix(raw, "\r"))
        if comments
            occursin(SCISSORS_PATTERN, line) && break
            startswith(line, '#') && continue
        end
        push!(kept, (number, line))
    end

    findings = MessageFinding[]
    header_index = findfirst(entry -> !is_blank(entry[2]), kept)
    if header_index === nothing
        push!(findings, MessageFinding(:empty, 0, ""))
        return filter(finding -> finding.rule in rules, findings)
    end

    header_number, header_line = kept[header_index]
    header = String(strip(header_line))
    is_conventional(header) ||
        push!(findings, MessageFinding(:header, header_number, header))
    rule = line_rule(header_line; header = true)
    rule === nothing || push!(findings, MessageFinding(rule, header_number, header))

    # git writes merge messages itself, not always with a blank second line
    check_separator = !startswith(header, "Merge ")
    for (number, line) in kept[(header_index + 1):end]
        text = String(strip(line))
        if check_separator && number == header_number + 1 && !is_blank(line)
            push!(findings, MessageFinding(:separator, number, text))
        end
        rule = line_rule(line)
        rule === nothing || push!(findings, MessageFinding(rule, number, text))
    end

    sort!(findings; by = finding -> finding.line)
    return filter(finding -> finding.rule in rules, findings)
end

"""
    check_history(repo, range = "HEAD"; rules = RULES)
        -> Vector{Pair{String, Vector{MessageFinding}}}

Full hash => findings of every commit of `git -C repo log range` whose message has a
finding under `rules`, newest first. All messages are read in one `git log` call, records
separated by `\\x1e` and hash from message by `\\x1f`, bytes that do not occur in a commit
message. Throws `ArgumentError` with git's reason when git fails.
"""
function check_history(repo::AbstractString, range::AbstractString = "HEAD"; rules = RULES)
    validate_rules(rules)
    ok, output = git(repo, "log", "--format=%H%x1f%B%x1e", "--end-of-options", range)
    ok || throw(ArgumentError("git log $range failed in $repo: $output"))
    results = Pair{String, Vector{MessageFinding}}[]
    for record in split(output, '\x1e')
        entry = lstrip(record, '\n')
        isempty(entry) && continue
        fields = split(entry, '\x1f'; limit = 2)
        length(fields) == 2 || continue
        hash, message = fields
        findings = check_message(message; comments = false, rules)
        isempty(findings) || push!(results, String(hash) => findings)
    end
    return results
end

"""
    hooks_directory(repo) -> String

Hooks directory of the repository holding `repo`: `hooks` under its common git directory,
which linked work trees share. Throws `ArgumentError` when `repo` is not inside a git work
tree, and when `core.hooksPath` is set. Git then runs the hooks of that directory, which
may serve every repository of the user, and this script writes into one repository only.
"""
function hooks_directory(repo::AbstractString)
    ok, common = git(repo, "rev-parse", "--git-common-dir")
    ok || throw(ArgumentError("not inside a git work tree: $repo ($common)"))
    shared, configured = git(repo, "config", "--get", "core.hooksPath")
    shared &&
        !isempty(configured) &&
        throw(
            ArgumentError(
                "core.hooksPath is set to $configured: git runs the hooks of that " *
                "directory for this repository, and install writes into the hooks " *
                "directory of a repository only",
            ),
        )
    directory = isabspath(common) ? common : abspath(joinpath(repo, common))
    return joinpath(directory, "hooks")
end

"""
    install_hook(repo; force = false) -> Symbol

Install this script as the `commit-msg` hook of the repository holding `repo`. Returns
`:installed` for a new hook, `:current` when the hook already has the same bytes and
`:updated` when a hook carrying the marker line is replaced. A hook without the marker
belongs to someone else: it is refused with `ArgumentError` unless `force`, which moves
it to `commit-msg.backup` first and refuses when that name is taken.
"""
function install_hook(repo::AbstractString; force::Bool = false)
    directory = hooks_directory(repo)
    mkpath(directory)
    hook = joinpath(directory, "commit-msg")
    source = @__FILE__
    status = :installed
    if ispath(hook)
        existing = read(hook)
        existing == read(source) && return :current
        if any(==(HOOK_MARKER), eachline(IOBuffer(existing)))
            status = :updated
        elseif !force
            throw(
                ArgumentError(
                    "$hook is not a commit-guard hook; --force keeps it as " *
                    "commit-msg.backup and installs over it",
                ),
            )
        else
            backup = joinpath(directory, "commit-msg.backup")
            (ispath(backup) || islink(backup)) &&
                throw(ArgumentError("cannot keep $hook: $backup exists"))
            mv(hook, backup)
        end
    end
    cp(source, hook; force = true, follow_symlinks = true)
    chmod(hook, 0o755)
    return status
end

"""
    parse_rules(list) -> Vector{Symbol}

Rule names of a comma-separated `list`. Throws `ArgumentError` for an empty list or a
name not in `RULES`.
"""
function parse_rules(list::AbstractString)
    names = filter(!isempty, strip.(split(list, ',')))
    isempty(names) && throw(ArgumentError("--rules takes at least one rule"))
    rules = Symbol.(names)
    validate_rules(rules)
    return rules
end

"""
    parse_arguments(command, args) -> NamedTuple

Positional arguments and options of `command`, from `args` in any order: `positionals`,
`repo` (`nothing` when absent), `rules` and `force`. Throws `ArgumentError` for an
unknown option, an option the command does not take, or a missing option value.
"""
function parse_arguments(command::AbstractString, args::Vector{String})
    allowed = COMMAND_OPTIONS[command]
    positionals = String[]
    repo = nothing
    rules = collect(RULES)
    force = false
    i = 1
    while i <= length(args)
        arg = args[i]
        if startswith(arg, "-")
            arg in OPTIONS || throw(ArgumentError("unknown option: $arg"))
            arg in allowed || throw(ArgumentError("$command does not take $arg"))
            if arg == "--force"
                force = true
            else
                i < length(args) || throw(ArgumentError("$arg takes a value"))
                i += 1
                if arg == "--repo"
                    repo = args[i]
                else
                    rules = parse_rules(args[i])
                end
            end
        else
            push!(positionals, arg)
        end
        i += 1
    end
    return (; positionals, repo, rules, force)
end

"""
    run_check(path, rules, err) -> Int

Check the message file at `path` as the hook does and report the findings to `err`.
Returns 0 without findings and 1 with any. Throws `ArgumentError` for a missing or
unreadable file.
"""
function run_check(path::AbstractString, rules, err::IO)
    isfile(path) || throw(ArgumentError("no message file at $path"))
    text = try
        read(path, String)
    catch exception
        exception isa SystemError || rethrow()
        throw(ArgumentError("cannot read $path"))
    end
    findings = check_message(text; comments = true, rules)
    isempty(findings) && return 0
    for finding in findings
        if finding.rule === :empty
            println(err, "commit-guard: empty: no message")
        else
            println(
                err,
                "commit-guard: ",
                finding.rule,
                ": line ",
                finding.line,
                ": ",
                finding.text,
            )
        end
    end
    for rule in RULES
        any(finding -> finding.rule === rule, findings) &&
            println(err, "commit-guard: ", EXPLANATIONS[rule])
    end
    println(err, "commit-guard: commit refused (git commit --no-verify bypasses the hook)")
    return 1
end

"""
    run_log(repo, range, rules, io) -> Int

Report to `io` the findings of every commit in `range` of `repo`, one line per finding,
then the number of commits with findings out of those in the range. Returns 1 when any
commit has a finding, else 0.
"""
function run_log(repo::AbstractString, range::AbstractString, rules, io::IO)
    results = check_history(repo, range; rules)
    ok, total = git(repo, "rev-list", "--count", "--end-of-options", range)
    ok || throw(ArgumentError("git rev-list --count $range failed in $repo: $total"))
    commits = tryparse(Int, total)
    commits === nothing &&
        throw(ArgumentError("git rev-list --count $range returned $total"))
    for (hash, findings) in results
        for finding in findings
            println(io, first(hash, 9), "  ", finding.rule, ": ", finding.text)
        end
    end
    println(io, length(results), " of ", commits, " commits with findings")
    return isempty(results) ? 0 : 1
end

"""
    run_command(args, io, err) -> Int

Dispatch a non-empty argument list without a help flag to its command. A single argument
that is neither a command nor an option is the message file git passes to the hook.
"""
function run_command(args::Vector{String}, io::IO, err::IO)
    command = first(args)
    if !haskey(COMMAND_OPTIONS, command)
        if startswith(command, "-")
            command in OPTIONS && throw(
                ArgumentError("$command must follow a command: check, log or install"),
            )
            throw(ArgumentError("unknown option: $command"))
        end
        length(args) == 1 && return run_check(command, RULES, err)
        throw(ArgumentError("unknown command: $command"))
    end

    options = parse_arguments(command, args[2:end])
    positionals = options.positionals
    if command == "check"
        isempty(positionals) && throw(ArgumentError("check takes a message file"))
        length(positionals) == 1 ||
            throw(ArgumentError("unexpected argument: $(positionals[2])"))
        return run_check(only(positionals), options.rules, err)
    end
    length(positionals) <= 1 ||
        throw(ArgumentError("unexpected argument: $(positionals[2])"))
    if command == "log"
        range = isempty(positionals) ? "HEAD" : only(positionals)
        return run_log(something(options.repo, pwd()), range, options.rules, io)
    end
    repo = isempty(positionals) ? pwd() : only(positionals)
    status = install_hook(repo; force = options.force)
    hook = joinpath(hooks_directory(repo), "commit-msg")
    println(io, "commit-guard: hook ", status, " at ", hook)
    return 0
end

"""
    main(args = ARGS; io = stdout, err = stderr) -> Int

Command-line entry point and hook body. Returns 0 when nothing is found, 1 when a message
has a finding, 2 on a usage error or any `ArgumentError`, which is printed to `err`.
"""
function main(args::Vector{String} = ARGS; io::IO = stdout, err::IO = stderr)
    if isempty(args)
        print(err, USAGE)
        return 2
    end
    if any(in(("-h", "--help")), args)
        print(io, USAGE)
        return 0
    end
    try
        return run_command(args, io, err)
    catch exception
        exception isa ArgumentError || rethrow()
        println(err, "commit-guard: ", exception.msg)
        return 2
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
