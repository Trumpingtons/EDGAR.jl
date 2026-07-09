# ESEF discovery via filings.xbrl.org — the XBRL-International aggregator that indexes ESEF (and
# other regimes) filings with no API key. It is a `FilingSource`, not a system: it yields
# system-tagged `FilingHandle`s (today all `ESEF()`; UKSEF and others are the same report-package
# parse and can be added without a new type). Its JSON:API exposes `/api/filings` with an `entity`
# relationship; a filing's `package_url` is the report-package ZIP that `fetch_filing(::ESEF, url)`
# downloads and reads. Per-country Officially Appointed Mechanisms (OAMs) are other sources that can
# be added later as further `FilingSource`s — the abstraction is here so that stays pluggable.

"""
    FilingsXBRLOrg <: FilingSource

The [filings.xbrl.org](https://filings.xbrl.org) aggregator (XBRL International) — a keyless index of
ESEF and related XBRL-International filings. Use it with [`discover`](@ref) to find a filer's report
packages by LEI, country and/or year. See [`discover(::FilingsXBRLOrg)`](@ref).
"""
struct FilingsXBRLOrg <: FilingSource end

const _FXBRL_BASE = "https://filings.xbrl.org"

# Build the filings.xbrl.org filter querystring (JSON:API): a JSON array of {name, op, val} objects,
# URL-encoded. Each object carries its own operator; `val` is a String (`eq`) or a Vector{String} (`in`).
# `entity.identifier` filters by the filer's LEI, `country` by ISO country, `period_end` by an `in` set of
# dates. Empty ⇒ no `filter` param.
_fxbrl_filter(objs::AbstractVector) = isempty(objs) ? "" :
    "&filter=" * HTTP.URIs.escapeuri(JSON3.write(objs))

# The twelve month-end dates of a calendar year — the plausible set of fiscal year-ends — so a `year` filter
# matches a June/March/January(retail)/… year-end via one `period_end in […]` query, not only 31 December.
# February is leap-aware: only a VALID date is sent (an invalid 29 Feb makes the API 500, not ignore it).
function _year_end_dates(y::Integer)
    feb = ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 29 : 28
    dpm = (31, feb, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
    return [string(y, "-", lpad(m, 2, '0'), "-", lpad(dpm[m], 2, '0')) for m in 1:12]
end

# Internal page size for the JSON:API pagination; the caller sees `limit` (how many filings), never pages.
const _FXBRL_PAGE = 200

# Parse one JSON:API page (`doc`) into [`FilingHandle`](@ref)s, appending to `handles` and skipping filings
# with no fetchable package. `lei`/`year` are the query's filters — the LEI fallback identifier and a
# defensive year guard (a no-op given the server-side period_end filter, but it also drops an unparseable
# period_end when a year was asked for).
function _fxbrl_page!(handles::Vector{FilingHandle}, doc, lei, year)
    idof = Dict{String,String}()                       # LEI per included entity, by JSON:API resource id
    for e in get(doc, :included, ())
        get(e, :type, "") == "entity" || continue
        idof[String(e.id)] = String(get(e.attributes, :identifier, ""))
    end
    for f in get(doc, :data, ())
        a = f.attributes
        pkg = get(a, :package_url, nothing)
        (pkg === nothing || isempty(String(pkg))) && continue
        pe = tryparse(Date, String(get(a, :period_end, "")))
        year === nothing || (pe !== nothing && Dates.year(pe) == year) || continue
        eid = String(get(f.relationships.entity.data, :id, ""))
        identifier = get(idof, eid, lei === nothing ? "" : String(lei))
        push!(handles, FilingHandle(; system = ESEF(), entity = EntityId(:lei, identifier),
              ref = String(get(a, :fxo_id, String(f.id))), url = _FXBRL_BASE * String(pkg),
              period_end = pe, country = String(get(a, :country, ""))))
    end
    return handles
end

# The next-page URL from a JSON:API document, or `nothing` on the last page (`links.next` absent or null).
function _fxbrl_next(doc)
    haskey(doc, :links) || return nothing
    nxt = get(doc.links, :next, nothing)
    (nxt === nothing || (nxt isa AbstractString && isempty(strip(String(nxt))))) ? nothing : String(nxt)
end

"""
    discover(::FilingsXBRLOrg; lei=nothing, country=nothing, year=nothing, limit=nothing) -> Vector{FilingHandle}

Find ESEF filings on [filings.xbrl.org](https://filings.xbrl.org). Filter by `lei` (the filer's Legal
Entity Identifier) and/or `country` (ISO-3166 alpha-2, e.g. `"FI"`), and optionally `year` — **all applied
server-side**. `year` matches a filing whose `period_end` is *any* month-end of that year (a single
`period_end in […]` query over the twelve month-ends), so a June/March/January fiscal year-end is caught, not
only 31 December.

The API's pagination is handled **transparently** — the whole matching set is returned, following the
JSON:API `next` links across pages. `limit` caps how many handles you get (default: all matches); pass e.g.
`limit = 5` for a quick sample of a large `country`. A `lei` query is a handful of packages (one page); a bulk
`country` query may span many pages. Returns [`FilingHandle`](@ref)s (tagged `ESEF()`), newest first, each
carrying the report-package URL; fetch one with [`fetch_filing`](@ref).

An entity often has several packages for one period (language variants, amendments); they are all
returned, so pick the one you want (e.g. the English `…-en.zip`).

```julia
hs = discover(FilingsXBRLOrg(); lei = "549300P8N0P6KDGTJ206", year = 2023)
h  = first(filter(h -> endswith(h.url, "-en.zip"), hs))   # prefer the English package
f  = fetch_filing(h)
facts(f; classify = true, labels = true)
```
"""
function discover(::FilingsXBRLOrg; lei::Union{AbstractString,Nothing}=nothing,
                  country::Union{AbstractString,Nothing}=nothing,
                  year::Union{Integer,Nothing}=nothing, limit::Union{Integer,Nothing}=nothing)
    objs = Any[]
    lei === nothing || push!(objs, (name = "entity.identifier", op = "eq", val = String(lei)))
    country === nothing || push!(objs, (name = "country", op = "eq", val = String(country)))
    # `year` server-side. filings.xbrl.org accepts only `eq`/`in` on period_end (no gte/lte), so match `year`
    # as `period_end in [<every month-end of the year>]` — one query that also catches non-December year-ends.
    year === nothing || push!(objs, (name = "period_end", op = "in", val = _year_end_dates(year)))
    url = "$_FXBRL_BASE/api/filings?include=entity&page%5Bsize%5D=$_FXBRL_PAGE" * _fxbrl_filter(objs)

    handles = FilingHandle[]
    pages = 0
    while url !== nothing && pages < 1000               # page backstop (~200k filings) against a runaway `next`
        doc = _get_json(url); pages += 1
        _fxbrl_page!(handles, doc, lei, year)
        (limit !== nothing && length(handles) >= limit) && break
        url = _fxbrl_next(doc)
    end
    limit !== nothing && length(handles) > limit && (handles = handles[1:limit])
    sort!(handles; by = h -> something(h.period_end, Date(0)), rev = true)
    return handles
end

# ESEF fetch from a discovered handle: download and read the report package at `h.url`, carrying the
# LEI and filing reference discovery already resolved (so identity is not re-parsed from the instance).
fetch_filing(::ESEF, h::FilingHandle) = fetch_filing(ESEF(), h.url; entity = h.entity, ref = h.ref)
