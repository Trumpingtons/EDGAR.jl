# EDGAR.jl

[![CI](https://github.com/Trumpingtons/EDGAR.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/Trumpingtons/EDGAR.jl/actions/workflows/ci.yml)
[![Docs](https://img.shields.io/badge/docs-online-blue.svg)](https://trumpingtons.github.io/EDGAR.jl/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

A small Julia package for pulling company filings from the U.S. SEC
[EDGAR](https://www.sec.gov/search-filings/edgar-application-programming-interfaces)
system: list a filer's submissions, download filings, convert them to text, and
extract sections such as *Item 7 — Management's Discussion*. It talks to the public
`data.sec.gov` / `sec.gov` endpoints with `HTTP.jl` + `JSON3.jl`, and uses
`Gumbo.jl` + `Cascadia.jl` for robust HTML parsing.

## Installation

EDGAR.jl requires **Julia 1.12 or later**. It is not yet registered, so install it
straight from GitHub:

```julia
using Pkg
Pkg.add(url = "https://github.com/Trumpingtons/EDGAR.jl")
```

## ⚠️ Set a User-Agent first

> The SEC requires a **descriptive `User-Agent` with contact information**. Requests
> without one are rejected (HTTP 403). Open `src/EDGAR.jl` and update the
> `USER_AGENT` constant to include your name and a contact email, for example
> `"Jane Doe jane@example.com"`.

## Quick start

```julia
using EDGAR

# 1. List a company's recent filings by CIK (Apple = 320193, zero-padded to 10 digits)
filings = list_recent_filings("0000320193"; count = 5)
for f in filings
    println(f.date, "  ", f.form, "  ", f.accession)
end

# 2. Download the most recent filing's documents into a directory
latest = first(filings)
path = download_filing("0000320193", latest.accession; destdir = "filings")

# 3. Convert the filing's HTML to plain text
text = parse_filing(path)

# 4. Extract specific sections (case-insensitive; heuristic match)
sections = extract_section(text, ["Item 7", "Management's Discussion"])
println(get(sections, "Item 7", "(not found)"))
```

## API

| Function | Purpose |
|---|---|
| `list_recent_filings(cik; count)` | Recent filings as `(accession, form, date)` rows |
| `fetch_submissions(cik)` | Full submissions JSON for a filer |
| `download_filing(cik, accession; destdir)` | Download a filing's documents |
| `parse_filing(path)` | Convert a filing's HTML to text (Gumbo + Cascadia) |
| `extract_section(text, names)` | Pull named sections (e.g. `"Item 7"`) from filing text |
| `save_filing(text, metadata; outdir)` | Write extracted text + metadata to disk |
| `fetch_url(url; use_cache)` | Cached HTTP GET with the SEC User-Agent |
| `set_config(; …)` | Override the cache dir/TTL, host whitelist, user agent, … |
| `cache_metrics()` / `clean_cache()` | Inspect / prune the on-disk cache |

CIKs are the SEC **Central Index Key**, zero-padded to 10 digits (Apple → `0000320193`).
Please stay under the SEC fair-access limit of **10 requests per second**.

## Documentation

Full documentation: **https://trumpingtons.github.io/EDGAR.jl/**

## License

[MIT](LICENSE) © Antonio Saragga Seabra
