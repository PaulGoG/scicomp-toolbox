# Entry point of the pipeline: reads a TOML configuration and runs it; without an
# argument, the smallest configuration.
#
#   julia scripts/run.jl [CONFIG.toml]

include(joinpath(@__DIR__, "..", "activate.jl"))

using <<PKG>>: load_configuration, run_directory

function main(args::Vector{String} = ARGS)
    length(args) <= 1 || throw(ArgumentError("usage: julia scripts/run.jl [CONFIG.toml]"))
    path = isempty(args) ? joinpath(@__DIR__, "..", "configs", "minimal.toml") : only(args)
    configuration = load_configuration(path)
    @info "Configuration read" path sections = sort!(collect(keys(configuration)))
    @info "Outputs of this run belong in" directory = run_directory("minimal")
    return configuration
end

abspath(PROGRAM_FILE) == @__FILE__ && main()
