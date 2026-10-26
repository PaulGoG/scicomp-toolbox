#!/usr/bin/env julia
# run.jl — workbench dispatcher: lists and executes tools.
#
#   julia run.jl <tool> [args...]              run a sub-environment tool or a standalone script
#   julia run.jl --threads N <tool> [args...]  Julia thread count of the child process
#                                              (default: JULIA_NUM_THREADS, else auto)
#   julia run.jl --list                        catalog of tools and standalone scripts
#   julia run.jl --help

using Printf: @printf

const REPO_ROOT = @__DIR__
const STANDALONE_DIR = joinpath(REPO_ROOT, "standalone")
# directories holding a Project.toml that are environments but not tools: the pinned
# formatter, and standalone/, whose Project.toml exists only so its scripts can be tested
const NON_TOOL_ENVIRONMENTS = Set(["formatter", "standalone"])

"""
    find_subenvironments() -> Vector{Pair{String, String}}

Tool directories: immediate subdirectories holding a `Project.toml`, excluding the
auxiliary environments. Each name is paired with its entry script `<name>/<name>.jl`,
or `""` when that file is absent.
"""
function find_subenvironments()
    tools = Pair{String, String}[]
    for item in sort(readdir(REPO_ROOT))
        startswith(item, ".") && continue
        item in NON_TOOL_ENVIRONMENTS && continue
        dir = joinpath(REPO_ROOT, item)
        (isdir(dir) && isfile(joinpath(dir, "Project.toml"))) || continue
        entry = joinpath(dir, "$item.jl")
        push!(tools, item => (isfile(entry) ? entry : ""))
    end
    return tools
end

"""
    find_standalone_scripts() -> Vector{String}

File names of the scripts in `standalone/`.
"""
function find_standalone_scripts()
    isdir(STANDALONE_DIR) || return String[]
    return filter(f -> endswith(f, ".jl"), sort(readdir(STANDALONE_DIR)))
end

"""
    extract_description(dir::String) -> String

First paragraph line of `dir/README.md` that is neither a heading nor a badge, truncated
to 80 characters.
"""
function extract_description(dir::String)
    readme = joinpath(dir, "README.md")
    isfile(readme) || return "No description available."
    for line in eachline(readme)
        text = strip(line)
        (isempty(text) || startswith(text, "#") || startswith(text, "[![")) && continue
        return length(text) > 80 ? first(text, 77) * "..." : String(text)
    end
    return "No description available."
end

function print_help()
    println(
        """
Workbench dispatcher

Usage:
  julia run.jl <tool> [args...]              run a tool or a standalone script
  julia run.jl --threads N <tool> [args...]  Julia thread count of the child (default: auto)
  julia run.jl --list                        catalog of tools and standalone scripts
  julia run.jl --help                        this message

Examples:
  julia run.jl hardware-diagnostics --quick --cpu-only
  julia run.jl --threads 8 hardware-diagnostics --gpu-backend oneapi
  julia run.jl sysinfo
""",
    )
end

function list_tools()
    println("Sub-environment tools")
    tools = find_subenvironments()
    if isempty(tools)
        println("  (none)")
    else
        for (name, entry) in tools
            @printf("  %-24s %s\n", name, extract_description(joinpath(REPO_ROOT, name)))
            @printf(
                "  %-24s entry: %s\n",
                "",
                isempty(entry) ? "missing $name/$name.jl" : relpath(entry, REPO_ROOT)
            )
        end
    end
    println("\nStandalone scripts (standalone/)")
    scripts = find_standalone_scripts()
    if isempty(scripts)
        println("  (none)")
    else
        for script in scripts
            name = replace(script, r"\.jl$" => "")
            @printf("  %-24s julia run.jl %s\n", name, name)
        end
    end
end

"""
    exit_status(process::Base.Process) -> Int

Conventional status of a finished child: its exit code, or 128 plus the signal number when
a signal terminated it.
"""
exit_status(process::Base.Process) =
    process.termsignal != 0 ? 128 + process.termsignal : process.exitcode

"""
    dispatch(target::String, args::Vector{String}, threads::String)

Run a tool (`<name>/<name>.jl` with its own project) or a standalone script, forwarding
`args`; the child's exit status becomes this process's exit status.
"""
function dispatch(target::String, args::Vector{String}, threads::String)
    target = rstrip(target, '/')
    tools = Dict(find_subenvironments())
    if haskey(tools, target)
        entry = tools[target]
        isempty(entry) && error("tool '$target' has no entry script $target/$target.jl")
        dir = joinpath(REPO_ROOT, target)
        cmd = `$(Base.julia_cmd()) --threads=$threads --project=$dir $entry $args`
        exit(exit_status(run(ignorestatus(cmd))))
    end
    script = joinpath(STANDALONE_DIR, endswith(target, ".jl") ? target : "$target.jl")
    if isfile(script)
        cmd = `$(Base.julia_cmd()) --threads=$threads $script $args`
        exit(exit_status(run(ignorestatus(cmd))))
    end
    println(stderr, "Unknown tool or script '$target'. Run `julia run.jl --list`.")
    exit(1)
end

function main(args::Vector{String} = ARGS)
    threads = get(ENV, "JULIA_NUM_THREADS", "auto")
    if length(args) >= 2 && args[1] == "--threads"
        threads = args[2]
        args = args[3:end]
    end
    if isempty(args) || args[1] in ("-h", "--help", "help")
        print_help()
        return
    end
    action = args[1]
    if action in ("-l", "--list", "list")
        list_tools()
    else
        dispatch(action, args[2:end], threads)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
