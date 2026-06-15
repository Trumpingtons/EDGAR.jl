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
and caches responses (ephemeral by default — see [Caching](#caching)).

## Installation

`EDGAR.jl` requires **Julia 1.12 or later**. It is not yet registered, so install it
straight from GitHub:

```julia
using Pkg
Pkg.add(url = "https://github.com/Trumpingtons/EDGAR.jl")
```

## ⚠️ Set a User-Agent first

> The SEC requires a **descriptive `User-Agent` with contact information**. Requests
> without one are rejected (HTTP 403). Set yours once per session with your name and
> a contact email:
>
> ```julia
> using EDGAR
> set_user_agent("Jane Doe jane@example.com")
> ```
>
> EDGAR.jl will otherwise stop with a clear error before contacting the SEC.

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

# 3. Read the filing's HTML (the extraction functions operate on HTML)
html = parse_filing(path)

# 4. Extract specific sections (heuristic, case-insensitive)
sections = extract_section(html, ["Item 7", "Management's Discussion"])
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

## Glossary

SEC filings and their structured (XBRL) data come with their own vocabulary. The
terms that matter here:

- **CIK** — *Central Index Key*, the SEC's unique ID for a filer, zero-padded to
  10 digits (Apple → `0000320193`). Get one from a ticker with `cik_for_ticker`.
- **Filing** — a document submitted to the SEC, identified by an **accession
  number** and a **form type** (`10-K` annual report, `10-Q` quarterly, `8-K`
  current report, …). List a filer's filings with `list_recent_filings`.
- **XBRL** — *eXtensible Business Reporting Language*, the machine-readable format
  companies tag their financial statements in; it is what makes the numbers
  queryable rather than locked inside a document.
- **iXBRL** — *Inline XBRL*: those same tags embedded directly inside the filing's
  human-readable HTML, so one document is both readable and machine-parseable. The
  SEC has required it for financial statements since around 2019.
- **Fact** — a single reported number: one *concept*, for one *period*, in one
  *unit* (e.g. "net income for FY2023 was 96,995,000,000 USD"). `company_facts`
  returns every fact a company has reported.
- **Concept** — the *name* of a reported line item, drawn from a taxonomy (e.g.
  `NetIncomeLoss`, `Assets`, `Revenues`) — the "what is being measured".
  `company_concept` returns one concept over time for one filer.
- **Taxonomy** — a dictionary that defines concepts. The big one is **`us-gaap`**
  (US accounting standards); **`dei`** (*Document and Entity Information*) holds
  metadata about the filing itself — entity name, fiscal year-end, document type,
  shares outstanding. Others you may meet: **`srt`** (shared, common elements),
  **`ifrs-full`** (filers reporting under IFRS), and each company's own
  **extension** namespace (e.g. `aapl` for Apple-specific concepts).
- **Frame** — a cross-section: one concept, one unit, one period, across *every*
  filer that reported it (e.g. Assets in USD at the end of Q4 2022, for all
  companies). `xbrl_frames` returns a frame.
- **Unit** — the unit of measure of a fact: `USD`, `shares`, `USD/shares`
  (per-share), `pure` (a ratio), …
- **Period** — the time a fact covers, and how it is written. **Frames** use
  *calendar* periods: `CY` + year, as in `CY2022` (a full calendar year),
  `CY2022Q4` (a quarter), or `CY2022Q4I` (a single instant — note the trailing
  `I`). An **instant** is a point in time (balance-sheet items such as Assets, at
  quarter-end); a **duration** is a span (income-statement items such as Revenue).
  By contrast, **`FY`** in a company's own facts is its *fiscal* year, which need
  not match the calendar (Apple's `FY2023` ended in September 2023).

> [!NOTE]
> **Concept vs Fact** — a concept is the *label* (`Assets`); a fact is a concrete
> *value* of that concept for a given period and unit. **The `I` suffix** — in
> Frames a trailing `I` means an *instant*, which is why
> `xbrl_frames("us-gaap", "Assets", "USD", "CY2022Q4I")` needs it: a balance is
> measured at a moment, whereas a flow like revenue uses a plain duration code.

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
| `fetch_url(url; use_cache)` | Cached HTTP GET with the SEC User-Agent (for endpoints not wrapped above) |
| `set_config(; user_agent, …)` | Set the User-Agent, cache dir/TTL, host whitelist, … |
| `cache_metrics()` / `clean_cache()` | Inspect / prune the on-disk cache |

CIKs are the SEC **Central Index Key**, zero-padded to 10 digits (Apple → `0000320193`).
Please stay under the SEC fair-access limit of **10 requests per second**.

## Caching

Responses are cached to avoid re-hitting the SEC. The mode is set with
`set_config(cache = …)`:

| Mode | Behaviour | Location |
|---|---|---|
| `:temporary` *(default)* | Ephemeral — wiped when the Julia process exits | A per-process temp directory |
| `:persistent` | Survives across sessions; old files auto-pruned (see below) | `~/.cache/EDGAR.jl` |
| `:off` | No caching; every call re-fetches | — |

```julia
set_config(cache = :persistent)        # keep the cache across sessions
set_config(cache_dir = "/data/edgar")  # or pin a specific directory
```

In persistent storage, files older than `cache_max_age` (default **7 days**) are
deleted automatically, so the cache stays bounded. This is **separate from**
`cache_ttl` (freshness, default **24 h**): `cache_ttl` controls when a response is
re-fetched, `cache_max_age` controls when a file is removed from disk.

```julia
set_config(cache_ttl = 3600, cache_max_age = 30*24*3600)  # re-fetch hourly, keep files a month
```

`clean_cache()` also prunes on demand, and `cache_metrics()` reports hit/miss counts.

## Documentation

Full documentation: **https://trumpingtons.github.io/EDGAR.jl/**

## License

[MIT](LICENSE) © Antonio Saragga Seabra
