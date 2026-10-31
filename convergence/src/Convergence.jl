"""
    Convergence

Observed order of accuracy of a numerical scheme from a sequence of errors against the
step size: pairwise orders, a least-squares fit of log e on log h with a Student-t
interval, Richardson extrapolation and the three-grid procedure of Celik et al. (2008),
with a text report, a CSV export and a publication figure.
"""
module Convergence

using CSV: CSV
using CairoMakie.Makie:
    Axis,
    Figure,
    Legend,
    LineElement,
    MarkerElement,
    RGBAf,
    Theme,
    hidexdecorations!,
    hlines!,
    lines!,
    linkxaxes!,
    rich,
    scatter!,
    set_theme!,
    superscript,
    text!,
    to_color,
    xlims!,
    ylims!
using CairoMakie.Makie.FileIO: save
using CairoMakie.Makie.GridLayoutBase: Auto, rowgap!, rowsize!
using Distributions: TDist
using MathTeXEngine: texfont
using PrettyTables: TextTableFormat, pretty_table, text_table_borders__compact
using Printf: @sprintf
using Statistics: mean, quantile
using TOML: TOML

export ConvergenceLevel, OrderEstimate, GridConvergence, StudySettings
export error_norm, pairwise_orders, fit_order, richardson_extrapolate, grid_convergence
export convergence_study, convergence_table, convergence_figure
export validate_settings, load_settings, read_series, main

include("norms.jl")
include("orders.jl")
include("settings.jl")
include("report.jl")
include("figure.jl")
include("cli.jl")

end
