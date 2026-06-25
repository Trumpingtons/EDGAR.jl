# SEC structured-data APIs (data.sec.gov / efts.sec.gov) and CIK/ticker lookup. SEC-specific.

# Internal: normalize a CIK given as an integer or a string (with or without
# leading zeros) to the SEC's canonical 10-digit, zero-padded string form,
# e.g. 320193, "320193" and "0000320193" all become "0000320193". Throws on
# empty, non-numeric, or over-long input.
function _normalize_cik(cik::Union{Integer,AbstractString})
    s = cik isa Integer ? string(cik) : strip(cik)
    isempty(s) && throw(ArgumentError("CIK must not be empty"))
    all(isdigit, s) || throw(ArgumentError("CIK must contain only digits, got $(repr(cik))"))
    length(s) > 10 && throw(ArgumentError("CIK has more than 10 digits: $(repr(cik))"))
    return lpad(s, 10, '0')
end

# Internal: fetch a filer's submissions document from `data.sec.gov/submissions/`
# (company profile + recent filings index under `.filings.recent`). Used by
# `filings_by_cik` to enrich EFTS hits with submissions-only fields.
function _fetch_submissions(cik::Union{Integer,AbstractString})
    return _get_json("https://data.sec.gov/submissions/CIK$(_normalize_cik(cik)).json")
end

# ── XBRL financial data, full-text search, and ticker lookup ─────────────────
#
# These call the public data.sec.gov / efts.sec.gov / sec.gov JSON endpoints
# through `fetch_url`, so they share the on-disk cache and the configured
# User-Agent. Each returns the parsed JSON (a `JSON3.Object`/`JSON3.Array`).

"""
    company_facts(cik) -> JSON3.Object

Every XBRL fact a company has ever reported, in a single document, from the
`/api/xbrl/companyfacts/` endpoint. `cik` may be an integer or a string, with or
without leading zeros; it is normalized to the 10-digit form.

```julia
facts = company_facts("320193")
keys(facts.facts)              # taxonomies, e.g. :dei and Symbol("us-gaap")
```
"""
function company_facts(cik::Union{Integer,AbstractString})
    c = _normalize_cik(cik)
    return _get_json("https://data.sec.gov/api/xbrl/companyfacts/CIK$(c).json")
end

"""
    company_concept(cik, taxonomy, tag) -> JSON3.Object

One XBRL concept over time for a single filer, from `/api/xbrl/companyconcept/`.

```julia
ni = company_concept("320193", "us-gaap", "NetIncomeLoss")
ni.units.USD[end].val
```
"""
function company_concept(cik::Union{Integer,AbstractString}, taxonomy::AbstractString, tag::AbstractString)
    c = _normalize_cik(cik)
    return _get_json("https://data.sec.gov/api/xbrl/companyconcept/CIK$(c)/$(taxonomy)/$(tag).json")
end

"""
    xbrl_frames(taxonomy, tag, unit, period) -> JSON3.Object

One XBRL concept for one period across *every* filer that reported it, from
`/api/xbrl/frames/`. A trailing `I` on the period denotes an instant (point in
time, e.g. `"CY2022Q4I"`); drop it for a duration (e.g. `"CY2022"`).

```julia
fr = xbrl_frames("us-gaap", "Assets", "USD", "CY2022Q4I")
length(fr.data)
```
"""
function xbrl_frames(taxonomy::AbstractString, tag::AbstractString, unit::AbstractString, period::AbstractString)
    return _get_json("https://data.sec.gov/api/xbrl/frames/$(taxonomy)/$(tag)/$(unit)/$(period).json")
end

# Internal: build and run an EDGAR full-text-search (EFTS) query. `q` is the
# already-prepared query string (quoted or not); `ciks` filters by filer. EFTS
# only applies a date filter when BOTH bounds are present, so a lone `startdate`
# or `enddate` is completed with the edge of EDGAR's coverage (2001 onward).
function _efts_search(; q::AbstractString="", ciks=nothing, forms=nothing, startdate=nothing, enddate=nothing, from::Int=0)
    url = "https://efts.sec.gov/LATEST/search-index?q=$(HTTP.escapeuri(q))&from=$(from)"
    ciks !== nothing && (url *= "&ciks=$(_normalize_cik(ciks))")
    if forms !== nothing
        url *= "&forms=$(forms isa AbstractString ? forms : join(forms, ","))"
    end
    if startdate !== nothing || enddate !== nothing
        sd = startdate === nothing ? "2001-01-01" : startdate
        ed = enddate === nothing ? "2099-12-31" : enddate
        url *= "&startdt=$(sd)&enddt=$(ed)"
    end
    return _get_json(url)
end

# Internal: null-safe string ("" for a missing/null JSON value) and the first
# element of a possibly-empty/absent JSON array.
_str(x) = (x === nothing || x === missing) ? "" : String(x)
_head(a) = (a === nothing || isempty(a)) ? nothing : first(a)

# Internal: the entity (filer) name from an EFTS `display_names` entry,
# "NAME (TICKER) (CIK …)" — the trailing ticker and CIK groups are dropped (the
# CIK is its own column; tickers belong to `cik()`).
function _entity_name(dn::AbstractString)
    m = match(r"^(.*?)\s*(?:\(([^()]*)\)\s*)?\(CIK\s+\d+\)\s*$", dn)
    return m === nothing ? String(strip(dn)) : String(strip(something(m.captures[1], "")))
end

# Internal: the columns shared by both search functions, built from one EFTS hit.
# `entity` is the filer's name (a company, fund, ETF, institutional manager, …).
# `document` (the primary filename) is recovered from the hit `_id` ("accession:file").
# Some filings (e.g. fund forms) carry a null `period_ending`, so guard every field.
function _efts_row(h)
    s = h._source
    return (cik        = _str(_head(s.ciks)),
            entity     = _entity_name(_str(_head(s.display_names))),
            form       = _str(s.form),
            reportDate = _str(s.period_ending),
            filed      = _str(s.file_date),
            accession  = _str(s.adsh),
            document   = _str(last(split(h._id, ':'))))
end

"""
    full_text_search(query; exact=true, forms=nothing, startdate=nothing, enddate=nothing, from=0) -> Vector{NamedTuple}
    filings_by_text(query; …)   # alias

Search filing *contents* (2001 onward) for `query` via the EDGAR full-text search
(EFTS) API, returning a Tables.jl *row table* (a `Vector` of `NamedTuple`s) of the
matching filings. Also exported as `filings_by_text`, to pair with
[`filings_by_cik`](@ref) (which looks up a filer's filings by CIK instead).

By default `query` is matched as an **exact phrase** (it is wrapped in quotes for
you), so `supply chain disruption` finds only filings with those three words
adjacent — the same as quoting the phrase in the EDGAR web UI. Pass `exact=false`
to send the query verbatim instead, matching the words loosely and letting you use
EDGAR's own operators (e.g. `word1 word2`).

`forms` may be a single string (`"10-K"`) or a collection; `startdate`/`enddate`
are `"YYYY-MM-DD"` strings (passing only one still filters — the other bound
defaults to the edge of EDGAR's coverage). Results come back ranked by relevance.

Columns: `cik`, `entity` (the filer's name — a company, mutual fund, ETF,
money-market fund, institutional manager, …), `form`, `reportDate` (period
covered), `filed` (filing date), `accession`, `document` (primary filename) and
`score` (relevance). Tickers are a filer attribute — use [`cik`](@ref), joining on
the CIK; richer filer data is in [`profile`](@ref).

EFTS returns a **fixed page of 100** results per request. The total match count is
not returned, so to page, advance `from` in steps of 100 until you get fewer than
100 rows (or an empty page). The submissions-only fields (`acceptanceDateTime`, the
XBRL flags) are **not** included: a text search spans many filers, so adding them
would need a submissions fetch per filer (~100 per page) — see
[`filings_by_cik`](@ref), which enriches a single filer cheaply.

```julia
rows = full_text_search("climate risk"; forms = "10-K", startdate = "2024-01-01")
rows[1].entity         # the top hit's filer
using PrettyTables
pretty_table(rows)     # the page as a table
```
"""
function full_text_search(query::AbstractString; exact::Bool=true, forms=nothing, startdate=nothing, enddate=nothing, from::Int=0)
    # Quote the query for an exact-phrase match unless `exact=false` or it is
    # already quoted.
    q = (exact && !(startswith(query, '"') && endswith(query, '"'))) ? "\"" * query * "\"" : query
    res = _efts_search(; q, forms, startdate, enddate, from)
    return [merge(_efts_row(h), (; score = Float64(h._score))) for h in res.hits.hits]
end

"Alias for [`full_text_search`](@ref); pairs with [`filings_by_cik`](@ref)."
const filings_by_text = full_text_search

"""
    filings_by_cik(cik; forms=nothing, startdate=nothing, enddate=nothing, from=0) -> Vector{NamedTuple}

List a single filer's filings (2001 onward) via the EDGAR full-text search (EFTS)
API, using its **entity filter** rather than a text query, returning a Tables.jl
*row table*. `cik` may be an integer or a string, with or without leading zeros.
This is the EFTS counterpart of the web search's company/CIK field — a true "filed
*by* this filer" query, unlike searching for the CIK as document text (which also
matches filings that merely *mention* it).

Each row is **one filing**: `form`, `reportDate` (period covered), `filed` (filing
date), `acceptanceDateTime` (when the SEC accepted it), `accession`, `document`
(primary filename), and the XBRL flags `isXBRL`, `isInlineXBRL`, `isXBRLNumeric`.
The XBRL flags are joined per-filing on the accession (so a `10-K` is XBRL while a
`Form 4` is not), and are `missing` for any filing outside the submissions recent
window. Filer-level data (name, `entityType`, SIC, fiscal year-end, …) is *not*
repeated on every row — get it from [`profile`](@ref).

Results are newest-first (there is no relevance to rank by). `forms`/dates/`from`
behave as in [`full_text_search`](@ref); the page is 100, and there is no total
count, so page by advancing `from` until you get fewer than 100 rows.

```julia
rows = filings_by_cik(320193; forms = "8-K", startdate = "2026-01-01")
rows[1].form, rows[1].filed, rows[1].isXBRL
```
"""
function filings_by_cik(cik; forms=nothing, startdate=nothing, enddate=nothing, from::Int=0)
    res = _efts_search(; ciks = cik, forms, startdate, enddate, from)
    rec = _fetch_submissions(cik).filings.recent
    # accession -> row index in the submissions recent array, for the per-filing join
    idx = Dict(String(rec.accessionNumber[i]) => i for i in eachindex(rec.accessionNumber))
    mstr(x) = x === nothing ? missing : String(x)
    mflag(x) = x === nothing ? missing : Bool(x)
    # Explicit row type: the enrichment columns are `missing` for any filing outside
    # the submissions recent window, so they must be Union{Missing,…} for all rows.
    RowT = @NamedTuple{form::String, reportDate::String, filed::String,
                       acceptanceDateTime::Union{Missing,String}, accession::String,
                       document::String, isXBRL::Union{Missing,Bool},
                       isInlineXBRL::Union{Missing,Bool}, isXBRLNumeric::Union{Missing,Bool}}
    function row(h)
        e = _efts_row(h)
        i = get(idx, String(h._source.adsh), nothing)
        at(arr) = i === nothing ? nothing : arr[i]   # nothing if the filing isn't in the recent window
        return (form = e.form, reportDate = e.reportDate, filed = e.filed,
                acceptanceDateTime = mstr(at(rec.acceptanceDateTime)),
                accession = e.accession, document = e.document,
                isXBRL = mflag(at(rec.isXBRL)), isInlineXBRL = mflag(at(rec.isInlineXBRL)),
                isXBRLNumeric = mflag(at(rec.isXBRLNumeric)))
    end
    return RowT[row(h) for h in res.hits.hits]
end

"""
    profile(cik) -> NamedTuple

The filer-level profile from the SEC submissions API — the data that is invariant
across a filer's filings, so it lives here rather than being repeated in the
per-filing rows of [`filings_by_cik`](@ref). `cik` may be an integer or a string,
with or without leading zeros.

Fields: `cik`, `name`, `entityType` (`"operating"` for a company, `"investment"`
for a mutual fund / ETF / money-market fund, …), `sic`, `sicDescription`,
`fiscalYearEnd`, `stateOfIncorporation`, `tickers`, `exchanges`, `ein`, `category`,
`website`, `description`, `formerNames`.

```julia
p = profile(320193)
p.name           # "Apple Inc."
p.entityType     # "operating"
p.sic            # "3571"
p.fiscalYearEnd  # "0927"
```
"""
function profile(cik)
    s = _fetch_submissions(cik)
    return (cik                  = _normalize_cik(cik),
            name                 = _str(get(s, :name, nothing)),
            entityType           = _str(get(s, :entityType, nothing)),
            sic                  = _str(get(s, :sic, nothing)),
            sicDescription       = _str(get(s, :sicDescription, nothing)),
            fiscalYearEnd        = _str(get(s, :fiscalYearEnd, nothing)),
            stateOfIncorporation = _str(get(s, :stateOfIncorporation, nothing)),
            tickers              = String[String(x) for x in get(s, :tickers, ())],
            exchanges            = String[String(x) for x in get(s, :exchanges, ())],
            ein                  = _str(get(s, :ein, nothing)),
            category             = _str(get(s, :category, nothing)),
            website              = _str(get(s, :website, nothing)),
            description          = _str(get(s, :description, nothing)),
            formerNames          = String[_str(get(x, :name, nothing)) for x in get(s, :formerNames, ())])
end

_company_tickers_raw() = _get_json("https://www.sec.gov/files/company_tickers.json")

"""
    cik() -> Vector{@NamedTuple{entity::String, ticker::String, cik::String}}
    cik(entity::AbstractString; by::Symbol = :any) -> Vector{…}

Look up ticketed entities (companies and ETFs/funds with a ticker) in the SEC's
`company_tickers.json`, always returned as a Tables.jl *row table* — a `Vector` of
`NamedTuple`s with fields `entity` (name), `ticker` and the 10-digit, zero-padded
`cik`.

- `cik()` returns every entity.
- `cik(entity)` (the default, `by = :any`) returns the rows matching `entity`
  *either* by name (case-insensitive substring) or by an exact ticker — so a short
  string like `"IBM"` finds the ticker and a word like `"apple"` finds the name,
  without you having to say which. Each row is tested once, so a row matching both
  is returned only once.
- `cik(entity; by = :name)` matches the name only (substring).
- `cik(entity; by = :ticker)` matches an exact (case-insensitive) ticker — `0` or
  `1` row; pull the bare CIK with `only(cik("AAPL"; by = :ticker)).cik`.

The result type is the same for every form, so it stays type-stable. A query may
match several rows, since one company can have multiple tickers (e.g. share
classes like `GOOGL`/`GOOG`) and a loose name can match more than one filer.

Because it implements the [Tables.jl](https://github.com/JuliaData/Tables.jl)
interface, any tool that reads tables takes the result directly — `DataFrames`, a
`CSV` file, Arrow, a SQL database — and as a plain `Vector` it indexes and slices
naturally.

```julia
cik()[1:5]                          # first 5 of every company
cik("IBM")                          # by = :any (default) — finds the ticker
cik("alphabet"; by = :name)        # company-name substring
cik("AAPL"; by = :ticker)          # 0 or 1 row

using CSV
CSV.write("tickers.csv", cik())
```
"""
function cik()
    raw = _company_tickers_raw()
    return [(entity = String(v.title), ticker = String(v.ticker), cik = lpad(v.cik_str, 10, '0'))
            for (_, v) in raw]
end

function cik(entity::AbstractString; by::Symbol = :any)
    needle = lowercase(strip(entity))
    t = uppercase(strip(entity))
    if by === :name
        return filter!(r -> occursin(needle, lowercase(r.entity)), cik())
    elseif by === :ticker
        return filter!(r -> uppercase(r.ticker) == t, cik())
    elseif by === :any
        return filter!(r -> occursin(needle, lowercase(r.entity)) || uppercase(r.ticker) == t, cik())
    else
        throw(ArgumentError("`by` must be :name, :ticker or :any, got $(repr(by))"))
    end
end

function _cik_dir(cik)
    return joinpath(pwd(), "data", strip(cik))
end

