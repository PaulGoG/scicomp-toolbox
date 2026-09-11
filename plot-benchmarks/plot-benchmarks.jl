#!/usr/bin/env julia
# plot-benchmarks — publication figures from hardware-diagnostics datasets: the CPU
# thread-scaling sweep (speedup and parallel efficiency) and the throughput of every
# engine per element type and device, from one dataset; the accelerator profile and the
# host thread scaling of several machines, from a directory of datasets (--compare).
#
#   julia run.jl plot-benchmarks [--input FILE.csv] [--out-dir DIR] [--format pdf|png|svg]
#                                [--size N] [--px-per-unit N] [--config PATH]
#   julia run.jl plot-benchmarks --compare [DIR] [options]

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
# the two engines the cross-host figure contrasts: the library path of the device and the
# portable kernel that competes with it
const REFERENCE_ENGINE = "blas"
const PORTABLE_ENGINE = "ka_tiled"
# vendor decorations of `device_name` that carry no information about the device
const NAME_DECORATIONS = [
    r"\((?:R|TM|C)\)"i => "",
    r"\s*CPU\s*@\s*[\d.]+\s*[GM]Hz" => "",
    r"\s+\d+-Core\s+Processor\b" => "",
    r"\s+Processor\b" => "",
    r"^\d+(?:st|nd|rd|th)\s+Gen\s+" => "",
    r"\bGeForce\s+" => "",
    r"\bwith\s+Max-Q\s+Design\b" => "Max-Q",
]
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
    comparison_directory::String
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
    reject_unknown_keys(input, ("dataset_directory", "comparison_directory"), "input")
    reject_unknown_keys(
        figures,
        ("format", "width_mm", "px_per_unit", "fontsize_pt", "output_directory"),
        "figures",
    )

    dataset_directory = get(input, "dataset_directory", "../hardware-diagnostics/data")
    dataset_directory isa AbstractString ||
        throw(ArgumentError("[input].dataset_directory must be a string"))
    comparison_directory = get(input, "comparison_directory", "../reference-runs")
    comparison_directory isa AbstractString ||
        throw(ArgumentError("[input].comparison_directory must be a string"))
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
        String(comparison_directory),
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

Three significant digits without exponent notation (`1130`, `212`, `94.3`, `3.46`,
`0.42`, `0.0042`).
"""
function value_label(x::Real)
    x >= 100 && return @sprintf("%.0f", round(x; sigdigits = 3))
    x >= 10 && return @sprintf("%.1f", x)
    x >= 1 && return @sprintf("%.2f", x)
    return @sprintf("%.3g", x)
end

"""
    decade_ticks(low::Real, high::Real) -> Tuple{Vector{Float64}, Vector}

Tick positions at the powers of ten inside `[low, high]`. An axis that stays between
10⁻³ and 10⁴ is labelled with plain decimals throughout; one that leaves that range is
labelled with powers of ten, except 10⁰ and 10¹, which always read `1` and `10`.
"""
function decade_ticks(low::Real, high::Real)
    exponents = ceil(Int, log10(low)):floor(Int, log10(high))
    plain = all(k -> -3 <= k <= 4, exponents)
    labels = Any[
        (plain || k in (0, 1)) ? @sprintf("%g", 10.0^k) : L"10^{%$k}" for k in exponents
    ]
    return (Float64[10.0^k for k in exponents], labels)
end

"""
    log_ticks(low::Real, high::Real) -> Tuple{Vector{Float64}, Vector}

Decade ticks inside `[low, high]`, with the 2× and 5× intermediates added when the range
spans fewer than three decades and would otherwise carry too few labels.
"""
function log_ticks(low::Real, high::Real)
    log10(high) - log10(low) >= 3 && return decade_ticks(low, high)
    positions = Float64[]
    for k in (floor(Int, log10(low))):(ceil(Int, log10(high))), mantissa in (1.0, 2.0, 5.0)
        value = mantissa * 10.0^k
        low <= value <= high && push!(positions, value)
    end
    isempty(positions) && return decade_ticks(low, high)
    labels = Any[
        1e-3 <= value <= 1e4 ? @sprintf("%g", value) : L"10^{%$(round(Int, log10(value)))}" for value in positions
    ]
    return (positions, labels)
end

"""
    ideal_scaling(max_threads::Real) -> Tuple{Vector{Float64}, Vector{Float64}}

Sampling of the ideal speedup S = t between one thread and `max_threads`. The curve is
sampled rather than drawn as a segment because the thread axis is logarithmic, on which a
two-point segment is a chord and not the reference.
"""
function ideal_scaling(max_threads::Real)
    threads = 2.0 .^ range(0, log2(Float64(max_threads)); length = 96)
    return (threads, threads)
end

"""
    shorten_device_name(name::AbstractString) -> String

Strip the vendor decorations of a `device_name` that carry no information about the
device — trademark marks, the clock suffix of Intel CPU strings, the core-count and
generation words, the GeForce and Max-Q wording — and collapse the remaining whitespace.
"""
function shorten_device_name(name::AbstractString)
    short = String(name)
    for (pattern, replacement) in NAME_DECORATIONS
        short = replace(short, pattern => replacement)
    end
    return strip(replace(short, r"\s+" => " "))
end

"""
    drop_vendor(name::AbstractString) -> String

Remove the leading vendor word of a device name, for legends whose group title already
names the vendor through the backend.
"""
drop_vendor(name::AbstractString) = replace(String(name), r"^(?:NVIDIA|AMD|Intel)\s+" => "")

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
        ideal_scaling(maximum(counts))...;
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
    # headroom for the value labels and the panel caption, at least 0.9 decades and
    # growing with the axis span so that wide ranges keep the caption clear
    span = log10(y_high) - log10(fill_to)
    y_top = y_high * 10.0^max(log10(8), 0.18 * span)
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
    comparison_datasets(root::AbstractString) -> Vector{String}

Paths of every `hardware_benchmark_*.csv` under `root`, searched recursively and sorted.
"""
function comparison_datasets(root::AbstractString)
    isdir(root) || throw(ArgumentError("comparison directory not found: $root"))
    paths = String[]
    for (directory, _, names) in walkdir(root), name in names
        startswith(name, "hardware_benchmark_") &&
            endswith(name, ".csv") &&
            push!(paths, joinpath(directory, name))
    end
    isempty(paths) &&
        throw(ArgumentError("no hardware_benchmark_*.csv under $root; pass --compare DIR"))
    return sort!(paths)
end

"""
    common_size(frames::Vector{DataFrame}) -> Int

Largest problem size measured in every dataset, so that the compared devices carry the
same work per point.
"""
function common_size(frames::Vector{DataFrame})
    shared =
        intersect((Set(frame[frame.status .== "ok", :matrix_dim]) for frame in frames)...)
    isempty(shared) &&
        throw(ArgumentError("the datasets share no problem size measured in all of them"))
    return maximum(shared)
end

"""
    pooled_devices(frames::Vector{DataFrame}, N::Integer, device_type::AbstractString) -> DataFrame

Measured rows at size `N` of every dataset, restricted to `device_type`. A device is
identified by its backend and name and is taken from the first dataset that carries it,
so the same processor benchmarked on two machines contributes one series.
"""
function pooled_devices(frames::Vector{DataFrame}, N::Integer, device_type::AbstractString)
    parts = DataFrame[]
    seen = Set{Tuple{String, String}}()
    for frame in frames
        rows = frame[
            (frame.status .== "ok") .& (frame.matrix_dim .== N) .& (frame.device_type .== device_type),
            :,
        ]
        for key in unique(tuple.(String.(rows.backend), String.(rows.device_name)))
            key in seen && continue
            push!(seen, key)
            push!(
                parts,
                rows[(rows.backend .== key[1]) .& (rows.device_name .== key[2]), :],
            )
        end
    end
    return isempty(parts) ? DataFrame() : reduce(vcat, parts)
end

"""
    log_limits(values; bottom = 0.06, top = 0.22) -> Tuple{Float64, Float64}

Limits of a logarithmic axis holding `values`, with room below the lowest point and above
the highest one for the panel caption.
"""
function log_limits(values; bottom::Real = 0.06, top::Real = 0.18)
    low, high = extrema(values)
    span = max(log10(high) - log10(low), 0.5)
    return (10.0^(log10(low) - bottom * span), 10.0^(log10(high) + top * span))
end

is_generic_library(library) = occursin("generic", lowercase(String(library)))

"""
    engine_series(panel::DataFrame, engine::AbstractString, types::Vector{String})

Positions, throughputs and generic-fallback flags of one engine on one device, aligned
with the element types present in `types`.
"""
function engine_series(panel::DataFrame, engine::AbstractString, types::Vector{String})
    positions = Float64[]
    throughputs = Float64[]
    generic = Bool[]
    for (t, type) in enumerate(types)
        hit = panel[(panel.engine .== engine) .& (panel.data_type .== type), :]
        nrow(hit) == 0 && continue
        push!(positions, t)
        push!(throughputs, first(hit.throughput_gops))
        push!(generic, is_generic_library(first(hit.library)))
    end
    return positions, throughputs, generic
end

"""
    ratio_series(panel::DataFrame, types::Vector{String})

Positions and throughput ratios of the portable tiled kernel against the library engine
on one device, for the element types both engines measured.
"""
function ratio_series(panel::DataFrame, types::Vector{String})
    positions = Float64[]
    ratios = Float64[]
    for (t, type) in enumerate(types)
        _, reference, _ = engine_series(panel, REFERENCE_ENGINE, [type])
        _, portable, _ = engine_series(panel, PORTABLE_ENGINE, [type])
        (isempty(reference) || isempty(portable)) && continue
        push!(positions, t)
        push!(ratios, first(portable) / first(reference))
    end
    return positions, ratios
end

"""
    marked_scatter!(ax, positions, values, hollow, color; marker = :circle, markersize = 7)

Scatter in `color` with the points flagged in `hollow` drawn as outlines.
"""
function marked_scatter!(
    ax,
    positions,
    values,
    hollow::AbstractVector{Bool},
    color;
    marker = :circle,
    markersize = 7,
)
    filled = .!hollow
    scatter!(ax, positions[filled], values[filled]; color, marker, markersize)
    scatter!(
        ax,
        positions[hollow],
        values[hollow];
        color = :white,
        strokecolor = color,
        strokewidth = 1.2,
        marker,
        markersize,
    )
    return nothing
end

"""
    accelerator_comparison_figure(frames::Vector{DataFrame}, settings::FigureSettings;
                                  matrix_dim = nothing) -> Union{Figure, Nothing}

Three stacked panels sharing the element-type axis: the throughput of the library engine
and of the portable tiled kernel on every accelerator of the datasets, and their ratio
against a parity line. Hollow markers in the library panel mark the types the device has
no vendor GEMM for, which run on the generic GPUArrays fallback. `nothing` when the
datasets hold no accelerator point.
"""
function accelerator_comparison_figure(
    frames::Vector{DataFrame},
    settings::FigureSettings;
    matrix_dim::Union{Integer, Nothing} = nothing,
)
    N = matrix_dim === nothing ? common_size(frames) : Int(matrix_dim)
    rows = pooled_devices(frames, N, "GPU")
    nrow(rows) == 0 && return nothing
    types = filter(type -> type in rows.data_type, TYPE_ORDER)
    devices = unique(device_key.(eachrow(rows)))
    panels =
        Dict(key => rows[device_key.(eachrow(rows)) .== Ref(key), :] for key in devices)
    # descending peak throughput, so that the legend order follows the panels
    sort!(devices; by = key -> -maximum(panels[key].throughput_gops))
    colors = Makie.wong_colors()

    fig = Figure(size = figure_size(settings.width_mm, 0.82))
    ticks = (1:length(types), types)
    ax_library =
        Axis(fig[2, 1]; yscale = log10, ylabel = "Throughput [GOP/s]", xticks = ticks)
    ax_portable =
        Axis(fig[3, 1]; yscale = log10, ylabel = "Throughput [GOP/s]", xticks = ticks)
    ax_ratio = Axis(
        fig[4, 1];
        yscale = log10,
        ylabel = "Tiled / library",
        xlabel = "Element type",
        xticks = ticks,
    )

    throughputs = Float64[]
    ratios = Float64[]
    backends = unique(String[String(key[2]) for key in devices])
    elements = [Any[] for _ in backends]
    labels = [Any[] for _ in backends]
    for (k, key) in enumerate(devices)
        panel = panels[key]
        color = colors[mod1(k, length(colors))]
        for (ax, engine) in ((ax_library, REFERENCE_ENGINE), (ax_portable, PORTABLE_ENGINE))
            positions, values, generic = engine_series(panel, engine, types)
            isempty(positions) && continue
            append!(throughputs, values)
            lines!(ax, positions, values; color, linewidth = 1.2)
            marked_scatter!(
                ax,
                positions,
                values,
                engine == REFERENCE_ENGINE ? generic : falses(length(positions)),
                color,
            )
        end
        positions, values = ratio_series(panel, types)
        if !isempty(positions)
            append!(ratios, values)
            lines!(ax_ratio, positions, values; color, linewidth = 1.2)
            scatter!(ax_ratio, positions, values; color, markersize = 7)
        end
        group = findfirst(==(String(key[2])), backends)
        push!(
            elements[group],
            [
                LineElement(; color, linewidth = 1.2),
                MarkerElement(; color, marker = :circle, markersize = 7),
            ],
        )
        push!(labels[group], drop_vendor(shorten_device_name(key[3])))
    end

    hlines!(ax_ratio, [1.0]; color = :grey35, linestyle = :dash, linewidth = 0.9)
    text!(
        ax_ratio,
        0.58,
        0.93;
        text = "Parity",
        align = (:left, :top),
        fontsize = 0.8 * settings.fontsize_pt,
        color = :grey35,
    )
    limits = log_limits(throughputs)
    for (ax, caption) in (
        (
            ax_library,
            "Library engine (mul!); open markers: generic fallback, no vendor GEMM",
        ),
        (
            ax_portable,
            "Portable engine: the same tiled KernelAbstractions kernel everywhere",
        ),
    )
        text!(
            ax,
            0.01,
            0.97;
            text = caption,
            space = :relative,
            align = (:left, :top),
            fontsize = 0.9 * settings.fontsize_pt,
        )
        ax.yticks = log_ticks(limits...)
        ylims!(ax, limits...)
        hidexdecorations!(ax; grid = false, ticks = false)
    end
    ratio_limits = log_limits(ratios; bottom = 0.10, top = 0.16)
    ax_ratio.yticks = log_ticks(ratio_limits...)
    ylims!(ax_ratio, ratio_limits...)
    for ax in (ax_library, ax_portable, ax_ratio)
        xlims!(ax, 0.5, length(types) + 0.5)
    end
    linkxaxes!(ax_library, ax_portable, ax_ratio)
    Legend(
        fig[1, 1],
        elements,
        labels,
        backends;
        orientation = :horizontal,
        nbanks = 2,
        titleposition = :left,
        titlegap = 4,
        groupgap = 8,
        labelsize = 0.86 * settings.fontsize_pt,
        titlesize = 0.86 * settings.fontsize_pt,
        patchsize = (11.0f0, 7.0f0),
        colgap = 5,
        tellwidth = false,
        tellheight = true,
    )
    rowsize!(fig.layout, 4, Auto(0.62))
    rowgap!(fig.layout, 1, 2)
    rowgap!(fig.layout, 2, 6)
    rowgap!(fig.layout, 3, 6)
    return fig
end

"""
    host_comparison_figure(frames::Vector{DataFrame}, settings::FigureSettings;
                           matrix_dim = nothing) -> Union{Figure, Nothing}

Speedup and parallel efficiency of the library engine against the BLAS thread count, one
series per host processor of the datasets, at the shared problem size. `nothing` when the
datasets hold no thread-scaling point.
"""
function host_comparison_figure(
    frames::Vector{DataFrame},
    settings::FigureSettings;
    matrix_dim::Union{Integer, Nothing} = nothing,
)
    N = matrix_dim === nothing ? common_size(frames) : Int(matrix_dim)
    pooled = pooled_devices(frames, N, "CPU")
    nrow(pooled) == 0 && return nothing
    rows = pooled[
        (pooled.engine .== REFERENCE_ENGINE) .& .!ismissing.(pooled.speedup_vs_1t) .& .!ismissing.(pooled.blas_threads),
        :,
    ]
    nrow(rows) == 0 && return nothing
    devices = unique(device_key.(eachrow(rows)))
    panels =
        Dict(key => rows[device_key.(eachrow(rows)) .== Ref(key), :] for key in devices)
    # descending sweep ceiling, which orders the hosts by the parallelism they expose
    sort!(devices; by = key -> (-maximum(panels[key].blas_threads), key[3]))
    counts = sort(unique(Int.(rows.blas_threads)))
    colors = Makie.wong_colors()

    fig = Figure(size = figure_size(settings.width_mm, 0.76))
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
    hollow = false
    elements = Any[]
    labels = Any[]
    for (k, key) in enumerate(devices)
        panel = sort(panels[key], :blas_threads)
        threads = Float64.(panel.blas_threads)
        speedup = Float64.(panel.speedup_vs_1t)
        efficiency = Float64.(panel.parallel_efficiency_pct)
        max_speedup = max(max_speedup, maximum(speedup))
        hollow |= any(panel.exceeds_physical_cores)
        color = colors[mod1(k, length(colors))]
        for (ax, values) in ((ax_speedup, speedup), (ax_efficiency, efficiency))
            lines!(ax, threads, values; color, linewidth = 1.2)
            marked_scatter!(
                ax,
                threads,
                values,
                Vector{Bool}(panel.exceeds_physical_cores),
                color,
            )
        end
        push!(
            elements,
            [
                LineElement(; color, linewidth = 1.2),
                MarkerElement(; color, marker = :circle, markersize = 7),
            ],
        )
        push!(labels, shorten_device_name(key[3]))
    end
    lines!(
        ax_speedup,
        ideal_scaling(maximum(counts))...;
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
    text!(
        ax_speedup,
        0.01,
        0.97;
        text = "Library engine (mul!), Float32, N = $N\nEach series ends at the physical core count of its host",
        space = :relative,
        align = (:left, :top),
        fontsize = 0.9 * settings.fontsize_pt,
    )
    top = 1.16 * max_speedup
    top <= 16 && (ax_speedup.yticks = 0:2:ceil(Int, top))
    ax_efficiency.yticks = 0:25:100
    ylims!(ax_speedup, 0, top)
    ylims!(ax_efficiency, 0, 112)
    xlims!(ax_efficiency, minimum(counts) / 1.3, maximum(counts) * 1.3)
    Legend(
        fig[1, 1],
        elements,
        labels;
        orientation = :horizontal,
        nbanks = 2,
        labelsize = 0.92 * settings.fontsize_pt,
        patchsize = (12.0f0, 8.0f0),
        colgap = 6,
        tellwidth = false,
        tellheight = true,
    )
    rowgap!(fig.layout, 1, 2)
    rowgap!(fig.layout, 2, 6)
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
  julia run.jl plot-benchmarks --compare [DIR] [options]

  --input FILE.csv    dataset (default: newest hardware_benchmark_*.csv in [input].dataset_directory)
  --compare [DIR]     cross-host figures from every dataset under DIR, searched recursively
                      (default: [input].comparison_directory)
  --out-dir DIR       output directory (default: [figures].output_directory, relative to the tool)
  --format F          pdf | png | svg
  --size N            problem size of the throughput figures (default: largest measured, and
                      with --compare the largest measured in every dataset)
  --px-per-unit N     pixels per point of a PNG export (default: [figures].px_per_unit)
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

"""
    render_comparison(paths, settings::FigureSettings, output_dir::AbstractString;
                      matrix_dim = nothing) -> Vector{String}

Produce the two cross-host figures from the datasets at `paths` into `output_dir`.
"""
function render_comparison(
    paths::Vector{String},
    settings::FigureSettings,
    output_dir::AbstractString;
    matrix_dim::Union{Integer, Nothing} = nothing,
)
    frames = DataFrame[read_dataset(path) for path in paths]
    N = matrix_dim === nothing ? common_size(frames) : Int(matrix_dim)
    mkpath(output_dir)
    set_theme!(publication_theme(settings.fontsize_pt))
    written = String[]
    for (figure, stem) in (
        (
            accelerator_comparison_figure(frames, settings; matrix_dim = N),
            "cross_host_accelerators",
        ),
        (host_comparison_figure(frames, settings; matrix_dim = N), "cross_host_hosts"),
    )
        if figure === nothing
            println("no rows for $stem in the compared datasets; figure skipped")
            continue
        end
        push!(
            written,
            save_figure(
                figure,
                joinpath(output_dir, "$(stem)_N$(N).$(settings.format)"),
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
    px_per_unit = nothing
    compare = false
    compare_dir = nothing
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
        elseif argument == "--px-per-unit"
            px_per_unit = parse(Int, value_of(argument))
        elseif argument == "--compare"
            compare = true
            # the directory is optional; the next token is one unless it is another flag
            if i < length(args) && !startswith(args[i + 1], "--")
                compare_dir = value_of(argument)
            end
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
    end
    if px_per_unit !== nothing && px_per_unit < 1
        throw(ArgumentError("--px-per-unit must be an integer >= 1, got $px_per_unit"))
    end
    settings = FigureSettings(
        settings.dataset_directory,
        settings.comparison_directory,
        format === nothing ? settings.format : format,
        settings.width_mm,
        px_per_unit === nothing ? settings.px_per_unit : px_per_unit,
        settings.fontsize_pt,
        settings.output_directory,
    )
    resolve(path) = isabspath(path) ? path : normpath(joinpath(@__DIR__, path))
    output = resolve(out_dir === nothing ? settings.output_directory : out_dir)
    if compare
        root =
            resolve(compare_dir === nothing ? settings.comparison_directory : compare_dir)
        paths = comparison_datasets(root)
        for path in paths
            println("dataset ", path)
        end
        written = render_comparison(paths, settings, output; matrix_dim)
    else
        dataset =
            input === nothing ? latest_dataset(resolve(settings.dataset_directory)) : input
        dataset === nothing && throw(
            ArgumentError(
                "no hardware_benchmark_*.csv found in $(resolve(settings.dataset_directory)); pass --input",
            ),
        )
        written = render(dataset, settings, output; matrix_dim)
    end
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
