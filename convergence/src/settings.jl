# Validated configuration: the tables of config.toml mapped onto a StudySettings. Every
# constraint stated in config.toml is enforced here.

const FORMATS = ("pdf", "png", "svg")

"""
    StudySettings

Validated configuration: confidence level, number of coarsest levels left out of the fit
and safety factor of the grid convergence index (`[fit]`); figure format, width [mm],
raster resolution [px/pt], font size [pt], reference orders, axis labels and output
directory (`[figures]`); directory of the CSV export (`[output]`).
"""
struct StudySettings
    confidence_level::Float64
    skip_coarsest::Int
    safety_factor::Float64
    format::String
    width_mm::Float64
    px_per_unit::Int
    fontsize_pt::Float64
    reference_orders::Vector{Float64}
    xlabel::String
    ylabel::String
    figure_directory::String
    csv_directory::String
end

function reject_unknown_keys(table::AbstractDict, known, context::AbstractString)
    for key in keys(table)
        key in known || throw(
            ArgumentError("unknown key '$key' at $context; allowed: $(join(known, ", "))"),
        )
    end
    return nothing
end

function section(raw::AbstractDict, name::AbstractString)
    table = get(raw, name, Dict{String, Any}())
    table isa AbstractDict || throw(ArgumentError("[$name] must be a table"))
    return table
end

"Whether `value` is a real number; `Bool` never counts as one."
is_number(value) = value isa Real && !(value isa Bool)

function real_value(table::AbstractDict, key::AbstractString, default::Real, context)
    value = get(table, key, default)
    (is_number(value) && isfinite(value)) ||
        throw(ArgumentError("$context.$key must be a number, got $(repr(value))"))
    return Float64(value)
end

function integer_value(table::AbstractDict, key::AbstractString, default::Integer, context)
    value = get(table, key, default)
    (value isa Integer && !(value isa Bool)) ||
        throw(ArgumentError("$context.$key must be an integer, got $(repr(value))"))
    return Int(value)
end

function nonempty_string(
    table::AbstractDict,
    key::AbstractString,
    default::AbstractString,
    context,
)
    value = get(table, key, default)
    (value isa AbstractString && !isempty(strip(value))) ||
        throw(ArgumentError("$context.$key must be a non-empty string"))
    return String(value)
end

"""
    validate_settings(raw::AbstractDict) -> StudySettings

Enforce the schema of the configuration tables `[fit]`, `[figures]` and `[output]`;
absent keys take the defaults of the shipped `config.toml`. Integers are accepted where
floats are expected, booleans never as numbers.

Returns a [`StudySettings`](@ref). Throws an `ArgumentError` naming the offending key for
unknown keys, wrong types and values out of bounds.
"""
function validate_settings(raw::AbstractDict)
    reject_unknown_keys(raw, ("fit", "figures", "output"), "top level")
    fit = section(raw, "fit")
    figures = section(raw, "figures")
    output = section(raw, "output")
    reject_unknown_keys(
        fit,
        ("confidence_level", "skip_coarsest", "safety_factor"),
        "[fit]",
    )
    reject_unknown_keys(
        figures,
        (
            "format",
            "width_mm",
            "px_per_unit",
            "fontsize_pt",
            "reference_orders",
            "xlabel",
            "ylabel",
            "output_directory",
        ),
        "[figures]",
    )
    reject_unknown_keys(output, ("csv_directory",), "[output]")

    confidence_level = real_value(fit, "confidence_level", 0.95, "[fit]")
    0 < confidence_level < 1 || throw(
        ArgumentError("[fit].confidence_level must lie in (0, 1), got $confidence_level"),
    )
    skip_coarsest = integer_value(fit, "skip_coarsest", 0, "[fit]")
    skip_coarsest >= 0 ||
        throw(ArgumentError("[fit].skip_coarsest must be >= 0, got $skip_coarsest"))
    safety_factor = real_value(fit, "safety_factor", 1.25, "[fit]")
    safety_factor >= 1 ||
        throw(ArgumentError("[fit].safety_factor must be >= 1, got $safety_factor"))

    format = get(figures, "format", "pdf")
    (format isa AbstractString && format in FORMATS) || throw(
        ArgumentError(
            "[figures].format must be one of: $(join(FORMATS, " | ")), got $(repr(format))",
        ),
    )
    width_mm = real_value(figures, "width_mm", 86.0, "[figures]")
    60 <= width_mm <= 300 ||
        throw(ArgumentError("[figures].width_mm must be in [60, 300], got $width_mm"))
    px_per_unit = integer_value(figures, "px_per_unit", 5, "[figures]")
    px_per_unit >= 1 ||
        throw(ArgumentError("[figures].px_per_unit must be >= 1, got $px_per_unit"))
    fontsize_pt = real_value(figures, "fontsize_pt", 9.0, "[figures]")
    6 <= fontsize_pt <= 14 ||
        throw(ArgumentError("[figures].fontsize_pt must be in [6, 14], got $fontsize_pt"))
    reference_orders = get(figures, "reference_orders", Float64[])
    (
        reference_orders isa AbstractVector &&
        all(p -> is_number(p) && isfinite(p) && p > 0, reference_orders)
    ) || throw(
        ArgumentError("[figures].reference_orders must be a list of real numbers > 0"),
    )
    xlabel = nonempty_string(figures, "xlabel", "Step size h", "[figures]")
    ylabel = nonempty_string(figures, "ylabel", "Error", "[figures]")
    figure_directory = nonempty_string(figures, "output_directory", "plots", "[figures]")
    csv_directory = nonempty_string(output, "csv_directory", "data", "[output]")
    return StudySettings(
        confidence_level,
        skip_coarsest,
        safety_factor,
        String(format),
        width_mm,
        px_per_unit,
        fontsize_pt,
        Float64[p for p in reference_orders],
        xlabel,
        ylabel,
        figure_directory,
        csv_directory,
    )
end

"""
    load_settings(path::AbstractString) -> StudySettings

Parse and validate a configuration file with [`validate_settings`](@ref). Throws an
`ArgumentError` naming the path when the file is missing or is not valid TOML.
"""
function load_settings(path::AbstractString)
    isfile(path) || throw(ArgumentError("configuration file not found: $path"))
    raw = try
        TOML.parsefile(path)
    catch err
        err isa TOML.ParserError || rethrow()
        throw(ArgumentError("$path: $(sprint(showerror, err))"))
    end
    return validate_settings(raw)
end
