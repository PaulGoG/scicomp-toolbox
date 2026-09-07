#!/usr/bin/env julia
# ==============================================================================
# run.jl — Universal CLI Dispatcher for Scientific Computing Workbench
# ==============================================================================
# Dispatches execution to isolated sub-environments or standalone scripts.
# Supports listing available tools and scaffolding new isolated sub-environments.
# ==============================================================================

using UUIDs
using Printf

const REPO_ROOT = @__DIR__
const EXCLUDED_DIRS =
    Set(["test", ".git", ".github", "paper", "notes", "context", "standalone"])

"""
    find_subenvironments() -> Vector{Pair{String, String}}

Discovers all sub-environments (directories containing a Project.toml).
Returns pairs of (subdir_name => entry_script_path).
"""
function find_subenvironments()
    subenvs = Pair{String, String}[]
    for item in readdir(REPO_ROOT)
        item in EXCLUDED_DIRS && continue
        full_path = joinpath(REPO_ROOT, item)
        if isdir(full_path) && isfile(joinpath(full_path, "Project.toml"))
            # Locate primary entry script
            entry_script = joinpath(full_path, "$item.jl")
            if !isfile(entry_script)
                # Search for any .jl file excluding activate.jl
                jl_candidates = filter(
                    f -> endswith(f, ".jl") && f != "activate.jl",
                    readdir(full_path),
                )
                entry_script =
                    isempty(jl_candidates) ? "" : joinpath(full_path, first(jl_candidates))
            end
            push!(subenvs, item => entry_script)
        end
    end
    return subenvs
end

"""
    find_standalone_scripts() -> Vector{String}

Discovers all standalone scripts in the `standalone/` directory.
"""
function find_standalone_scripts()
    standalone_dir = joinpath(REPO_ROOT, "standalone")
    !isdir(standalone_dir) && return String[]
    return filter(f -> endswith(f, ".jl"), readdir(standalone_dir))
end

"""
    extract_description(path::String) -> String

Extracts a brief summary from a README or top-level file comments.
"""
function extract_description(dir_path::String)
    readme = joinpath(dir_path, "README.md")
    if isfile(readme)
        lines = readlines(readme)
        for line in lines
            trimmed = strip(line)
            if !startswith(trimmed, "#") && !startswith(trimmed, "[![") && !isempty(trimmed)
                return length(trimmed) > 80 ? first(trimmed, 77) * "..." : trimmed
            end
        end
    end
    return "No description available."
end

"""
    print_help()

Displays CLI usage guidance.
"""
function print_help()
    println("""
Scientific Computing Scripting Workbench Dispatcher

Usage:
  julia run.jl <tool-or-script> [args...]    Execute an isolated tool or standalone script
  julia run.jl --list                       List all cataloged tools and scripts
  julia run.jl --new <tool-name>            Scaffold a new sub-environment tool
  julia run.jl --help                       Show this help message

Examples:
  julia run.jl hardware-diagnostics --quick
  julia run.jl sysinfo
  julia run.jl --new data-converter
""")
end

"""
    list_tools()

Prints a structured overview of all tools and standalone scripts in the repository.
"""
function list_tools()
    println("="^80)
    println(" Scientific Computing Scripting Catalog")
    println("="^80)

    subenvs = find_subenvironments()
    println("\n[Isolated Sub-Environments]")
    if isempty(subenvs)
        println("  (None found)")
    else
        for (name, entry) in subenvs
            desc = extract_description(joinpath(REPO_ROOT, name))
            @printf("  • %-24s : %s\n", name, desc)
            entry_rel = isempty(entry) ? "N/A" : relpath(entry, REPO_ROOT)
            @printf("    └─ Entry: %s\n", entry_rel)
        end
    end

    scripts = find_standalone_scripts()
    println("\n[Standalone Scripts (standalone/)]")
    if isempty(scripts)
        println("  (None found)")
    else
        for s in scripts
            script_name = replace(s, r"\.jl$" => "")
            @printf("  • %-24s : julia run.jl %s\n", script_name, script_name)
        end
    end

    println("\n" * "="^80)
end

"""
    scaffold_tool(name::String)

Creates a new isolated sub-environment directory with standard boilerplate.
"""
function scaffold_tool(name::String)
    tool_dir = joinpath(REPO_ROOT, name)
    if isdir(tool_dir)
        error("Directory already exists: $tool_dir")
    end

    println("Scaffolding new sub-environment: $name")
    mkdir(tool_dir)
    mkdir(joinpath(tool_dir, "test"))

    # 1. Project.toml
    project_toml = joinpath(tool_dir, "Project.toml")
    write(
        project_toml,
        """
name = "$name"
uuid = "$(UUIDs.uuid4())"
version = "0.1.0"

[deps]

[compat]
julia = "1.10, 1.11, 1.12"
""",
    )

    # 2. activate.jl
    activate_jl = joinpath(tool_dir, "activate.jl")
    write(
        activate_jl,
        """
using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)
""",
    )

    # 3. config.toml
    config_toml = joinpath(tool_dir, "config.toml")
    write(
        config_toml,
        """
# Configuration for $name

[parameters]
# Add domain-specific parameters here
verbose = true
""",
    )

    # 4. Primary executable script
    script_jl = joinpath(tool_dir, "$name.jl")
    write(
        script_jl,
        """
#!/usr/bin/env julia
# ==============================================================================
# $name — Computational Script
# ==============================================================================

using TOML

function main(args::Vector{String} = String[])
    println("Executing $name with arguments: ", args)
    config_file = joinpath(@__DIR__, "config.toml")
    if isfile(config_file)
        cfg = TOML.parsefile(config_file)
        println("Loaded configuration: ", cfg)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
""",
    )

    # 5. test/runtests.jl
    test_jl = joinpath(tool_dir, "test", "runtests.jl")
    write(
        test_jl,
        """
#!/usr/bin/env julia
using Test

@testset "$name Tests" begin
    @test 1 + 1 == 2
    @test isfile(joinpath(@__DIR__, "..", "config.toml"))
end
""",
    )

    # 6. README.md
    readme_md = joinpath(tool_dir, "README.md")
    write(
        readme_md,
        """
# $name

Domain-specific computational script.

## Usage

```bash
# Execute via workbench dispatcher
julia run.jl $name

# Or directly with dedicated project
julia --project=$name $name/$name.jl
```
""",
    )

    println("✓ Successfully created sub-environment: $name/")
    println("  • Project.toml      : Isolated package environment")
    println("  • activate.jl       : Silent Pkg environment activator")
    println("  • config.toml       : Parameter configuration")
    println("  • $name.jl       : Primary execution script")
    println("  • test/runtests.jl  : Unit test suite")
    println("  • README.md         : Documentation\n")
    println("Next steps:")
    println(
        "  1. Add dependencies: julia --project=$name -e 'using Pkg; Pkg.add(\"PackageName\")'",
    )
    println("  2. Run tool        : julia run.jl $name")
end

"""
    dispatch(target::String, args::Vector{String})

Dispatches execution to the specified tool or script.
"""
function dispatch(target::String, args::Vector{String})
    # Check if target is a sub-environment directory
    tool_dir = joinpath(REPO_ROOT, target)
    if isdir(tool_dir) && isfile(joinpath(tool_dir, "Project.toml"))
        subenvs = Dict(find_subenvironments())
        entry = get(subenvs, target, "")
        if isempty(entry) || !isfile(entry)
            error(
                "Sub-environment '$target' does not contain a primary execution script (.jl).",
            )
        end
        cmd = `$(Base.julia_cmd()) --project=$tool_dir $entry $args`
        exit(Base.run(cmd).exitcode)
    end

    # Check if target is a standalone script
    standalone_dir = joinpath(REPO_ROOT, "standalone")
    standalone_candidates = [
        joinpath(standalone_dir, target),
        joinpath(standalone_dir, "$target.jl"),
        joinpath(REPO_ROOT, target),
        joinpath(REPO_ROOT, "$target.jl"),
    ]

    for candidate in standalone_candidates
        if isfile(candidate)
            cmd = `$(Base.julia_cmd()) $candidate $args`
            exit(Base.run(cmd).exitcode)
        end
    end

    println(stderr, "Error: Unknown tool or script '$target'.")
    println(stderr, "Run 'julia run.jl --list' to view available catalog entries.")
    exit(1)
end

function main(args::Vector{String} = ARGS)
    if isempty(args) || args[1] in ("-h", "--help", "help")
        print_help()
        return
    end

    action = args[1]
    if action in ("-l", "--list", "list")
        list_tools()
        return
    elseif action in ("-n", "--new", "new")
        if length(args) < 2
            println(
                stderr,
                "Error: Missing tool name. Usage: julia run.jl --new <tool-name>",
            )
            exit(1)
        end
        scaffold_tool(args[2])
        return
    else
        dispatch(action, args[2:end])
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
