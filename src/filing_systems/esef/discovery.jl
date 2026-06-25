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
# URL-encoded. `entity.identifier` filters by the filer's LEI (a relationship attribute the API
# supports); `country` filters by ISO country. Empty ⇒ no `filter` param.
function _fxbrl_filter(pairs::Vector{Pair{String,String}})
    isempty(pairs) && return ""
    objs = [(name = n, op = "eq", val = v) for (n, v) in pairs]   # NamedTuple ⇒ stable key order
    return "&filter=" * HTTP.URIs.escapeuri(JSON3.write(objs))
end

"""
    discover(::FilingsXBRLOrg; lei=nothing, country=nothing, year=nothing, size=100) -> Vector{FilingHandle}

Find ESEF filings on [filings.xbrl.org](https://filings.xbrl.org). Filter by `lei` (the filer's Legal
Entity Identifier) and/or `country` (ISO-3166 alpha-2, e.g. `"FI"`) — both applied server-side — and
optionally `year` (matched client-side against each filing's `period_end`). `size` caps how many
filings are requested. Returns [`FilingHandle`](@ref)s (tagged `ESEF()`), newest first, each carrying
the report-package URL; fetch one with [`fetch_filing`](@ref).

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
                  year::Union{Integer,Nothing}=nothing, size::Integer=100)
    pairs = Pair{String,String}[]
    lei === nothing || push!(pairs, "entity.identifier" => String(lei))
    country === nothing || push!(pairs, "country" => String(country))
    url = "$_FXBRL_BASE/api/filings?include=entity&page%5Bsize%5D=$size" * _fxbrl_filter(pairs)
    doc = _get_json(url)

    # identifier (LEI) per included entity, keyed by its JSON:API resource id.
    idof = Dict{String,String}()
    for e in get(doc, :included, ())
        get(e, :type, "") == "entity" || continue
        idof[String(e.id)] = String(get(e.attributes, :identifier, ""))
    end

    handles = FilingHandle[]
    for f in get(doc, :data, ())
        a = f.attributes
        pkg = get(a, :package_url, nothing)
        (pkg === nothing || isempty(String(pkg))) && continue          # no fetchable package
        pe = tryparse(Date, String(get(a, :period_end, "")))
        year === nothing || (pe !== nothing && Dates.year(pe) == year) || continue
        eid = String(get(f.relationships.entity.data, :id, ""))
        identifier = get(idof, eid, lei === nothing ? "" : String(lei))
        push!(handles, FilingHandle(; system = ESEF(), entity = EntityId(:lei, identifier),
              ref = String(get(a, :fxo_id, String(f.id))), url = _FXBRL_BASE * String(pkg),
              period_end = pe, country = String(get(a, :country, ""))))
    end
    sort!(handles; by = h -> something(h.period_end, Date(0)), rev = true)
    return handles
end

# ESEF fetch from a discovered handle: download and read the report package at `h.url`, carrying the
# LEI and filing reference discovery already resolved (so identity is not re-parsed from the instance).
fetch_filing(::ESEF, h::FilingHandle) = fetch_filing(ESEF(), h.url; entity = h.entity, ref = h.ref)
