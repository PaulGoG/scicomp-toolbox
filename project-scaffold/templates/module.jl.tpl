module <<PKG>>

using DrWatson: datadir
using TOML: TOML

export load_configuration, run_directory

"""
    load_configuration(path::AbstractString) -> Dict{String, Any}

Read the TOML configuration of a run. Throws `ArgumentError` when there is no file at
`path`. The validation of keys, types and bounds belongs here.
"""
function load_configuration(path::AbstractString)
    isfile(path) || throw(ArgumentError("no configuration at $path"))
    return TOML.parsefile(path)
end

"""
    run_directory(name::AbstractString) -> String

Directory of the outputs of the run `name`: `data/runs/<name>` below the project.
"""
run_directory(name::AbstractString) = datadir("runs", name)

end
