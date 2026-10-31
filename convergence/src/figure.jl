# Publication figure of one or several order estimates: errors against the step size on
# logarithmic axes with the fitted power laws, and the pairwise orders in a strip below.

const PT_PER_MM = 72 / 25.4

"Okabe–Ito palette, in the order the series take their colours."
const OKABE_ITO =
    ("#E69F00", "#56B4E9", "#009E73", "#D55E00", "#CC79A7", "#0072B2", "#F0E442", "#000000")

"""
    publication_theme(fontsize_pt::Real) -> Theme

Computer Modern fonts, boxed axes, faint dashed grid, no minor ticks, ticks pointing
inward and a frameless legend.
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

"""
    figure_size(width_mm::Real, aspect::Real) -> Tuple{Float64, Float64}

Figure size in points for a printed width in millimetres and a height-to-width ratio.
"""
figure_size(width_mm::Real, aspect::Real) =
    (width_mm * PT_PER_MM, width_mm * PT_PER_MM * aspect)

"""
    darker(color) -> RGBAf

The same hue at 65 % of its intensity, for marker strokes.
"""
darker(color) = RGBAf(0.65 * color.r, 0.65 * color.g, 0.65 * color.b, color.alpha)

"""
    log_label(value::Real, plain::Bool)

Label of a logarithmic tick: a plain decimal when `plain` or when the decade is 10⁰ or
10¹, otherwise `10^k` or `m × 10^k` with the integer mantissa `m`, the exponent set as
a superscript.
"""
function log_label(value::Real, plain::Bool)
    k = floor(Int, log10(value) + 1e-9)
    mantissa = round(Int, value / 10.0^k)
    (plain || k in (0, 1)) && return @sprintf("%g", mantissa * 10.0^k)
    exponent = superscript(replace(string(k), "-" => "−"))
    return mantissa == 1 ? rich("10", exponent) : rich("$mantissa × 10", exponent)
end

"""
    decade_ticks(low::Real, high::Real) -> Tuple{Vector{Float64}, Vector}

Tick positions at the powers of ten inside `[low, high]`, thinned to at most seven. An
axis that stays between 10⁻³ and 10⁴ is labelled with plain decimals throughout; one that
leaves that range is labelled with powers of ten, except 10⁰ and 10¹, which always read
`1` and `10`.
"""
function decade_ticks(low::Real, high::Real)
    exponents = ceil(Int, log10(low)):floor(Int, log10(high))
    # at most seven labels: wide ranges are labelled every second or third decade
    step = max(1, ceil(Int, length(exponents) / 7))
    exponents = filter(k -> mod(k, step) == 0, exponents)
    plain = all(k -> -3 <= k <= 4, exponents)
    labels = Any[log_label(10.0^k, plain) for k in exponents]
    return (Float64[10.0^k for k in exponents], labels)
end

"""
    log_ticks(low::Real, high::Real) -> Tuple{Vector{Float64}, Vector}

Decade ticks inside `[low, high]`, with the 2× and 5× intermediates added when the range
spans fewer than three decades. The labels keep one style for the whole axis: plain
decimals while every tick lies between 10⁻³ and 10⁴, powers of ten otherwise.
"""
function log_ticks(low::Real, high::Real)
    log10(high) - log10(low) >= 3 && return decade_ticks(low, high)
    positions = Float64[]
    for k in (floor(Int, log10(low))):(ceil(Int, log10(high))), mantissa in (1.0, 2.0, 5.0)
        value = mantissa * 10.0^k
        low <= value <= high && push!(positions, value)
    end
    isempty(positions) && return decade_ticks(low, high)
    plain = all(v -> 1e-3 <= v <= 1e4, positions)
    labels = Any[log_label(v, plain) for v in positions]
    return (positions, labels)
end

"""
    log_limits(low, high; bottom = 0.06, top = 0.06) -> Tuple{Float64, Float64}

Limits of a logarithmic axis holding values in `[low, high]`, widened by the fractions
`bottom` and `top` of the span in decades (at least half a decade).
"""
function log_limits(low::Real, high::Real; bottom::Real = 0.06, top::Real = 0.06)
    span = max(log10(high) - log10(low), 0.5)
    return (10.0^(log10(low) - bottom * span), 10.0^(log10(high) + top * span))
end

"Label of a reference order: integers without decimals."
order_label(p::Real) = isinteger(p) ? "p = $(round(Int, p))" : "p = $(@sprintf("%.3g", p))"

"""
    fit_label(name, estimate::OrderEstimate) -> String

Legend entry of a series: its name and the fitted order with its standard error, both
printed with as many decimals as the standard error needs (two to four), or the order
alone with two decimals when the fit is exact.
"""
function fit_label(name::AbstractString, estimate::OrderEstimate)
    σ = estimate.standard_error
    σ == 0 && return @sprintf("%s: p = %.2f", name, estimate.order)
    decimals = clamp(ceil(Int, -log10(σ)) + 1, 2, 4)
    return name * ": p = " * @sprintf("%.*f ± %.*f", decimals, estimate.order, decimals, σ)
end

"The coarsest level that entered the fit, or the coarsest level when none did."
function coarsest_fitted(estimate::OrderEstimate)
    k = findfirst(level -> level.fitted, estimate.levels)
    return estimate.levels[something(k, 1)]
end

"""
    convergence_figure(series::AbstractVector{<:Pair{<:AbstractString, OrderEstimate}};
                       reference_orders::AbstractVector{<:Real} = Float64[],
                       xlabel::AbstractString = "Step size h",
                       ylabel::AbstractString = "Error",
                       width_mm::Real = 86.0, fontsize_pt::Real = 9.0) -> Figure
    convergence_figure(estimate::OrderEstimate; label::AbstractString = "Error",
                       kwargs...) -> Figure

Two panels sharing the logarithmic step-size axis. The upper one shows the error of
every series (`name => estimate`) against h on logarithmic axes, with the fitted power
law C hᵖ dashed over the fitted range and the levels left out of the fit drawn hollow;
each `reference_orders` entry adds a dotted grey line of that slope through the
coarsest fitted point of the first series, labelled at its fine end. The strip below
shows the pairwise orders at the finer step size of each pair, with the fitted order as
a dashed guide. The legend above the panels names each series with its fitted order and
standard error, one entry per series.
The figure is `width_mm` wide and square; `fontsize_pt` sets the marker size, while the
fonts follow the active theme ([`publication_theme`](@ref)).

The second form plots a single estimate under the name `label`.

Returns the `Figure`. Throws `ArgumentError` for an empty series list or a reference
order that is not positive and finite.
"""
function convergence_figure(
    series::AbstractVector{<:Pair{<:AbstractString, OrderEstimate}};
    reference_orders::AbstractVector{<:Real} = Float64[],
    xlabel::AbstractString = "Step size h",
    ylabel::AbstractString = "Error",
    width_mm::Real = 86.0,
    fontsize_pt::Real = 9.0,
)
    isempty(series) && throw(ArgumentError("at least one series is required"))
    all(p -> isfinite(p) && p > 0, reference_orders) ||
        throw(ArgumentError("the reference orders must be positive and finite"))
    markersize = 0.7 * fontsize_pt

    fig = Figure(size = figure_size(width_mm, 1.0))
    ax_error = Axis(fig[1, 1]; xscale = log10, yscale = log10, ylabel = ylabel)
    ax_order = Axis(fig[2, 1]; xscale = log10, xlabel = xlabel, ylabel = "Order")
    rowsize!(fig.layout, 2, Auto(0.4))
    linkxaxes!(ax_error, ax_order)
    hidexdecorations!(ax_error; grid = false, ticks = false)
    rowgap!(fig.layout, 1, 4)

    steps = sort!(unique(Float64[level.h for (_, e) in series for level in e.levels]))
    h_low, h_high = first(steps), last(steps)
    errors_drawn = Float64[]
    orders_drawn = Float64[]

    # reference lines first, beneath the data
    anchor = coarsest_fitted(last(first(series)))
    for p in reference_orders
        hs = [h_low, h_high]
        es = anchor.error .* (hs ./ anchor.h) .^ p
        lines!(ax_error, hs, es; color = (:grey45, 0.7), linestyle = :dot, linewidth = 0.9)
        text!(
            ax_error,
            h_low,
            first(es);
            text = order_label(p),
            color = (:grey45, 0.9),
            align = (:left, :top),
            offset = (markersize, -markersize),
            fontsize = 0.8 * fontsize_pt,
        )
        append!(errors_drawn, es)
    end

    elements = Vector{Vector{Any}}()
    labels = String[]
    for (k, (name, estimate)) in enumerate(series)
        color = to_color(OKABE_ITO[mod1(k, length(OKABE_ITO))])
        stroke = darker(color)
        levels = estimate.levels
        hs = Float64[level.h for level in levels]
        es = Float64[level.error for level in levels]
        fitted = Bool[level.fitted for level in levels]
        if any(fitted)
            h_fit = [maximum(hs[fitted]), minimum(hs[fitted])]
            e_fit = estimate.constant .* h_fit .^ estimate.order
            lines!(ax_error, h_fit, e_fit; color, linestyle = :dash, linewidth = 1.0)
            append!(errors_drawn, e_fit)
            scatter!(
                ax_error,
                hs[fitted],
                es[fitted];
                color,
                strokecolor = stroke,
                strokewidth = 0.8,
                marker = :circle,
                markersize,
            )
        end
        if !all(fitted)
            scatter!(
                ax_error,
                hs[.!fitted],
                es[.!fitted];
                color = :transparent,
                strokecolor = stroke,
                strokewidth = 0.8,
                marker = :circle,
                markersize,
            )
        end
        append!(errors_drawn, es)

        h_pairs = Float64[]
        p_pairs = Float64[]
        for level in levels
            order = level.order
            order === nothing && continue
            push!(h_pairs, level.h)
            push!(p_pairs, order)
        end
        lines!(ax_order, h_pairs, p_pairs; color, linewidth = 0.8)
        scatter!(
            ax_order,
            h_pairs,
            p_pairs;
            color,
            strokecolor = stroke,
            strokewidth = 0.8,
            marker = :circle,
            markersize = 0.8 * markersize,
        )
        hlines!(ax_order, [estimate.order]; color, linestyle = :dash, linewidth = 1.0)
        append!(orders_drawn, p_pairs)
        push!(orders_drawn, estimate.order)

        push!(
            elements,
            [
                LineElement(; color, linestyle = :dash, linewidth = 1.0),
                MarkerElement(;
                    color,
                    strokecolor = stroke,
                    strokewidth = 0.8,
                    marker = :circle,
                    markersize,
                ),
            ],
        )
        push!(labels, fit_label(name, estimate))
    end

    x_limits = log_limits(h_low, h_high)
    # the step sizes themselves label the axis when they are few and print as plain
    # decimals; otherwise the decades do
    xticks =
        (length(steps) <= 8 && h_low >= 1e-3) ?
        (steps, String[@sprintf("%.3g", h) for h in steps]) : decade_ticks(x_limits...)
    isempty(first(xticks)) && (xticks = log_ticks(x_limits...))
    for ax in (ax_error, ax_order)
        ax.xticks = xticks
        xlims!(ax, x_limits...)
    end
    # room below the lowest reference line for its label
    y_limits = log_limits(
        extrema(errors_drawn)...;
        bottom = isempty(reference_orders) ? 0.06 : 0.18,
    )
    ax_error.yticks = log_ticks(y_limits...)
    ylims!(ax_error, y_limits...)
    low, high = extrema(orders_drawn)
    half_range = max(0.6 * (high - low), 0.25)
    ylims!(ax_order, (low + high) / 2 - half_range, (low + high) / 2 + half_range)

    # one entry per series, marker and fit line together, stacked so that a narrow
    # single-column figure never clips the legend
    Legend(
        fig[0, 1],
        elements,
        labels;
        orientation = :vertical,
        framevisible = false,
        tellwidth = false,
        tellheight = true,
        rowgap = 0,
        patchsize = (2.4 * fontsize_pt, fontsize_pt),
    )
    rowgap!(fig.layout, 1, 2)
    return fig
end

function convergence_figure(
    estimate::OrderEstimate;
    label::AbstractString = "Error",
    kwargs...,
)
    return convergence_figure([String(label) => estimate]; kwargs...)
end

"""
    save_figure(fig::Figure, path::AbstractString, settings::StudySettings) -> String

Export at native size: vector formats at one point per unit, raster at
`settings.px_per_unit` pixels per point. The figure goes to [`safe_filepath`](@ref)`(path)`,
whose result is returned.
"""
function save_figure(fig::Figure, path::AbstractString, settings::StudySettings)
    target = safe_filepath(path)
    if settings.format == "png"
        save(target, fig; px_per_unit = settings.px_per_unit)
    else
        save(target, fig; pt_per_unit = 1)
    end
    return target
end
