# convergence

Observed order of accuracy of a numerical scheme from a sequence of errors against the
step size. The tool forms the pairwise orders of successive levels, fits the order and
the constant of e ≈ C hᵖ by least squares with a Student-t interval, and, for a quantity
of interest without a known exact value, applies the three-grid procedure of Celik et al.
with Richardson extrapolation and the grid convergence index. Each run prints a report,
writes the levels to a CSV file and draws a publication figure. The package
`Convergence` implements the tool and can be used directly from Julia.

```
convergence/
├── activate.jl                  # environment activation
├── config.toml                  # fit and figure settings, validated on load
├── convergence.jl               # entry point
├── Project.toml                 # package
├── README.md
├── src/
│   ├── Convergence.jl           # module, imports, exports, includes
│   ├── norms.jl                 # discrete error norms
│   ├── orders.jl                # pairwise orders, fit, Richardson, three-grid procedure
│   ├── settings.jl              # TOML schema and constraints
│   ├── report.jl                # tables, collision-free paths
│   ├── figure.jl                # theme, figure, export
│   └── cli.jl                   # input CSV, command line
└── test/
    ├── Project.toml             # Aqua, ExplicitImports, JET, Test
    └── runtests.jl
```

## Usage

```bash
julia run.jl convergence --help
julia run.jl convergence errors.csv                                 # every series, default settings
julia run.jl convergence errors.csv --skip 1 --reference-orders 1,2 # drop the coarsest level
julia run.jl convergence errors.csv --confidence 0.99 --format png --out-dir results
julia run.jl convergence drag.csv --quantity --ylabel "Error in C_D"
julia convergence/convergence.jl errors.csv --no-csv                # without the dispatcher
```

Every column besides `h` is a series. The report gives, per series, the table of levels
with their pairwise orders and the fitted order with its interval. The CSV file
`convergence_<stem>_<timestamp>.csv` goes to `data/` and the figure
`convergence_<stem>.<format>` to `plots/`, or both to `--out-dir`; existing files are
never overwritten (`#1`, `#2`, ... suffixes). `--no-csv` and `--no-figure` suppress
either output.

With `--quantity` the columns hold values of a quantity of interest rather than errors.
The three finest levels of each series go through the three-grid procedure, whose report
precedes the table, and the error of every level becomes its distance |q − q_ext| from
the extrapolated value, which then enters the usual fit and figure.

## Method

**Error norms.** For a solution u and a reference u_ref on the same grid, with the cell
measure μ (h in one dimension, h² in two), the discrete L1 norm is μ Σ |uᵢ − u_ref,ᵢ|,
the L2 norm (μ Σ |uᵢ − u_ref,ᵢ|²)^(1/2) and the maximum norm max |uᵢ − u_ref,ᵢ|; the
relative norm ‖u − u_ref‖₂ / ‖u_ref‖₂ uses plain Euclidean norms, in which μ cancels.
Entries are widened to double precision before the difference is formed.

**Pairwise order.** With the levels sorted by decreasing h, the observed order between
levels k and k + 1 is p_k = ln(e_k / e_k+1) / ln(h_k / h_k+1). It is attached to the finer
level of the pair and shows whether the sequence has reached its asymptotic range.

**Least-squares fit.** The order and constant follow from ordinary least squares of
y = ln e on x = ln h over m levels: p = Sxy / Sxx and ln C = ȳ − p x̄. With the residual
sum of squares SSR and s² = SSR / (m − 2), the standard error of p is (s² / Sxx)^(1/2)
and the two-sided interval at confidence level γ is p ± t s_p, where t is the
1 − (1 − γ)/2 quantile of Student's t distribution with m − 2 degrees of freedom. An
exact power law has SSR = 0 and is reported as such. The coarsest levels of a sequence
are often outside the asymptotic range; `skip_coarsest` (or `--skip`) leaves that many of
them out of the fit, which needs at least three remaining levels. Excluded levels keep
their pairwise orders in the table and the figure.

**Three-grid procedure.** For a quantity φ on three grids h₁ < h₂ < h₃ with refinement
ratios r21 = h₂/h₁ and r32 = h₃/h₂, let ε21 = φ₂ − φ₁, ε32 = φ₃ − φ₂ and s = sign(ε32/ε21);
s < 0 indicates oscillatory convergence. The observed order solves

```
p = |ln|ε32/ε21| + q(p)| / ln(r21),   q(p) = ln((r21^p − s) / (r32^p − s))
```

by fixed-point iteration from q = 0, to 10⁻¹² in p; with a constant refinement ratio q
vanishes. Then

```
φ_ext  = (r21^p φ₁ − φ₂) / (r21^p − 1)
e_a    = |(φ₁ − φ₂) / φ₁|,            e_ext = |(φ_ext − φ₁) / φ_ext|
GCI21  = F_s e_a / (r21^p − 1),       GCI32 = F_s |(φ₂ − φ₃) / φ₂| / (r32^p − 1)
```

with the safety factor F_s = 1.25 recommended for three or more grids. The ratio
r21^p GCI21 / GCI32 approaches 1 when the grids lie in the asymptotic range. The
procedure follows Celik, Ghia, Roache, Freitas, Coleman and Raad, J. Fluids Eng. 130(7),
078001 (2008), doi:[10.1115/1.2960953](https://doi.org/10.1115/1.2960953); the grid
convergence index is due to Roache, J. Fluids Eng. 116(3), 405–413 (1994),
doi:[10.1115/1.2910291](https://doi.org/10.1115/1.2910291).

**Richardson extrapolation.** Two solutions of a scheme of order p on grids with
refinement ratio r = h_coarse / h_fine combine into (r^p f_fine − f_coarse) / (r^p − 1),
which cancels the leading error term; `richardson_extrapolate` applies it to numbers and,
entry by entry, to arrays.

## Input

A CSV file with a header row and one row per level, in any order. The column `h` holds
the step sizes, which must be positive and distinct; every other column is a series,
numeric without missing cells.

```csv
h,L2,Linf
0.1,3.12e-3,6.05e-3
0.05,7.84e-4,1.53e-3
0.025,1.96e-4,3.84e-4
0.0125,4.91e-5,9.61e-5
```

## Library use

```julia
include("convergence/activate.jl")
using Convergence

# forward Euler for y' = -y, y(0) = 1, integrated to t = 1
function euler(h)
    y = 1.0
    for _ in 1:round(Int, 1 / h)
        y -= h * y
    end
    return y
end

estimate = convergence_study(h -> abs(euler(h) - exp(-1)), [0.1, 0.05, 0.025, 0.0125])
convergence_table(stdout, estimate)                 # order close to 1
fig = convergence_figure(estimate; reference_orders = [1])
```

For field solutions, `convergence_study(solve, exact, h; norm = :L2, measure = h -> h^2)`
evaluates `error_norm(solve(h), exact(h), norm; measure = measure(h))` at every step
size. `fit_order`, `pairwise_orders`, `grid_convergence` and `richardson_extrapolate`
take plain vectors and numbers.

## Figure

The figure has two panels sharing a logarithmic step-size axis. The upper panel shows
the error of every series on logarithmic axes with the fitted power law C hᵖ dashed over
the fitted range; levels left out of the fit are drawn as hollow markers. Reference
orders appear as dotted grey lines through the coarsest fitted point of the first
series, labelled with their slope at the fine end. The strip below shows the pairwise
orders at the finer step size of each pair, with the fitted order as a dashed guide; a
sequence that has not reached its asymptotic order shows as a drift away from it. The
legend above names each series with its fitted order and standard error, printed with as
many decimals as the error needs. The x ticks sit at the step sizes when there are at
most eight of them and none is below 10⁻³, at the decades otherwise.

## Configuration

`config.toml` next to the entry point is read by default; `--config FILE` replaces it and
the command-line options apply on top. Unknown keys are rejected, and a value of the
wrong type or out of bounds stops the tool with a message naming the key.

```toml
[fit]
confidence_level = 0.95  # float in (0, 1); coverage of the t-interval of the order
skip_coarsest = 0  # integer >= 0; coarsest levels left out of the least-squares fit
safety_factor = 1.25  # float >= 1; safety factor of the grid convergence index

[figures]
format = "pdf"  # one of: "pdf" | "png" | "svg"
width_mm = 86.0  # float in [60, 300] [mm]; printed figure width
px_per_unit = 5  # integer >= 1 [px/pt]; raster export only
fontsize_pt = 9.0  # float in [6, 14] [pt]
reference_orders = []  # list of reals > 0; slopes of the reference lines
xlabel = "Step size h"  # non-empty string; x-axis label
ylabel = "Error"  # non-empty string; y-axis label of the error panel
output_directory = "plots"  # path; relative to this tool

[output]
csv_directory = "data"  # path; relative to this tool
```

The CSV file has the columns `series, h, error, order, fitted`, one row per level of
every series; `order` is the pairwise order and is empty for the coarsest level.

## Tests

```bash
julia test.jl convergence
julia --project=convergence -e 'using Pkg; Pkg.test()'
```

The suite runs the static checks of Aqua, JET and ExplicitImports on the package
together with the unit tests.
