# API

```@meta
CurrentModule = EDGAR
```

The complete reference for the exported functions, grouped by topic. CIKs are the
SEC **Central Index Key**, zero-padded to 10 digits (Apple → `0000320193`). Any
`cik` argument accepts an integer or a string, with or without leading zeros
(`320193`, `"320193"` and `"0000320193"` are equivalent); functions normalize to
the 10-digit form, and the `cik` column returned by [`cik`](@ref) always holds the
padded string.

## Filings

Fetch a filing's document, turn it into text, extract sections, and save it. (To
*list* a filer's filings, see [`filings_by_cik`](@ref) under Filings search.)

```@docs
fetch_filing
Filing
save_filing
open_filing
download_assets
extract_section
```

## Interactive extraction and export

Pick a region from a rendered filing in the browser and get it back as a `Selection`,
then export it across the four layers: the lossless iXBRL fragment, Markdown, a portable
**Facts JSON** document, or a DuckDB fact warehouse. For whole filings, `facts(::Filing)`
extracts every XBRL fact natively (no browser), and `archive_filings` bulk-loads a filer's
filings into the warehouse. Each fact also carries a `standard_concept` from `standardize`,
for cross-company comparison. `to_duckdb`, `statement_view` and `archive_filings` are
provided by a package extension, available after `using DuckDB`.

```@docs
select_section
select_sections
Selection
Fact
markdown
facts
facts_json
read_facts_json
standardize
set_standardizer
edgartools_mapping
statement_map
label_map
calculations
save_selection
to_duckdb
statement_view
archive_filings
```

## Financial data

XBRL facts from the `data.sec.gov` structured-data endpoints.

```@docs
company_facts
company_concept
xbrl_frames
```

## Filings search

Search the contents of filings (2001 onward), or list a single filer's filings,
via the EDGAR full-text search API — both return Tables.jl row tables.
`full_text_search` is also exported as `filings_by_text`, to pair with `filings_by_cik`.
`profile` returns a filer's row-invariant data (name, type, SIC, fiscal year-end, …).

```@docs
full_text_search
filings_by_cik
profile
```

## Company lookup

Resolve a CIK from a ticker symbol, or search for companies by name.

```@docs
cik
```

## Configuration and caching

Responses are cached so that an interactive session does not repeatedly hammer
the SEC, which asks for fair use (no more than 10 requests per second). Some
responses are both large and fetched again and again — for example:

- the ~1 MB `company_tickers.json`, which [`cik`](@ref) downloads on every
  lookup, and
- [`company_facts`](@ref), which can return several megabytes for a single company.

Caching keeps these from being downloaded more than once.

How the cache is stored and expired — the `:temporary` / `:persistent` / `:off`
modes, and the freshness and retention limits — is configured entirely through
[`set_config`](@ref), documented in full below.

```@docs
set_user_agent
get_user_agent
persist_user_agent
unpersist_user_agent
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
