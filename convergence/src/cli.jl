# Command line: input CSV, per-series fit, report, CSV export and figure.

"Directory of the tool; relative configuration paths resolve against it."
const TOOL_DIR = normpath(joinpath(@__DIR__, ".."))

function numeric_column(file::CSV.File, name::Symbol, path::AbstractString)
    column = getproperty(file, name)
    T = eltype(column)
    (T <: Real && !(T <: Bool)) || throw(
        ArgumentError("column \"$name\" of $path must be numeric without missing values"),
    )
    return Float64[x for x in column]
end

"""
    read_series(path::AbstractString)
        -> Tuple{Vector{Float64}, Vector{Pair{String, Vector{Float64}}}}

Read a convergence table: a header row and one row per level, with the step sizes in the
column named `h` and one series in every other column, each numeric without missing
cells.

Returns the step sizes and the series as `name => values` pairs in column order. Throws
`ArgumentError` naming the file or the column when the file is missing, lacks the
column `h`, holds fewer than two rows or no series, or has a non-numeric column.
"""
function read_series(path::AbstractString)
    isfile(path) || throw(ArgumentError("input file not found: $path"))
    file = CSV.File(path)
    columns = propertynames(file)
    :h in columns || throw(ArgumentError("$path has no column named \"h\""))
    length(file) >= 2 ||
        throw(ArgumentError("$path must hold at least two rows, got $(length(file))"))
    h = numeric_column(file, :h, path)
    series = Pair{String, Vector{Float64}}[]
    for name in columns
        name === :h && continue
        push!(series, String(name) => numeric_column(file, name, path))
    end
    isempty(series) &&
        throw(ArgumentError("$path holds no series besides the column \"h\""))
    return h, series
end

csv_text(value::AbstractString) = "\"" * replace(value, "\"" => "\"\"") * "\""

"""
    write_csv(path, estimates) -> path

The levels of every estimate as a tidy CSV file with the columns
`series,h,error,order,fitted`; the order of the coarsest level is empty.
"""
function write_csv(path::AbstractString, estimates::Vector{Pair{String, OrderEstimate}})
    open(path, "w") do out
        println(out, "series,h,error,order,fitted")
        for (name, estimate) in estimates, level in estimate.levels
            order = level.order
            println(
                out,
                join(
                    (
                        csv_text(name),
                        string(level.h),
                        string(level.error),
                        order === nothing ? "" : string(order),
                        string(level.fitted),
                    ),
                    ",",
                ),
            )
        end
    end
    return path
end

function usage(io::IO = stdout)
    print(
        io,
        """
        convergence — observed order of accuracy from an error sequence

        Usage:
          julia run.jl convergence FILE [options]

          FILE                    CSV file: one column h with the step sizes and one error
                                  column per series, numeric without missing cells
          --skip N                coarsest levels left out of the fit, integer >= 0
                                  (default: [fit].skip_coarsest)
          --confidence X          coverage of the interval of the order, in (0, 1)
                                  (default: [fit].confidence_level)
          --quantity              the series hold values of a quantity of interest: the
                                  three finest levels give the three-grid estimate, and the
                                  error of each level is its distance from the extrapolated
                                  value
          --reference-orders L    comma-separated slopes > 0 of the reference lines
                                  (default: [figures].reference_orders)
          --xlabel TEXT           x-axis label (default: [figures].xlabel)
          --ylabel TEXT           y-axis label (default: [figures].ylabel)
          --format FMT            pdf | png | svg (default: [figures].format)
          --out-dir DIR           directory of the CSV and the figure, relative to the
                                  working directory (default: [output].csv_directory and
                                  [figures].output_directory, relative to the tool)
          --no-csv                write no CSV file
          --no-figure             write no figure
          --config PATH           configuration file (default: config.toml next to the tool)
          -h, --help
        """,
    )
    return nothing
end

function option_value(args::Vector{String}, i::Int, flag::AbstractString)
    i < length(args) || throw(ArgumentError("$flag requires a value"))
    return args[i + 1]
end

function parse_orders(text::AbstractString)
    orders = Float64[]
    for item in split(text, ',')
        value = tryparse(Float64, strip(item))
        (value === nothing || !isfinite(value) || value <= 0) && throw(
            ArgumentError(
                "--reference-orders must be a comma-separated list of reals > 0, got '$text'",
            ),
        )
        push!(orders, value)
    end
    return orders
end

function nonempty_text(text::AbstractString, flag::AbstractString)
    isempty(strip(text)) && throw(ArgumentError("$flag must not be empty"))
    return String(text)
end

"""
    main(args::Vector{String} = ARGS; io::IO = stdout) -> Union{NamedTuple, Nothing}

Parse the command line (see `--help`), fit the order of every series of the input CSV,
print the tables to `io`, write the CSV of the levels and the figure. With `--quantity`
the three finest levels of each series first go through [`grid_convergence`](@ref),
whose report is printed, and the errors become the distances |q - q_ext| from the
extrapolated value.

Returns `(; estimates, grids, csv, figure)`: the estimates and three-grid results as
`name => result` pairs (`grids` empty without `--quantity`) and the paths written
(`nothing` for an output not written); `nothing` after `--help`. Invalid arguments,
configurations and inputs throw an `ArgumentError`.
"""
function main(args::Vector{String} = ARGS; io::IO = stdout)
    config_path = joinpath(TOOL_DIR, "config.toml")
    file = nothing
    skip = nothing
    confidence = nothing
    quantity = false
    reference_orders = nothing
    xlabel = nothing
    ylabel = nothing
    format = nothing
    out_dir = nothing
    write_table = true
    draw_figure = true
    i = 1
    while i <= length(args)
        argument = args[i]
        if argument in ("-h", "--help")
            usage(io)
            return nothing
        elseif argument == "--skip"
            text = option_value(args, i, argument)
            skip = tryparse(Int, text)
            (skip === nothing || skip < 0) &&
                throw(ArgumentError("--skip must be an integer >= 0, got '$text'"))
            i += 1
        elseif argument == "--confidence"
            text = option_value(args, i, argument)
            confidence = tryparse(Float64, text)
            (confidence === nothing || !(0 < confidence < 1)) &&
                throw(ArgumentError("--confidence must lie in (0, 1), got '$text'"))
            i += 1
        elseif argument == "--quantity"
            quantity = true
        elseif argument == "--reference-orders"
            reference_orders = parse_orders(option_value(args, i, argument))
            i += 1
        elseif argument == "--xlabel"
            xlabel = nonempty_text(option_value(args, i, argument), argument)
            i += 1
        elseif argument == "--ylabel"
            ylabel = nonempty_text(option_value(args, i, argument), argument)
            i += 1
        elseif argument == "--format"
            text = lowercase(option_value(args, i, argument))
            text in FORMATS || throw(
                ArgumentError(
                    "--format must be one of: $(join(FORMATS, " | ")), got '$text'",
                ),
            )
            format = text
            i += 1
        elseif argument == "--out-dir"
            out_dir = option_value(args, i, argument)
            i += 1
        elseif argument == "--no-csv"
            write_table = false
        elseif argument == "--no-figure"
            draw_figure = false
        elseif argument == "--config"
            config_path = option_value(args, i, argument)
            i += 1
        elseif startswith(argument, "-")
            throw(ArgumentError("unknown command-line argument '$argument'; see --help"))
        elseif file === nothing
            file = argument
        else
            throw(ArgumentError("only one input file may be given, got '$argument'"))
        end
        i += 1
    end
    file === nothing && throw(ArgumentError("an input CSV file is required; see --help"))

    configured = load_settings(config_path)
    settings = StudySettings(
        something(confidence, configured.confidence_level),
        something(skip, configured.skip_coarsest),
        configured.safety_factor,
        something(format, configured.format),
        configured.width_mm,
        configured.px_per_unit,
        configured.fontsize_pt,
        something(reference_orders, configured.reference_orders),
        something(xlabel, configured.xlabel),
        something(ylabel, configured.ylabel),
        configured.figure_directory,
        configured.csv_directory,
    )
    h, series = read_series(file)

    estimates = Pair{String, OrderEstimate}[]
    grids = Pair{String, GridConvergence}[]
    for (k, (name, values)) in enumerate(series)
        k > 1 && println(io)
        errors = values
        if quantity
            length(h) >= 3 || throw(
                ArgumentError(
                    "--quantity requires at least three levels, got $(length(h))",
                ),
            )
            finest = sortperm(h)[1:3]
            grid = grid_convergence(
                h[finest],
                values[finest];
                safety_factor = settings.safety_factor,
            )
            push!(grids, name => grid)
            convergence_table(io, grid; label = name)
            println(io)
            errors = abs.(values .- grid.extrapolated)
        end
        estimate = fit_order(
            h,
            errors;
            confidence = settings.confidence_level,
            skip = settings.skip_coarsest,
        )
        push!(estimates, name => estimate)
        convergence_table(io, estimate; label = name)
    end

    # configuration paths resolve against the tool directory, command-line paths against
    # the working directory
    resolve(path) = isabspath(path) ? path : normpath(joinpath(TOOL_DIR, path))
    csv_directory = out_dir === nothing ? resolve(settings.csv_directory) : abspath(out_dir)
    figure_directory =
        out_dir === nothing ? resolve(settings.figure_directory) : abspath(out_dir)
    stem = first(splitext(basename(file)))
    csv_path = nothing
    if write_table
        mkpath(csv_directory)
        stamp = Libc.strftime("%Y-%m-%d_%H-%M-%S", time())
        target = joinpath(csv_directory, "convergence_$(stem)_$(stamp).csv")
        csv_path = write_csv(safe_filepath(target), estimates)
        println(io)
        println(io, "CSV written to ", csv_path)
    end
    figure_path = nothing
    if draw_figure
        mkpath(figure_directory)
        set_theme!(publication_theme(settings.fontsize_pt))
        fig = convergence_figure(
            estimates;
            reference_orders = settings.reference_orders,
            xlabel = settings.xlabel,
            ylabel = settings.ylabel,
            width_mm = settings.width_mm,
            fontsize_pt = settings.fontsize_pt,
        )
        target = joinpath(figure_directory, "convergence_$(stem).$(settings.format)")
        figure_path = save_figure(fig, target, settings)
        write_table || println(io)
        println(io, "Figure written to ", figure_path)
    end
    return (; estimates, grids, csv = csv_path, figure = figure_path)
end
