#!/usr/bin/env -S julia --startup-file=no --compile=min
# commit-guard hook
# commit-guard.jl — check of commit messages against the commit conventions, with the
# standard library only: a Conventional Commits header, a blank line after it, no
# Co-authored-by, Co-developed-by or Signed-off-by trailers, no attribution to an AI tool
# or model and no link to an AI session. Attribution is a line that begins with a phrase
# such as "Generated with" and names a tool or vendor, an attribution trailer, the robot
# face or Anthropic's no-reply address. Serves as a commit-msg hook, as a check of a
# message file and as a check of the history. The strip command removes from a message
# file the co-author trailers that name an AI tool, the attribution lines and the session
# links; it keeps the header, human co-authors and Signed-off-by lines. The hook refuses
# a commit with a finding, or strips the message when the git configuration key
# commit-guard.mode is set to strip.
#
# The hook is a byte-for-byte copy of this file; the marker on the second line tells a
# hook installed from here apart from someone else's. It is written into the hooks
# directory of one repository, never into a directory that core.hooksPath shares between
# repositories.
#
# The interpreter line asks for --compile=min because the hook runs once per commit:
# interpreted, the script takes 0.3 s, against 2 s when Julia compiles it first.
#
# Usage:
#   julia run.jl commit-guard check FILE [--rules LIST]
#   julia run.jl commit-guard strip FILE
#   julia run.jl commit-guard log [RANGE] [--repo DIR] [--rules LIST]
#   julia run.jl commit-guard install [REPO] [--force]
#   julia run.jl commit-guard --help
#   <git dir>/hooks/commit-msg FILE            # as installed: git passes the message file
#   git config commit-guard.mode strip         # the hook strips instead of refusing
#
# Return values: 0 when no message has a finding, after strip, and when the hook is in
# place; 1 when a message has a finding; 2 on invalid arguments, an unreadable or
# unwritable file, a git failure or a refused install.

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
    :trailer => "Co-authored-by, Co-developed-by and Signed-off-by trailers are not used",
    :attribution => "a commit message carries no attribution to an AI tool or model",
    :session_url => "a commit message carries no link to an AI session",
)

# Header prefixes that git writes itself for merges, reverts and autosquash commits.
const GIT_HEADER_PREFIXES =
    ("Merge ", "Revert \"", "Reapply \"", "fixup! ", "squash! ", "amend! ")
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
# Tools and vendors that sign commits; matched as whole words without regard to case.
const AI_NAMES = (
    "claude",
    "anthropic",
    "gemini",
    "antigravity",
    "copilot",
    "chatgpt",
    "openai",
    "codex",
    "cursor",
    "aider",
    "windsurf",
    "codeium",
    "grok",
    "deepseek",
    "devin",
    "jules",
    "ampcode",
    "llm",
)
# Regex text naming an AI tool: AI_NAMES or a GPT model in any case, AI in capitals only,
# so that Ai(x) and a .ai host name are no match.
const NAMES = raw"(?i:\b(?:" * join(AI_NAMES, "|") * raw")\b|\bgpt-?[0-9])|\bAI\b"

# Co-author, co-developer and sign-off trailers.
const TRAILER_PATTERN = r"^\s*(co-authored-by|co-developed-by|signed-off-by)\s*:"i
# Line that begins with a phrase crediting an AI tool or model with the change, the name
# within the same clause; an optional subject such as "This commit was" or "Patch" leads.
const ATTRIBUTION_PATTERN = Regex(
    raw"^\W*(?i:(?:(?:this|the)\s+)?" *
    raw"(?:(?:commit|change|patch|code|message|diff)\s+(?:(?:was|is|has\s+been)\s+)?)?" *
    raw"(?:generated|written|created|authored|produced|assisted|co-?authored|made)" *
    raw"\s+(?:with|by|using|via)\b)[^.;:!?]*?(?:" *
    NAMES *
    ")",
)
# Attribution trailers naming an assisting or generating tool or its session.
const ATTRIBUTION_TRAILER_PATTERN = Regex(
    raw"^\s*(assisted-by|generated-by|ai-assisted(-by)?|claude-session|amp-thread-id)\s*:",
    "i",
)
# Co-author or co-developer trailer naming an AI tool, an assistant or agent.
const AI_COAUTHOR_PATTERN = Regex(
    raw"^\s*(?i:co-(?:authored|developed)-by)\s*:.*(?:" *
    NAMES *
    raw"|(?i:\b(?:assistant|agent|amp)\b|noreply@anthropic))",
)
# Address that Anthropic tools put in co-author trailers.
const ANTHROPIC_ADDRESS_PATTERN = r"noreply@anthropic\.com"i
# Link to a session of a hosted AI assistant: a host or one of its subdomains with a path,
# scheme optional.
const SESSION_URL_PATTERN = Regex(
    raw"(?<![\w.@-])(?:https?://)?(?:[\w-]+\.)*(?:claude\.ai|claude\.com|chatgpt\.com|" *
    raw"chat\.openai\.com|gemini\.google\.com|g\.co/gemini|aistudio\.google\.com|" *
    raw"copilot\.microsoft\.com|cursor\.com|jules\.google\.com|antigravity\.google|" *
    raw"ampcode\.com)/\S",
    "i",
)

# Variables by which git points a child process at a repository other than `-C dir`.
const GIT_REPOSITORY_VARIABLES =
    ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX")

# Options of each command; --repo and --rules take a value.
const COMMAND_OPTIONS = Dict(
    "check" => ("--rules",),
    "log" => ("--repo", "--rules"),
    "install" => ("--force",),
    "strip" => (),
)
const OPTIONS = ("--repo", "--rules", "--force")

const USAGE = """
commit-guard — check of commit messages against the commit conventions

Usage:
  julia run.jl commit-guard check FILE [--rules LIST]
  julia run.jl commit-guard strip FILE
  julia run.jl commit-guard log [RANGE] [--repo DIR] [--rules LIST]
  julia run.jl commit-guard install [REPO] [--force]
  <git dir>/hooks/commit-msg FILE

  check FILE      check a message file as git hands it to the hook: everything from
                  git's scissors line on is ignored, and lines starting with # are
                  tested for trailers, attribution and session links only
  strip FILE      remove from a message file the co-author trailers that name an AI
                  tool, the attribution lines and the session links; the header,
                  human co-authors and Signed-off-by lines stay, and the file is
                  rewritten only when a line is removed
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

The hook checks the message file as check does and refuses the commit on a finding. When
the git configuration key commit-guard.mode is strip (one of: refuse | strip; default:
refuse), it strips the message file as strip does instead:
  git config commit-guard.mode strip

A header reads <type>[(scope)][!]: <description>, with type one of: feat, fix,
refactor, docs, test, perf, chore, build, ci, style, revert; headers that git writes
itself (Merge, Revert, Reapply, fixup!, squash!, amend!) pass. The line after the
header is blank. Co-authored-by, Co-developed-by and Signed-off-by trailers, links to
an AI session and attribution to an AI tool or model are refused; attribution is an
attribution trailer, the robot face, or a line that begins with a phrase such as
"Generated with" and names a tool or vendor.

Return values:
  0  no finding; strip completed; the hook is installed, updated or already current
  1  a message has a finding
  2  usage error, missing, unreadable or unwritable file, git failure or refused install
"""

"""
    git(dir, args...; inherit = false) -> Tuple{Bool, String}

Run `git -C dir args...`. Returns whether it succeeded and, trimmed, its standard output
on success or its standard error on failure, so that a caller can pass git's reason on.
Unless `inherit`, the child runs without `GIT_REPOSITORY_VARIABLES`: inside a hook git
sets them, and they would make git answer for that repository instead of `dir`.
"""
function git(dir::AbstractString, args::AbstractString...; inherit::Bool = false)
    Sys.which("git") === nothing && throw(ArgumentError("git is not on PATH"))
    out = IOBuffer()
    errors = IOBuffer()
    argv = String[arg for arg in args]
    command = `git -C $dir $argv`
    if !inherit
        environment = copy(ENV)
        foreach(name -> delete!(environment, name), GIT_REPOSITORY_VARIABLES)
        command = setenv(command, environment)
    end
    ok = success(pipeline(command; stdout = out, stderr = errors))
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

Whether `line` credits an AI tool or model: the robot face, a line that begins with a
phrase such as "Generated with Claude", an attribution trailer, or Anthropic's no-reply
address.
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
    message_lines(message; comments = false) -> Vector{Tuple{Int, String, Symbol}}

Every line of `message`, split at `\\n`: its 1-based number, its text without a trailing
`\\r`, and its kind, `:message`, `:comment` for a line starting with `#` above the cut, or
`:discarded` for a line from the cut on. Without `comments` every line is a message line.
With `comments`, a line matching `SCISSORS_PATTERN` is git's cut only when the first line
after it that does not start with `#` begins with `diff --git ` or, under
`diff.submodule=log`, with `Submodule `, or when there is none; an author may type such a
line in the message, and git cuts at its own line only. The hook cannot see whether git
will clean the message up (an editor session) or keep it as written (`-m`, `-F`): a
scissors line and a diff typed into `-m` hide what follows from the hook, and a `#` line
typed there is recorded as text. `check_history` judges the recorded message.
"""
function message_lines(message::AbstractString; comments::Bool = false)
    lines = [String(chopsuffix(line, "\r")) for line in split(message, '\n')]
    comments || return [(number, line, :message) for (number, line) in enumerate(lines)]
    cut = length(lines) + 1
    for (index, line) in enumerate(lines)
        occursin(SCISSORS_PATTERN, line) || continue
        following = findnext(other -> !startswith(other, '#'), lines, index + 1)
        if following === nothing ||
           startswith(lines[following], "diff --git ") ||
           startswith(lines[following], "Submodule ")
            cut = index
            break
        end
    end
    entries = Tuple{Int, String, Symbol}[]
    for (number, line) in enumerate(lines)
        kind = number >= cut ? :discarded : startswith(line, '#') ? :comment : :message
        push!(entries, (number, line, kind))
    end
    return entries
end

"""
    comment_text(line) -> SubString{String}

Text of a `#` line after its leading `#` characters and the whitespace that follows them.
"""
comment_text(line::AbstractString) = lstrip(lstrip(==('#'), line))

"""
    check_message(message; comments = false, rules = RULES) -> Vector{MessageFinding}

Findings of `message` sorted by line, restricted to `rules`. With `comments`, the message
is read as git hands it to the hook (see `message_lines`): every line from git's cut on is
discarded, and lines starting with `#` above it are no part of the message for `:empty`,
`:header` and `:separator`. Those lines are still tested with the line rules, on
`comment_text`, because git keeps them when the message comes from `-m` or `-F`. Line
numbers count the lines of the original text, so that they point into the file the author
edits. Throws `ArgumentError` for a rule not in `RULES`.

# Example
```julia
check_message("Update stuff")  # [MessageFinding(:header, 1, "Update stuff")]
```
"""
function check_message(message::AbstractString; comments::Bool = false, rules = RULES)
    validate_rules(rules)
    entries = message_lines(message; comments)
    kept = [(number, line) for (number, line, kind) in entries if kind === :message]

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
    if !startswith(header, "Merge ") && header_index < length(kept)
        number, line = kept[header_index + 1]
        is_blank(line) ||
            push!(findings, MessageFinding(:separator, number, String(strip(line))))
    end
    for (number, line) in kept[(header_index + 1):end]
        rule = line_rule(line)
        rule === nothing ||
            push!(findings, MessageFinding(rule, number, String(strip(line))))
    end
    for (number, line, kind) in entries
        kind === :comment || continue
        rule = line_rule(comment_text(line))
        rule === nothing ||
            push!(findings, MessageFinding(rule, number, String(strip(line))))
    end

    sort!(findings; by = finding -> finding.line)
    return filter(finding -> finding.rule in rules, findings)
end

"""
    is_removable(line) -> Bool

Whether strip removes `line`: a co-author trailer that names an AI tool
(`AI_COAUTHOR_PATTERN`), or a line that is an attribution or holds a session link, a
co-author trailer included (`Co-authored-by: x (https://jules.google.com/task/1)`). A
co-author that names no AI tool and every `Signed-off-by` line stay.
"""
function is_removable(line::AbstractString)
    occursin(r"^\s*signed-off-by\s*:"i, line) && return false
    occursin(AI_COAUTHOR_PATTERN, line) && return true
    return is_attribution(line) || occursin(SESSION_URL_PATTERN, line)
end

"""
    strip_message(message; comments = false)
        -> Tuple{String, Vector{MessageFinding}}

`message` without the lines for which `is_removable` holds, and one finding per removed
line, sorted by line. The header, the first non-blank message line, is never removed, and
with `comments` neither is any line from git's cut on; a `#` line above the cut is tested
on `comment_text`. Kept lines stay byte for byte. A finding's `rule` is `:trailer` for a
match of `AI_COAUTHOR_PATTERN` and the `line_rule` of the line otherwise; `line` and
`text` are as in `check_message`. A message without a header is returned unchanged with
no finding.

# Example
```julia
strip_message("fix: x\\n\\nCo-authored-by: Claude")
# ("fix: x\\n", [MessageFinding(:trailer, 3, "Co-authored-by: Claude")])
```
"""
function strip_message(message::AbstractString; comments::Bool = false)
    lines = split(message, '\n')
    entries = message_lines(message; comments)
    header = findfirst(entry -> entry[3] === :message && !is_blank(entry[2]), entries)
    header === nothing && return (String(message), MessageFinding[])

    findings = MessageFinding[]
    keep = trues(length(lines))
    for (number, line, kind) in entries
        (number == header || kind === :discarded) && continue
        text = kind === :comment ? comment_text(line) : line
        is_removable(text) || continue
        rule = occursin(AI_COAUTHOR_PATTERN, text) ? :trailer : line_rule(text)
        push!(findings, MessageFinding(rule, number, String(strip(line))))
        keep[number] = false
    end
    return join(lines[keep], '\n'), findings
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
    ok, output = git(
        repo,
        "log",
        "--no-show-signature",
        "--format=%H%x1f%B%x1e",
        "--end-of-options",
        range,
    )
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

Hooks directory of the repository holding `repo`: `hooks` under the `realpath` of its
common git directory, which linked work trees share. Throws `ArgumentError` when `repo` is
not inside a git work tree (a bare repository included), and when `core.hooksPath` is
set. Git then runs the hooks of that directory, which may serve every repository of the
user, and this script writes into one repository only. Throws `ArgumentError` as well
when `hooks` is a symbolic link or resolves elsewhere, since writing through it would
leave the git directory of the repository.
"""
function hooks_directory(repo::AbstractString)
    ok, inside = git(repo, "rev-parse", "--is-inside-work-tree")
    ok || throw(ArgumentError("not inside a git work tree: $repo ($inside)"))
    inside == "true" || throw(ArgumentError("not inside a git work tree: $repo"))
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
    # absolute: a relative answer is relative to the physical working directory of git,
    # which differs from `repo` when `repo` is reached through a symbolic link
    ok, common = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
    ok || throw(ArgumentError("not inside a git work tree: $repo ($common)"))
    isabspath(common) ||
        throw(ArgumentError("git gave no absolute git directory for $repo: $common"))
    common = realpath(common)
    hooks = joinpath(common, "hooks")
    if islink(hooks) || (ispath(hooks) && realpath(hooks) != hooks)
        throw(ArgumentError("$hooks leads outside the git directory of the repository"))
    end
    return hooks
end

"""
    install_hook(repo; force = false) -> Symbol

Install this script as the `commit-msg` hook of the repository holding `repo`. Returns
`:installed` for a new hook, `:current` when the hook already has the same bytes and is
executable by its owner, and `:updated` when a hook with the same bytes is made
executable or a hook carrying the marker as its second line is replaced. Any other hook,
a symbolic link included, dangling or not, belongs to someone else: it is refused with
`ArgumentError` unless `force`, which moves it (the link itself, not its target) to
`commit-msg.backup` first and refuses when that name is taken.
"""
function install_hook(repo::AbstractString; force::Bool = false)
    directory = hooks_directory(repo)
    mkpath(directory)
    hook = joinpath(directory, "commit-msg")
    source = @__FILE__
    status = :installed
    if islink(hook) || ispath(hook)
        ours = false
        if !islink(hook) && isfile(hook)
            existing = read(hook, String)
            if existing == read(source, String)
                iszero(uperm(hook) & 0x01) || return :current
                chmod(hook, 0o755)
                return :updated
            end
            lines = split(existing, '\n')
            ours = length(lines) >= 2 && lines[2] == HOOK_MARKER
        end
        if ours
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
    read_message(path) -> String

Text of the message file at `path`. Throws `ArgumentError` for a missing or unreadable
file.
"""
function read_message(path::AbstractString)
    isfile(path) || throw(ArgumentError("no message file at $path"))
    return try
        read(path, String)
    catch exception
        exception isa SystemError || rethrow()
        throw(ArgumentError("cannot read $path"))
    end
end

"""
    run_check(path, rules, err) -> Int

Check the message file at `path` as the hook does and report the findings to `err`.
Returns 0 without findings and 1 with any. Throws `ArgumentError` for a missing or
unreadable file.
"""
function run_check(path::AbstractString, rules, err::IO)
    text = read_message(path)
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
    run_strip(path, err) -> Int

Strip the message file at `path` with `strip_message` as the hook reads it, and report
each removed line to `err`. The file is written only when a line was removed. Returns 0.
Throws `ArgumentError` for a missing or unreadable file.
"""
function run_strip(path::AbstractString, err::IO)
    text = read_message(path)
    stripped, findings = strip_message(text; comments = true)
    isempty(findings) && return 0
    write(path, stripped)
    for finding in findings
        println(err, "commit-guard: removed line ", finding.line, ": ", finding.text)
    end
    return 0
end

"""
    hook_mode() -> Symbol

What the hook does, from `git config --get commit-guard.mode` in the working directory
under the environment git gave the hook: `:refuse` when the key is not set or reads
`refuse`, `:strip` when it reads `strip`. Throws `ArgumentError` for any other value.
"""
function hook_mode()
    ok, value = git(pwd(), "config", "--get", "commit-guard.mode"; inherit = true)
    (!ok || value == "refuse") && return :refuse
    value == "strip" && return :strip
    throw(ArgumentError("commit-guard.mode must be refuse or strip, got '$value'"))
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
that is neither a command nor an option is the message file git passes to the hook,
checked or stripped as `hook_mode` says.
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
        if length(args) == 1
            hook_mode() === :strip && return run_strip(command, err)
            return run_check(command, RULES, err)
        end
        throw(ArgumentError("unknown command: $command"))
    end

    options = parse_arguments(command, args[2:end])
    positionals = options.positionals
    if command == "check" || command == "strip"
        isempty(positionals) && throw(ArgumentError("$command takes a message file"))
        length(positionals) == 1 ||
            throw(ArgumentError("unexpected argument: $(positionals[2])"))
        command == "strip" && return run_strip(only(positionals), err)
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

Command-line entry point and hook body. Returns 0 when nothing is found or a message file
was stripped, 1 when a message has a finding, 2 on a usage error or any `ArgumentError`,
`Base.IOError` or `SystemError`, which is printed to `err`.
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
        if exception isa ArgumentError
            println(err, "commit-guard: ", exception.msg)
        elseif exception isa Base.IOError || exception isa SystemError
            println(err, "commit-guard: ", sprint(showerror, exception))
        else
            rethrow()
        end
        return 2
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
