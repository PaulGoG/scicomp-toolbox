#!/usr/bin/env julia
# plot-benchmarks — publication figures from hardware-diagnostics datasets: the CPU
# thread-scaling sweep (speedup and parallel efficiency) and the throughput of every
# engine per element type and device.
#
#   julia run.jl plot-benchmarks [--input FILE.csv] [--out-dir DIR] [--format pdf|png|svg]
#                                [--size N] [--config PATH]

using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)

using CSV: CSV
using CairoMakie
using DataFrames: DataFrame, nrow, sort
using MathTeXEngine: texfont
using Printf: @sprintf
using TOML: TOML

const TYPE_ORDER = [
    "Float16",
    "Float32",
    "Float64",
    "ComplexF32",
    "ComplexF64",
    "Int8",
    "Int16",
    "Int32",
    "Int64",
]
const ENGINE_ORDER = ["blas", "ka", "ka_tiled"]
const ENGINE_LABELS = Dict(
    "blas" => "Library (mul!)",
    "ka" => "KernelAbstractions, naive",
    "ka_tiled" => "KernelAbstractions, tiled",
)
const REQUIRED_COLUMNS = [
    "device_type",
    "backend",
    "engine",
    "library",
    "device_name",
    "data_type",
    "matrix_dim",
    "blas_threads",
    "exceeds_physical_cores",
    "throughput_gops",
    "speedup_vs_1t",
    "parallel_efficiency_pct",
    "status",
]
const PT_PER_MM = 72 / 25.4
const FORMATS = ("pdf", "png", "svg")

"""
    FigureSettings

Validated `[input]` and `[figures]` tables of `config.toml`.
"""
struct FigureSettings
    dataset_directory::String
    format::String
    width_mm::Float64
    px_per_unit::Int
    fontsize_pt::Float64
    output_directory::String
end

function reject_unknown_keys(table::AbstractDict, known, context::String)
    for key in keys(table)
        key in known || throw(
            ArgumentError(
                "unknown key '$key' in [$context]; allowed: $(join(known, ", "))",
            ),
        )
    end
    return nothing
end

"""
    load_settings(path::AbstractString) -> FigureSettings

Parse and validate the configuration file; fails with an `ArgumentError` naming the key.
"""
function load_settings(path::AbstractString)
    isfile(path) || throw(ArgumentError("configuration file not found: $path"))
    raw = TOML.parsefile(path)
    reject_unknown_keys(raw, ("input", "figures"), "top level")
    input = get(raw, "input", Dict{String, Any}())
    figures = get(raw, "figures", Dict{String, Any}())
    reject_unknown_keys(input, ("dataset_directory",), "input")
    reject_unknown_keys(
        figures,
        ("format", "width_mm", "px_per_unit", "fontsize_pt", "output_directory"),
        "figures",
    )

    dataset_directory = get(input, "dataset_directory", "../hardware-diagnostics/data")
    dataset_directory isa AbstractString ||
        throw(ArgumentError("[input].dataset_directory must be a string"))
    format = lowercase(string(get(figures, "format", "pdf")))
    format in FORMATS || throw(
        ArgumentError(
            "[figures].format must be one of: $(join(FORMATS, " | ")), got '$format'",
        ),
    )
    width_mm = get(figures, "width_mm", 178.0)
    (width_mm isa Real && 60 <= width_mm <= 300) || throw(
        ArgumentError("[figures].width_mm must be in [60, 300], got $(repr(width_mm))"),
    )
    px_per_unit = get(figures, "px_per_unit", 5)
    (px_per_unit isa Integer && px_per_unit >= 1) || throw(
        ArgumentError(
            "[figures].px_per_unit must be an integer >= 1, got $(repr(px_per_unit))",
        ),
    )
    fontsize_pt = get(figures, "fontsize_pt", 9.0)
    (fontsize_pt isa Real && 6 <= fontsize_pt <= 14) || throw(
        ArgumentError("[figures].fontsize_pt must be in [6, 14], got $(repr(fontsize_pt))"),
    )
    output_directory = get(figures, "output_directory", "plots")
    output_directory isa AbstractString ||
        throw(ArgumentError("[figures].output_directory must be a string"))
    return FigureSettings(
        String(dataset_directory),
        format,
        Float64(width_mm),
        Int(px_per_unit),
        Float64(fontsize_pt),
        String(output_directory),
    )
end

"""
    latest_dataset(directory::AbstractString) -> Union{String, Nothing}

Path of the newest `hardware_benchmark_*.csv` in `directory` (the file names carry the
run timestamp), or `nothing`.
"""
function latest_dataset(directory::AbstractString)
    isdir(directory) || return nothing
    candidates = filter(readdir(directory)) do name
        startswith(name, "hardware_benchmark_") && endswith(name, ".csv")
    end
    isempty(candidates) && return nothing
    return joinpath(directory, maximum(candidates))
end

"""
    read_dataset(path::AbstractString) -> DataFrame

Read a hardware-diagnostics CSV dataset; empty cells become `missing`.
"""
function read_dataset(path::AbstractString)
    isfile(path) || throw(ArgumentError("dataset not found: $path"))
    df = CSV.read(path, DataFrame; missingstring = "")
    absent = filter(column -> !(column in names(df)), REQUIRED_COLUMNS)
    isempty(absent) ||
        throw(ArgumentError("dataset $path lacks the columns: $(join(absent, ", "))"))
    return df
end

"""
    publication_theme(fontsize_pt::Real) -> Theme

Computer Modern fonts, boxed axes, faint dashed grid, no minor ticks.
"""
function publication_theme(fontsize_pt::Real)
    return Theme(
        fonts = (;
            regular = texfont(:text),
            bold = texfont(:bold),
            italic = texfont(:italic),
        ),
        fontsize = fontsize_pt,
        figure_padding = 6,
        Axis = (
            xgridstyle = :dash,
            ygridstyle = :dash,
            xgridcolor = (:grey, 0.15),
            ygridcolor = (:grey, 0.15),
            xminorticksvisible = false,
            yminorticksvisible = false,
            xtickalign = 1,
            ytickalign = 1,
            spinewidth = 0.8,
        ),
        Legend = (framevisible = false, padding = (2, 2, 2, 2), rowgap = 0, colgap = 10),
    )
end

figure_size(width_mm::Real, aspect::Real) =
    (width_mm * PT_PER_MM, width_mm * PT_PER_MM * aspect)

darker(color) = RGBAf(0.65 * color.r, 0.65 * color.g, 0.65 * color.b, color.alpha)

"""
    value_label(x::Real) -> String

Three significant digits without exponent notation (`1130`, `212`, `94.3`, `3.46`).
"""
function value_label(x::Real)
    x >= 100 && return @sprintf("%.0f", round(x; sigdigits = 3))
    x >= 10 && return @sprintf("%.1f", x)
    return @sprintf("%.2f", x)
end

"""
    decade_ticks(low::Real, high::Real) -> Tuple{Vector{Float64}, Vector}

Tick positions at the powers of ten inside `[low, high]`, labelled as plain decimals up
to 10⁴ and as powers of ten beyond.
"""
function decade_ticks(low::Real, high::Real)
    exponents = ceil(Int, log10(low)):floor(Int, log10(high))
    labels = Any[k <= 4 ? @sprintf("%d", 10^k) : L"10^{%$k}" for k in exponents]
    return (Float64[10.0^k for k in exponents], labels)
end

"""
    sweep_rows(df::DataFrame) -> DataFrame

Rows of the CPU thread-scaling stage: measured, library engine, with a defined speedup.
"""
function sweep_rows(df::DataFrame)
    keep =
        (df.device_type .== "CPU") .& (df.engine .== "blas") .& (df.status .== "ok") .&
        .!ismissing.(df.speedup_vs_1t) .& .!ismissing.(df.blas_threads)
    return sort(df[keep, :], [:matrix_dim, :blas_threads])
end

"""
    thread_scaling_figure(df::DataFrame, settings::FigureSettings) -> Union{Figure, Nothing}

Speedup and parallel efficiency against BLAS thread count, one series per problem size,
with the ideal references; hollow markers mark thread counts above the physical core
count. `nothing` when the dataset has no sweep rows.
"""
function thread_scaling_figure(df::DataFrame, settings::FigureSettings)
    rows = sweep_rows(df)
    nrow(rows) == 0 && return nothing
    sizes = sort(unique(rows.matrix_dim))
    counts = sort(unique(Int.(rows.blas_threads)))
    colors = Makie.wong_colors()
    hollow = any(rows.exceeds_physical_cores)

    fig = Figure(size = figure_size(settings.width_mm, 0.78))
    ticks = (counts, string.(counts))
    ax_speedup = Axis(
        fig[2, 1];
        ylabel = L"Speedup $S(t) = t_1 / t_t$",
        xscale = log2,
        xticks = ticks,
    )
    ax_efficiency = Axis(
        fig[3, 1];
        xlabel = "BLAS threads",
        ylabel = "Parallel efficiency [%]",
        xscale = log2,
        xticks = ticks,
    )
    linkxaxes!(ax_speedup, ax_efficiency)
    hidexdecorations!(ax_speedup; grid = false, ticks = false)

    max_speedup = 1.0
    elements = Any[]
    labels = Any[]
    for (k, N) in enumerate(sizes)
        series = rows[rows.matrix_dim .== N, :]
        threads = Float64.(series.blas_threads)
        speedup = Float64.(series.speedup_vs_1t)
        efficiency = Float64.(series.parallel_efficiency_pct)
        max_speedup = max(max_speedup, maximum(speedup))
        color = colors[mod1(k, length(colors))]
        for (ax, values) in ((ax_speedup, speedup), (ax_efficiency, efficiency))
            lines!(ax, threads, values; color, linewidth = 1.2)
            filled = .!series.exceeds_physical_cores
            scatter!(ax, threads[filled], values[filled]; color, markersize = 7)
            scatter!(
                ax,
                threads[.!filled],
                values[.!filled];
                color = :white,
                strokecolor = color,
                strokewidth = 1.2,
                markersize = 7,
            )
        end
        push!(
            elements,
            [
                LineElement(; color, linewidth = 1.2),
                MarkerElement(; color, marker = :circle, markersize = 7),
            ],
        )
        push!(labels, "N = $N")
    end
    top = 1.08 * max(max_speedup, 1.0)
    lines!(
        ax_speedup,
        [1.0, Float64(maximum(counts))],
        [1.0, Float64(maximum(counts))];
        color = :grey35,
        linestyle = :dash,
        linewidth = 0.9,
    )
    hlines!(ax_efficiency, [100.0]; color = :grey35, linestyle = :dash, linewidth = 0.9)
    push!(elements, LineElement(; color = :grey35, linestyle = :dash, linewidth = 0.9))
    push!(labels, L"Ideal ($S = t$, $E = 100$ \%)")
    if hollow
        push!(
            elements,
            MarkerElement(;
                color = :white,
                strokecolor = :grey35,
                strokewidth = 1.2,
                marker = :circle,
                markersize = 7,
            ),
        )
        push!(labels, "Above physical cores")
    end
    top <= 12 && (ax_speedup.yticks = 0:1:ceil(Int, top))
    ax_efficiency.yticks = 0:25:100
    ylims!(ax_speedup, 0, top)
    ylims!(ax_efficiency, 0, 112)
    xlims!(ax_efficiency, minimum(counts) / 1.25, maximum(counts) * 1.25)
    Legend(
        fig[1, 1],
        elements,
        labels;
        orientation = :horizontal,
        tellwidth = false,
        tellheight = true,
    )
    rowgap!(fig.layout, 1, 2)
    rowgap!(fig.layout, 2, 6)
    return fig
end

"""
    throughput_rows(df::DataFrame, N::Integer) -> DataFrame

Measured points at problem size `N`: every engine on accelerators; on the CPU the kernel
engines and the library engine at its largest thread count within the physical cores
(the largest count overall when every count exceeds them).
"""
function throughput_rows(df::DataFrame, N::Integer)
    ok = df[(df.status .== "ok") .& (df.matrix_dim .== N), :]
    cpu_blas = ok[(ok.device_type .== "CPU") .& (ok.engine .== "blas"), :]
    within = cpu_blas[.!cpu_blas.exceeds_physical_cores, :]
    pool = nrow(within) == 0 ? cpu_blas : within
    max_threads = nrow(pool) == 0 ? 0 : maximum(skipmissing(pool.blas_threads))
    keep = map(eachrow(ok)) do row
        row.device_type != "CPU" ||
            row.engine != "blas" ||
            (!ismissing(row.blas_threads) && row.blas_threads == max_threads)
    end
    return ok[keep, :]
end

device_key(row) = (row.device_type, row.backend, row.device_name)

function device_caption(row, N::Integer, cpu_threads)
    if row.device_type == "CPU"
        return "$(row.device_name), library at $(cpu_threads) threads, N = $N"
    end
    return "$(row.backend): $(row.device_name), N = $N"
end

"""
    throughput_figure(df::DataFrame, settings::FigureSettings;
                      matrix_dim::Union{Integer, Nothing} = nothing) -> Union{Figure, Nothing}

Throughput of every engine per element type, one panel per device, at `matrix_dim`
(default: the largest measured size). Bars carry their value; the y axis is
logarithmic. `nothing` when no measured point exists.
"""
function throughput_figure(
    df::DataFrame,
    settings::FigureSettings;
    matrix_dim::Union{Integer, Nothing} = nothing,
)
    measured = df[df.status .== "ok", :]
    nrow(measured) == 0 && return nothing
    N = matrix_dim === nothing ? maximum(measured.matrix_dim) : Int(matrix_dim)
    rows = throughput_rows(df, N)
    nrow(rows) == 0 && return nothing

    types = filter(t -> t in rows.data_type, TYPE_ORDER)
    engines = filter(e -> e in rows.engine, ENGINE_ORDER)
    devices = unique(device_key.(eachrow(rows)))
    sort!(devices; by = key -> (key[1] != "CPU", key[2], key[3]))
    colors =
        Dict(engine => Makie.wong_colors()[i] for (i, engine) in enumerate(ENGINE_ORDER))
    n_engines = length(engines)
    bar_width = 0.8 / n_engines
    cpu_blas = rows[(rows.device_type .== "CPU") .& (rows.engine .== "blas"), :]
    cpu_threads = nrow(cpu_blas) == 0 ? 0 : first(cpu_blas.blas_threads)
    y_low = minimum(rows.throughput_gops)
    y_high = maximum(rows.throughput_gops)
    fill_to = 10.0^(floor(log10(y_low)) - 0.3)
    y_top = y_high * 8
    ticks = decade_ticks(fill_to, y_top)

    fig = Figure(size = figure_size(settings.width_mm, 0.22 + 0.3 * length(devices)))
    axes = Axis[]
    for (d, key) in enumerate(devices)
        panel = rows[device_key.(eachrow(rows)) .== Ref(key), :]
        ax = Axis(
            fig[d + 1, 1];
            yscale = log10,
            ylabel = "Throughput [GOP/s]",
            yticks = ticks,
            xticks = (1:length(types), types),
            xlabel = d == length(devices) ? "Element type" : "",
        )
        for (e, engine) in enumerate(engines)
            xs = Float64[]
            ys = Float64[]
            for (t, type) in enumerate(types)
                hit = panel[(panel.engine .== engine) .& (panel.data_type .== type), :]
                nrow(hit) == 0 && continue
                push!(xs, t + (e - (n_engines + 1) / 2) * bar_width)
                push!(ys, first(hit.throughput_gops))
            end
            isempty(xs) && continue
            color = colors[engine]
            barplot!(
                ax,
                xs,
                ys;
                width = bar_width * 0.92,
                color,
                strokecolor = darker(color),
                strokewidth = 0.6,
                fillto = fill_to,
            )
            text!(
                ax,
                xs,
                ys .* 1.18;
                text = value_label.(ys),
                align = (:center, :bottom),
                fontsize = 0.8 * settings.fontsize_pt,
                color = darker(color),
            )
        end
        text!(
            ax,
            0.01,
            0.97;
            text = device_caption(first(eachrow(panel)), N, cpu_threads),
            space = :relative,
            align = (:left, :top),
            fontsize = 0.9 * settings.fontsize_pt,
        )
        ylims!(ax, fill_to, y_top)
        xlims!(ax, 0.4, length(types) + 0.6)
        d < length(devices) && hidexdecorations!(ax; grid = false, ticks = false)
        push!(axes, ax)
    end
    linkxaxes!(axes...)
    Legend(
        fig[1, 1],
        [
            PolyElement(;
                color = colors[e],
                strokecolor = darker(colors[e]),
                strokewidth = 0.6,
            ) for e in engines
        ],
        [ENGINE_LABELS[e] for e in engines];
        orientation = :horizontal,
        tellwidth = false,
        tellheight = true,
    )
    rowgap!(fig.layout, 1, 2)
    for d in 2:length(devices)
        rowgap!(fig.layout, d, 6)
    end
    return fig
end

"""
    safe_filepath(path) -> String

`path` when free, otherwise `stem#1.ext`, `stem#2.ext`, ... so that figures are never
overwritten.
"""
function safe_filepath(path::AbstractString)
    isfile(path) || return String(path)
    stem, extension = splitext(basename(path))
    k = 1
    while true
        candidate = joinpath(dirname(path), "$(stem)#$(k)$(extension)")
        isfile(candidate) || return candidate
        k += 1
    end
end

"""
    save_figure(fig::Figure, path::AbstractString, settings::FigureSettings) -> String

Export at native size: vector formats at one point per unit, raster at
`settings.px_per_unit` pixels per point.
"""
function save_figure(fig::Figure, path::AbstractString, settings::FigureSettings)
    target = safe_filepath(path)
    if settings.format == "png"
        save(target, fig; px_per_unit = settings.px_per_unit)
    else
        save(target, fig; pt_per_unit = 1)
    end
    return target
end

function usage()
    println(
        """
plot-benchmarks — figures from hardware-diagnostics datasets

Usage:
  julia run.jl plot-benchmarks [options]

  --input FILE.csv    dataset (default: newest hardware_benchmark_*.csv in [input].dataset_directory)
  --out-dir DIR       output directory (default: [figures].output_directory, relative to the tool)
  --format F          pdf | png | svg
  --size N            problem size of the throughput figure (default: largest measured)
  --config PATH       configuration file (default: config.toml next to the tool)
  -h, --help
""",
    )
end

"""
    render(dataset::AbstractString, settings::FigureSettings, output_dir::AbstractString;
           matrix_dim = nothing) -> Vector{String}

Produce both figures from `dataset` into `output_dir`; file names carry the dataset stem.
"""
function render(
    dataset::AbstractString,
    settings::FigureSettings,
    output_dir::AbstractString;
    matrix_dim::Union{Integer, Nothing} = nothing,
)
    df = read_dataset(dataset)
    mkpath(output_dir)
    stem = first(splitext(basename(dataset)))
    set_theme!(publication_theme(settings.fontsize_pt))
    written = String[]
    scaling = thread_scaling_figure(df, settings)
    if scaling === nothing
        println("no thread-scaling rows in $dataset; figure skipped")
    else
        push!(
            written,
            save_figure(
                scaling,
                joinpath(output_dir, "$(stem)_thread_scaling.$(settings.format)"),
                settings,
            ),
        )
    end
    throughput = throughput_figure(df, settings; matrix_dim)
    if throughput === nothing
        println("no measured points in $dataset; throughput figure skipped")
    else
        N =
            matrix_dim === nothing ? maximum(df[df.status .== "ok", :matrix_dim]) :
            matrix_dim
        push!(
            written,
            save_figure(
                throughput,
                joinpath(output_dir, "$(stem)_throughput_N$(N).$(settings.format)"),
                settings,
            ),
        )
    end
    return written
end

function main(args::Vector{String} = ARGS)
    config_path = joinpath(@__DIR__, "config.toml")
    input = nothing
    out_dir = nothing
    format = nothing
    matrix_dim = nothing
    i = 1
    function value_of(flag)
        i < length(args) || throw(ArgumentError("$flag requires a value"))
        i += 1
        return args[i]
    end
    while i <= length(args)
        argument = args[i]
        if argument in ("-h", "--help")
            usage()
            return String[]
        elseif argument == "--input"
            input = value_of(argument)
        elseif argument == "--out-dir"
            out_dir = value_of(argument)
        elseif argument == "--format"
            format = lowercase(value_of(argument))
        elseif argument == "--size"
            matrix_dim = parse(Int, value_of(argument))
        elseif argument == "--config"
            config_path = value_of(argument)
        else
            throw(ArgumentError("unknown command-line argument '$argument'; see --help"))
        end
        i += 1
    end
    settings = load_settings(config_path)
    if format !== nothing
        format in FORMATS || throw(
            ArgumentError(
                "--format must be one of: $(join(FORMATS, " | ")), got '$format'",
            ),
        )
        settings = FigureSettings(
            settings.dataset_directory,
            format,
            settings.width_mm,
            settings.px_per_unit,
            settings.fontsize_pt,
            settings.output_directory,
        )
    end
    resolve(path) = isabspath(path) ? path : normpath(joinpath(@__DIR__, path))
    dataset =
        input === nothing ? latest_dataset(resolve(settings.dataset_directory)) : input
    dataset === nothing && throw(
        ArgumentError(
            "no hardware_benchmark_*.csv found in $(resolve(settings.dataset_directory)); pass --input",
        ),
    )
    output = resolve(out_dir === nothing ? settings.output_directory : out_dir)
    written = render(dataset, settings, output; matrix_dim)
    for path in written
        println("wrote ", path)
    end
    return written
end

if abspath(PROGRAM_FILE) == @__FILE__
    try
        main(ARGS)
    catch err
        err isa ArgumentError || rethrow()
        println(stderr, "plot-benchmarks: ", err.msg)
        exit(2)
    end
end
