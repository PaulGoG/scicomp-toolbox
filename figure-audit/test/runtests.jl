# Tests of figure-audit against figures drawn with Cairo in mktempdir(), so no fixture is
# committed; Poppler runs through Poppler_jll as in the tool.

using Test
using Cairo

include(joinpath(@__DIR__, "..", "figure-audit.jl"))

const TOOL_DIR = normpath(joinpath(@__DIR__, ".."))
const MM = 72 / 25.4
const CHECK_ORDER = [:size, :height, :pages, :fonts, :text_size, :raster, :vector, :colour]
const FIGURES = [
    "broken.pdf",
    "broken.png",
    "cairo.svg",
    "double.pdf",
    "fig.pdf",
    "fig.png",
    "narrow.pdf",
    "notext.pdf",
    "raster.pdf",
    "single.svg",
    "small.png",
    "tall.pdf",
    "unembedded.pdf",
]

# a standard font referenced without embedding; the xref table is missing, so Poppler
# reconstructs it and prints a syntax warning
const UNEMBEDDED_PDF = """
%PDF-1.4
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 504.567 283.465] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >> endobj
4 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj
5 0 obj << /Length 44 >> stream
BT /F1 9 Tf 20 100 Td (Unembedded) Tj ET
endstream endobj
trailer << /Root 1 0 R >>
"""

# --- fixtures --------------------------------------------------------------------------

function draw_pdf(draw::Function, path::AbstractString, width::Real, height::Real)
    surface = CairoPDFSurface(path, width, height)
    draw(CairoContext(surface))
    finish(surface)
    return path
end

function show_label(cr::CairoContext, pt::Real, x::Real, y::Real, label::AbstractString)
    select_font_face(cr, "serif", Cairo.FONT_SLANT_NORMAL, Cairo.FONT_WEIGHT_NORMAL)
    set_font_size(cr, pt)
    move_to(cr, x, y)
    show_text(cr, label)
    return nothing
end

function frame(cr::CairoContext, width::Real, height::Real)
    rectangle(cr, 10, 10, width - 20, height - 20)
    stroke(cr)
    return nothing
end

function crc32(bytes::AbstractVector{UInt8})
    crc = 0xffffffff
    for byte in bytes
        crc ⊻= byte
        for _ in 1:8
            crc = isodd(crc) ? (crc >> 1) ⊻ 0xedb88320 : crc >> 1
        end
    end
    return crc ⊻ 0xffffffff
end

be_bytes(value::UInt32) = UInt8[(value >> shift) & 0xff for shift in (24, 16, 8, 0)]

function png_chunk(type::AbstractString, data::Vector{UInt8})
    body = vcat(collect(codeunits(type)), data)
    return vcat(be_bytes(UInt32(length(data))), body, be_bytes(crc32(body)))
end

# a pHYs chunk in pixels per metre, inserted right after the IHDR chunk; the vertical
# value defaults to the horizontal one
function insert_phys!(
    path::AbstractString,
    pixels_per_metre::UInt32,
    vertical::UInt32 = pixels_per_metre,
)
    bytes = read(path)
    String(bytes[13:16]) == "IHDR" || error("$path: IHDR is not the first chunk")
    data = vcat(be_bytes(pixels_per_metre), be_bytes(vertical), UInt8[1])
    write(path, vcat(bytes[1:33], png_chunk("pHYs", data), bytes[34:end]))
    return path
end

# signature, a 1 × 1 IHDR of the given colour type and IEND; no image data is needed
function minimal_png(path::AbstractString, colour_type::Integer)
    one_pixel = be_bytes(UInt32(1))
    header = vcat(one_pixel, one_pixel, UInt8[8, colour_type, 0, 0, 0])
    bytes = vcat(PNG_SIGNATURE, png_chunk("IHDR", header), png_chunk("IEND", UInt8[]))
    write(path, bytes)
    return path
end

# one page with a 10 pt line of Helvetica and no xref table; `extra` adds page entries
function minimal_pdf(path; extra = "")
    write(
        path,
        """
        %PDF-1.4
        1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
        3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 600 400] $extra /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj
        4 0 obj << /Length 44 >> stream
        BT /F1 10 Tf 100 100 Td (Ten point) Tj ET
        endstream endobj
        5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj
        trailer << /Root 1 0 R /Size 6 >>
        %%EOF
        """,
    )
    return path
end

function build_fixtures(dir::AbstractString)
    fixture(name) = joinpath(dir, name)
    draw_pdf(fixture("double.pdf"), 178MM, 100MM) do cr
        show_label(cr, 9.0, 30, 60, "Frequency f [Hz]")
        show_label(cr, 7.5, 30, 120, "Tick label 0.5")
        frame(cr, 178MM, 100MM)
    end
    draw_pdf(fixture("narrow.pdf"), 150MM, 100MM) do cr
        show_label(cr, 7.0, 30, 60, "Residual r")
        frame(cr, 150MM, 100MM)
    end
    draw_pdf(fixture("tall.pdf"), 86MM, 250MM) do cr
        show_label(cr, 9.0, 30, 60, "Panel a")
        show_page(cr)
        # Cairo drops an empty last page, so the second page carries text as well
        show_label(cr, 9.0, 30, 60, "Panel b")
    end
    draw_pdf(cr -> frame(cr, 86MM, 60MM), fixture("notext.pdf"), 86MM, 60MM)
    picture = CairoARGBSurface(400, 300)
    pc = CairoContext(picture)
    set_source_rgb(pc, 0.2, 0.4, 0.6)
    paint(pc)
    draw_pdf(fixture("raster.pdf"), 86MM, 60MM) do cr
        set_source_surface(cr, picture, 10, 10)
        paint(cr)
    end

    surface = CairoARGBSurface(2100, 1200)
    cr = CairoContext(surface)
    # translucent, so that Cairo writes an RGBA file rather than an opaque RGB one
    set_source_rgba(cr, 0.9, 0.6, 0.0, 0.5)
    paint(cr)
    write_to_png(surface, fixture("fig.png"))
    insert_phys!(fixture("fig.png"), UInt32(11811))
    draw_pdf(cr -> frame(cr, 178MM, 100MM), fixture("fig.pdf"), 178MM, 100MM)
    surface = CairoRGBSurface(800, 500)
    cr = CairoContext(surface)
    set_source_rgb(cr, 0.3, 0.3, 0.3)
    paint(cr)
    write_to_png(surface, fixture("small.png"))

    # Cairo writes its point dimensions without a unit, which SVG readers take as px,
    # and draws glyphs as outlines; the single-column fixture is therefore written by
    # hand, with explicit units and one live text element
    surface = CairoSVGSurface(fixture("cairo.svg"), 86MM, 60MM)
    show_label(CairoContext(surface), 9.0, 30, 60, "Time t [s]")
    finish(surface)
    write(
        fixture("single.svg"),
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="86mm" height="60mm" viewBox="0 0 325 227">
        <rect x="10" y="10" width="300" height="200" fill="none" stroke="black"/>
        <text x="30" y="120" font-size="9">Time t [s]</text>
        </svg>
        """,
    )

    write(fixture("unembedded.pdf"), UNEMBEDDED_PDF)
    write(fixture("broken.pdf"), "not a pdf")
    write(fixture("broken.png"), "not a png")
    write(fixture("notes.txt"), "not a figure")
    cp(fixture("double.pdf"), joinpath(mkpath(fixture("nested")), "inner.pdf"))
    return nothing
end

status_of(report, check) = only(c.status for c in report.checks if c.check == check)
detail_of(report, check) = only(c.detail for c in report.checks if c.check == check)

@testset "figure-audit" begin
    @testset "Settings" begin
        shipped = load_settings(joinpath(TOOL_DIR, "config.toml"))
        defaults = validate_settings(Dict{String, Any}())
        for name in fieldnames(AuditSettings)
            @test getfield(shipped, name) == getfield(defaults, name)
        end
        @test shipped.default_column == "double" && shipped.double_mm == 178.0
        @test validate_settings(Dict("columns" => Dict("single_mm" => 90))).single_mm ===
              90.0
        bad(table, key, value) = validate_settings(Dict(table => Dict(key => value)))
        for (table, key, value) in (
            ("columns", "default", "triple"),
            ("columns", "single_mm", 39.9),
            ("columns", "single_mm", 401),
            ("columns", "single_mm", true),
            ("columns", "double_mm", 30.0),
            ("columns", "tolerance_mm", -0.1),
            ("columns", "max_height_mm", 0.0),
            ("columns", "max_height_mm", 501),
            ("typography", "min_font_pt", 0),
            ("typography", "min_font_pt", 72.5),
            ("typography", "require_subset", "yes"),
            ("raster", "min_dpi", 0),
            ("raster", "min_dpi", 10001),
            ("raster", "min_dpi", 300.0),
            ("raster", "min_dpi", true),
        )
            @test_throws "[$table].$key" bad(table, key, value)
        end
        @test_throws "unknown key 'extra' at top level" validate_settings(
            Dict("extra" => Dict()),
        )
        @test_throws "unknown key 'width' at [columns]" bad("columns", "width", 86.0)
        @test_throws "[raster] must be a table" validate_settings(Dict("raster" => 300))
        @test_throws ArgumentError load_settings(joinpath(TOOL_DIR, "missing.toml"))
    end

    mktempdir() do dir
        build_fixtures(dir)
        fixture(name) = joinpath(dir, name)
        settings = load_settings(joinpath(TOOL_DIR, "config.toml"))
        audited(name, target_mm; with = settings) =
            audit_figure(fixture(name), with; target_mm)

        @testset "PNG parsing" begin
            fig = png_info(fixture("fig.png"))
            @test (fig.width, fig.height, fig.bit_depth, fig.colour) ==
                  (2100, 1200, 8, "RGBA")
            @test fig.ppu == 11811.0
            small = png_info(fixture("small.png"))
            @test (small.width, small.height, small.bit_depth, small.colour) ==
                  (800, 500, 8, "RGB")
            @test small.ppu === nothing
            mktempdir() do scratch
                for (colour_type, name) in
                    (0 => "greyscale", 3 => "palette", 4 => "greyscale with alpha")
                    file = minimal_png(joinpath(scratch, "$colour_type.png"), colour_type)
                    @test png_info(file).colour == name
                end
            end
            @test_throws UnreadableFigure png_info(fixture("broken.png"))
        end

        @testset "SVG parsing" begin
            single = svg_info(read(fixture("single.svg"), String))
            @test isapprox(single.width_pt / MM, 86; atol = 0.05)
            @test isapprox(single.height_pt / MM, 60; atol = 0.05)
            @test single.texts == 1
            # unitless dimensions are px: a Cairo SVG drawn 86 mm wide reads 0.75 times as wide
            cairo = svg_info(read(fixture("cairo.svg"), String))
            @test isapprox(cairo.width_pt / MM, 0.75 * 86; atol = 0.05)
            @test isapprox(cairo.height_pt / MM, 0.75 * 60; atol = 0.05)
            @test cairo.texts == 0
            root(attributes) = svg_info(
                "<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" $attributes>\n</svg>\n",
            )
            px = root("width=\"400px\" height=\"300\"")
            @test (px.width_pt, px.height_pt) == (300.0, 225.0)
            @test root("width=\"86mm\" height=\"60mm\"").width_pt / MM ≈ 86
            @test root("width=\"8.6cm\" height=\"6cm\"").width_pt / MM ≈ 86
            @test root("width=\"3.5in\" height=\"2in\"").width_pt ≈ 252
            boxed = root("viewBox=\"0 0 400 300\"")
            @test (boxed.width_pt, boxed.height_pt) == (300.0, 225.0)
            @test root("width=\"100%\"").width_pt === nothing
            counts = svg_info(
                "<svg width=\"10pt\" height=\"10pt\"><text>a</text><g><text>b</text></g>" *
                "<image href=\"p.png\"/></svg>",
            )
            @test (counts.texts, counts.images) == (2, 1)
            @test_throws UnreadableFigure svg_info("<html></html>")
        end

        @testset "PDF introspection" begin
            info = pdf_info(fixture("double.pdf"))
            @test info.pages == 1
            @test isapprox(info.width_pt / MM, 178; atol = 0.05)
            @test isapprox(info.height_pt / MM, 100; atol = 0.05)
            @test occursin("cairo", lowercase(info.producer))
            fonts = pdf_fonts(fixture("double.pdf"))
            @test !isempty(fonts) && all(f -> f.embedded && f.subset, fonts)
            helvetica = only(pdf_fonts(fixture("unembedded.pdf")))
            @test helvetica.name == "Helvetica" && !helvetica.embedded
            sizes = sort(unique(pdf_text_sizes(fixture("double.pdf"), info.width_pt)))
            @test length(sizes) == 2 && all(isapprox.(sizes, [7.5, 9.0]; atol = 0.4))
            image = only(pdf_images(fixture("raster.pdf")))
            @test (image.width, image.height, image.colour) == (400, 300, "rgb")
            @test image.x_ppi ≈ 72 && image.y_ppi ≈ 72
            @test pdf_info(fixture("tall.pdf")).pages == 2
            @test isempty(pdf_fonts(fixture("notext.pdf")))
            @test isempty(pdf_images(fixture("double.pdf")))
            @test_throws UnreadableFigure pdf_info(fixture("broken.pdf"))
        end

        @testset "Checks" begin
            for name in FIGURES
                startswith(name, "broken") && continue
                @test [c.check for c in audited(name, 178).checks] == CHECK_ORDER
            end
            double = audited("double.pdf", 178)
            for (check, status) in (
                :size => :pass,
                :height => :pass,
                :pages => :pass,
                :fonts => :pass,
                :text_size => :pass,
                :raster => :skip,
                :colour => :skip,
            )
                @test status_of(double, check) == status
            end
            @test double.format == :pdf && isapprox(double.scale, 1; atol = 1e-3)
            narrow = audited("narrow.pdf", 178)
            @test status_of(narrow, :size) == :fail
            @test occursin("(LaTeX would scale by 1.187)", detail_of(narrow, :size))
            @test status_of(narrow, :text_size) == :pass
            @test status_of(audited("narrow.pdf", 120), :text_size) == :fail
            tall = audited("tall.pdf", 86)
            @test status_of(tall, :height) == :fail && status_of(tall, :pages) == :warn
            notext = audited("notext.pdf", 86)
            @test status_of(notext, :fonts) == :skip
            @test status_of(notext, :text_size) == :skip
            raster = audited("raster.pdf", 86)
            @test status_of(raster, :raster) == :warn
            @test occursin("400 × 300 px at 72 ppi", detail_of(raster, :raster))
            @test status_of(raster, :colour) == :info
            @test occursin("rgb", detail_of(raster, :colour))
            png = audited("fig.png", 178)
            @test status_of(png, :size) == :pass && occursin("177.8", detail_of(png, :size))
            @test status_of(png, :raster) == :pass
            @test occursin("recorded", detail_of(png, :raster))
            @test status_of(png, :vector) == :warn
            @test occursin("fig.pdf", detail_of(png, :vector))
            @test status_of(png, :colour) == :info
            @test detail_of(png, :colour) == "RGBA, 8 bit"
            small = audited("small.png", 178)
            @test status_of(small, :size) == :skip && status_of(small, :height) == :pass
            @test status_of(small, :raster) == :fail
            @test detail_of(small, :raster) == "114 dpi at 178.0 mm (minimum 300)"
            svg = audited("single.svg", 86)
            @test status_of(svg, :size) == :pass && status_of(svg, :fonts) == :info
            unembedded = audited("unembedded.pdf", 178)
            @test status_of(unembedded, :fonts) == :fail
            @test occursin("Helvetica", detail_of(unembedded, :fonts))
            for name in ("broken.pdf", "broken.png")
                broken = audited(name, 178)
                @test length(broken.checks) == 1
                @test status_of(broken, :readable) == :fail
                @test broken.width_mm === nothing && broken.scale === nothing
            end
            @test detail_of(audited("broken.png", 178), :readable) == "not a PNG file"
            @test_throws "notes.txt" audited("notes.txt", 178)
        end

        @testset "collect_figures" begin
            @test issorted(FIGURES)
            @test collect_figures([dir]) == fixture.(FIGURES)
            @test collect_figures([fixture("fig.png"), fixture("double.pdf")]) ==
                  [fixture("fig.png"), fixture("double.pdf")]
            @test_throws "notes.txt" collect_figures([fixture("notes.txt")])
            @test_throws "not a file or directory" collect_figures([fixture("absent.pdf")])
        end

        @testset "print_report" begin
            reports = [
                audited("double.pdf", 178),
                audited("narrow.pdf", 178),
                audited("fig.png", 178),
            ]
            io = IOBuffer()
            print_report(io, reports)
            lines = split(String(take!(io)), '\n'; keepempty = false)
            @test lines[1] == "PASS  double.pdf"
            @test startswith(lines[2], "FAIL  narrow.pdf  size: 150.0 mm wide, target")
            @test lines[3] == "WARN  fig.png  vector: vector version available: fig.pdf"
            @test lines[4] == "3 figures: 1 failed, 1 with warnings, 1 passed"
            # failed checks come before warnings, whatever the order of the checks
            strict_text = AuditSettings("double", 86.0, 178.0, 1.0, 300.0, 10.0, false, 300)
            io = IOBuffer()
            print_report(io, [audited("tall.pdf", 86; with = strict_text)])
            line = first(split(String(take!(io)), '\n'))
            @test startswith(line, "FAIL  tall.pdf  text_size: smallest text 9.0 pt")
            @test endswith(line, "; pages: 2 pages; a figure is one page")
            io = IOBuffer()
            print_report(io, reports[1:1]; verbose = true)
            output = String(take!(io))
            @test occursin(
                "\n    pass   size        178.0 mm wide (target 178.0 ± 1.0 mm)\n",
                output,
            )
            @test occursin("\n    skip   raster      no embedded raster\n", output)
            @test endswith(output, "1 figure: 0 failed, 0 with warnings, 1 passed\n")
        end

        @testset "write_csv" begin
            reports = [audited("narrow.pdf", 178), audited("broken.png", 178)]
            mktempdir() do scratch
                path = write_csv(joinpath(scratch, "out", "checks.csv"), reports)
                lines = readlines(path)
                @test lines[1] ==
                      "figure,format,width_mm,height_mm,scale,check,status,detail"
                @test length(lines) == 1 + sum(length(r.checks) for r in reports)
                row = only(filter(l -> occursin(",size,fail,", l), lines))
                @test occursin(",pdf,150.000,100.000,1.187,size,fail,", row)
                @test endswith(
                    row,
                    ",\"150.0 mm wide, target 178.0 ± 1.0 mm (LaTeX would scale by 1.187)\"",
                )
                @test endswith(lines[end], ",png,,,,readable,fail,not a PNG file")
            end
        end

        @testset "main" begin
            io = IOBuffer()
            result = main([fixture("double.pdf")]; io)
            @test length(result.reports) == 1
            @test !result.failed && result.csv === nothing
            @test startswith(String(take!(io)), "PASS  double.pdf")
            @test main([fixture("narrow.pdf")]; io = IOBuffer()).failed
            @test !main(["--width", "150", fixture("narrow.pdf")]; io = IOBuffer()).failed
            single = main(["--column", "single", fixture("single.svg")]; io = IOBuffer())
            @test !single.failed
            @test !main([fixture("fig.png")]; io = IOBuffer()).failed
            @test main(["--strict", fixture("fig.png")]; io = IOBuffer()).failed
            mktempdir() do scratch
                csv = joinpath(scratch, "audit.csv")
                written = main(["--csv", csv, fixture("double.pdf")]; io = IOBuffer())
                @test written.csv == csv && isfile(csv)
            end
            io = IOBuffer()
            @test main(["--help"]; io) === nothing
            @test occursin("--column", String(take!(io)))
            @test_throws "--width and --column" main(
                ["--width", "120", "--column", "single", fixture("double.pdf")];
                io = IOBuffer(),
            )
            @test_throws "unknown command-line argument" main(["--bogus"]; io = IOBuffer())
            @test_throws "--column must be" main(
                ["--column", "tripled", fixture("double.pdf")];
                io = IOBuffer(),
            )
            @test_throws "--width must be" main(
                ["--width", "-3", fixture("double.pdf")];
                io = IOBuffer(),
            )
            @test_throws "no figure given" main(String[]; io = IOBuffer())
        end

        @testset "Review fixes" begin
            # a name longer than the padded column shifts every later column
            fonts = parse_pdffonts(
                """
                name                                 type              encoding         emb sub uni object ID
                ------------------------------------ ----------------- ---------------- --- --- --- ---------
                WCQNES+NotoSerif-ExtraCondensedExtraLightItalic TrueType          WinAnsi          yes yes yes      7  0
                ABCDEF+DejaVuSans                    CID TrueType      Identity-H       yes yes yes     10  0
                Helvetica                            Type 1            WinAnsi          no  no  no       5  0
                GHIJKL+Füßball                       Type 1C (OT)      Custom           yes yes no      12  0
                [none]                               Type 3            Custom           yes no  no       9  0
                """,
            )
            @test length(fonts) == 5
            @test [f.name for f in fonts] == [
                "WCQNES+NotoSerif-ExtraCondensedExtraLightItalic",
                "ABCDEF+DejaVuSans",
                "Helvetica",
                "GHIJKL+Füßball",
                "[none]",
            ]
            @test [f.type for f in fonts] == ["TrueType", "CID TrueType", "Type 1", "Type 1C (OT)", "Type 3"]
            @test [f.embedded for f in fonts] == [true, true, false, true, true]
            @test [f.subset for f in fonts] == [true, true, false, true, false]
            @test_throws UnreadableFigure parse_pdffonts("no header here\n")

            # an inline image prints one token as its object ID
            images = parse_pdfimages(
                """
                page   num  type   width height color comp bpc  enc interp  object ID x-ppi y-ppi size ratio
                --------------------------------------------------------------------------------------------
                   1     0 image     600   400  rgb     3   8  image  no         8  0   150   151 1.2M  11%
                   1     1 image      10    10  gray    1   8  image  no   [inline]     72   300   12B  12%
                   1     2 smask     600   400  gray    1   8  image  no         9  0   150   150 300K  20%
                """,
            )
            @test length(images) == 2
            @test [(i.x_ppi, i.y_ppi) for i in images] == [(150.0, 151.0), (72.0, 300.0)]
            @test_throws UnreadableFigure parse_pdfimages("")

            mktempdir() do scratch
                plain = minimal_pdf(joinpath(scratch, "plain.pdf"))
                cropped = minimal_pdf(
                    joinpath(scratch, "cropped.pdf");
                    extra = "/CropBox [50 50 350 250]",
                )
                rotated =
                    minimal_pdf(joinpath(scratch, "rotated.pdf"); extra = "/Rotate 90")
                for (path, width_pt, height_pt) in
                    ((plain, 600, 400), (cropped, 300, 200), (rotated, 400, 600))
                    figure = read_figure(path, Val(:pdf))
                    @test isapprox(figure.width_mm, width_pt * 25.4 / 72; atol = 0.01)
                    @test isapprox(figure.height_mm, height_pt * 25.4 / 72; atol = 0.01)
                    @test isapprox(only(figure.text_sizes), 10.0; atol = 0.2)
                end
            end

            mktempdir() do scratch
                bytes = read(fixture("fig.png"))
                head = joinpath(scratch, "head.png")
                write(head, bytes[1:38])
                @test_throws UnreadableFigure png_info(head)
                no_iend = joinpath(scratch, "no_iend.png")
                write(no_iend, bytes[1:(end - 12)])
                @test_throws UnreadableFigure png_info(no_iend)
                anisotropic = joinpath(scratch, "anisotropic.png")
                write_to_png(CairoRGBSurface(1000, 1500), anisotropic)
                insert_phys!(anisotropic, UInt32(11811), UInt32(5906))
                figure = read_figure(anisotropic, Val(:png))
                @test isapprox(figure_width_mm(figure), 1000 / 11811 * 1000; atol = 0.01)
                @test isapprox(figure_height_mm(figure), 1500 / 5906 * 1000; atol = 0.01)
                tall_png = joinpath(scratch, "tall.png")
                write_to_png(CairoRGBSurface(400, 1200), tall_png)
                defaults = validate_settings(Dict{String, Any}())
                # printed height 258 mm against 230 mm
                tall = audit_figure(tall_png, defaults; target_mm = 86)
                @test status_of(tall, :height) == :fail
            end

            partial = svg_info("<svg width=\"86mm\" viewBox=\"0 0 8600 6000\"/>")
            @test partial.width_pt ≈ 86 * 72 / 25.4
            @test partial.height_pt ≈ 86 * 72 / 25.4 * 6000 / 8600
            pica = svg_info("<svg width=\"10pc\" height=\"5pc\"/>")
            @test (pica.width_pt, pica.height_pt) == (120.0, 60.0)
            degenerate = svg_info("<svg width=\"0mm\" height=\"0mm\"/>")
            @test degenerate.width_pt === nothing && degenerate.height_pt === nothing
            @test svg_info("<svg height=\"30mm\" viewBox=\"0 0 200 100\"/>").width_pt ≈
                  60 * 72 / 25.4

            subset = validate_settings(Dict("typography" => Dict("require_subset" => true)))
            font_figure(font) =
                PdfFigure("fonts.pdf", 1, 178.0, 100.0, "", [font], [9.0], PdfImage[])
            type3 = font_figure(PdfFont("[none]", "Type 3", "Custom", true, false))
            @test check_fonts(type3, subset, 178.0).status == :warn
            arial = font_figure(PdfFont("Arial", "TrueType", "WinAnsi", true, false))
            @test check_fonts(arial, subset, 178.0).status == :fail

            mktempdir() do vacant
                @test_throws ArgumentError main([vacant]; io = IOBuffer())
            end
            mktempdir() do scratch
                csv = joinpath(scratch, "audit.csv")
                write(csv, "kept\n")
                written = main(["--csv", csv, fixture("double.pdf")]; io = IOBuffer())
                @test read(csv, String) == "kept\n"
                @test written.csv == joinpath(scratch, "audit#1.csv")
                @test isfile(written.csv)
            end
        end
    end
end
