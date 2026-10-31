# Text report of an order estimate and of the three-grid procedure, and collision-free
# output paths.

const TABLE_FORMAT = TextTableFormat(;
    borders = text_table_borders__compact,
    horizontal_line_at_beginning = false,
    horizontal_line_after_data_rows = false,
    vertical_line_at_beginning = false,
    vertical_lines_at_data_columns = :none,
    vertical_line_after_data_columns = false,
)

"Three significant digits."
g3(x::Real) = @sprintf("%.3g", x)

"Four significant digits."
g4(x::Real) = @sprintf("%.4g", x)

fitted_count(estimate::OrderEstimate) = count(level -> level.fitted, estimate.levels)

"""
    convergence_table(io::IO, estimate::OrderEstimate; label::AbstractString = "error")
    convergence_table(io::IO, grid::GridConvergence; label::AbstractString = "quantity")

Print a convergence study to `io`.

For an [`OrderEstimate`](@ref), a table of the levels with the columns `h`, `label`,
`order` (pairwise, with respect to the next coarser level) and `fit` (`*` for the levels
that entered the fit), followed by the fitted order with its interval and the constant
of e ≈ C hᵖ, or the order alone when the levels follow an exact power law.

For a [`GridConvergence`](@ref), the step size and value of the quantity `label` on each
grid, the refinement ratios, the observed order, the extrapolated value, the approximate
and extrapolated relative errors, the grid convergence indices of the fine and medium
grids in percent and the asymptotic ratio, with a final line when the convergence is
oscillatory.

Returns `nothing`.
"""
function convergence_table(io::IO, estimate::OrderEstimate; label::AbstractString = "error")
    levels = estimate.levels
    rows = Matrix{String}(undef, length(levels), 4)
    for (k, level) in enumerate(levels)
        order = level.order
        rows[k, 1] = g4(level.h)
        rows[k, 2] = g4(level.error)
        rows[k, 3] = order === nothing ? "" : @sprintf("%.3f", order)
        rows[k, 4] = level.fitted ? "*" : ""
    end
    pretty_table(
        io,
        rows;
        column_labels = String["h", String(label), "order", "fit"],
        alignment = [:r, :r, :r, :c],
        table_format = TABLE_FORMAT,
        fit_table_in_display_horizontally = false,
        fit_table_in_display_vertically = false,
    )
    m = fitted_count(estimate)
    p = estimate.order
    if estimate.standard_error == 0
        println(io, "Order p = $(g3(p)) (exact power law over $m levels)")
    else
        low, high = estimate.confidence_interval
        percent = round(Int, 100 * estimate.confidence_level)
        println(
            io,
            "Order p = $(g3(p)) ± $(g3(estimate.standard_error)) ($percent % interval [$(g3(low)), $(g3(high))]); e ≈ $(g3(estimate.constant)) h^p over $m levels",
        )
    end
    return nothing
end

function convergence_table(
    io::IO,
    grid::GridConvergence;
    label::AbstractString = "quantity",
)
    h1, h2, h3 = grid.h
    φ1, φ2, φ3 = grid.values
    r21, r32 = grid.refinement_ratios
    println(io, "Three-grid procedure (Celik et al. 2008) for $label")
    println(io, "  fine grid      h = $(g4(h1)), $label = $(g4(φ1))")
    println(io, "  medium grid    h = $(g4(h2)), $label = $(g4(φ2))")
    println(io, "  coarse grid    h = $(g4(h3)), $label = $(g4(φ3))")
    println(io, "  refinement ratios                r21 = $(g3(r21)), r32 = $(g3(r32))")
    println(io, "  observed order                   p = $(g3(grid.order))")
    println(io, "  extrapolated value               $(g4(grid.extrapolated))")
    println(io, "  approximate relative error       e_a = $(g3(grid.relative_error))")
    println(
        io,
        "  extrapolated relative error      e_ext = $(g3(grid.extrapolated_relative_error))",
    )
    println(io, "  GCI fine                         $(g3(100 * grid.gci_fine)) %")
    println(io, "  GCI medium                       $(g3(100 * grid.gci_medium)) %")
    println(io, "  asymptotic ratio                 $(g3(grid.asymptotic_ratio))")
    grid.oscillatory && println(io, "  oscillatory convergence")
    return nothing
end

"""
    show(io::IO, ::MIME"text/plain", estimate::OrderEstimate)

One line with the order, its standard error and the number of fitted levels.
"""
function Base.show(io::IO, ::MIME"text/plain", estimate::OrderEstimate)
    print(
        io,
        @sprintf(
            "OrderEstimate: p = %.2f ± %.2f over %d levels",
            estimate.order,
            estimate.standard_error,
            fitted_count(estimate)
        )
    )
    return nothing
end

"""
    safe_filepath(path) -> String

`path` when no file exists there, otherwise the first free `stem#k.ext`, so that no
output is overwritten.
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
