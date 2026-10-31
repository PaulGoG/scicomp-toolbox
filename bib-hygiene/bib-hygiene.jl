#!/usr/bin/env julia
# bib-hygiene — validation of a BibTeX file before submission: keys, required fields,
# DOIs and arXiv identifiers, journal spellings, encoding and escaping, protected
# capitals, page ranges, years and citations against the LaTeX sources. Offline unless
# --online; the input is never written, a corrected copy goes to a separate file.
#
#   julia run.jl bib-hygiene BIB [--tex PATH ...] [--online] [--refresh] [--strict]
#                            [--fixed FILE] [--csv FILE] [--config PATH]

using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)

using Dates: Dates, DateTime, now
using HTTP: HTTP
using Printf: @sprintf
using TOML: TOML

"""
Names of the checks, in the order they run. The online checks `doi_unresolved` and
`arxiv_published` also emit `doi_unchecked` and `arxiv_unchecked` findings when a lookup
fails; those belong to their check and are disabled with it.
"""
const CHECKS = (
    :duplicate_key,
    :duplicate_entry,
    :missing_field,
    :doi_prefix,
    :doi_syntax,
    :doi_missing,
    :journal_spelling,
    :non_ascii,
    :unescaped,
    :title_case,
    :pages_dash,
    :year,
    :duplicate_field,
    :uncited,
    :undefined_citation,
    :doi_unresolved,
    :arxiv_published,
)

# --- settings ---------------------------------------------------------------------------

"""
    HygieneSettings

Validated configuration: the checks to skip, the contact e-mail sent with online
requests, the path of the lookup cache and the age in days beyond which a cached lookup
is repeated, the pauses in seconds between doi.org and between arXiv requests, and the
number of arXiv identifiers per API request.
"""
struct HygieneSettings
    disabled::Set{Symbol}
    contact_email::String
    cache_file::String
    cache_ttl_days::Int
    doi_delay_s::Float64
    arxiv_delay_s::Float64
    arxiv_batch::Int
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

function string_list(
    table::AbstractDict,
    key::AbstractString,
    default::Vector{String},
    context::AbstractString;
    nonempty::Bool = false,
)
    value = get(table, key, default)
    (
        value isa AbstractVector &&
        all(item -> item isa AbstractString && !isempty(strip(item)), value)
    ) || throw(ArgumentError("$context.$key must be a list of non-empty strings"))
    (nonempty && isempty(value)) && throw(ArgumentError("$context.$key must not be empty"))
    return String[strip(item) for item in value]
end

function nonnegative_seconds(table::AbstractDict, key::AbstractString, default::Float64)
    value = get(table, key, default)
    (value isa Real && !(value isa Bool) && isfinite(value) && value >= 0) ||
        throw(ArgumentError("[network].$key must be a number >= 0 [s], got $(repr(value))"))
    return Float64(value)
end

"""
    validate_settings(raw::AbstractDict) -> HygieneSettings

Enforce the schema of the configuration tables; absent keys take the defaults of the
shipped `config.toml`. Fails with an `ArgumentError` naming the offending key.
"""
function validate_settings(raw::AbstractDict)
    reject_unknown_keys(raw, ("checks", "network"), "top level")
    checks = section(raw, "checks")
    network = section(raw, "network")
    reject_unknown_keys(checks, ("disabled",), "[checks]")
    reject_unknown_keys(
        network,
        (
            "contact_email",
            "cache_file",
            "cache_ttl_days",
            "doi_delay_s",
            "arxiv_delay_s",
            "arxiv_batch",
        ),
        "[network]",
    )
    disabled = Set{Symbol}()
    for name in string_list(checks, "disabled", String[], "[checks]")
        Symbol(name) in CHECKS || throw(
            ArgumentError(
                "[checks].disabled: unknown check '$name'; allowed: $(join(CHECKS, ", "))",
            ),
        )
        push!(disabled, Symbol(name))
    end
    contact_email = get(network, "contact_email", "")
    (
        contact_email isa AbstractString &&
        (isempty(strip(contact_email)) || occursin('@', contact_email))
    ) || throw(
        ArgumentError(
            "[network].contact_email must be empty or an e-mail address containing \"@\"",
        ),
    )
    cache_file = get(network, "cache_file", "data/lookup_cache.toml")
    (cache_file isa AbstractString && !isempty(strip(cache_file))) ||
        throw(ArgumentError("[network].cache_file must be a non-empty string"))
    cache_ttl_days = get(network, "cache_ttl_days", 30)
    (cache_ttl_days isa Integer && !(cache_ttl_days isa Bool) && cache_ttl_days >= 0) ||
        throw(
            ArgumentError(
                "[network].cache_ttl_days must be an integer >= 0, got $(repr(cache_ttl_days))",
            ),
        )
    doi_delay_s = nonnegative_seconds(network, "doi_delay_s", 0.5)
    arxiv_delay_s = nonnegative_seconds(network, "arxiv_delay_s", 3.0)
    arxiv_batch = get(network, "arxiv_batch", 20)
    (arxiv_batch isa Integer && !(arxiv_batch isa Bool) && 1 <= arxiv_batch <= 100) ||
        throw(
            ArgumentError(
                "[network].arxiv_batch must be an integer in [1, 100], got $(repr(arxiv_batch))",
            ),
        )
    return HygieneSettings(
        disabled,
        String(strip(contact_email)),
        String(strip(cache_file)),
        Int(cache_ttl_days),
        doi_delay_s,
        arxiv_delay_s,
        Int(arxiv_batch),
    )
end

"""
    load_settings(path::AbstractString) -> HygieneSettings

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

first_line(text::AbstractString) = String(first(split(text, '\n')))

counted(n::Integer, noun::AbstractString, plural::AbstractString = noun * "s") =
    n == 1 ? "1 $noun" : "$n $plural"

# --- parser -----------------------------------------------------------------------------

"""
    BibField

One field of an entry: its lowercase `name`; its `value` after `#` concatenation and
`@string` substitution, outer braces or quotes removed, inner braces kept, runs of
whitespace collapsed to one space; the byte range `span` of the raw value in the source,
delimiters included (the whole expression for a concatenation); and the source `line`
of the field name.
"""
struct BibField
    name::String
    value::String
    span::UnitRange{Int}
    line::Int
end

"""
    BibEntry

One entry: its lowercase `type`, its `key`, its `fields` in source order (a repeated
name keeps its first value), the source `line` of its `@` and the byte range `span` from
the `@` to the closing delimiter.
"""
struct BibEntry
    type::String
    key::String
    fields::Vector{BibField}
    line::Int
    span::UnitRange{Int}
end

"""
    BibParseError(message::String, line::Int)

Malformed BibTeX at a 1-based source line; shown as `line N: message`.
"""
struct BibParseError <: Exception
    message::String
    line::Int
end

Base.showerror(io::IO, err::BibParseError) = print(io, "line ", err.line, ": ", err.message)

const MONTHS =
    ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec")

# bytes that end a field name, a string name or a bare value
const NAME_STOPS = codeunits("{}()=,\"#%")

"""
    BibSource(text)

Source text with the byte positions of its newlines, for line numbers. All structural
characters of BibTeX are ASCII, so the scanner walks bytes and every span covers whole
characters.
"""
struct BibSource
    text::String
    newlines::Vector{Int}
end

function BibSource(text::AbstractString)
    s = String(text)
    return BibSource(s, findall(==(UInt8('\n')), codeunits(s)))
end

line_at(src::BibSource, i::Int) = searchsortedfirst(src.newlines, i)
byte_at(src::BibSource, i::Int) = codeunit(src.text, i)
byte_count(src::BibSource) = ncodeunits(src.text)
slice(src::BibSource, a::Int, b::Int) = String(view(codeunits(src.text), a:b))
is_space(b::UInt8) = b == 0x20 || 0x09 <= b <= 0x0d
is_digit(b::UInt8) = UInt8('0') <= b <= UInt8('9')
is_name_byte(b::UInt8) = !is_space(b) && !(b in NAME_STOPS)

function skip_space(src::BibSource, i::Int)
    n = byte_count(src)
    while i <= n && is_space(byte_at(src, i))
        i += 1
    end
    return i
end

# first byte after the name that starts at i
function scan_name(src::BibSource, i::Int)
    n = byte_count(src)
    while i <= n && is_name_byte(byte_at(src, i))
        i += 1
    end
    return i
end

"""
    closing_brace(src, i) -> Union{Int, Nothing}

Position of the `}` that closes the `{` at `i`, or `nothing` when the input ends first.
"""
function closing_brace(src::BibSource, i::Int)
    depth = 0
    for k in i:byte_count(src)
        b = byte_at(src, k)
        if b == UInt8('{')
            depth += 1
        elseif b == UInt8('}')
            depth -= 1
            depth == 0 && return k
        end
    end
    return nothing
end

# the closing quote of the quoted value at i; braces nest and shield quotes
function closing_quote(src::BibSource, i::Int)
    depth = 0
    for k in (i + 1):byte_count(src)
        b = byte_at(src, k)
        if b == UInt8('{')
            depth += 1
        elseif b == UInt8('}')
            depth -= 1
            depth < 0 && return nothing
        elseif b == UInt8('"') && depth == 0
            return k
        end
    end
    return nothing
end

# the `}` or `)` that closes the group opened at i, counting braces
function closing_delimiter(src::BibSource, i::Int)
    byte_at(src, i) == UInt8('{') && return closing_brace(src, i)
    depth = 0
    for k in (i + 1):byte_count(src)
        b = byte_at(src, k)
        if b == UInt8('{')
            depth += 1
        elseif b == UInt8('}')
            depth -= 1
        elseif b == UInt8(')') && depth == 0
            return k
        end
    end
    return nothing
end

collapse(text::AbstractString) = String(strip(replace(text, r"\s+" => " ")))

"""
    parse_value(src, i, strings, entry_line) -> (value, span, next)

The value expression that starts at or after `i`: braced and quoted parts, unsigned
integers and string names joined by `#`. Returns the collapsed value, the byte span of
the expression and the position after it.
"""
function parse_value(src::BibSource, i::Int, strings::Dict{String, String}, entry_line::Int)
    n = byte_count(src)
    parts = String[]
    i = skip_space(src, i)
    start = i
    stop = i - 1
    while true
        i = skip_space(src, i)
        i > n && throw(BibParseError("end of input inside an entry", entry_line))
        b = byte_at(src, i)
        if b == UInt8('{')
            close = closing_brace(src, i)
            close === nothing && throw(BibParseError("unbalanced braces", entry_line))
            push!(parts, slice(src, i + 1, close - 1))
            stop = close
        elseif b == UInt8('"')
            close = closing_quote(src, i)
            close === nothing &&
                throw(BibParseError("unbalanced braces or unterminated quote", entry_line))
            push!(parts, slice(src, i + 1, close - 1))
            stop = close
        elseif is_digit(b)
            stop = i
            while stop < n && is_digit(byte_at(src, stop + 1))
                stop += 1
            end
            push!(parts, slice(src, i, stop))
        elseif is_name_byte(b)
            stop = scan_name(src, i) - 1
            name = lowercase(slice(src, i, stop))
            if haskey(strings, name)
                push!(parts, strings[name])
            elseif name in MONTHS
                push!(parts, name)
            else
                throw(BibParseError("undefined string $name", line_at(src, i)))
            end
        else
            throw(
                BibParseError(
                    "unexpected character '$(Char(b))' in a field value",
                    line_at(src, i),
                ),
            )
        end
        i = skip_space(src, stop + 1)
        (i <= n && byte_at(src, i) == UInt8('#')) || break
        i += 1
    end
    return collapse(join(parts)), start:stop, stop + 1
end

"""
    parse_fields(src, i, closer, strings, entry_line, key, duplicates) -> (fields, close)

The `name = value` list that starts at `i`, up to the `closer` byte of the entry; a
trailing comma is allowed. A name repeated within the list keeps its first value and is
recorded in `duplicates`. Returns the fields and the position of the closer.
"""
function parse_fields(
    src::BibSource,
    i::Int,
    closer::UInt8,
    strings::Dict{String, String},
    entry_line::Int,
    key::String,
    duplicates::Vector{Tuple{String, String, Int}},
)
    n = byte_count(src)
    fields = BibField[]
    while true
        i = skip_space(src, i)
        i > n && throw(BibParseError("end of input inside an entry", entry_line))
        byte_at(src, i) == closer && return fields, i
        is_name_byte(byte_at(src, i)) ||
            throw(BibParseError("expected a field name", line_at(src, i)))
        stop = scan_name(src, i)
        name = lowercase(slice(src, i, stop - 1))
        line = line_at(src, i)
        i = skip_space(src, stop)
        (i <= n && byte_at(src, i) == UInt8('=')) ||
            throw(BibParseError("expected '=' after field $name", line))
        value, span, i = parse_value(src, i + 1, strings, entry_line)
        if any(f -> f.name == name, fields)
            push!(duplicates, (key, name, line))
        else
            push!(fields, BibField(name, value, span, line))
        end
        i = skip_space(src, i)
        i > n && throw(BibParseError("end of input inside an entry", entry_line))
        b = byte_at(src, i)
        if b == UInt8(',')
            i += 1
        elseif b == closer
            return fields, i
        else
            throw(
                BibParseError(
                    "expected ',' or the end of the entry after field $name",
                    line_at(src, i),
                ),
            )
        end
    end
end

"""
    parse_bibtex(text::AbstractString) -> (entries, strings, duplicates)

Parse BibTeX source. Text outside entries is ignored; `@comment` and `@preamble` are
skipped; `@string` definitions fill the macro table `strings` (lowercase names), through
which bare identifiers in later values resolve, the month names `jan` to `dec` resolving
to themselves. An entry opens with `{` or `(`, its key runs to the first comma, and its
fields follow. `duplicates` lists `(key, field, line)` for every field name repeated
within an entry. Throws a [`BibParseError`](@ref) on an entry without key, an undefined
string, unbalanced braces or the end of input inside an entry.
"""
function parse_bibtex(text::AbstractString)
    src = BibSource(text)
    bytes = codeunits(src.text)
    n = byte_count(src)
    entries = BibEntry[]
    strings = Dict{String, String}()
    duplicates = Tuple{String, String, Int}[]
    i = 1
    while i <= n
        at = findnext(==(UInt8('@')), bytes, i)
        at === nothing && break
        j = scan_name(src, at + 1)
        type = lowercase(slice(src, at + 1, j - 1))
        j = skip_space(src, j)
        if isempty(type) || j > n || !(byte_at(src, j) in (UInt8('{'), UInt8('(')))
            i = at + 1
            continue
        end
        line = line_at(src, at)
        if type in ("comment", "preamble")
            close = closing_delimiter(src, j)
            close === nothing && throw(BibParseError("unbalanced braces", line))
            i = close + 1
            continue
        end
        closer = byte_at(src, j) == UInt8('{') ? UInt8('}') : UInt8(')')
        if type == "string"
            definitions, close = parse_fields(
                src,
                j + 1,
                closer,
                strings,
                line,
                "",
                Tuple{String, String, Int}[],
            )
            for definition in definitions
                strings[definition.name] = definition.value
            end
            i = close + 1
            continue
        end
        k = j + 1
        while k <= n && byte_at(src, k) != UInt8(',') && byte_at(src, k) != closer
            k += 1
        end
        k > n && throw(BibParseError("end of input inside an entry", line))
        key = String(strip(slice(src, j + 1, k - 1)))
        isempty(key) && throw(BibParseError("entry without key", line))
        fields, close =
            byte_at(src, k) == closer ? (BibField[], k) :
            parse_fields(src, k + 1, closer, strings, line, key, duplicates)
        push!(entries, BibEntry(type, key, fields, line, at:close))
        i = close + 1
    end
    return entries, strings, duplicates
end

"""
    field(entry::BibEntry, name::AbstractString) -> Union{String, Nothing}

Value of the field `name` (case-insensitive), or `nothing` when the entry lacks it.
"""
function field(entry::BibEntry, name::AbstractString)
    f = field_of(entry, name)
    return f === nothing ? nothing : f.value
end

function field_of(entry::BibEntry, name::AbstractString)
    target = lowercase(name)
    for f in entry.fields
        f.name == target && return f
    end
    return nothing
end

has_value(entry::BibEntry, name::AbstractString) =
    !isempty(something(field(entry, name), ""))

# --- identifiers ------------------------------------------------------------------------

const DOI_PREFIX = r"^(?:https?://|(?:dx\.)?doi\.org/|doi:)"i
const DOI_SYNTAX = r"^10\.\d{4,9}/\S+$"

"""
    bare_doi(value::AbstractString) -> String

`value` without surrounding whitespace and without the prefixes `http://`, `https://`,
`doi.org/`, `dx.doi.org/` and `doi:` (case-insensitive, in any combination).
"""
function bare_doi(value::AbstractString)
    doi = strip(value)
    while true
        m = match(DOI_PREFIX, doi)
        m === nothing && break
        doi = lstrip(SubString(doi, ncodeunits(m.match) + 1))
    end
    return String(doi)
end

const ARXIV_NEW = "\\d{4}\\.\\d{4,5}"
const ARXIV_OLD = "[a-z\\-]+(?:\\.[A-Z]{2})?/\\d{7}"
const ARXIV_WHOLE = Regex("^(?:(?i:arxiv):)?\\s*($ARXIV_NEW|$ARXIV_OLD)(?:v\\d+)?\$")
const ARXIV_IN_TEXT = Regex("(?i:arxiv\\.org/abs/|arxiv:)\\s*($ARXIV_NEW|$ARXIV_OLD)")
const ARXIV_DOI = r"^10\.48550/arxiv\.(.+)$"i
const ARXIV_TEXT_FIELDS = ("journal", "note", "url", "howpublished")

"""
    arxiv_id(entry::BibEntry) -> Union{String, Nothing}

The arXiv identifier of an entry, without version, taken in order from: the `eprint`
field, when `archiveprefix` or `eprinttype` is `arxiv` or the field itself has the form
of an identifier; a DOI `10.48550/arXiv.<id>`; an `arxiv.org/abs/<id>` or `arXiv:<id>`
in `journal`, `note`, `url` or `howpublished`. Identifiers are of the form
`2301.00001` or, in the old style, `hep-th/9901001`.
"""
function arxiv_id(entry::BibEntry)
    eprint = field(entry, "eprint")
    if eprint !== nothing && !isempty(eprint)
        m = match(ARXIV_WHOLE, eprint)
        m === nothing || return String(m.captures[1]::AbstractString)
        any(
            name -> lowercase(something(field(entry, name), "")) == "arxiv",
            ("archiveprefix", "eprinttype"),
        ) && return eprint
    end
    doi = field(entry, "doi")
    if doi !== nothing
        m = match(ARXIV_DOI, bare_doi(doi))
        if m !== nothing
            id = match(ARXIV_WHOLE, m.captures[1]::AbstractString)
            id === nothing || return String(id.captures[1]::AbstractString)
        end
    end
    for name in ARXIV_TEXT_FIELDS
        value = field(entry, name)
        value === nothing && continue
        m = match(ARXIV_IN_TEXT, value)
        m === nothing || return String(m.captures[1]::AbstractString)
    end
    return nothing
end

"""
    is_preprint(entry::BibEntry) -> Bool

Whether the entry has an arXiv identifier and no DOI other than an arXiv one
(`10.48550/...`).
"""
function is_preprint(entry::BibEntry)
    arxiv_id(entry) === nothing && return false
    doi = field(entry, "doi")
    return doi === nothing ||
           isempty(doi) ||
           startswith(lowercase(bare_doi(doi)), "10.48550/")
end

# --- offline checks ---------------------------------------------------------------------

"""
    Finding

One result of a check: the entry `key` (`""` for a finding about the whole file), the
`check` that produced it, its `severity` (`:error`, `:warning` or `:info`), a `detail`
for the author and the source `line` (0 when none applies).
"""
struct Finding
    key::String
    check::Symbol
    severity::Symbol
    detail::String
    line::Int
end

"""
Required fields per entry type, as in standard BibTeX; `a|b` means one of the two
suffices. Types absent from the table require nothing.
"""
const REQUIRED_FIELDS = Dict{String, Vector{String}}(
    "article" => ["author", "title", "journal", "year"],
    "book" => ["author|editor", "title", "publisher", "year"],
    "booklet" => ["title"],
    "inbook" => ["author|editor", "title", "chapter|pages", "publisher", "year"],
    "incollection" => ["author", "title", "booktitle", "publisher", "year"],
    "inproceedings" => ["author", "title", "booktitle", "year"],
    "conference" => ["author", "title", "booktitle", "year"],
    "manual" => ["title"],
    "mastersthesis" => ["author", "title", "school", "year"],
    "phdthesis" => ["author", "title", "school", "year"],
    "proceedings" => ["title", "year"],
    "techreport" => ["author", "title", "institution", "year"],
    "unpublished" => ["author", "title", "note"],
    "misc" => String[],
    "online" => ["title", "url"],
    "electronic" => ["title", "url"],
)

"""
    check_duplicate_key(entries) -> Vector{Finding}

Errors for keys that, compared case-insensitively, already belong to an earlier entry;
one per later occurrence.
"""
function check_duplicate_key(entries::Vector{BibEntry})
    findings = Finding[]
    seen = Dict{String, Int}()
    for entry in entries
        id = lowercase(entry.key)
        if haskey(seen, id)
            push!(
                findings,
                Finding(
                    entry.key,
                    :duplicate_key,
                    :error,
                    "key already used by the entry on line $(seen[id])",
                    entry.line,
                ),
            )
        else
            seen[id] = entry.line
        end
    end
    return findings
end

normalized_title(title::AbstractString) =
    filter(c -> isletter(c) || isdigit(c), lowercase(title))

function doi_key(entry::BibEntry)
    value = field(entry, "doi")
    (value === nothing || isempty(value)) && return nothing
    return lowercase(bare_doi(value))
end

function title_key(entry::BibEntry)
    value = field(entry, "title")
    value === nothing && return nothing
    title = normalized_title(value)
    return length(title) >= 20 ? title : nothing
end

"""
    check_duplicate_entry(entries) -> Vector{Finding}

Warnings for pairs of entries that share a DOI (bare, lowercase) or a normalized title
(lowercase letters and digits, at least 20 characters); one per pair, on the later
entry, naming the earlier key.
"""
function check_duplicate_entry(entries::Vector{BibEntry})
    dois = [doi_key(entry) for entry in entries]
    titles = [title_key(entry) for entry in entries]
    findings = Finding[]
    for j in eachindex(entries), i in 1:(j - 1)
        shared = String[]
        (dois[i] !== nothing && dois[i] == dois[j]) && push!(shared, "DOI")
        (titles[i] !== nothing && titles[i] == titles[j]) && push!(shared, "title")
        isempty(shared) && continue
        push!(
            findings,
            Finding(
                entries[j].key,
                :duplicate_entry,
                :warning,
                "same $(join(shared, " and ")) as $(entries[i].key)",
                entries[j].line,
            ),
        )
    end
    return findings
end

"""
    check_missing_field(entries) -> Vector{Finding}

Errors for the required fields of [`REQUIRED_FIELDS`](@ref) that are absent or empty;
one per missing requirement.
"""
function check_missing_field(entries::Vector{BibEntry})
    findings = Finding[]
    for entry in entries
        for requirement in get(REQUIRED_FIELDS, entry.type, String[])
            alternatives = split(requirement, '|')
            any(name -> has_value(entry, name), alternatives) && continue
            push!(
                findings,
                Finding(
                    entry.key,
                    :missing_field,
                    :error,
                    "missing " * join(alternatives, " or "),
                    entry.line,
                ),
            )
        end
    end
    return findings
end

"""
    check_doi_prefix(entries) -> Vector{Finding}

Warnings for DOIs written with a resolver or scheme prefix ([`bare_doi`](@ref)).
"""
function check_doi_prefix(entries::Vector{BibEntry})
    findings = Finding[]
    for entry in entries
        f = field_of(entry, "doi")
        f === nothing && continue
        bare = bare_doi(f.value)
        bare == strip(f.value) && continue
        push!(
            findings,
            Finding(
                entry.key,
                :doi_prefix,
                :warning,
                "prefixed doi; bare form $bare",
                f.line,
            ),
        )
    end
    return findings
end

"""
    check_doi_syntax(entries) -> Vector{Finding}

Errors for non-empty bare DOIs that do not match `10.NNNN/suffix`.
"""
function check_doi_syntax(entries::Vector{BibEntry})
    findings = Finding[]
    for entry in entries
        f = field_of(entry, "doi")
        f === nothing && continue
        bare = bare_doi(f.value)
        (isempty(bare) || occursin(DOI_SYNTAX, bare)) && continue
        push!(
            findings,
            Finding(
                entry.key,
                :doi_syntax,
                :error,
                "doi '$bare' does not have the form 10.NNNN/suffix",
                f.line,
            ),
        )
    end
    return findings
end

"""
    check_doi_missing(entries) -> Vector{Finding}

Warnings for articles, papers in proceedings and chapters in collections that carry
neither a DOI nor an arXiv identifier.
"""
function check_doi_missing(entries::Vector{BibEntry})
    findings = Finding[]
    for entry in entries
        entry.type in ("article", "inproceedings", "incollection") || continue
        (has_value(entry, "doi") || arxiv_id(entry) !== nothing) && continue
        push!(
            findings,
            Finding(
                entry.key,
                :doi_missing,
                :warning,
                "no doi and no arXiv identifier",
                entry.line,
            ),
        )
    end
    return findings
end

const JOURNAL_STOPWORDS =
    ("of", "the", "and", "for", "on", "in", "de", "der", "und", "et", "a", "an")

"""
    journal_tokens(name::AbstractString) -> Vector{String}

Words of a journal name for comparison: braces removed, lowercase, `.`, `,`, `:` and `&`
read as spaces, and the stopwords of [`JOURNAL_STOPWORDS`](@ref) dropped.
"""
function journal_tokens(name::AbstractString)
    text = replace(lowercase(replace(name, r"[{}]" => "")), r"[.,:&]" => " ")
    return [String(t) for t in split(text) if !(t in JOURNAL_STOPWORDS)]
end

"""
    same_journal(a, b) -> Bool

Whether two token lists name the same journal: equal length and, at every position, one
token a prefix of the other, so that `Phys. Rev. D` matches `Physical Review D`.
"""
same_journal(a::Vector{String}, b::Vector{String}) =
    length(a) == length(b) &&
    all(startswith(x, y) || startswith(y, x) for (x, y) in zip(a, b))

function find_root!(parent::Vector{Int}, k::Int)
    while parent[k] != k
        parent[k] = parent[parent[k]]
        k = parent[k]
    end
    return k
end

"""
    check_journal_spelling(entries) -> Vector{Finding}

File-level warnings for journals written in more than one way. Entries are grouped with
union-find over [`same_journal`](@ref); every group with more than one distinct spelling
gives one finding listing the spellings in order of first appearance, each with its
keys, on the line of the first entry of the group.
"""
function check_journal_spelling(entries::Vector{BibEntry})
    members = Int[]
    names = String[]
    tokens = Vector{String}[]
    for (i, entry) in enumerate(entries)
        value = field(entry, "journal")
        value === nothing && continue
        words = journal_tokens(value)
        isempty(words) && continue
        push!(members, i)
        push!(names, value)
        push!(tokens, words)
    end
    parent = collect(eachindex(members))
    for b in eachindex(members), a in 1:(b - 1)
        same_journal(tokens[a], tokens[b]) || continue
        ra, rb = find_root!(parent, a), find_root!(parent, b)
        ra == rb || (parent[max(ra, rb)] = min(ra, rb))
    end
    findings = Finding[]
    for k in eachindex(members)
        find_root!(parent, k) == k || continue
        group = [m for m in eachindex(members) if find_root!(parent, m) == k]
        spellings = unique(names[group])
        length(spellings) > 1 || continue
        parts = String[]
        for s in spellings
            spelled = [entries[members[m]].key for m in group if names[m] == s]
            push!(parts, "'$s' (" * join(spelled, ", ") * ")")
        end
        push!(
            findings,
            Finding(
                "",
                :journal_spelling,
                :warning,
                "journal written as " * join(parts, ", ", " and "),
                entries[members[first(group)]].line,
            ),
        )
    end
    return findings
end

const IDENTIFIER_FIELDS = ("url", "doi", "file", "eprint")

"""
    check_non_ascii(entries) -> Vector{Finding}

Warnings for field values holding characters above U+007F, listing up to eight distinct
characters in order of appearance; `url`, `doi`, `file` and `eprint` are exempt.
"""
function check_non_ascii(entries::Vector{BibEntry})
    findings = Finding[]
    for entry in entries, f in entry.fields
        f.name in IDENTIFIER_FIELDS && continue
        characters = unique(c for c in f.value if !isascii(c))
        isempty(characters) && continue
        push!(
            findings,
            Finding(
                entry.key,
                :non_ascii,
                :warning,
                "non-ASCII in $(f.name): " * join(first(characters, 8), ", "),
                f.line,
            ),
        )
    end
    return findings
end

"""
    unescaped_characters(value::AbstractString) -> Vector{Char}

The distinct characters among `&`, `%`, `#` and `_` that occur without a preceding
backslash, outside `\\url{...}` and outside `\$...\$`.
"""
function unescaped_characters(value::AbstractString)
    text = String(value)
    found = Char[]
    in_math = false
    previous = ' '
    i = firstindex(text)
    while i <= lastindex(text)
        c = text[i]
        if c == '\\' && startswith(SubString(text, i), "\\url{")
            close = closing_brace(BibSource(text), i + 4)
            close === nothing && break
            i = close + 1
            previous = '}'
            continue
        end
        if c == '$' && previous != '\\'
            in_math = !in_math
        elseif !in_math && c in ('&', '%', '#', '_') && previous != '\\'
            c in found || push!(found, c)
        end
        previous = c
        i = nextind(text, i)
    end
    return found
end

"""
    check_unescaped(entries) -> Vector{Finding}

Warnings for `&`, `%`, `#` and `_` left unescaped ([`unescaped_characters`](@ref)), one
per field; `url`, `doi`, `file`, `eprint` and `howpublished` are exempt.
"""
function check_unescaped(entries::Vector{BibEntry})
    findings = Finding[]
    for entry in entries, f in entry.fields
        (f.name in IDENTIFIER_FIELDS || f.name == "howpublished") && continue
        characters = unescaped_characters(f.value)
        isempty(characters) && continue
        push!(
            findings,
            Finding(
                entry.key,
                :unescaped,
                :warning,
                "unescaped $(join(characters, ", ")) in $(f.name)",
                f.line,
            ),
        )
    end
    return findings
end

"""
    unprotected_capitals(value::AbstractString) -> Vector{String}

The distinct words, the first word of `value` excepted, that hold an uppercase letter at
brace depth 0, which a bibliography style may lowercase.
"""
function unprotected_capitals(value::AbstractString)
    found = String[]
    depth = 0
    position = 0
    word = Char[]
    flagged = false
    for c in value * " "
        if isspace(c)
            isempty(word) && continue
            position += 1
            if flagged && position > 1
                w = String(strip(String(word), ['.', ',', ';', ':', '!', '?', '(', ')']))
                w in found || push!(found, w)
            end
            empty!(word)
            flagged = false
            continue
        end
        push!(word, c)
        if c == '{'
            depth += 1
        elseif c == '}'
            depth = max(depth - 1, 0)
        elseif depth == 0 && isuppercase(c)
            flagged = true
        end
    end
    return found
end

"""
    check_title_case(entries) -> Vector{Finding}

Warnings for capitals not protected by braces in `title` ([`unprotected_capitals`](@ref)),
listing up to five words. The standard styles lower the case of the title only, so
`booktitle` is left alone.
"""
function check_title_case(entries::Vector{BibEntry})
    findings = Finding[]
    for entry in entries, f in entry.fields
        f.name == "title" || continue
        words = unprotected_capitals(f.value)
        isempty(words) && continue
        push!(
            findings,
            Finding(
                entry.key,
                :title_case,
                :warning,
                "capitals not protected by braces in $(f.name): " *
                join(first(words, 5), ", "),
                f.line,
            ),
        )
    end
    return findings
end

# a hyphen, en dash or em dash between two digits; "--" never matches
const PAGE_DASH = r"(\d)(?:-|\x{2013}|\x{2014})(?=\d)"

"""
    check_pages_dash(entries) -> Vector{Finding}

Warnings for page ranges joined by a single hyphen, an en dash or an em dash instead of
`--`.
"""
function check_pages_dash(entries::Vector{BibEntry})
    findings = Finding[]
    for entry in entries
        f = field_of(entry, "pages")
        f === nothing && continue
        corrected = replace(f.value, PAGE_DASH => s"\1--")
        corrected == f.value && continue
        push!(
            findings,
            Finding(
                entry.key,
                :pages_dash,
                :warning,
                "pages '$(f.value)' should read '$corrected'",
                f.line,
            ),
        )
    end
    return findings
end

const YEAR_WORDS = ("in press", "forthcoming", "submitted")

"""
    check_year(entries; current_year = Dates.year(now())) -> Vector{Finding}

Errors for years that are neither integers nor one of `in press`, `forthcoming`,
`submitted` (case-insensitive); warnings for integers outside
`[1500, current_year + 1]`.
"""
function check_year(entries::Vector{BibEntry}; current_year::Int = Dates.year(now()))
    findings = Finding[]
    for entry in entries
        f = field_of(entry, "year")
        f === nothing && continue
        year = tryparse(Int, f.value)
        if year === nothing
            lowercase(f.value) in YEAR_WORDS && continue
            push!(
                findings,
                Finding(
                    entry.key,
                    :year,
                    :error,
                    "year '$(f.value)' is neither an integer nor one of: " *
                    join(YEAR_WORDS, ", "),
                    f.line,
                ),
            )
        elseif !(1500 <= year <= current_year + 1)
            push!(
                findings,
                Finding(
                    entry.key,
                    :year,
                    :warning,
                    "year $year outside [1500, $(current_year + 1)]",
                    f.line,
                ),
            )
        end
    end
    return findings
end

"""
    check_duplicate_field(duplicates) -> Vector{Finding}

Warnings for the repeated fields recorded by [`parse_bibtex`](@ref).
"""
check_duplicate_field(duplicates::Vector{Tuple{String, String, Int}}) = [
    Finding(
        key,
        :duplicate_field,
        :warning,
        "field $name repeated; the first value is kept",
        line,
    ) for (key, name, line) in duplicates
]

const CITE_COMMAND = r"\\[A-Za-z]*cite[A-Za-z]*\*?(?:\[[^\]]*\]){0,2}\{([^}]*)\}"

"""
    citation_keys(text::AbstractString) -> (keys::Set{String}, nocite_all::Bool)

The keys cited in LaTeX source by any `\\...cite...` command (`\\cite`, `\\citep`,
`\\parencite`, `\\textcite`, `\\autocite`, `\\nocite`, the starred forms and the like),
after removing `%` comments; `nocite_all` is set by `\\nocite{*}`.
"""
function citation_keys(text::AbstractString)
    source = replace(text, r"(?<!\\)%[^\n]*" => "")
    found = Set{String}()
    nocite_all = false
    for m in eachmatch(CITE_COMMAND, source)
        for item in split(m.captures[1]::AbstractString, ',')
            key = String(strip(item))
            isempty(key) && continue
            if key == "*"
                startswith(m.match, "\\nocite") && (nocite_all = true)
            else
                push!(found, key)
            end
        end
    end
    return found, nocite_all
end

"""
    check_uncited(entries, tex_sources) -> Vector{Finding}

Warnings for entries whose key no source cites; none when `tex_sources` is empty or one
of them holds `\\nocite{*}`. `tex_sources` pairs a source name with its text.
"""
function check_uncited(entries::Vector{BibEntry}, tex_sources::Vector{Pair{String, String}})
    isempty(tex_sources) && return Finding[]
    cited = Set{String}()
    for (_, text) in tex_sources
        found, nocite_all = citation_keys(text)
        nocite_all && return Finding[]
        union!(cited, found)
    end
    return [
        Finding(
            entry.key,
            :uncited,
            :warning,
            "not cited in the LaTeX sources",
            entry.line,
        ) for entry in entries if !(entry.key in cited)
    ]
end

"""
    check_undefined_citation(entries, tex_sources) -> Vector{Finding}

File-level errors for cited keys that match no entry key (case-sensitive), one per key
in sorted order, naming the sources that cite it.
"""
function check_undefined_citation(
    entries::Vector{BibEntry},
    tex_sources::Vector{Pair{String, String}},
)
    defined = Set(entry.key for entry in entries)
    citing = Dict{String, Vector{String}}()
    for (name, text) in tex_sources
        for key in first(citation_keys(text))
            key in defined || push!(get!(citing, key, String[]), name)
        end
    end
    return [
        Finding(
            "",
            :undefined_citation,
            :error,
            "'$key' cited in $(join(citing[key], ", ")) has no entry",
            0,
        ) for key in sort!(collect(keys(citing)))
    ]
end

# --- online checks ----------------------------------------------------------------------

"""
    default_fetch(method::String, url::String; contact_email = "") -> (status, body)

One HTTP request without redirects, retries or status exceptions, with a 20 s read
timeout and a User-Agent that carries `contact_email` when it is set. Any exception is
returned as status 0 with the first line of its message as body.
"""
function default_fetch(method::String, url::String; contact_email::AbstractString = "")
    agent =
        isempty(contact_email) ? "scicomp-toolbox bib-hygiene" :
        "scicomp-toolbox bib-hygiene (mailto:$contact_email)"
    try
        response = HTTP.request(
            method,
            url;
            headers = ["User-Agent" => agent],
            redirect = false,
            status_exception = false,
            request_timeout = 20,
            retry = false,
        )
        return Int(response.status), String(response.body)
    catch err
        err isa InterruptException && rethrow()
        return 0, first_line(sprint(showerror, err))
    end
end

"""
    load_cache(path::AbstractString) -> Dict{String, Any}

The lookup cache stored at `path`, empty when the file is absent.
"""
function load_cache(path::AbstractString)
    isfile(path) || return Dict{String, Any}()
    try
        return TOML.parsefile(path)
    catch err
        err isa TOML.ParserError || rethrow()
        throw(ArgumentError("$path: $(sprint(showerror, err))"))
    end
end

"""
    save_cache(path::AbstractString, cache::AbstractDict) -> path

Write the lookup cache as TOML, creating the parent directory.
"""
function save_cache(path::AbstractString, cache::AbstractDict)
    directory = dirname(path)
    isempty(directory) || mkpath(directory)
    open(path, "w") do io
        TOML.print(io, cache; sorted = true)
    end
    return path
end

function cache_table!(cache::Dict{String, Any}, name::String)
    table = get(cache, name, nothing)
    table isa Dict{String, Any} && return table
    fresh = Dict{String, Any}()
    cache[name] = fresh
    return fresh
end

# the cached record of id when it is younger than ttl_days, else nothing
function cached_record(
    table::AbstractDict,
    id::AbstractString,
    ttl_days::Int,
    now_time::DateTime,
)
    record = get(table, id, nothing)
    record isa AbstractDict || return nothing
    checked = get(record, "checked", nothing)
    time =
        checked isa DateTime ? checked :
        checked isa AbstractString ? tryparse(DateTime, checked) : nothing
    (time === nothing || now_time - time > Dates.Day(ttl_days)) && return nothing
    return record
end

"""
    check_doi_unresolved(entries, settings; fetch, pause, cache, refresh, now_time)
        -> Vector{Finding}

Resolve every syntactically valid DOI with `HEAD https://doi.org/<doi>`, without
following the redirect: a 3xx status resolves, 404 or 410 is an error, anything else a
`doi_unchecked` warning that is not cached. Requests are separated by
`pause(settings.doi_delay_s)`; outcomes are read from and written to `cache["doi"]`,
keyed by the lowercase DOI, unless `refresh` is set or the record is older than
`settings.cache_ttl_days`.
"""
function check_doi_unresolved(
    entries::Vector{BibEntry},
    settings::HygieneSettings;
    fetch = default_fetch,
    pause = sleep,
    cache::Dict{String, Any} = Dict{String, Any}(),
    refresh::Bool = false,
    now_time::DateTime = now(),
)
    table = cache_table!(cache, "doi")
    stamp = string(floor(now_time, Dates.Second))
    outcomes = Dict{String, Tuple{Int, String}}()
    requests = 0
    findings = Finding[]
    for entry in entries
        f = field_of(entry, "doi")
        f === nothing && continue
        doi = bare_doi(f.value)
        occursin(DOI_SYNTAX, doi) || continue
        id = lowercase(doi)
        if !haskey(outcomes, id)
            record =
                refresh ? nothing :
                cached_record(table, id, settings.cache_ttl_days, now_time)
            cached_status = record === nothing ? nothing : get(record, "status", nothing)
            if cached_status isa Integer
                outcomes[id] = (Int(cached_status), "")
            else
                requests > 0 && pause(settings.doi_delay_s)
                status, body = fetch("HEAD", "https://doi.org/" * doi)
                requests += 1
                outcomes[id] = (Int(status), String(body))
                if 300 <= status <= 399 || status in (404, 410)
                    table[id] =
                        Dict{String, Any}("status" => Int(status), "checked" => stamp)
                end
            end
        end
        status, message = outcomes[id]
        if status in (404, 410)
            push!(
                findings,
                Finding(
                    entry.key,
                    :doi_unresolved,
                    :error,
                    "DOI does not resolve (HTTP $status)",
                    f.line,
                ),
            )
        elseif !(300 <= status <= 399)
            reason = status == 0 ? message : "HTTP $status"
            push!(
                findings,
                Finding(
                    entry.key,
                    :doi_unchecked,
                    :warning,
                    "could not be checked: $reason",
                    f.line,
                ),
            )
        end
    end
    return findings
end

const ARXIV_FEED_ID = r"<id>https?://arxiv\.org/abs/([^<]+?)(?:v\d+)?</id>"
const ARXIV_FEED_DOI = r"<arxiv:doi[^>]*>(.+?)</arxiv:doi>"
const ARXIV_FEED_REF = r"<arxiv:journal_ref[^>]*>(.+?)</arxiv:journal_ref>"

"""
    parse_arxiv_feed(body::AbstractString) -> Dict{String, Tuple{String, String}}

The DOI and journal reference (empty when absent) of every entry of an arXiv API
response, keyed by identifier without version.
"""
function parse_arxiv_feed(body::AbstractString)
    found = Dict{String, Tuple{String, String}}()
    for chunk in Iterators.drop(split(body, "<entry>"), 1)
        id = match(ARXIV_FEED_ID, chunk)
        id === nothing && continue
        doi = match(ARXIV_FEED_DOI, chunk)
        ref = match(ARXIV_FEED_REF, chunk)
        found[String(id.captures[1]::AbstractString)] = (
            doi === nothing ? "" : String(strip(doi.captures[1]::AbstractString)),
            ref === nothing ? "" : String(strip(ref.captures[1]::AbstractString)),
        )
    end
    return found
end

"""
    check_arxiv_published(entries, settings; fetch, pause, cache, refresh, now_time)
        -> Vector{Finding}

Look up the preprints ([`is_preprint`](@ref)) in the arXiv API, at most
`settings.arxiv_batch` identifiers per request and `pause(settings.arxiv_delay_s)`
between requests, and warn when arXiv records a DOI or a journal reference for them.
A failed request or an identifier absent from the response gives an `arxiv_unchecked`
warning. Results are read from and written to `cache["arxiv"]` as for
[`check_doi_unresolved`](@ref).
"""
function check_arxiv_published(
    entries::Vector{BibEntry},
    settings::HygieneSettings;
    fetch = default_fetch,
    pause = sleep,
    cache::Dict{String, Any} = Dict{String, Any}(),
    refresh::Bool = false,
    now_time::DateTime = now(),
)
    table = cache_table!(cache, "arxiv")
    stamp = string(floor(now_time, Dates.Second))
    preprints = Tuple{BibEntry, String}[]
    for entry in entries
        is_preprint(entry) || continue
        push!(preprints, (entry, something(arxiv_id(entry))))
    end
    published = Dict{String, Tuple{String, String}}()
    unchecked = Dict{String, String}()
    pending = String[]
    for (_, id) in preprints
        (haskey(published, id) || id in pending) && continue
        record =
            refresh ? nothing : cached_record(table, id, settings.cache_ttl_days, now_time)
        if record === nothing
            push!(pending, id)
        else
            published[id] =
                (string(get(record, "doi", "")), string(get(record, "journal_ref", "")))
        end
    end
    for (k, batch) in enumerate(Iterators.partition(pending, settings.arxiv_batch))
        k > 1 && pause(settings.arxiv_delay_s)
        url = "https://export.arxiv.org/api/query?id_list=$(join(batch, ","))&max_results=$(length(batch))"
        status, body = fetch("GET", url)
        if status != 200
            reason = status == 0 ? String(body) : "HTTP $status"
            for id in batch
                unchecked[id] = reason
            end
            continue
        end
        found = parse_arxiv_feed(String(body))
        for id in batch
            if haskey(found, id)
                published[id] = found[id]
                table[id] = Dict{String, Any}(
                    "doi" => found[id][1],
                    "journal_ref" => found[id][2],
                    "checked" => stamp,
                )
            else
                unchecked[id] = "arXiv:$id absent from the API response"
            end
        end
    end
    findings = Finding[]
    for (entry, id) in preprints
        if haskey(unchecked, id)
            push!(
                findings,
                Finding(
                    entry.key,
                    :arxiv_unchecked,
                    :warning,
                    "could not be checked: $(unchecked[id])",
                    entry.line,
                ),
            )
            continue
        end
        doi, ref = published[id]
        parts = String[]
        isempty(doi) || push!(parts, "doi $doi")
        if !isempty(ref)
            push!(parts, isempty(parts) ? "journal ref $ref" : "(journal ref $ref)")
        end
        isempty(parts) && continue
        push!(
            findings,
            Finding(
                entry.key,
                :arxiv_published,
                :warning,
                "published version: " * join(parts, " "),
                entry.line,
            ),
        )
    end
    return findings
end

# --- driver -----------------------------------------------------------------------------

"""
    run_checks(entries, strings, duplicates; tex_sources = Pair{String, String}[],
               settings, online = false, fetch = default_fetch, pause = sleep,
               cache = Dict{String, Any}(), refresh = false) -> Vector{Finding}

Run every check of [`CHECKS`](@ref) not disabled in `settings` on the output of
[`parse_bibtex`](@ref), in order. The citation checks need `tex_sources` (name => text)
and the online checks need `online`; `fetch(method, url) -> (status, body)` and
`pause(seconds)` carry out and space the requests, and `cache` is updated in place.
Nothing is read from disk.
"""
function run_checks(
    entries::Vector{BibEntry},
    strings::Dict{String, String},
    duplicates::Vector{Tuple{String, String, Int}};
    tex_sources::Vector{Pair{String, String}} = Pair{String, String}[],
    settings::HygieneSettings,
    online::Bool = false,
    fetch = default_fetch,
    pause = sleep,
    cache::Dict{String, Any} = Dict{String, Any}(),
    refresh::Bool = false,
)
    enabled(name::Symbol) = !(name in settings.disabled)
    findings = Finding[]
    enabled(:duplicate_key) && append!(findings, check_duplicate_key(entries))
    enabled(:duplicate_entry) && append!(findings, check_duplicate_entry(entries))
    enabled(:missing_field) && append!(findings, check_missing_field(entries))
    enabled(:doi_prefix) && append!(findings, check_doi_prefix(entries))
    enabled(:doi_syntax) && append!(findings, check_doi_syntax(entries))
    enabled(:doi_missing) && append!(findings, check_doi_missing(entries))
    enabled(:journal_spelling) && append!(findings, check_journal_spelling(entries))
    enabled(:non_ascii) && append!(findings, check_non_ascii(entries))
    enabled(:unescaped) && append!(findings, check_unescaped(entries))
    enabled(:title_case) && append!(findings, check_title_case(entries))
    enabled(:pages_dash) && append!(findings, check_pages_dash(entries))
    enabled(:year) && append!(findings, check_year(entries))
    enabled(:duplicate_field) && append!(findings, check_duplicate_field(duplicates))
    enabled(:uncited) && append!(findings, check_uncited(entries, tex_sources))
    enabled(:undefined_citation) &&
        append!(findings, check_undefined_citation(entries, tex_sources))
    if online
        contact_email = settings.contact_email
        request =
            fetch === default_fetch ?
            ((method, url) -> default_fetch(method, url; contact_email)) : fetch
        enabled(:doi_unresolved) && append!(
            findings,
            check_doi_unresolved(entries, settings; fetch = request, pause, cache, refresh),
        )
        enabled(:arxiv_published) && append!(
            findings,
            check_arxiv_published(
                entries,
                settings;
                fetch = request,
                pause,
                cache,
                refresh,
            ),
        )
    end
    return findings
end

# --- output -----------------------------------------------------------------------------

# the entry a finding belongs to: the last entry with its key that starts at or before
# its line, so that entries sharing a key keep their own findings
function owner_index(entries::Vector{BibEntry}, finding::Finding)
    owner = nothing
    for (i, entry) in enumerate(entries)
        entry.key == finding.key || continue
        (owner === nothing || entry.line <= finding.line) && (owner = i)
    end
    return owner
end

finding_order(f::Finding) = (f.line, string(f.check))

function print_findings(io::IO, findings::Vector{Finding})
    for f in sort(findings; by = finding_order)
        println(
            io,
            @sprintf("  %-8s %s: %s", string(f.severity), string(f.check), f.detail)
        )
    end
    return nothing
end

"""
    print_report(io::IO, findings, entries; online::Bool)

The file-level findings, then every entry with findings in file order under a
`key (line N)` header, one line per finding sorted by line and check; then the summary
counts and whether the online checks ran.
"""
function print_report(
    io::IO,
    findings::Vector{Finding},
    entries::Vector{BibEntry};
    online::Bool,
)
    general = Finding[]
    owned = [Finding[] for _ in entries]
    for f in findings
        owner = isempty(f.key) ? nothing : owner_index(entries, f)
        owner === nothing ? push!(general, f) : push!(owned[owner], f)
    end
    if !isempty(general)
        println(io, "File")
        print_findings(io, general)
    end
    for (i, entry) in enumerate(entries)
        isempty(owned[i]) && continue
        println(io, entry.key, " (line ", entry.line, ")")
        print_findings(io, owned[i])
    end
    errors = count(f -> f.severity == :error, findings)
    warnings = count(f -> f.severity == :warning, findings)
    notes = count(f -> f.severity == :info, findings)
    isempty(findings) || println(io)
    println(
        io,
        "$(counted(length(entries), "entry", "entries")): $(counted(errors, "error")), $(counted(warnings, "warning")), $(counted(notes, "note"))",
    )
    println(io, online ? "online checks: ran" : "online checks: skipped (pass --online)")
    return nothing
end

function csv_cell(value::AbstractString)
    occursin(r"[\",\n\r]", value) || return String(value)
    return "\"" * replace(value, "\"" => "\"\"") * "\""
end

"""
    write_csv(path, findings) -> path

The findings as CSV with the columns `key,line,severity,check,detail`; cells holding a
comma, a quote or a newline are quoted. The parent directory is created.
"""
function write_csv(path::AbstractString, findings::Vector{Finding})
    directory = dirname(path)
    isempty(directory) || mkpath(directory)
    open(path, "w") do io
        println(io, "key,line,severity,check,detail")
        for f in findings
            println(
                io,
                join(
                    (csv_cell(f.key), f.line, f.severity, f.check, csv_cell(f.detail)),
                    ",",
                ),
            )
        end
    end
    return path
end

# whether raw is a single braced or quoted group
function single_group(raw::AbstractString)
    src = BibSource(raw)
    n = byte_count(src)
    n >= 2 || return false
    b = byte_at(src, 1)
    b == UInt8('{') && return closing_brace(src, 1) == n
    b == UInt8('"') && return closing_quote(src, 1) == n
    return false
end

# the corrected raw text of a field, or nothing when the field is not corrected
function corrected_value(name::AbstractString, raw::AbstractString)
    if name == "doi"
        single_group(raw) || return nothing
        inner = raw[2:prevind(raw, lastindex(raw))]
        bare = bare_doi(inner)
        bare == strip(inner) && return nothing
        return raw[1:1] * bare * raw[end:end]
    elseif name == "pages"
        return replace(raw, PAGE_DASH => s"\1--")
    end
    return nothing
end

"""
    write_corrected(source, entries, path; input) -> Int

Write to `path` a copy of `source` in which prefixed DOIs are reduced to the bare DOI,
the delimiters kept, and page ranges joined by a hyphen, an en dash or an em dash are
joined by `--`. The edits go through the field spans, applied from the end of the text
backwards; nothing else changes. Refuses with an `ArgumentError` when `path` is the
`input` file. Returns the number of replacements.
"""
function write_corrected(
    source::AbstractString,
    entries::Vector{BibEntry},
    path::AbstractString;
    input::AbstractString,
)
    normpath(abspath(path)) == normpath(abspath(input)) &&
        throw(ArgumentError("the corrected copy must not overwrite the input"))
    text = String(source)
    edits = Pair{UnitRange{Int}, String}[]
    for entry in entries, f in entry.fields
        raw = String(view(codeunits(text), f.span))
        corrected = corrected_value(f.name, raw)
        (corrected === nothing || corrected == raw) && continue
        push!(edits, f.span => corrected)
    end
    sort!(edits; by = e -> first(first(e)), rev = true)
    for (span, replacement) in edits
        bytes = codeunits(text)
        text = String(
            vcat(
                bytes[1:(first(span) - 1)],
                codeunits(replacement),
                bytes[(last(span) + 1):end],
            ),
        )
    end
    write(path, text)
    return length(edits)
end

"""
    safe_filepath(path) -> String

`path` when no file exists there, otherwise the first free `stem#k.ext`.
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
    tex_files(path) -> Vector{String}

`path` when it is a file, else the `.tex` files below the directory `path`, sorted.
"""
function tex_files(path::AbstractString)
    isfile(path) && return [String(path)]
    isdir(path) || throw(ArgumentError("LaTeX source not found: $path"))
    files = String[]
    for (root, _, names) in walkdir(path)
        for name in sort(names)
            lowercase(splitext(name)[2]) == ".tex" && push!(files, joinpath(root, name))
        end
    end
    return files
end

function usage(io::IO = stdout)
    print(
        io,
        """
        bib-hygiene — validation of a BibTeX file before submission

        Usage:
          julia run.jl bib-hygiene BIB [options]

          BIB                 BibTeX file to check; it is never written
          --tex PATH          LaTeX file, or directory searched recursively for .tex files;
                              repeatable; enables the uncited and undefined_citation checks
          --online            resolve DOIs at doi.org and look up preprints in the arXiv API
          --refresh           ignore the lookup cache ([network].cache_file)
          --strict            fail on warnings as well as on errors
          --fixed FILE        write a corrected copy to FILE (bare DOIs, "--" in page ranges)
          --csv FILE          write the findings to FILE
          --config PATH       configuration file (default: config.toml next to the tool)
          -h, --help

        Exit status: 0 when the file passes, 1 on errors (or warnings with --strict),
        2 on invalid arguments, configuration or input.

        Checks: $(join(CHECKS, ", ")).
        """,
    )
    return nothing
end

"""
    main(args = ARGS; io = stdout, fetch = default_fetch, pause = sleep)
        -> Union{NamedTuple, Nothing}

Parse the command line, parse the BibTeX file, run the checks, print the report to `io`
and write the corrected copy, the CSV and the lookup cache when asked. Returns
`(; findings, entries, failed, fixed, csv)`, where `failed` is set by any error, or any
warning under `--strict`, and `fixed` and `csv` are the paths written or `nothing`;
returns `nothing` after `--help`.
"""
function main(
    args::Vector{String} = ARGS;
    io::IO = stdout,
    fetch = default_fetch,
    pause = sleep,
)
    config_path = joinpath(@__DIR__, "config.toml")
    bib = nothing
    tex_paths = String[]
    online = false
    refresh = false
    strict = false
    fixed = nothing
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
        elseif argument == "--tex"
            push!(tex_paths, value_of(argument))
        elseif argument == "--online"
            online = true
        elseif argument == "--refresh"
            refresh = true
        elseif argument == "--strict"
            strict = true
        elseif argument == "--fixed"
            fixed = value_of(argument)
        elseif argument == "--csv"
            csv = value_of(argument)
        elseif argument == "--config"
            config_path = value_of(argument)
        elseif startswith(argument, "-")
            throw(ArgumentError("unknown command-line argument '$argument'; see --help"))
        elseif bib === nothing
            bib = argument
        else
            throw(ArgumentError("one BibTeX file expected, got '$bib' and '$argument'"))
        end
        i += 1
    end
    bib === nothing && throw(ArgumentError("no BibTeX file given; see --help"))
    settings = load_settings(config_path)
    isfile(bib) || throw(ArgumentError("BibTeX file not found: $bib"))
    (fixed !== nothing && normpath(abspath(fixed)) == normpath(abspath(bib))) &&
        throw(ArgumentError("the corrected copy must not overwrite the input"))
    source = read(bib, String)
    entries, strings, duplicates = try
        parse_bibtex(source)
    catch err
        err isa BibParseError || rethrow()
        throw(ArgumentError("parse error in $bib, line $(err.line): $(err.message)"))
    end
    tex_sources = Pair{String, String}[]
    for path in tex_paths, file in tex_files(path)
        push!(tex_sources, file => read(file, String))
    end
    cache_path =
        isabspath(settings.cache_file) ? settings.cache_file :
        normpath(joinpath(@__DIR__, settings.cache_file))
    cache = online ? load_cache(cache_path) : Dict{String, Any}()
    findings = run_checks(
        entries,
        strings,
        duplicates;
        tex_sources,
        settings,
        online,
        fetch,
        pause,
        cache,
        refresh,
    )
    print_report(io, findings, entries; online)
    fixed_path = nothing
    if fixed !== nothing
        target = safe_filepath(abspath(fixed))
        mkpath(dirname(target))
        n = write_corrected(source, entries, target; input = bib)
        fixed_path = target
        println(io)
        println(
            io,
            "Corrected copy written to ",
            target,
            " (",
            counted(n, "replacement"),
            ")",
        )
    end
    csv_path = nothing
    if csv !== nothing
        csv_path = write_csv(safe_filepath(abspath(csv)), findings)
        println(io)
        println(io, "CSV written to ", csv_path)
    end
    online && save_cache(cache_path, cache)
    failed =
        any(f -> f.severity == :error, findings) ||
        (strict && any(f -> f.severity == :warning, findings))
    return (; findings, entries, failed, fixed = fixed_path, csv = csv_path)
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = try
        main(ARGS)
    catch err
        err isa ArgumentError || rethrow()
        println(stderr, "bib-hygiene: ", err.msg)
        exit(2)
    end
    (result !== nothing && result.failed) && exit(1)
end
