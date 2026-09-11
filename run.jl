#!/usr/bin/env julia
# run.jl — workbench dispatcher: lists, executes and scaffolds tools.
#
#   julia run.jl <tool> [args...]              run a sub-environment tool or a standalone script
#   julia run.jl --threads N <tool> [args...]  Julia thread count of the child process
#                                              (default: JULIA_NUM_THREADS, else auto)
#   julia run.jl --list                        catalog of tools and standalone scripts
#   julia run.jl --new <name>                  scaffold a sub-environment tool
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
  julia run.jl --new <name>                  scaffold a sub-environment tool
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
    instantiate_environment(dir::String)

Resolve and install the environment in `dir` in a child process, so that a fresh clone
runs without manual setup. Raises an error when instantiation fails.
"""
function instantiate_environment(dir::String)
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$dir -e 'using Pkg; Pkg.instantiate(; io = devnull)'`
    process = run(ignorestatus(cmd))
    process.exitcode == 0 || error(
        "instantiation of environment '$(basename(dir))' failed (exit $(process.exitcode))",
    )
    return nothing
end

"""
    dispatch(target::String, args::Vector{String}, threads::String)

Run a tool (`<name>/<name>.jl` with its own project) or a standalone script, forwarding
`args`; the child's exit status becomes this process's exit status.
"""
function dispatch(target::String, args::Vector{String}, threads::String)
    tools = Dict(find_subenvironments())
    if haskey(tools, target)
        entry = tools[target]
        isempty(entry) && error("tool '$target' has no entry script $target/$target.jl")
        dir = joinpath(REPO_ROOT, target)
        instantiate_environment(dir)
        cmd = `$(Base.julia_cmd()) --threads=$threads --project=$dir $entry $args`
        exit(run(ignorestatus(cmd)).exitcode)
    end
    script = joinpath(STANDALONE_DIR, endswith(target, ".jl") ? target : "$target.jl")
    if isfile(script)
        cmd = `$(Base.julia_cmd()) --threads=$threads $script $args`
        exit(run(ignorestatus(cmd)).exitcode)
    end
    println(stderr, "Unknown tool or script '$target'. Run `julia run.jl --list`.")
    exit(1)
end

"""
    scaffold_tool(name::String)

Create `<name>/` as a plain project environment with an activation script, a validated
configuration, an entry script `<name>.jl`, a test suite and a README.
"""
function scaffold_tool(name::String)
    if !occursin(r"^[a-z][a-z0-9-]*$", name)
        println(stderr, "Tool names are lowercase kebab-case identifiers, got '$name'.")
        exit(1)
    end
    dir = joinpath(REPO_ROOT, name)
    if isdir(dir)
        println(stderr, "Directory already exists: $dir")
        exit(1)
    end
    mkdir(dir)
    mkdir(joinpath(dir, "test"))

    write(
        joinpath(dir, "Project.toml"),
        """
[deps]
TOML = "fa267f1f-6049-4f14-aa54-33bafae1ed76"

[compat]
TOML = "1"
julia = "1.12"
""",
    )

    write(
        joinpath(dir, "activate.jl"),
        """
using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)
""",
    )

    write(
        joinpath(dir, "config.toml"),
        """
# Configuration of $name

[parameters]
verbose = true  # boolean
""",
    )

    write(
        joinpath(dir, "$name.jl"),
        """
#!/usr/bin/env julia
# $name — entry point.
#
#   julia run.jl $name [--config PATH]

using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)

using TOML: TOML

\"\"\"
    load_config(path::AbstractString) -> Dict{String, Any}

Parse the TOML configuration and enforce its constraints, raising an `ArgumentError`
that names the offending key.
\"\"\"
function load_config(path::AbstractString)
    isfile(path) || throw(ArgumentError("configuration file not found: \$path"))
    config = TOML.parsefile(path)
    parameters = get(config, "parameters", Dict{String, Any}())
    verbose = get(parameters, "verbose", true)
    verbose isa Bool ||
        throw(ArgumentError("[parameters].verbose must be a boolean, got \$(repr(verbose))"))
    return config
end

function main(args::Vector{String} = ARGS)
    config_path = joinpath(@__DIR__, "config.toml")
    i = 1
    while i <= length(args)
        if args[i] == "--config" && i < length(args)
            config_path = args[i + 1]
            i += 2
        else
            throw(ArgumentError("unknown argument '\$(args[i])'"))
        end
    end
    config = load_config(config_path)
    println("$name: configuration loaded from ", config_path)
    return config
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
""",
    )

    write(
        joinpath(dir, "test", "runtests.jl"),
        """
using Test

include(joinpath(@__DIR__, "..", "$name.jl"))

@testset "$name" begin
    config = load_config(joinpath(@__DIR__, "..", "config.toml"))
    @test haskey(config, "parameters")
    @test_throws ArgumentError load_config(joinpath(@__DIR__, "missing.toml"))
end
""",
    )

    write(
        joinpath(dir, "README.md"),
        """
# $name

One-sentence statement of what the tool computes.

```
$name/
├── activate.jl      # environment activation
├── config.toml      # parameters (validated on load)
├── $name.jl         # entry point
├── Manifest.toml    # pinned dependencies, written by the first run
├── Project.toml     # dependencies and compat bounds
├── README.md
└── test/
    └── runtests.jl
```

## Usage

```bash
julia run.jl $name                       # through the dispatcher
julia --project=$name $name/$name.jl     # directly
julia test.jl $name                      # tests
```
""",
    )

    println(
        "Created $name/ (Project.toml, activate.jl, config.toml, $name.jl, test/runtests.jl, README.md).",
    )
    println(
        "Add dependencies with: julia --project=$name -e 'using Pkg; Pkg.add(\"PackageName\")'",
    )
    println("Run with:              julia run.jl $name")
    println("The first run writes $name/Manifest.toml; commit it together with the tool.")
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
    elseif action in ("-n", "--new", "new")
        length(args) >= 2 || (println(stderr, "Usage: julia run.jl --new <name>"); exit(1))
        scaffold_tool(args[2])
    else
        dispatch(action, args[2:end], threads)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
