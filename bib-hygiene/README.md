# bib-hygiene

Validation of a BibTeX file before submission: duplicate keys and entries, required
fields, DOI and arXiv identifiers, journal names written in several ways, encoding and
escaping, capitals that a style would lowercase, page ranges, years, and the citations of
the manuscript against the entries. The tool works offline by default; the network is
used only with `--online`, and then every lookup is rate-limited and cached on disk. The
input file is never rewritten: the mechanical corrections go to a separate copy.

```
bib-hygiene/
├── activate.jl                  # environment activation
├── bib-hygiene.jl               # entry point, parser and checks
├── config.toml                  # disabled checks and network settings, validated on load
├── Project.toml
├── README.md
└── test/
    └── runtests.jl              # parser, settings, every check, stub fetcher, corrected copy, CLI
```

## Usage

```bash
julia run.jl bib-hygiene paper/references.bib
julia run.jl bib-hygiene paper/references.bib --tex paper/                # citations of every .tex below paper/
julia run.jl bib-hygiene paper/references.bib --tex paper/main.tex --online
julia run.jl bib-hygiene paper/references.bib --fixed paper/references_fixed.bib
julia run.jl bib-hygiene paper/references.bib --strict --csv /tmp/bib_findings.csv
```

The report lists the findings about the file as a whole first, then every entry with
findings under a `key (line N)` header, and ends with the counts and whether the online
checks ran. `--tex` takes a LaTeX file or a directory searched recursively for `.tex`
files, and may be repeated; without it the two citation checks are skipped. `--csv FILE`
writes the findings as a table (`key,line,severity,check,detail`) and `--fixed FILE` the
corrected copy; neither overwrites an existing file (`#1`, `#2`, ... suffixes), and
`--fixed` refuses the input path itself.

The exit status is 0 when the file passes, 1 when there is an error (or, with `--strict`,
a warning), and 2 for invalid arguments, an invalid configuration or a file that does not
parse. A manuscript build can therefore run `bib-hygiene --tex . --strict` as a gate and
stop on a non-zero status.

## Checks

| Check | Severity | What it flags |
| :--- | :--- | :--- |
| `duplicate_key` | error | a key already used by an earlier entry, compared case-insensitively |
| `duplicate_entry` | warning | two entries with the same DOI or the same normalized title (letters and digits, at least 20 characters) |
| `missing_field` | error | a field required by the standard BibTeX entry type (`author or editor` where either suffices) |
| `doi_prefix` | warning | a DOI written as a URL or with `doi:` |
| `doi_syntax` | error | a DOI that does not have the form `10.NNNN/suffix` |
| `doi_missing` | warning | an article, inproceedings or incollection with neither a DOI nor an arXiv identifier |
| `journal_spelling` | warning | one journal written in several ways, such as `Phys. Rev. D` and `Physical Review D` |
| `non_ascii` | warning | characters above U+007F outside `url`, `doi`, `file` and `eprint` |
| `unescaped` | warning | `&`, `%`, `#` or `_` without a backslash, outside `\url{}`, math and the identifier fields |
| `title_case` | warning | capitals in `title`, after the first word, not protected by braces (styles lower the case of the title, not of the booktitle) |
| `pages_dash` | warning | a page range joined by `-`, an en dash or an em dash instead of `--` |
| `year` | error, warning | a year that is neither an integer nor `in press`, `forthcoming` or `submitted` (error); an integer outside [1500, next year] (warning) |
| `duplicate_field` | warning | a field repeated within an entry; the first value is the one kept |
| `uncited` | warning | an entry that no LaTeX source cites (none when a source has `\nocite{*}`) |
| `undefined_citation` | error | a cited key that matches no entry |
| `doi_unresolved` | error | with `--online`: a DOI for which doi.org answers 404 or 410 |
| `arxiv_published` | warning | with `--online`: a preprint for which arXiv records a DOI or a journal reference |

Two journal names are taken as the same journal when, after removing braces and
punctuation and dropping short function words, they have the same number of words and
each word is a prefix of the other at its position. The citation scan recognises every
`\...cite...` command with optional arguments and starred forms (`\cite`, `\citep`,
`\textcite`, `\autocite*`, `\nocite`, ...) and ignores commented lines.

The arXiv identifier of an entry comes from `eprint` (with `archiveprefix` or
`eprinttype` set to `arXiv`, or in identifier form), from a DOI `10.48550/arXiv.<id>`, or
from an `arxiv.org/abs/<id>` or `arXiv:<id>` in `journal`, `note`, `url` or
`howpublished`. An entry with an arXiv identifier and no other DOI counts as a preprint.

## Online checks

With `--online`, every valid DOI is requested with `HEAD https://doi.org/<doi>` without
following the redirect: a 3xx answer means the DOI is registered, 404 or 410 that it is
not, and any other status or a network failure gives a `doi_unchecked` warning. The
preprints are looked up in the arXiv API (`export.arxiv.org/api/query`), up to
`arxiv_batch` identifiers per request; the fields `arxiv:doi` and `arxiv:journal_ref` of
the answer indicate a published version. A failed request or an identifier missing from
the answer gives an `arxiv_unchecked` warning.

Requests are spaced by `doi_delay_s` (doi.org) and `arxiv_delay_s` (arXiv, whose API
terms ask for three seconds). Settled outcomes are kept in the TOML file `cache_file`
and reused for `cache_ttl_days` days; failures are not cached, and `--refresh` ignores
the cache. When `contact_email` is set, it travels in the User-Agent header as
`mailto:`, the polite form that Crossref asks of automated clients.

## Corrected copy

`--fixed FILE` writes a copy of the input in which two mechanical corrections are made: a
prefixed DOI is reduced to the bare DOI inside its original delimiters, and a page range
joined by a hyphen, an en dash or an em dash is joined by `--`. Every other byte of the
file is left as it was. All other findings call for a decision by the author and are only
reported.

## Configuration

`config.toml` holds the list of disabled checks (`[checks]`) and the network settings
(`[network]`: contact e-mail, cache file and its lifetime, delays, arXiv batch size). A
relative `cache_file` resolves against the tool directory. Absent keys take the shipped
defaults; unknown keys, unknown check names and out-of-range values are rejected with a
message naming the key.

## Tests

```bash
julia test.jl bib-hygiene
```

The suite parses a fixture held in `test/runtests.jl` that carries the defects the
offline checks look for, together with `@string`, `@comment` and `@preamble` blocks, a parenthesised entry, a
concatenated value and a repeated field. It checks the parser, the settings validation,
every check in isolation with the keys it must flag, the citation scan of a LaTeX
fixture, the online checks and the cache through a stub fetcher, the corrected copy and
the command line. No test touches the network.
