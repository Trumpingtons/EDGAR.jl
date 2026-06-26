# NSM discovery via the FCA National Storage Mechanism (data.fca.org.uk) — the UK's official store of
# listed-issuer regulated information, and the upstream of filings.xbrl.org's UK data. Like
# `FilingsXBRLOrg`, it is a `FilingSource` (not a system): its Annual Financial Reports are ESEF/UKSEF
# report-package ZIPs that the existing `fetch_filing(::ESEF, url)` parses unchanged, so handles are
# tagged `ESEF()`.
#
# The search backend is a keyless JSON API (reverse-engineered from the NSM Angular app):
#   POST https://api.data.fca.org.uk/search?index=fca-nsm-searchdata
# with a `criteriaObj` body (NOT raw Elasticsearch DSL — that is ignored). The category dimension is the
# `type_code` (see NSM_CATEGORIES); the iXBRL annual reports carry `tag_esef="Tagged"` and a `.zip`
# `download_link` resolved under https://data.fca.org.uk/artefacts/. Only Annual Financial Reports are
# XBRL-tagged; every other category (quarterly, half-year, RNS) is untagged PDF/HTML — a separate
# (PDF-extractor) track, not handled here yet.

"""
    NSM <: FilingSource

The FCA **National Storage Mechanism** ([data.fca.org.uk](https://data.fca.org.uk)) as a keyless
[`FilingSource`](@ref) — the UK regulated-market disclosure store. Use it with [`discover`](@ref) to
find a listed issuer's **Annual Financial Reports** (UKSEF/ESEF iXBRL) by LEI; they parse through the
existing ESEF path. Browse the category vocabulary with [`nsm_categories`](@ref).
"""
struct NSM <: FilingSource end

const _NSM_SEARCH_URL = "https://api.data.fca.org.uk/search?index=fca-nsm-searchdata"
const _NSM_ARTEFACTS_BASE = "https://data.fca.org.uk/artefacts/"
const _NSM_HEADERS = ["Content-Type" => "application/json", "Origin" => "https://data.fca.org.uk",
                      "User-Agent" => "EDGAR.jl (https://github.com/Trumpingtons/EDGAR.jl)"]

# Normalize a category string for forgiving comparison: lowercase, non-alphanumerics → single spaces.
_nsm_norm(s) = strip(replace(lowercase(String(s)), r"[^a-z0-9]+" => " "))

# Normalized-description → type_code, for resolving friendly category names. Built once from
# NSM_CATEGORIES (see nsm_categories.jl), which must be included first.
const _NSM_NAME_TO_CODE = Dict(_nsm_norm(desc) => code for (code, desc) in NSM_CATEGORIES)

"""
    nsm_categories(query="") -> Vector{Pair{String,String}}

Browse the NSM category vocabulary — `type_code => description` pairs (active categories only). With a
`query`, keep only entries whose code or description contains it (case-insensitive). Use this to find
the right `category` for [`discover(::NSM)`](@ref).

```julia
nsm_categories("quarter")   # ["QRF" => "1st Quarter Results", "QRT" => "3rd Quarter Results"]
```
"""
function nsm_categories(query::AbstractString="")
    q = lowercase(strip(query))
    pairs = [c => d for (c, d) in NSM_CATEGORIES
             if isempty(q) || occursin(q, lowercase(d)) || occursin(q, lowercase(c))]
    return sort!(pairs)
end

# Resolve a user `category` (a type_code like "ACS", or a friendly description in any case/spacing) to
# its type_code. Throws with close-match suggestions when it cannot be resolved.
function _nsm_category_code(q::AbstractString)
    qs = strip(q)
    haskey(NSM_CATEGORIES, qs) && return qs                       # exact code
    haskey(NSM_CATEGORIES, uppercase(qs)) && return uppercase(qs) # code, any case
    n = _nsm_norm(qs)
    haskey(_NSM_NAME_TO_CODE, n) && return _NSM_NAME_TO_CODE[n]   # normalized description
    sugg = sort!([c => d for (c, d) in NSM_CATEGORIES
                  if (!isempty(n) && occursin(n, _nsm_norm(d))) || occursin(lowercase(qs), lowercase(c))])
    hint = isempty(sugg) ? "browse with nsm_categories(\"…\")." :
        "closest: " * join(["$(repr(c)) => $(repr(d))" for (c, d) in first(sugg, 5)], ", ") *
        "; or pass the code directly."
    error("unknown NSM category $(repr(q)). $hint")
end

# POST a search body to the NSM API and return the parsed JSON (keyless). Goes through the shared,
# cached, header-aware `fetch_url` (method=:POST); throws if the request fails / returns non-200.
function _nsm_search(body::AbstractString)
    resp = fetch_url(_NSM_SEARCH_URL; method = :POST, body = body, headers = _NSM_HEADERS)
    resp === nothing && error("NSM search request failed (network error or non-200 from $_NSM_SEARCH_URL)")
    return JSON3.read(resp)
end

# Format a `Date` for an NSM dateCriteria value: dd/MM/yyyy (the format the API expects).
_nsm_ddmmyyyy(d::Date) = Dates.format(d, "dd/mm/yyyy")

# The criteriaObj search body for a filer's tagged Annual Financial Reports: filter by LEI and
# `tag_esef="Tagged"` (the iXBRL marker), optionally narrowing `document_date` (the accounting
# reference date) to a `from`/`to` window. The API's dateCriteria value always carries both bounds,
# so an open-ended request fills the missing side with a wide sentinel. JSON key order is irrelevant.
function _nsm_afr_body(lei::AbstractString, from::Union{Date,Nothing}, to::Union{Date,Nothing},
                       size::Integer)
    crit = [Dict("name" => "lei", "value" => lei), Dict("name" => "tag_esef", "value" => "Tagged")]
    dc = (from === nothing && to === nothing) ? nothing :
         [Dict("name" => "document_date",
               "value" => Dict("from" => _nsm_ddmmyyyy(something(from, Date(1990, 1, 1))),
                               "to"   => _nsm_ddmmyyyy(something(to,   Date(2100, 12, 31)))))]
    return JSON3.write(Dict("from" => 0, "size" => size,
                            "criteriaObj" => Dict("criteria" => crit, "dateCriteria" => dc)))
end

# Parse a `Date` from an NSM datetime string ("2025-02-22" or "2025-02-22T…"), or `nothing`.
function _nsm_date(x)
    x === nothing && return nothing
    s = String(x)
    length(s) < 10 && return nothing
    return tryparse(Date, s[1:10])
end

"""
    discover(::NSM; lei, category="Annual Financial Report", year=nothing,
             from=nothing, to=nothing, size=100) -> Vector{FilingHandle}

Find a UK listed issuer's filings on the FCA [`NSM`](@ref) by `lei` (its Legal Entity Identifier).
`category` selects the document type — a `type_code` or a friendly name resolved via
[`nsm_categories`](@ref) — and the accounting-reference date is narrowed by either `year` (a single
calendar year) or an explicit `from`/`to` window (each a `Date`, inclusive). `year` is shorthand for
the full calendar year; an explicit `from` or `to` overrides the corresponding bound. Returns
[`FilingHandle`](@ref)s (newest first), each carrying the report-package URL; fetch one with
[`fetch_filing`](@ref).

Only **Annual Financial Reports** (UKSEF/ESEF iXBRL) are supported today — they are tagged `ESEF()`
and parse through the existing ESEF path. Other categories (quarterly, half-year, RNS) are untagged
PDF/HTML on the NSM and are not yet fetchable here; requesting one raises an informative error.

```julia
hs = discover(NSM(); lei = "2138002P5RNKC5W2JZ46", year = 2025)   # Tesco PLC, one calendar year
discover(NSM(); lei = "2138002P5RNKC5W2JZ46", from = Date(2022), to = Date(2024))  # a range
f  = fetch_filing(first(hs))
facts(f; classify = true, labels = true)
```
"""
function discover(::NSM; lei::AbstractString,
                  category::AbstractString="Annual Financial Report",
                  year::Union{Integer,Nothing}=nothing,
                  from::Union{Date,Nothing}=nothing, to::Union{Date,Nothing}=nothing,
                  size::Integer=100)
    code = _nsm_category_code(category)
    code == "ACS" || error("the NSM source currently supports only Annual Financial Reports (iXBRL). " *
        "Category $(repr(category)) (type_code $(repr(code))) is delivered as untagged PDF/HTML on the " *
        "NSM — the PDF-extraction track is not yet implemented. Browse with nsm_categories().")
    if year !== nothing                       # `year` fills whichever bound an explicit from/to leaves open
        from === nothing && (from = Date(year, 1, 1))
        to   === nothing && (to   = Date(year, 12, 31))
    end
    l = strip(lei)
    doc = _nsm_search(_nsm_afr_body(l, from, to, size))
    handles = FilingHandle[]
    for h in get(get(doc, :hits, (;)), :hits, ())
        s = get(h, :_source, nothing); s === nothing && continue
        link = String(get(s, :download_link, ""))
        (isempty(link) || !endswith(lowercase(link), ".zip")) && continue   # AFR iXBRL package only
        push!(handles, FilingHandle(; system = ESEF(),
              entity = EntityId(:lei, l),
              ref = String(get(s, :disclosure_id, get(s, :seq_id, ""))),
              url = _NSM_ARTEFACTS_BASE * link,
              period_end = _nsm_date(get(s, :document_date, nothing)), country = "GB"))
    end
    sort!(handles; by = h -> something(h.period_end, Date(0)), rev = true)
    return handles
end

# NSM Annual Financial Reports are ESEF report packages, so fetch flows through the existing
# `fetch_filing(::ESEF, h::FilingHandle)` (handles are tagged `ESEF()`). No NSM-specific fetch needed.

# ── Company search (the generic `company_search` verb, NSM method) ─────────────────────────────
# The NSM is a filing store, not a company registry, and `discover(::NSM)` keys off an LEI a caller
# rarely knows by heart. So `company_search(::NSM, name)` does the step before discovery: resolve a
# name to its issuer LEI(s). It searches the `company` criterion and — crucially — scopes to
# `tag_esef="Tagged"` (the iXBRL Annual Financial Reports) by default, because those are exactly the
# filings that carry an LEI *and* the only ones NSM discovery can fetch; the unscoped `company`
# criterion also matches RNS/PDMR filings whose `lei` is blank (verified live). Hits are deduped to
# one `CompanyHit` per LEI, with `id = EntityId(:lei, …)` ready for `discover(NSM(); lei = …)`. The
# registry facets a registrar would carry (status/type/incorporation/SIC/address) are left empty —
# the NSM does not publish them.

# The criteriaObj search body for resolving a company name to issuers: the `company` criterion, plus
# `tag_esef="Tagged"` when `tagged_only` (so every hit carries an LEI and is AFR-fetchable).
function _nsm_company_body(name::AbstractString, tagged_only::Bool, size::Integer)
    crit = [Dict("name" => "company", "value" => String(name))]
    tagged_only && push!(crit, Dict("name" => "tag_esef", "value" => "Tagged"))
    return JSON3.write(Dict("from" => 0, "size" => size,
                            "criteriaObj" => Dict("criteria" => crit, "dateCriteria" => nothing)))
end

"""
    company_search(::NSM, query=""; tagged_only=true, size=100) -> Vector{CompanyHit}

Resolve a company `query` (a name substring) to its issuer(s) on the FCA [`NSM`](@ref), returning a
uniform [`CompanyHit`](@ref) row table whose `id` is each issuer's `EntityId(:lei, …)`. Take a hit's
LEI straight into discovery: `discover(NSM(); lei = hit.id.value)`. Keyless.

The NSM is a disclosure store rather than a company registry, so this is name → LEI resolution: hits
are deduped to one row per LEI, and the registrar facets (`status`, `type`, `incorporated`, `sic`,
`address`) are left empty. By default `tagged_only` scopes the search to the iXBRL Annual Financial
Reports — the filings that carry an LEI and that NSM discovery can fetch; set `tagged_only=false` to
search the whole disclosure corpus (rows without an LEI are still dropped, as they cannot be fetched).

```julia
company_search(NSM(), "tesco")                       # → CompanyHit for TESCO PLC, id.value = the LEI
discover(NSM(); lei = only(company_search(NSM(), "tesco")).id.value, year = 2025)
```
"""
function company_search(::NSM, query::AbstractString=""; tagged_only::Bool=true, size::Integer=100)
    doc = _nsm_search(_nsm_company_body(query, tagged_only, size))
    hits = CompanyHit[]
    seen = Set{String}()
    for h in get(get(doc, :hits, (;)), :hits, ())
        s = get(h, :_source, nothing); s === nothing && continue
        lei = strip(String(get(s, :lei, "")))
        (isempty(lei) || lei in seen) && continue          # need an LEI to be fetchable; one row per issuer
        push!(seen, lei)
        name = rstrip(strip(String(get(s, :company, ""))), ';')
        push!(hits, CompanyHit((name, EntityId(:lei, lei), "", "", nothing, String[], "", "GB")))
    end
    sort!(hits; by = h -> h.name)
    return hits
end
