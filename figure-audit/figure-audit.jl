#!/usr/bin/env julia
# figure-audit — checks exported figures (PDF, PNG, SVG) against the printed column width
# and the typographic requirements of a manuscript: width, printed height, pages, fonts,
# text size, raster resolution, vector siblings and colour. One line per figure; the exit
# status is non-zero when a figure fails, so the tool can gate a manuscript build.
#
#   julia run.jl figure-audit PATH ... [--column single|double | --width MM] [--strict]
#                                      [--verbose] [--csv FILE] [--config PATH]

using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)

using Poppler_jll: Poppler_jll
using Printf: @sprintf
using TOML: TOML

const MM_PER_PT = 25.4 / 72
const COLUMNS = ("single", "double")
const FIGURE_EXTENSIONS = (".pdf", ".png", ".svg")

# --- settings --------------------------------------------------------------------------

"""
    AuditSettings(default_column, single_mm, double_mm, tolerance_mm, max_height_mm,
                  min_font_pt, require_subset, min_dpi)

Validated configuration: the column whose width is the target by default (`"single"` or
`"double"`), the two column widths, the tolerance on the exported width and the largest
printed height [mm]; the smallest printed text size [pt] and whether a font embedded
without subsetting fails; the smallest raster resolution at the printed size [dpi].
"""
struct AuditSettings
    default_column::String
    single_mm::Float64
    double_mm::Float64
    tolerance_mm::Float64
    max_height_mm::Float64
    min_font_pt::Float64
    require_subset::Bool
    min_dpi::Int
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

"""
    bounded_real(table, key, default, context, bounds, valid) -> Float64

Value of `key` in `table` (`default` when absent) as a `Float64`. Integers are accepted,
`Bool` and non-finite values are not; `valid` decides the bounds, which `bounds` states
in the error message.
"""
function bounded_real(
    table::AbstractDict,
    key::AbstractString,
    default::Float64,
    context::AbstractString,
    bounds::AbstractString,
    valid::Function,
)
    value = get(table, key, default)
    (value isa Real && !(value isa Bool) && isfinite(value) && valid(value)) ||
        throw(ArgumentError("$context.$key must be a number $bounds, got $(repr(value))"))
    return Float64(value)
end

"""
    validate_settings(raw::AbstractDict) -> AuditSettings

Enforce the schema of the configuration tables `[columns]`, `[typography]` and
`[raster]`; absent keys take the defaults of the shipped `config.toml`. Fails with an
`ArgumentError` naming the offending key.
"""
function validate_settings(raw::AbstractDict)
    reject_unknown_keys(raw, ("columns", "typography", "raster"), "top level")
    columns = section(raw, "columns")
    typography = section(raw, "typography")
    raster = section(raw, "raster")
    reject_unknown_keys(
        columns,
        ("default", "single_mm", "double_mm", "tolerance_mm", "max_height_mm"),
        "[columns]",
    )
    reject_unknown_keys(typography, ("min_font_pt", "require_subset"), "[typography]")
    reject_unknown_keys(raster, ("min_dpi",), "[raster]")

    default_column = get(columns, "default", "double")
    default_column in COLUMNS || throw(
        ArgumentError(
            "[columns].default must be \"single\" or \"double\", got $(repr(default_column))",
        ),
    )
    column_number(key, default, bounds, valid) =
        bounded_real(columns, key, default, "[columns]", bounds, valid)
    single_mm = column_number("single_mm", 86.0, "in [40, 400]", x -> 40 <= x <= 400)
    double_mm = column_number("double_mm", 178.0, "in [40, 400]", x -> 40 <= x <= 400)
    tolerance_mm = column_number("tolerance_mm", 1.0, ">= 0", x -> x >= 0)
    max_height_mm = column_number("max_height_mm", 230.0, "in (0, 500]", x -> 0 < x <= 500)
    min_font_pt = bounded_real(
        typography,
        "min_font_pt",
        7.0,
        "[typography]",
        "in (0, 72]",
        x -> 0 < x <= 72,
    )
    require_subset = get(typography, "require_subset", false)
    require_subset isa Bool || throw(
        ArgumentError(
            "[typography].require_subset must be a boolean, got $(repr(require_subset))",
        ),
    )
    min_dpi = get(raster, "min_dpi", 300)
    (min_dpi isa Integer && !(min_dpi isa Bool) && 1 <= min_dpi <= 10000) || throw(
        ArgumentError(
            "[raster].min_dpi must be an integer in [1, 10000], got $(repr(min_dpi))",
        ),
    )
    return AuditSettings(
        String(default_column),
        single_mm,
        double_mm,
        tolerance_mm,
        max_height_mm,
        min_font_pt,
        require_subset,
        Int(min_dpi),
    )
end

"""
    load_settings(path::AbstractString) -> AuditSettings

Parse and validate a configuration file.
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

"""
    column_width(settings::AuditSettings, column::AbstractString) -> Float64

Width [mm] of the `"single"` or `"double"` column.
"""
column_width(settings::AuditSettings, column::AbstractString) =
    column == "single" ? settings.single_mm : settings.double_mm

# --- results ---------------------------------------------------------------------------

"""
    CheckResult(check::Symbol, status::Symbol, detail::String)

Outcome of one check of one figure. `status` is `:pass`, `:fail`, `:warn`, `:info` (a
statement that never fails) or `:skip` (the check does not apply); `detail` is the
human-readable finding.
"""
struct CheckResult
    check::Symbol
    status::Symbol
    detail::String
end

"""
    FigureReport(path, format, width_mm, height_mm, scale, checks)

Audit of one figure: its path, its format (`:pdf`, `:png` or `:svg`), its exported width
and height [mm] (`nothing` when the file records no physical size), the factor by which
LaTeX scales it to the target width (target width divided by exported width, `nothing`
when the width is unknown) and the results of the checks in reporting order. An
unreadable file holds the single check `readable`.
"""
struct FigureReport
    path::String
    format::Symbol
    width_mm::Union{Float64, Nothing}
    height_mm::Union{Float64, Nothing}
    scale::Union{Float64, Nothing}
    checks::Vector{CheckResult}
end

"""
    PdfFont(name, type, encoding, embedded, subset)

One row of `pdffonts`: font name, font type (`"Type 1C"`, `"TrueType (CID)"`, ...),
encoding, and whether the font is embedded and subset.
"""
struct PdfFont
    name::String
    type::String
    encoding::String
    embedded::Bool
    subset::Bool
end

"""
    PdfImage(page, kind, width, height, colour, bits, x_ppi, y_ppi)

One image row of `pdfimages -list`: page, kind (`"image"`), pixel width and height,
colour space, bits per component, and the resolution at which the page draws it [ppi];
`NaN` where Poppler reports none.
"""
struct PdfImage
    page::Int
    kind::String
    width::Int
    height::Int
    colour::String
    bits::Int
    x_ppi::Float64
    y_ppi::Float64
end

"""
    UnreadableFigure(detail::String)

Raised by the readers when a figure cannot be parsed; [`audit_figure`](@ref) turns it
into a report holding the single check `readable` with `detail`.
"""
struct UnreadableFigure <: Exception
    detail::String
end

Base.showerror(io::IO, err::UnreadableFigure) = print(io, "unreadable figure: ", err.detail)

# --- Poppler ---------------------------------------------------------------------------

"""
    poppler(product::Function, args::Vector{String})
        -> (exit_code::Int, stdout_text::String, stderr_text::String)

Run the Poppler executable of the `Poppler_jll` product function `product` with `args`,
whatever its exit status, and capture its standard output and error separately.
"""
function poppler(product::Function, args::Vector{String})
    out = IOBuffer()
    err = IOBuffer()
    process = run(pipeline(ignorestatus(`$(product()) $args`); stdout = out, stderr = err))
    return process.exitcode, String(take!(out)), String(take!(err))
end

# Standard output of a Poppler call. Poppler reports "Syntax Warning" lines on stderr for
# files it can still read, so only the exit status decides; on failure the last non-empty
# stderr line becomes the detail of the `readable` check.
function poppler_output(product::Function, args::Vector{String})
    code, out, err = poppler(product, args)
    code == 0 && return out
    lines = filter(!isempty, strip.(split(err, '\n')))
    detail = isempty(lines) ? "$(nameof(product)) exited with status $code" : last(lines)
    throw(UnreadableFigure(String(detail)))
end

"""
    pdf_info(path) -> (pages::Int, width_pt::Float64, height_pt::Float64, producer::String)

Page count, size of the first page [pt] and producer (empty when absent), read with
`pdfinfo`. Throws [`UnreadableFigure`](@ref) when Poppler cannot read the file.
"""
function pdf_info(path::AbstractString)
    text = poppler_output(Poppler_jll.pdfinfo, [String(path)])
    pages = match(r"(?m)^Pages:\s+(\d+)", text)
    page_size = match(r"(?m)^Page size:\s+([0-9.]+) x ([0-9.]+) pts", text)
    (pages === nothing || page_size === nothing) &&
        throw(UnreadableFigure("pdfinfo reports no page count or page size"))
    producer = match(r"(?m)^Producer:[ \t]*(.*)$", text)
    return (;
        pages = parse(Int, pages.captures[1]),
        width_pt = parse(Float64, page_size.captures[1]),
        height_pt = parse(Float64, page_size.captures[2]),
        producer = producer === nothing ? "" : String(strip(producer.captures[1])),
    )
end

"""
    pdf_fonts(path) -> Vector{PdfFont}

Fonts listed by `pdffonts`; empty when the file holds no text. The rows are sliced at the
offsets where the header words `type`, `encoding`, `emb`, `sub` and `uni` begin, since the
type column contains spaces.
"""
function pdf_fonts(path::AbstractString)
    lines = split(poppler_output(Poppler_jll.pdffonts, [String(path)]), '\n')
    at = findfirst(line -> startswith(line, "name"), lines)
    at === nothing && throw(UnreadableFigure("pdffonts prints no header"))
    header = lines[at]
    starts = Int[]
    for word in ("type", "encoding", "emb", "sub", "uni")
        found = findfirst(word, header)
        found === nothing && throw(UnreadableFigure("pdffonts header lacks '$word'"))
        push!(starts, first(found))
    end
    fonts = PdfFont[]
    for line in lines[(at + 2):end]
        isempty(strip(line)) && continue
        chars = collect(line)
        field(a, b) = String(strip(String(chars[a:min(b, length(chars))])))
        push!(
            fonts,
            PdfFont(
                field(1, starts[1] - 1),
                field(starts[1], starts[2] - 1),
                field(starts[2], starts[3] - 1),
                field(starts[3], starts[4] - 1) == "yes",
                field(starts[4], starts[5] - 1) == "yes",
            ),
        )
    end
    return fonts
end

"""
    pdf_text_sizes(path, width_pt) -> Vector{Float64}

Sizes [pt] of the fonts `pdftohtml` finds in the file, one per font specification;
empty when there is no text. pdftohtml scales the page by its zoom, so a reported size
`S` on a page `W` units wide is `S * width_pt / W` points.
"""
function pdf_text_sizes(path::AbstractString, width_pt::Real)
    text = poppler_output(
        Poppler_jll.pdftohtml,
        ["-xml", "-i", "-zoom", "3", "-stdout", String(path)],
    )
    sizes = [
        parse(Float64, m.captures[1]) for
        m in eachmatch(r"<fontspec\b[^>]*\ssize=\"([0-9.]+)\"", text)
    ]
    isempty(sizes) && return Float64[]
    page = match(r"<page\b[^>]*\swidth=\"([0-9.]+)\"", text)
    page === nothing && throw(UnreadableFigure("pdftohtml reports no page width"))
    zoomed_width = parse(Float64, page.captures[1])
    zoomed_width > 0 || throw(UnreadableFigure("pdftohtml reports a page width of 0"))
    return sizes .* (width_pt / zoomed_width)
end

function ppi_value(text::AbstractString)
    value = tryparse(Float64, text)
    return (value === nothing || !isfinite(value)) ? NaN : value
end

"""
    pdf_images(path) -> Vector{PdfImage}

Images listed by `pdfimages -list`; soft masks and stencils are left out. A resolution
that Poppler reports as `inf` or not at all is `NaN`.
"""
function pdf_images(path::AbstractString)
    text = poppler_output(Poppler_jll.pdfimages, ["-list", String(path)])
    images = PdfImage[]
    for line in split(text, '\n')
        fields = split(line)
        # the header and the dash line fail this test as well
        (length(fields) >= 14 && fields[3] == "image") || continue
        page, width, height, bits = tryparse.(Int, fields[[1, 4, 5, 8]])
        any(isnothing, (page, width, height, bits)) && continue
        push!(
            images,
            PdfImage(
                page,
                String(fields[3]),
                width,
                height,
                String(fields[6]),
                bits,
                ppi_value(fields[13]),
                ppi_value(fields[14]),
            ),
        )
    end
    return images
end

# --- PNG and SVG -----------------------------------------------------------------------

const PNG_SIGNATURE = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
const PNG_COLOUR_TYPES = Dict(
    0 => "greyscale",
    2 => "RGB",
    3 => "palette",
    4 => "greyscale with alpha",
    6 => "RGBA",
)

be32(bytes::AbstractVector{UInt8}, i::Int) =
    (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16) | (Int(bytes[i + 2]) << 8) |
    Int(bytes[i + 3])

"""
    png_info(path) -> (width, height, bit_depth, colour::String, ppu)

Pixel width and height, bit depth and colour type of a PNG file from its IHDR chunk,
and the horizontal pixels per metre of its pHYs chunk (`ppu`, `nothing` when the chunk
is absent or its unit is not the metre). CRCs are not verified. Throws
[`UnreadableFigure`](@ref) for a file without the PNG signature or a valid IHDR chunk.
"""
function png_info(path::AbstractString)
    bytes = read(path)
    (length(bytes) >= 8 && bytes[1:8] == PNG_SIGNATURE) ||
        throw(UnreadableFigure("not a PNG file"))
    header = nothing
    ppu = nothing
    position = 9
    # chunk: 4-byte big-endian length, 4-byte type, data, 4-byte CRC
    while position + 7 <= length(bytes)
        chunk_length = be32(bytes, position)
        chunk_type = String(bytes[(position + 4):(position + 7)])
        chunk_type == "IEND" && break
        first_byte = position + 8
        last_byte = first_byte + chunk_length - 1
        last_byte + 4 <= length(bytes) ||
            throw(UnreadableFigure("truncated $chunk_type chunk"))
        data = @view bytes[first_byte:last_byte]
        if chunk_type == "IHDR" && chunk_length == 13
            header = (;
                width = be32(data, 1),
                height = be32(data, 5),
                bit_depth = Int(data[9]),
                colour_type = Int(data[10]),
            )
        elseif chunk_type == "pHYs" && chunk_length == 9
            ppu = (data[9] == 0x01 && be32(data, 1) > 0) ? Float64(be32(data, 1)) : nothing
        end
        position = last_byte + 5
    end
    header === nothing && throw(UnreadableFigure("no IHDR chunk"))
    colour = get(PNG_COLOUR_TYPES, header.colour_type, "colour type $(header.colour_type)")
    return (;
        width = header.width,
        height = header.height,
        bit_depth = header.bit_depth,
        colour,
        ppu,
    )
end

# points per unit of the SVG length units; unitless lengths are user units, taken as px
const SVG_UNITS = Dict(
    "pt" => 1.0,
    "px" => 0.75,
    "" => 0.75,
    "mm" => 72 / 25.4,
    "cm" => 72 / 2.54,
    "in" => 72.0,
)

function svg_attribute(tag::AbstractString, name::AbstractString)
    m = match(Regex("\\s$name\\s*=\\s*([\"'])(.*?)\\1"), tag)
    return m === nothing ? nothing : String(strip(m.captures[2]))
end

svg_length(::Nothing) = nothing
function svg_length(text::AbstractString)
    m = match(r"^([0-9]*\.?[0-9]+(?:[eE][+-]?[0-9]+)?)\s*([a-zA-Z]*)$", text)
    m === nothing && return nothing
    factor = get(SVG_UNITS, lowercase(m.captures[2]), nothing)
    factor === nothing && return nothing
    return parse(Float64, m.captures[1]) * factor
end

"""
    svg_info(text) -> (width_pt, height_pt, texts::Int, images::Int)

Width and height [pt] from the `width` and `height` attributes of the root `<svg>` tag
(units pt, px or none at 0.75 pt per px, mm, cm, in), each falling back on the viewBox
in px when absent, `nothing` when neither gives it; and the numbers of `<text>` and
`<image>` elements in the whole text. Throws [`UnreadableFigure`](@ref) when there is no
root tag.
"""
function svg_info(text::AbstractString)
    root = match(r"<svg\b[^>]*>", text)
    root === nothing && throw(UnreadableFigure("no <svg> root element"))
    tag = root.match
    width_pt = svg_length(svg_attribute(tag, "width"))
    height_pt = svg_length(svg_attribute(tag, "height"))
    box = svg_attribute(tag, "viewBox")
    if box !== nothing && (width_pt === nothing || height_pt === nothing)
        values = tryparse.(Float64, split(box, r"[\s,]+"; keepempty = false))
        if length(values) == 4 && !any(isnothing, values)
            width_pt = something(width_pt, values[3] * SVG_UNITS["px"])
            height_pt = something(height_pt, values[4] * SVG_UNITS["px"])
        end
    end
    return (;
        width_pt,
        height_pt,
        texts = count(r"<text\b", text),
        images = count(r"<image\b", text),
    )
end

# --- figures ---------------------------------------------------------------------------

"""
    PdfFigure

What Poppler reports about a PDF: path, page count, page size [mm], producer, fonts, text
sizes [pt] and embedded images.
"""
struct PdfFigure
    path::String
    pages::Int
    width_mm::Float64
    height_mm::Float64
    producer::String
    fonts::Vector{PdfFont}
    text_sizes::Vector{Float64}
    images::Vector{PdfImage}
end

"""
    PngFigure

Header of a PNG: path, pixel width and height, bit depth, colour type and horizontal
pixels per metre (`nothing` without a pHYs chunk in metres).
"""
struct PngFigure
    path::String
    width::Int
    height::Int
    bit_depth::Int
    colour::String
    ppu::Union{Float64, Nothing}
end

"""
    SvgFigure

Root tag and content counts of an SVG: path, width and height [mm] (`nothing` when not
recorded), and the numbers of live text elements and embedded images.
"""
struct SvgFigure
    path::String
    width_mm::Union{Float64, Nothing}
    height_mm::Union{Float64, Nothing}
    texts::Int
    images::Int
end

function read_figure(path::String, ::Val{:pdf})
    info = pdf_info(path)
    return PdfFigure(
        path,
        info.pages,
        info.width_pt * MM_PER_PT,
        info.height_pt * MM_PER_PT,
        info.producer,
        pdf_fonts(path),
        pdf_text_sizes(path, info.width_pt),
        pdf_images(path),
    )
end

function read_figure(path::String, ::Val{:png})
    info = png_info(path)
    return PngFigure(path, info.width, info.height, info.bit_depth, info.colour, info.ppu)
end

function read_figure(path::String, ::Val{:svg})
    info = svg_info(read(path, String))
    to_mm(pt) = pt === nothing ? nothing : pt * MM_PER_PT
    return SvgFigure(
        path,
        to_mm(info.width_pt),
        to_mm(info.height_pt),
        info.texts,
        info.images,
    )
end

figure_width_mm(figure::Union{PdfFigure, SvgFigure}) = figure.width_mm
figure_width_mm(figure::PngFigure) =
    figure.ppu === nothing ? nothing : figure.width / figure.ppu * 1000
figure_height_mm(figure::Union{PdfFigure, SvgFigure}) = figure.height_mm
figure_height_mm(figure::PngFigure) =
    figure.ppu === nothing ? nothing : figure.height / figure.ppu * 1000

counted(n::Integer, noun::AbstractString) = n == 1 ? "1 $noun" : "$n $(noun)s"

# --- checks ----------------------------------------------------------------------------

unknown_size(::PngFigure) = "no physical size recorded (see raster)"
unknown_size(::SvgFigure) = "no physical size recorded"

"""
    check_size(figure, settings, target_mm) -> CheckResult

Exported width against the target width ± `tolerance_mm`; on failure, the factor by
which LaTeX would scale the figure. Skipped when the file records no physical size.
"""
function check_size(figure, settings::AuditSettings, target_mm::Float64)
    width = figure_width_mm(figure)
    width === nothing && return CheckResult(:size, :skip, unknown_size(figure))
    target = @sprintf("%.1f ± %.1f mm", target_mm, settings.tolerance_mm)
    abs(width - target_mm) <= settings.tolerance_mm || return CheckResult(
        :size,
        :fail,
        @sprintf(
            "%.1f mm wide, target %s (LaTeX would scale by %.3f)",
            width,
            target,
            target_mm / width
        ),
    )
    return CheckResult(:size, :pass, @sprintf("%.1f mm wide (target %s)", width, target))
end

"""
    check_height(figure, settings, target_mm) -> CheckResult

Printed height, the exported height scaled to the target width, against
`max_height_mm`. Skipped when the size is unknown.
"""
function check_height(figure, settings::AuditSettings, target_mm::Float64)
    width = figure_width_mm(figure)
    height = figure_height_mm(figure)
    (width === nothing || height === nothing) &&
        return CheckResult(:height, :skip, "height unknown")
    printed = height * target_mm / width
    printed > settings.max_height_mm && return CheckResult(
        :height,
        :fail,
        @sprintf("printed height %.1f mm exceeds %.1f mm", printed, settings.max_height_mm),
    )
    return CheckResult(:height, :pass, @sprintf("printed height %.1f mm", printed))
end

"""
    check_pages(figure, settings, target_mm) -> CheckResult

A PDF figure is one page; more pages warn. Skipped for PNG and SVG.
"""
function check_pages(figure::PdfFigure, ::AuditSettings, ::Float64)
    figure.pages > 1 &&
        return CheckResult(:pages, :warn, "$(figure.pages) pages; a figure is one page")
    return CheckResult(:pages, :pass, counted(figure.pages, "page"))
end
check_pages(::Union{PngFigure, SvgFigure}, ::AuditSettings, ::Float64) =
    CheckResult(:pages, :skip, "not paged")

"""
    check_fonts(figure, settings, target_mm) -> CheckResult

PDF: every font embedded (fail otherwise); a Type 3 font warns, and so does an embedded
font without subsetting, which fails instead under `require_subset`. SVG: the live text
elements are reported, since their fonts are resolved where the file is rendered.
Skipped for PNG and for files without text.
"""
function check_fonts(figure::PdfFigure, settings::AuditSettings, ::Float64)
    fonts = figure.fonts
    isempty(fonts) && return CheckResult(:fonts, :skip, "no text")
    unembedded = unique(f.name for f in fonts if !f.embedded)
    isempty(unembedded) ||
        return CheckResult(:fonts, :fail, "not embedded: $(join(unembedded, ", "))")
    findings = String[]
    type3 = unique(f.name for f in fonts if occursin("Type 3", f.type))
    isempty(type3) ||
        push!(findings, "Type 3 font$(length(type3) > 1 ? "s" : ""): $(join(type3, ", "))")
    whole = unique(f.name for f in fonts if !f.subset)
    isempty(whole) || push!(findings, "not subset: $(join(whole, ", "))")
    detail = join(findings, "; ")
    (settings.require_subset && !isempty(whole)) &&
        return CheckResult(:fonts, :fail, detail)
    isempty(findings) || return CheckResult(:fonts, :warn, detail)
    return CheckResult(
        :fonts,
        :pass,
        "$(counted(length(fonts), "font")) embedded and subset",
    )
end
function check_fonts(figure::SvgFigure, ::AuditSettings, ::Float64)
    figure.texts > 0 || return CheckResult(:fonts, :skip, "no text")
    return CheckResult(
        :fonts,
        :info,
        "$(counted(figure.texts, "live text element")); fonts are resolved where the file is rendered",
    )
end
check_fonts(::PngFigure, ::AuditSettings, ::Float64) = CheckResult(:fonts, :skip, "raster")

"""
    check_text_size(figure, settings, target_mm) -> CheckResult

Smallest PDF text size scaled to the target width against `min_font_pt`, compared at
the one decimal reported, since pdftohtml quantises the sizes. Skipped for PNG, SVG and
files without text.
"""
function check_text_size(figure::PdfFigure, settings::AuditSettings, target_mm::Float64)
    sizes = figure.text_sizes
    isempty(sizes) && return CheckResult(:text_size, :skip, "no text")
    scale = target_mm / figure.width_mm
    smallest = minimum(sizes) * scale
    round(smallest; digits = 1) < settings.min_font_pt && return CheckResult(
        :text_size,
        :fail,
        @sprintf(
            "smallest text %.1f pt after scaling by %.3f (minimum %.1f pt)",
            smallest,
            scale,
            settings.min_font_pt
        ),
    )
    return CheckResult(
        :text_size,
        :pass,
        @sprintf(
            "text %.1f to %.1f pt after scaling by %.3f",
            smallest,
            maximum(sizes) * scale,
            scale
        ),
    )
end
check_text_size(::PngFigure, ::AuditSettings, ::Float64) =
    CheckResult(:text_size, :skip, "raster")
check_text_size(::SvgFigure, ::AuditSettings, ::Float64) =
    CheckResult(:text_size, :skip, "not read from SVG")

"""
    check_raster(figure, settings, target_mm) -> CheckResult

PNG: pixel width over the target width, in whole dpi, against `min_dpi` (fail). PDF:
every embedded image at its printed resolution against `min_dpi` (warn). SVG: embedded
images warn, their resolution unread.
"""
function check_raster(figure::PngFigure, settings::AuditSettings, target_mm::Float64)
    dpi = round(Int, figure.width / (target_mm / 25.4))
    at = @sprintf("%d dpi at %.1f mm", dpi, target_mm)
    dpi < settings.min_dpi &&
        return CheckResult(:raster, :fail, "$at (minimum $(settings.min_dpi))")
    recorded =
        figure.ppu === nothing ? "" : ", recorded $(round(Int, figure.ppu * 0.0254)) dpi"
    return CheckResult(:raster, :pass, at * recorded)
end
function check_raster(figure::PdfFigure, settings::AuditSettings, target_mm::Float64)
    images = figure.images
    isempty(images) && return CheckResult(:raster, :skip, "no embedded raster")
    scale = target_mm / figure.width_mm
    low = String[]
    for image in images
        isnan(image.x_ppi) && continue
        ppi = round(Int, image.x_ppi / scale)
        ppi < settings.min_dpi && push!(
            low,
            "embedded raster $(image.width) × $(image.height) px at $ppi ppi (minimum $(settings.min_dpi))",
        )
    end
    isempty(low) || return CheckResult(:raster, :warn, join(low, "; "))
    return CheckResult(
        :raster,
        :pass,
        "$(counted(length(images), "embedded raster")) at or above $(settings.min_dpi) ppi",
    )
end
function check_raster(figure::SvgFigure, ::AuditSettings, ::Float64)
    figure.images > 0 || return CheckResult(:raster, :skip, "no embedded raster")
    return CheckResult(
        :raster,
        :warn,
        "$(counted(figure.images, "embedded raster")), resolution not checked",
    )
end

"""
    check_vector(figure, settings, target_mm) -> CheckResult

A PNG with a PDF or SVG of the same stem in its directory warns that the vector version
should be used. Skipped for PDF and SVG.
"""
function check_vector(figure::PngFigure, ::AuditSettings, ::Float64)
    dir = dirname(figure.path)
    dir = isempty(dir) ? "." : dir
    stem = first(splitext(basename(figure.path)))
    siblings = String[]
    for name in readdir(dir)
        base, extension = splitext(name)
        (base == stem && lowercase(extension) in (".pdf", ".svg")) || continue
        isfile(joinpath(dir, name)) && push!(siblings, name)
    end
    isempty(siblings) && return CheckResult(:vector, :skip, "no vector sibling")
    return CheckResult(:vector, :warn, "vector version available: $(join(siblings, ", "))")
end
check_vector(::Union{PdfFigure, SvgFigure}, ::AuditSettings, ::Float64) =
    CheckResult(:vector, :skip, "vector")

"""
    check_colour(figure, settings, target_mm) -> CheckResult

Information only: colour type and bit depth of a PNG, colour spaces of the images
embedded in a PDF. Skipped for SVG and for a PDF without embedded images.
"""
check_colour(figure::PngFigure, ::AuditSettings, ::Float64) =
    CheckResult(:colour, :info, "$(figure.colour), $(figure.bit_depth) bit")
function check_colour(figure::PdfFigure, ::AuditSettings, ::Float64)
    isempty(figure.images) && return CheckResult(:colour, :skip, "no embedded raster")
    spaces = sort!(unique(image.colour for image in figure.images))
    return CheckResult(:colour, :info, "embedded rasters: $(join(spaces, ", "))")
end
check_colour(::SvgFigure, ::AuditSettings, ::Float64) =
    CheckResult(:colour, :skip, "not read from SVG")

"Checks of every readable figure, in reporting order."
const CHECKS = (
    check_size,
    check_height,
    check_pages,
    check_fonts,
    check_text_size,
    check_raster,
    check_vector,
    check_colour,
)

# --- audit -----------------------------------------------------------------------------

function figure_format(path::AbstractString)
    extension = lowercase(splitext(path)[2])
    extension == ".pdf" && return :pdf
    extension == ".png" && return :png
    extension == ".svg" && return :svg
    throw(ArgumentError("not a PDF, PNG or SVG file: $path"))
end

"""
    audit_figure(path::AbstractString, settings::AuditSettings; target_mm::Real)
        -> FigureReport

Run every check of [`CHECKS`](@ref) on the figure at `path` for a printed width of
`target_mm` millimetres. The format follows the lowercase extension; another extension
is an `ArgumentError`. A file that cannot be parsed yields a report with the single
check `readable`. The file is only read.
"""
function audit_figure(path::AbstractString, settings::AuditSettings; target_mm::Real)
    format = figure_format(path)
    (isfinite(target_mm) && target_mm > 0) ||
        throw(ArgumentError("target width must be a positive number of mm, got $target_mm"))
    isfile(path) || throw(ArgumentError("not a file: $path"))
    figure = try
        read_figure(String(path), Val(format))
    catch err
        err isa UnreadableFigure || rethrow()
        return FigureReport(
            String(path),
            format,
            nothing,
            nothing,
            nothing,
            [CheckResult(:readable, :fail, err.detail)],
        )
    end
    target = Float64(target_mm)
    checks = CheckResult[check(figure, settings, target) for check in CHECKS]
    width = figure_width_mm(figure)
    return FigureReport(
        String(path),
        format,
        width,
        figure_height_mm(figure),
        width === nothing ? nothing : target / width,
        checks,
    )
end

"""
    collect_figures(paths::AbstractVector{<:AbstractString}) -> Vector{String}

The figures named by `paths`: a file is taken as is and must have the extension `.pdf`,
`.png` or `.svg` (any case); a directory contributes its files with those extensions,
sorted, without descending into subdirectories. A path that is neither is an
`ArgumentError`.
"""
function collect_figures(paths::AbstractVector{<:AbstractString})
    figures = String[]
    for path in paths
        if isfile(path)
            figure_format(path)
            push!(figures, String(path))
        elseif isdir(path)
            for name in sort(readdir(path))
                file = joinpath(path, name)
                (isfile(file) && lowercase(splitext(name)[2]) in FIGURE_EXTENSIONS) &&
                    push!(figures, file)
            end
        else
            throw(ArgumentError("not a file or directory: $path"))
        end
    end
    return figures
end

"""
    audit(paths, settings::AuditSettings; target_mm::Real) -> Vector{FigureReport}

[`audit_figure`](@ref) applied to every path of `paths`, in order.
"""
audit(paths::AbstractVector{<:AbstractString}, settings::AuditSettings; target_mm::Real) =
    FigureReport[audit_figure(path, settings; target_mm) for path in paths]

"""
    worst_status(report::FigureReport) -> Symbol

`:fail` when a check failed, else `:warn` when one warned, else `:pass`; `:info` and
`:skip` never count.
"""
function worst_status(report::FigureReport)
    statuses = [check.status for check in report.checks]
    :fail in statuses && return :fail
    :warn in statuses && return :warn
    return :pass
end

const STATUS_LABELS = Dict(:pass => "PASS", :warn => "WARN", :fail => "FAIL")

"""
    print_report(io::IO, reports::AbstractVector{FigureReport}; verbose::Bool = false)

One line per figure, its worst status and file name followed by the failed checks and
then the warnings as `check: detail`; with `verbose`, every check on its own indented
line. A summary line closes the report.
"""
function print_report(io::IO, reports::AbstractVector{FigureReport}; verbose::Bool = false)
    for report in reports
        findings = [c for c in report.checks if c.status == :fail]
        append!(findings, c for c in report.checks if c.status == :warn)
        line = rpad(STATUS_LABELS[worst_status(report)], 6) * basename(report.path)
        isempty(findings) ||
            (line *= "  " * join(("$(c.check): $(c.detail)" for c in findings), "; "))
        println(io, line)
        verbose || continue
        # status left-justified to 6 and check to 11 characters, one space after each
        for c in report.checks
            status, check = rpad(string(c.status), 7), rpad(string(c.check), 12)
            println(io, "    ", status, check, c.detail)
        end
    end
    statuses = worst_status.(reports)
    println(
        io,
        "$(counted(length(reports), "figure")): $(count(==(:fail), statuses)) failed, ",
        "$(count(==(:warn), statuses)) with warnings, $(count(==(:pass), statuses)) passed",
    )
    return nothing
end

csv_text(text::AbstractString) =
    occursin(r"[,\"\n\r]", text) ? "\"" * replace(text, "\"" => "\"\"") * "\"" : text
csv_number(::Nothing) = ""
csv_number(value::Float64) = @sprintf("%.3f", value)

"""
    write_csv(path::AbstractString, reports::AbstractVector{FigureReport}) -> path

The audit as a tidy CSV file, one row per check, with the columns `figure`, `format`,
`width_mm`, `height_mm`, `scale`, `check`, `status` and `detail`. Numbers carry three
decimals and are empty when unknown; text is quoted when it contains a comma, a quote or
a line break. Missing directories are created.
"""
function write_csv(path::AbstractString, reports::AbstractVector{FigureReport})
    mkpath(dirname(abspath(path)))
    open(path, "w") do io
        println(io, "figure,format,width_mm,height_mm,scale,check,status,detail")
        for report in reports, check in report.checks
            cells = (
                csv_text(report.path),
                string(report.format),
                csv_number(report.width_mm),
                csv_number(report.height_mm),
                csv_number(report.scale),
                string(check.check),
                string(check.status),
                csv_text(check.detail),
            )
            println(io, join(cells, ","))
        end
    end
    return path
end

function usage(io::IO = stdout)
    print(
        io,
        """
        figure-audit — figures against the column width and typography of a manuscript

        Usage:
          julia run.jl figure-audit PATH ... [options]

          PATH ...            figures (.pdf, .png, .svg) or directories holding them, not
                              searched recursively
          --column NAME       target the width of the single or double column
                              (default: [columns].default)
          --width MM          target an explicit width in millimetres; excludes --column
          --strict            count warnings as failures
          --verbose           list every check under its figure
          --csv FILE          write one row per check to FILE
          --config PATH       configuration file (default: config.toml next to the tool)
          -h, --help

        Checks:
          size        exported width within [columns].tolerance_mm of the target
          height      printed height at most [columns].max_height_mm
          pages       a PDF holds one page
          fonts       PDF fonts embedded and subset, no Type 3 font; live SVG text noted
          text_size   smallest PDF text at least [typography].min_font_pt once printed
          raster      resolution of a PNG, or of rasters in a PDF, at least [raster].min_dpi
          vector      no PDF or SVG of the same name beside a PNG
          colour      colour type of a PNG, colour spaces of rasters in a PDF (information)

        Exit status: 0 when no figure fails, 1 when one does, 2 for invalid arguments.
        """,
    )
    return nothing
end

"""
    main(args::Vector{String} = ARGS; io::IO = stdout) -> Union{Nothing, NamedTuple}

Parse the command line, audit the figures, print the report to `io` and write the CSV
file when `--csv` is given. Returns `(reports, failed, csv)`, where `failed` is true when
a figure failed (or warned, with `--strict`) and `csv` is the path written or `nothing`;
returns `nothing` after `--help`.
"""
function main(args::Vector{String} = ARGS; io::IO = stdout)
    config_path = joinpath(@__DIR__, "config.toml")
    paths = String[]
    column = nothing
    width = nothing
    strict = false
    verbose = false
    csv = nothing
    i = 1
    function value_of(flag)
        i < length(args) || throw(ArgumentError("$flag requires a value"))
        i += 1
        return args[i]
    end
    while i <= length(args)
        argument = args[i]
        if argument in ("-h", "--help")
            usage(io)
            return nothing
        elseif argument == "--column"
            text = value_of(argument)
            text in COLUMNS ||
                throw(ArgumentError("--column must be single or double, got '$text'"))
            column = text
        elseif argument == "--width"
            text = value_of(argument)
            width = tryparse(Float64, text)
            (width === nothing || !(isfinite(width) && width > 0)) && throw(
                ArgumentError("--width must be a number of millimetres > 0, got '$text'"),
            )
        elseif argument == "--strict"
            strict = true
        elseif argument == "--verbose"
            verbose = true
        elseif argument == "--csv"
            csv = value_of(argument)
        elseif argument == "--config"
            config_path = value_of(argument)
        elseif startswith(argument, "-")
            throw(ArgumentError("unknown command-line argument '$argument'; see --help"))
        else
            push!(paths, argument)
        end
        i += 1
    end
    (width !== nothing && column !== nothing) &&
        throw(ArgumentError("--width and --column exclude each other"))
    isempty(paths) && throw(ArgumentError("no figure given; see --help"))
    settings = load_settings(config_path)
    target_mm =
        width !== nothing ? width :
        column_width(settings, something(column, settings.default_column))
    reports = audit(collect_figures(paths), settings; target_mm)
    print_report(io, reports; verbose)
    failed = any(reports) do report
        status = worst_status(report)
        status == :fail || (strict && status == :warn)
    end
    path = csv === nothing ? nothing : write_csv(abspath(csv), reports)
    path === nothing || println(io, "Checks written to ", path)
    return (; reports, failed, csv = path)
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = try
        main(ARGS)
    catch err
        err isa ArgumentError || rethrow()
        println(stderr, "figure-audit: ", err.msg)
        exit(2)
    end
    exit(result !== nothing && result.failed ? 1 : 0)
end
