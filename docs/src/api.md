# API

```@meta
CurrentModule = EDGAR
```

The complete reference for the exported functions, grouped by topic. CIKs are the
SEC **Central Index Key**, zero-padded to 10 digits (Apple → `0000320193`).

## Filings

List a filer's submissions, download filings, and turn them into text.

```@docs
list_recent_filings
fetch_submissions
download_filing
parse_filing
extract_section
save_filing
```

## Financial data

XBRL facts from the `data.sec.gov` structured-data endpoints.

```@docs
company_facts
company_concept
xbrl_frames
```

## Full-text search

Search the contents of filings (2001 onward) via the EDGAR full-text search API.

```@docs
full_text_search
```

## Company lookup

Resolve ticker symbols to CIK numbers.

```@docs
cik_for_ticker
company_tickers
```

## Configuration and caching

Responses are cached so that an interactive session does not repeatedly hammer
the SEC, which asks for fair use (no more than 10 requests per second). Some
responses are both large and fetched again and again — for example:

- the ~1 MB `company_tickers.json`, which [`cik_for_ticker`](@ref) downloads on
  every lookup, and
- [`company_facts`](@ref), which can return several megabytes for a single company.

Caching keeps these from being downloaded more than once.

How the cache is stored and expired — the `:temporary` / `:persistent` / `:off`
modes, and the freshness and retention limits — is configured entirely through
[`set_config`](@ref), documented in full below.

```@docs
set_config
clean_cache
cache_metrics
cache_path_for
```

## Low-level requests

Most users never need this — the functions above wrap the SEC endpoints you are
likely to want. [`fetch_url`](@ref) is the primitive they are built on, exposed
as an escape hatch for endpoints EDGAR.jl does not yet wrap.

```@docs
fetch_url
```
