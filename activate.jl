#!/usr/bin/env julia
# ==============================================================================
# Toolbox Environment Activation & Orchestration Dispatcher
# ==============================================================================

using Pkg

"""
    activate_subenvironment(subdir::String; instantiate::Bool=true)

Silently activates and optionally instantiates an isolated sub-environment within this repository.
"""
function activate_subenvironment(subdir::String; instantiate::Bool=true)
    env_path = joinpath(@__DIR__, subdir)
    if !isdir(env_path) || !isfile(joinpath(env_path, "Project.toml"))
        error("Sub-environment directory not found or missing Project.toml: $subdir")
    end
    Pkg.activate(env_path; io=devnull)
    if instantiate
        Pkg.instantiate(; io=devnull)
    end
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    target = isempty(ARGS) ? "hardware-diagnostics" : ARGS[1]
    activate_subenvironment(target)
    println("Successfully activated sub-environment: ", target)
end
