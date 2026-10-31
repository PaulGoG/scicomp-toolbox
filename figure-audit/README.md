# figure-audit

Checks exported figures (PDF, PNG, SVG) against the printed column width and the
typographic requirements of a manuscript: the exported width against the target column,
the height once printed, the page count, font embedding and subsetting, the smallest text
size after LaTeX has scaled the figure, the resolution of raster content, and whether a
PNG has a vector version beside it. The tool prints one line per figure and exits with a
non-zero status when a figure fails, so that it can gate a manuscript build. Poppler comes
through `Poppler_jll`, so nothing is installed on the system; the figures are only read.

```
figure-audit/
├── activate.jl                  # environment activation
├── config.toml                  # column widths, typographic and raster limits; validated on load
├── figure-audit.jl              # entry point, readers and checks
├── Manifest.toml                # resolved with Julia 1.12, the compat floor (see Tests)
├── Project.toml                 # Poppler_jll; Cairo and Test serve the test suite only
├── README.md
└── test/
    └── runtests.jl              # fixtures drawn with Cairo at test time; parsing, checks, report, CSV, CLI
```

## Usage

```bash
julia run.jl figure-audit paper/figures --column double
julia run.jl figure-audit paper/figures/spectrum.pdf --width 120
julia run.jl figure-audit paper/figures --strict --verbose
julia run.jl figure-audit paper/figures --csv figure-audit.csv
```

Paths resolve against the working directory. A directory contributes its PDF, PNG and SVG
files, not those of its subdirectories. The target width is the one given by `--width`,
for a declared artwork width, else that of the column named by `--column`, else that of
`[columns].default`.

```
PASS  spectrum.pdf
FAIL  residuals.pdf  size: 150.0 mm wide, target 178.0 ± 1.0 mm (LaTeX would scale by 1.187)
WARN  map.png  vector: vector version available: map.pdf
3 figures: 1 failed, 1 with warnings, 1 passed
```

A figure line lists its failed checks and then its warnings; `--verbose` adds every check
on its own line. The exit status is 0 when no figure fails, 1 when one does, and 2 for an
invalid argument or configuration; under `--strict` a warning counts as a failure. A build
that runs the audit before LaTeX and stops on a non-zero status therefore never typesets
a figure that LaTeX would rescale or that falls below the limits. `--csv FILE` writes one
row per check with the exported size and the scale factor.

## Checks

| Check | Formats | Pass condition | Otherwise |
| :--- | :--- | :--- | :--- |
| `size` | PDF, PNG, SVG | exported width within `tolerance_mm` of the target | fail, with the factor LaTeX would scale by; skip for a PNG without physical size |
| `height` | PDF, PNG, SVG | height scaled to the target width at most `max_height_mm` | fail; skip when the size is unknown |
| `pages` | PDF | one page | warn |
| `fonts` | PDF | every font embedded and subset, none of Type 3 | fail when a font is not embedded; warn for Type 3 or an unsubset font, fail for the latter under `require_subset`; info for live SVG text |
| `text_size` | PDF | smallest text, scaled to the target width, at least `min_font_pt` | fail |
| `raster` | PNG, PDF, SVG | PNG: pixel width over the target width at least `min_dpi`; PDF: every embedded image at least `min_dpi` once printed | fail for a PNG; warn for a PDF, and for any image embedded in an SVG |
| `vector` | PNG | no PDF or SVG of the same name in the directory | warn |
| `colour` | PNG, PDF | information only: colour type and bit depth, colour spaces of embedded images | info |

A check that does not apply to a format is reported as skipped. A file that cannot be
parsed carries the single check `readable`, which fails.

## How sizes are read

The width and height of a PDF are those of its first page as `pdfinfo` reports them. A PNG
records a physical size only in its pHYs chunk, as pixels per metre; without it the width
is unknown and only the resolution at the target width is checked. An SVG gives its size in
the `width` and `height` attributes of the root element, in pt, px (0.75 pt), mm, cm or in,
or else through the viewBox, taken in px.

Text sizes come from `pdftohtml -xml -zoom 3`, which lists every font size on a page scaled
by the zoom. Dividing by the ratio of the reported page width to the true one gives the
size in points; since the reported sizes are whole numbers, they are known to about
0.2 pt, and the comparison with `min_font_pt` uses the value rounded to 0.1 pt. The
resolution of an image embedded in a PDF is the one `pdfimages -list` reports for the page,
divided by the scale factor. An SVG produced by Cairo or Makie draws glyphs as outlines;
only live `<text>` elements are counted, and their fonts depend on where the file is
rendered.

## Configuration

`config.toml` holds the column widths, the width tolerance and the largest printed height
(`[columns]`), the smallest text size and whether unsubset fonts fail (`[typography]`),
and the smallest raster resolution (`[raster]`). Absent keys take the shipped defaults;
unknown keys and out-of-range values are rejected with a message naming the key.

## Tests

```bash
julia test.jl figure-audit
```

The manifest is resolved with Julia 1.12 rather than the current stable release:
`Zstd_jll` became a standard library in 1.13 and a manifest resolved there records it
without a tree hash, which 1.12 cannot load, and Poppler reaches it through Libtiff at
load time. Resolved on 1.12 the manifest pins the registered `Zstd_jll`, which both
versions load.

The suite draws its fixtures with Cairo in `mktempdir()`, so none is committed: a PDF at
double-column width with text at 9 and 7.5 pt, a narrower one, a tall two-page one, one
without text and one with an embedded raster, a PNG with a pHYs chunk inserted at 300 dpi
and a vector sibling, a PNG without physical size, an SVG, a PDF that references
Helvetica without embedding it, and two broken files. Cairo and Test are in the
environment for this reason only; the tool itself loads neither. The suite checks the
settings validation, the PNG, SVG and PDF readers, every check on these fixtures, the
file collection, the report, the CSV and the command line.
