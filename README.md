# EDGAR.jl

[![CI](https://github.com/Trumpingtons/EDGAR.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/Trumpingtons/EDGAR.jl/actions/workflows/ci.yml)
[![Docs](https://img.shields.io/badge/docs-online-blue.svg)](https://trumpingtons.github.io/EDGAR.jl/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

`Edgar.jl` is a Julia package for pulling company data from the U.S. SEC
[EDGAR](https://www.sec.gov/search-filings/edgar-application-programming-interfaces)
system:

- **Filings** — list a filer's submissions, download filings, convert them to
  text, and extract sections such as *Item 7 — Management's Discussion*.
- **XBRL financial data** — a filer's full set of reported facts
  (`company_facts`), one concept over time (`company_concept`), or one concept
  across every filer for a period (`xbrl_frames`).
- **Full-text search** — search the contents of filings since 2001
  (`full_text_search`).
- **Ticker lookup** — resolve a ticker symbol to its CIK (`cik_for_ticker`).

It talks to the public `data.sec.gov` / `efts.sec.gov` / `sec.gov` endpoints with
`HTTP.jl` + `JSON3.jl`, uses `Gumbo.jl` + `Cascadia.jl` for robust HTML parsing,
and caches responses on disk.

## Installation

`EDGAR.jl` requires **Julia 1.12 or later**. It is not yet registered, so install it
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

### Financial data & search

```julia
using EDGAR

# Resolve a ticker to a CIK
cik = cik_for_ticker("AAPL")                       # "0000320193"

# All XBRL facts a company has reported
facts = company_facts(cik)

# One concept over time (net income, in USD)
ni = company_concept(cik, "us-gaap", "NetIncomeLoss")
println(ni.units.USD[end].val)

# The same concept across every filer for one period
assets = xbrl_frames("us-gaap", "Assets", "USD", "CY2022Q4I")
println(length(assets.data), " filers reported Assets")

# Full-text search the contents of filings
hits = full_text_search("climate risk"; forms = "10-K")
println(hits.hits.total.value, " matching filings")
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
| `company_facts(cik)` | Every XBRL fact a filer has reported |
| `company_concept(cik, taxonomy, tag)` | One XBRL concept over time for a filer |
| `xbrl_frames(taxonomy, tag, unit, period)` | One concept across all filers for a period |
| `full_text_search(query; forms, startdate, enddate)` | Search filing contents (2001+) |
| `cik_for_ticker(ticker)` / `company_tickers()` | Resolve a ticker to a CIK |
| `fetch_url(url; use_cache)` | Cached HTTP GET with the SEC User-Agent |
| `set_config(; …)` | Override the cache dir/TTL, host whitelist, user agent, … |
| `cache_metrics()` / `clean_cache()` | Inspect / prune the on-disk cache |

CIKs are the SEC **Central Index Key**, zero-padded to 10 digits (Apple → `0000320193`).
Please stay under the SEC fair-access limit of **10 requests per second**.

## Documentation

Full documentation: **https://trumpingtons.github.io/EDGAR.jl/**

## License

[MIT](LICENSE) © Antonio Saragga Seabra
