# Tests of bib-hygiene against a BibTeX fixture held in this file. Online lookups go
# through a stub fetcher; no test touches the network.

using Test
using Dates: Dates, DateTime
using TOML: TOML

include(joinpath(@__DIR__, "..", "bib-hygiene.jl"))

const TOOL_DIR = normpath(joinpath(@__DIR__, ".."))

const FIXTURE = raw"""
@string{prd = "Physical Review D"}
@comment{ ignored {nested} braces }
@preamble{"\newcommand{\noop}[1]{}"}

@article{good2020,
  author = {Author, A. and Author, B.},
  title = {A {LIGO} result on binary mergers},
  journal = prd,
  year = 2020,
  volume = 101,
  pages = {1--10},
  doi = {10.1103/PhysRevD.101.000001}
}

@article{prefix2021,
  author = {Author, C.},
  title = {Ringdown spectroscopy of remnants},
  journal = {Phys. Rev. D},
  year = {2021},
  pages = {11-20},
  doi = {https://doi.org/10.1103/PhysRevD.104.000002}
}

@article{nojournal2019,
  author = {Author, D.},
  title = {An analysis without a venue},
  year = 2019
}

@Article{GOOD2020,
  author = {Author, E.},
  title = {Duplicate key by case},
  journal = prd,
  year = 2020,
  doi = {10.1103/PhysRevD.102.000009}
}

@article{same2022,
  author = {Author, F.},
  title = {A {LIGO} result on binary mergers},
  journal = prd,
  year = 2022,
  doi = {10.1103/PhysRevD.105.000004}
}

@article{accent2018,
  author = {Gogîță, P.},
  title = {Signal & noise},
  journal = prd,
  year = 2018,
  doi = {10.1103/PhysRevD.97.000005}
}

@article{caps2017,
  author = {Author, G.},
  title = {Inference with LIGO data by Bayesian methods},
  journal = {Physical Review Letters},
  year = 2017,
  doi = {10.1103/PhysRevLett.118.000006}
}

@misc{preprint2023,
  author = {Author, H.},
  title = {A preprint awaiting publication},
  year = 2023,
  eprint = {2301.00001},
  archiveprefix = {arXiv},
  primaryclass = {gr-qc}
}

@article{press2024,
  author = {Author, I.},
  title = {Forthcoming measurement of a constant},
  journal = {Physical Review Letters},
  year = {in press},
  doi = {10.1000/notfound}
}

@article{badyear2016,
  author = {Author, J.},
  title = {A year that is not a number},
  journal = prd,
  year = {20x6},
  doi = {10.1103/PhysRevD.93.000007}
}

@phdthesis{thesis2015,
  author = {Author, K.},
  title = {A thesis without a school},
  year = 2015
}

@book{edited2010,
  editor = {Editor, E.},
  title = {An edited volume},
  publisher = {Press},
  year = 2010
}

@article{urlfield2019,
  author = {Author, L.},
  title = {Underscores in a url only},
  journal = {J. Fluids Eng.},
  year = 2019,
  url = {https://example.org/a_b%20c},
  doi = {10.5555/a_b}
}

@inproceedings{concat2012,
  author = {Author, M.},
  title = {Concatenated booktitle},
  booktitle = "Proceedings of the " # "Workshop",
  month = jan,
  year = 2012
}

@article(paren2011,
  author = {Author, N.},
  title = {Parenthesised entry},
  journal = {Journal of Fluids Engineering},
  year = 2011,
  doi = {10.1115/1.0000000}
)

@article{dupfield2013,
  author = {Author, O.},
  title = {Repeated field},
  title = {Second title},
  journal = prd,
  year = 2013,
  doi = {10.1103/PhysRevD.88.000008}
}
"""

const TEX = raw"""
\documentclass{article}
\begin{document}
Binary mergers~\cite{good2020, prefix2021} and detector noise~\citep[p.~3]{accent2018}.
\textcite{caps2017} applied Bayesian methods; \autocite*{press2024} is forthcoming.
\nocite{ghost2000}
% \cite{commented1999}
\end{document}
"""

const WARNING_ONLY = raw"""
@article{w2020,
  author = {Author, P.},
  title = {A short note},
  journal = {J},
  year = 2020,
  pages = {1-2},
  doi = {10.1000/xyz}
}
"""

const ARXIV_FEED = "<feed><entry><id>http://arxiv.org/abs/2301.00001v2</id><arxiv:doi>10.1103/PhysRevD.108.000003</arxiv:doi></entry></feed>"

const ARXIV_QUERY = "https://export.arxiv.org/api/query?id_list=2301.00001&max_results=1"

const ONLINE_CHECKS = (:doi_unresolved, :doi_unchecked, :arxiv_published, :arxiv_unchecked)

keys_of(findings) = [f.key for f in findings]
entry_named(entries, key) = only(filter(e -> e.key == key, entries))
line_of(text, needle) = count(==('\n'), text[1:first(findfirst(needle, text))]) + 1
parse_entries(text) = first(parse_bibtex(text))

# responses of doi.org and of the arXiv API for the fixture: every DOI resolves except
# 10.1000/notfound, and arXiv knows a published version of 2301.00001
function fixture_responses(entries)
    responses = Dict{String, Tuple{Int, String}}()
    for entry in entries
        value = field(entry, "doi")
        value === nothing && continue
        doi = bare_doi(value)
        responses["https://doi.org/$doi"] =
            doi == "10.1000/notfound" ? (404, "") : (302, "")
    end
    responses[ARXIV_QUERY] = (200, ARXIV_FEED)
    return responses
end

function stub_fetcher(responses, counter::Ref{Int})
    return function (method, url)
        counter[] += 1
        return get(responses, url, (500, ""))
    end
end

@testset "bib-hygiene" begin
    entries, strings, duplicates = parse_bibtex(FIXTURE)
    defaults = validate_settings(Dict{String, Any}())

    @testset "Parser" begin
        @test length(entries) == 16
        @test all(e -> e.type == lowercase(e.type), entries)
        @test entry_named(entries, "GOOD2020").type == "article"
        @test entry_named(entries, "edited2010").type == "book"
        paren = entry_named(entries, "paren2011")
        @test field(paren, "journal") == "Journal of Fluids Engineering"
        @test FIXTURE[last(paren.span)] == ')'
        concat = entry_named(entries, "concat2012")
        @test field(concat, "booktitle") == "Proceedings of the Workshop"
        @test field(concat, "month") == "jan"
        booktitle = field_of(concat, "booktitle")
        @test FIXTURE[booktitle.span] == "\"Proceedings of the \" # \"Workshop\""
        good = entry_named(entries, "good2020")
        @test field(good, "journal") == "Physical Review D"
        @test strings["prd"] == "Physical Review D"
        @test field(good, "TITLE") == "A {LIGO} result on binary mergers"
        @test field(good, "volume") == "101"
        @test field(good, "note") === nothing
        @test good.line == line_of(FIXTURE, "@article{good2020")
        @test startswith(FIXTURE[good.span], "@article{good2020,")
        @test endswith(FIXTURE[good.span], "000001}\n}")
        doi = field_of(entry_named(entries, "prefix2021"), "doi")
        @test FIXTURE[doi.span] == "{https://doi.org/10.1103/PhysRevD.104.000002}"
        @test doi.line == line_of(FIXTURE, "doi = {https://")
        @test field(entry_named(entries, "dupfield2013"), "title") == "Repeated field"
        @test duplicates ==
              [("dupfield2013", "title", line_of(FIXTURE, "title = {Second title}"))]

        unbalanced = "% header\n\n@article{x, title = {abc, year = 2020}\n"
        err = try
            parse_bibtex(unbalanced)
        catch e
            e
        end
        @test err isa BibParseError && err.line == 3
        @test sprint(showerror, err) == "line 3: " * err.message
        undefined = "@string{a = {b}}\n@article{y, journal = nosuch, year = 2020}\n"
        err = try
            parse_bibtex(undefined)
        catch e
            e
        end
        @test err isa BibParseError && err.line == 2
        @test err.message == "undefined string nosuch"
        @test_throws "entry without key" parse_bibtex("@article{, title = {x}}")
        @test isempty(parse_entries("no entries here, only an address user@example.org"))
    end

    @testset "Settings" begin
        shipped = load_settings(joinpath(TOOL_DIR, "config.toml"))
        for name in fieldnames(HygieneSettings)
            @test getfield(shipped, name) == getfield(defaults, name)
        end
        @test shipped.cache_ttl_days == 30 && shipped.arxiv_batch == 20
        bad(network) = validate_settings(Dict("network" => network))
        @test_throws "cache_ttl_days" bad(Dict("cache_ttl_days" => -1))
        @test_throws "cache_ttl_days" bad(Dict("cache_ttl_days" => 1.5))
        @test_throws "doi_delay_s" bad(Dict("doi_delay_s" => -0.1))
        @test_throws "arxiv_delay_s" bad(Dict("arxiv_delay_s" => -1.0))
        @test_throws "arxiv_batch" bad(Dict("arxiv_batch" => 0))
        @test_throws "arxiv_batch" bad(Dict("arxiv_batch" => 101))
        @test_throws "contact_email" bad(Dict("contact_email" => "nobody"))
        @test_throws "cache_file" bad(Dict("cache_file" => ""))
        @test_throws "unknown key 'timeout'" bad(Dict("timeout" => 3))
        @test_throws "unknown key 'extra'" validate_settings(Dict("extra" => Dict()))
        @test_throws "unknown check 'spelling'" validate_settings(
            Dict("checks" => Dict("disabled" => ["spelling"])),
        )
        @test bad(Dict("doi_delay_s" => 1)).doi_delay_s == 1.0
        @test_throws ArgumentError load_settings(joinpath(TOOL_DIR, "missing.toml"))
        no_year = validate_settings(Dict("checks" => Dict("disabled" => ["year"])))
        @test no_year.disabled == Set([:year])
        @test !any(
            f -> f.check == :year,
            run_checks(entries, strings, duplicates; settings = no_year),
        )
    end

    @testset "Offline checks" begin
        found = check_duplicate_key(entries)
        @test keys_of(found) == ["GOOD2020"]
        @test occursin("line $(entry_named(entries, "good2020").line)", only(found).detail)
        @test only(found).severity == :error

        found = check_duplicate_entry(entries)
        @test keys_of(found) == ["same2022"]
        @test only(found).detail == "same title as good2020"

        found = check_missing_field(entries)
        @test [(f.key, f.detail) for f in found] == [("nojournal2019", "missing journal"), ("thesis2015", "missing school")]
        book = parse_entries("@book{b, title = {T}, publisher = {P}, year = 1}")
        @test [f.detail for f in check_missing_field(book)] == ["missing author or editor"]

        found = check_doi_prefix(entries)
        @test keys_of(found) == ["prefix2021"]
        @test occursin("10.1103/PhysRevD.104.000002", only(found).detail)
        @test bare_doi(" https://dx.doi.org/10.1/x ") == "10.1/x"
        @test bare_doi("DOI: 10.1/x") == "10.1/x"
        @test bare_doi("https://doi.org/doi:10.1/x") == "10.1/x"

        @test isempty(check_doi_syntax(entries))
        @test keys_of(check_doi_syntax(parse_entries("@article{bad, doi = {12345}}"))) ==
              ["bad"]

        @test keys_of(check_doi_missing(entries)) == ["nojournal2019", "concat2012"]

        found = check_journal_spelling(entries)
        @test length(found) == 2 && all(f -> isempty(f.key), found)
        physical = only(filter(f -> occursin("'Physical Review D'", f.detail), found))
        @test occursin("'Phys. Rev. D' (prefix2021)", physical.detail)
        @test startswith(
            physical.detail,
            "journal written as 'Physical Review D' (good2020,",
        )
        @test physical.line == entry_named(entries, "good2020").line
        fluids = only(filter(f -> occursin("'J. Fluids Eng.'", f.detail), found))
        @test occursin("'Journal of Fluids Engineering' (paren2011)", fluids.detail)
        @test !any(f -> occursin("Physical Review Letters", f.detail), found)

        found = check_non_ascii(entries)
        @test keys_of(found) == ["accent2018"]
        @test startswith(only(found).detail, "non-ASCII in author: î, ț")

        found = check_unescaped(entries)
        @test keys_of(found) == ["accent2018"]
        @test only(found).detail == "unescaped & in title"
        @test unescaped_characters(raw"see \url{a_b} and $x_1$ at 5\% or 5%") == ['%']

        found = check_title_case(entries)
        caps = only(filter(f -> f.key == "caps2017", found))
        @test caps.detail == "capitals not protected by braces in title: LIGO, Bayesian"
        @test !("good2020" in keys_of(found))
        # the capital in the booktitle of concat2012 is not flagged: styles keep its case
        @test keys_of(found) == ["caps2017"]

        found = check_pages_dash(entries)
        @test keys_of(found) == ["prefix2021"]
        @test only(found).detail == "pages '11-20' should read '11--20'"

        found = check_year(entries)
        @test keys_of(found) == ["badyear2016"] && only(found).severity == :error
        future = check_year(parse_entries("@article{future, year = 2999}"))
        @test keys_of(future) == ["future"] && only(future).severity == :warning

        @test keys_of(check_duplicate_field(duplicates)) == ["dupfield2013"]
    end

    @testset "Citations" begin
        cited, nocite_all = citation_keys(TEX)
        @test cited == Set([
            "good2020",
            "prefix2021",
            "accent2018",
            "caps2017",
            "press2024",
            "ghost2000",
        ])
        @test !nocite_all
        @test citation_keys(raw"\nocite{*}") == (Set{String}(), true)
        sources = ["paper.tex" => TEX]
        @test keys_of(check_uncited(entries, sources)) == [
            "nojournal2019",
            "GOOD2020",
            "same2022",
            "preprint2023",
            "badyear2016",
            "thesis2015",
            "edited2010",
            "urlfield2019",
            "concat2012",
            "paren2011",
            "dupfield2013",
        ]
        @test isempty(check_uncited(entries, Pair{String, String}[]))
        @test isempty(check_uncited(entries, ["all.tex" => raw"\nocite{*}"]))
        undefined = only(check_undefined_citation(entries, sources))
        @test undefined.key == "" && undefined.line == 0 && undefined.severity == :error
        @test undefined.detail == "'ghost2000' cited in paper.tex has no entry"
    end

    @testset "arXiv identifiers" begin
        @test arxiv_id(entry_named(entries, "preprint2023")) == "2301.00001"
        @test is_preprint(entry_named(entries, "preprint2023"))
        doi_form = only(parse_entries("@misc{h, doi = {10.48550/arXiv.2105.12345v2}}"))
        @test arxiv_id(doi_form) == "2105.12345" && is_preprint(doi_form)
        old_style = only(parse_entries("@misc{o, note = {arXiv:hep-th/9901001}}"))
        @test arxiv_id(old_style) == "hep-th/9901001"
        @test arxiv_id(entry_named(entries, "good2020")) === nothing
    end

    @testset "Online checks" begin
        responses = fixture_responses(entries)
        counter = Ref(0)
        stub = stub_fetcher(responses, counter)
        pauses = Float64[]
        cache = Dict{String, Any}()
        lookup(; kwargs...) = run_checks(
            entries,
            strings,
            duplicates;
            settings = defaults,
            online = true,
            fetch = stub,
            pause = s -> push!(pauses, s),
            cache,
            kwargs...,
        )
        found = lookup()
        @test keys_of(filter(f -> f.check == :doi_unresolved, found)) == ["press2024"]
        published = only(filter(f -> f.check == :arxiv_published, found))
        @test published.key == "preprint2023"
        @test published.detail == "published version: doi 10.1103/PhysRevD.108.000003"
        @test !any(f -> f.check in (:doi_unchecked, :arxiv_unchecked), found)
        @test counter[] == length(responses)
        @test count(==(defaults.doi_delay_s), pauses) == length(responses) - 2
        @test haskey(cache, "doi") && haskey(cache, "arxiv")
        @test cache["doi"]["10.1000/notfound"]["status"] == 404
        @test cache["doi"]["10.1103/physrevd.101.000001"]["status"] == 302
        @test cache["arxiv"]["2301.00001"]["doi"] == "10.1103/PhysRevD.108.000003"
        @test cache["arxiv"]["2301.00001"]["journal_ref"] == ""

        counter[] = 0
        again = lookup()
        @test counter[] == 0
        @test filter(f -> f.check in ONLINE_CHECKS, again) ==
              filter(f -> f.check in ONLINE_CHECKS, found)
        lookup(; refresh = true)
        @test counter[] == length(responses)

        offline_arxiv = delete!(copy(responses), ARXIV_QUERY)
        found = run_checks(
            entries,
            strings,
            duplicates;
            settings = defaults,
            online = true,
            fetch = stub_fetcher(offline_arxiv, Ref(0)),
            pause = _ -> nothing,
        )
        @test keys_of(filter(f -> f.check == :arxiv_unchecked, found)) == ["preprint2023"]

        # a record checked two days ago is stale under a one-day TTL, fresh under three
        single = parse_entries("@article{t, title = {T}, doi = {10.1000/ttl}}")
        ttl_responses = Dict("https://doi.org/10.1000/ttl" => (302, ""))
        stale() = Dict{String, Any}(
            "doi" => Dict{String, Any}(
                "10.1000/ttl" => Dict{String, Any}(
                    "status" => 302,
                    "checked" => string(Dates.now() - Dates.Day(2)),
                ),
            ),
        )
        for (ttl, expected) in ((1, 1), (3, 0))
            requests = Ref(0)
            settings = validate_settings(Dict("network" => Dict("cache_ttl_days" => ttl)))
            run_checks(
                single,
                Dict{String, String}(),
                Tuple{String, String, Int}[];
                settings,
                online = true,
                fetch = stub_fetcher(ttl_responses, requests),
                pause = _ -> nothing,
                cache = stale(),
            )
            @test requests[] == expected
        end

        mktempdir() do dir
            path = joinpath(dir, "nested", "cache.toml")
            @test load_cache(path) == Dict{String, Any}()
            save_cache(path, cache)
            @test load_cache(path) == cache
            @test occursin("[doi.\"10.1000/notfound\"]", read(path, String))
        end
    end

    @testset "Corrected copy" begin
        mktempdir() do dir
            input = joinpath(dir, "refs.bib")
            write(input, FIXTURE)
            output = joinpath(dir, "refs_fixed.bib")
            @test write_corrected(FIXTURE, entries, output; input) == 2
            doi = "10.1103/PhysRevD.104.000002"
            expected = replace(
                FIXTURE,
                "{https://doi.org/$doi}" => "{$doi}",
                "{11-20}" => "{11--20}",
            )
            @test read(output, String) == expected
            @test_throws "must not overwrite" write_corrected(
                FIXTURE,
                entries,
                input;
                input,
            )
            @test read(input, String) == FIXTURE
        end
    end

    @testset "Command line" begin
        mktempdir() do dir
            bib = joinpath(dir, "refs.bib")
            write(bib, FIXTURE)
            io = IOBuffer()
            result = main([bib]; io)
            text = String(take!(io))
            errors = count(f -> f.severity == :error, result.findings)
            warnings = count(f -> f.severity == :warning, result.findings)
            @test errors == 4
            @test occursin("16 entries: $errors errors, $warnings warnings, 0 notes", text)
            @test occursin("online checks: skipped (pass --online)", text)
            @test result.failed && length(result.entries) == 16
            @test result.fixed === nothing && result.csv === nothing
            @test !any(f -> f.check in ONLINE_CHECKS, result.findings)
            @test !any(f -> f.check in (:uncited, :undefined_citation), result.findings)
            @test startswith(text, "File\n  warning  journal_spelling: ")
            header = "GOOD2020 (line $(entry_named(entries, "GOOD2020").line))"
            @test occursin("\n$header\n", text)
            @test occursin("\n  error    duplicate_key: ", text)
            @test occursin(
                "\n  warning  pages_dash: pages '11-20' should read '11--20'",
                text,
            )
            @test !occursin(r"^good2020 \(line"m, text)

            csv = joinpath(dir, "out", "findings.csv")
            fixed = joinpath(dir, "refs_fixed.bib")
            io = IOBuffer()
            result = main([bib, "--csv", csv, "--fixed", fixed]; io)
            text = String(take!(io))
            @test result.csv == csv && result.fixed == fixed
            @test occursin("Corrected copy written to $fixed (2 replacements)", text)
            @test occursin("CSV written to $csv", text)
            lines = readlines(csv)
            @test lines[1] == "key,line,severity,check,detail"
            @test length(lines) == length(result.findings) + 1
            # the journal detail holds commas and is quoted
            @test any(
                l -> occursin(",warning,journal_spelling,\"journal written as ", l),
                lines,
            )
            @test any(
                l -> startswith(l, "GOOD2020,") && occursin(",error,duplicate_key,", l),
                lines,
            )
            @test read(bib, String) == FIXTURE
            @test occursin("{11--20}", read(fixed, String))
            again = main([bib, "--fixed", fixed]; io = IOBuffer())
            @test again.fixed == joinpath(dir, "refs_fixed#1.bib")
            @test_throws "must not overwrite" main([bib, "--fixed", bib]; io = IOBuffer())

            manuscript = joinpath(dir, "manuscript")
            write(joinpath(mkpath(joinpath(manuscript, "sections")), "intro.tex"), TEX)
            write(joinpath(manuscript, "notes.txt"), raw"\cite{nowhere}")
            result = main([bib, "--tex", manuscript]; io = IOBuffer())
            undefined = only(filter(f -> f.check == :undefined_citation, result.findings))
            @test occursin("ghost2000", undefined.detail)
            @test occursin("intro.tex", undefined.detail)
            @test length(filter(f -> f.check == :uncited, result.findings)) == 11

            warning_bib = joinpath(dir, "warning.bib")
            write(warning_bib, WARNING_ONLY)
            relaxed = main([warning_bib]; io = IOBuffer())
            @test keys_of(relaxed.findings) == ["w2020"] && !relaxed.failed
            @test main([warning_bib, "--strict"]; io = IOBuffer()).failed

            io = IOBuffer()
            @test main(["--help"]; io) === nothing
            @test occursin("--online", String(take!(io)))
            @test_throws "unknown command-line argument '--bogus'" main(
                [bib, "--bogus"];
                io = IOBuffer(),
            )
            @test_throws "BibTeX file not found" main(
                [joinpath(dir, "absent.bib")];
                io = IOBuffer(),
            )
            @test_throws "one BibTeX file expected" main([bib, bib]; io = IOBuffer())
            @test_throws "no BibTeX file" main(String[]; io = IOBuffer())
            @test_throws "LaTeX source not found" main(
                [bib, "--tex", joinpath(dir, "absent.tex")];
                io = IOBuffer(),
            )
            broken = joinpath(dir, "broken.bib")
            write(broken, "\n\n@article{broken,\n  title = {unclosed\n")
            @test_throws "broken.bib, line 3" main([broken]; io = IOBuffer())

            cache_path = joinpath(dir, "cache", "lookups.toml")
            config = joinpath(dir, "online.toml")
            open(config, "w") do out
                TOML.print(out, Dict("network" => Dict("cache_file" => cache_path)))
            end
            io = IOBuffer()
            result = main(
                [bib, "--online", "--config", config];
                io,
                fetch = stub_fetcher(fixture_responses(entries), Ref(0)),
                pause = _ -> nothing,
            )
            @test occursin("online checks: ran", String(take!(io)))
            @test keys_of(filter(f -> f.check == :doi_unresolved, result.findings)) ==
                  ["press2024"]
            @test isfile(cache_path)
            stored = TOML.parsefile(cache_path)
            @test stored["doi"]["10.1000/notfound"]["status"] == 404
            @test haskey(stored["arxiv"], "2301.00001")
        end
    end
end
