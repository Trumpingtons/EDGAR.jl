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

Responses are cached so an interactive session does not hammer the SEC. The SEC
asks for fair use (no more than 10 requests per second), and a few endpoints
return large payloads that get hit repeatedly: `company_tickers.json` is ~1 MB
and [`cik_for_ticker`](@ref) consults it on every lookup, and
[`company_facts`](@ref) can be several MB. Caching these avoids re-downloading
them.

The cache is controlled entirely through [`set_config`](@ref):

- `cache = :temporary` (default) — an ephemeral per-process temporary directory,
  deleted when Julia exits, so nothing persists or accumulates.
- `cache = :persistent` — kept in `~/.cache/EDGAR.jl` across sessions; files
  older than `cache_max_age` (default 7 days) are pruned automatically.
- `cache = :off` — no caching; every call re-fetches.

Two **independent** time limits apply: `cache_ttl` (default 24 h) is *freshness* —
how long a cached response is reused before being re-fetched — while
`cache_max_age` governs how long a file lives on disk in persistent storage. Use
[`clean_cache`](@ref) to prune on demand and [`cache_metrics`](@ref) to inspect
hit/miss counts.

```@docs
set_config
fetch_url
clean_cache
cache_metrics
cache_path_for
```

## Command-line entry point

```@docs
main
```
