# Companies House discovery + authenticated fetch (C2). Unlike ESEF (one aggregator, no key), CH is
# its own `FilingSource` backed by the Companies House REST API and Document API, which require a free
# API key (HTTP Basic, key as the username, blank password). The flow is:
#
#   discover(CompaniesHouseApi(); company_number) → filing-history endpoint → FilingHandles whose
#     `url` is each accounts filing's *document-metadata* URL.
#   fetch_filing(::CompaniesHouse, handle) → read the metadata, then GET `{metadata}/content` with the
#     iXBRL `Accept` header. The content endpoint 302-redirects to signed object storage; HTTP.jl
#     strips the `Authorization` header on that cross-host hop (see fetch_url), so the key never leaks.
#
# A filing with no structured (xhtml/xml) resource — paper/PDF accounts, common for small/dormant
# companies — yields a typed, non-fatal `:pdf` filing (Companies House II territory), not an error.
#
# Shapes below reconciled against the Companies House OpenAPI specs
# (specs.developer.ch.gov.uk / developer-specs.company-information.service.gov.uk): filing-history
# items carry `transaction_id`, `category`, `type`, `date` and `links.document_metadata`; the content
# endpoint `{document_metadata}/content` selects format via the `Accept` header (unsupported ⇒ 406)
# and returns a **302** to storage (whence HTTP.jl strips `Authorization` cross-host — see C0). A live
# call is only the final runtime confirmation. `period_end` is best-effort (made-up date when present,
# else the processed `date`), since the accounting-period field is free-form in the schema.

"""
    CompaniesHouseApi <: FilingSource

The Companies House REST + Document API as a [`FilingSource`](@ref). Requires a free API key —
set it with `set_credentials(CompaniesHouse(); api_key = "…")` (or the `COMPANIES_HOUSE_API_KEY`
environment variable). Use it with [`discover`](@ref) to find a company's accounts filings by
registration number. See [`discover(::CompaniesHouseApi)`](@ref).
"""
struct CompaniesHouseApi <: FilingSource end

const _CH_API_BASE = "https://api.company-information.service.gov.uk"

# The HTTP headers for a Companies House API request (N3): Basic auth with the API key as the username
# and a blank password. The key comes from the credentials registry (`set_credentials`) or, failing
# that, the `COMPANIES_HOUSE_API_KEY` environment variable; absent both, a clear error before any call.
function system_headers(::CompaniesHouse)
    key = get_credential(CompaniesHouse(), :api_key)
    if key === nothing || isempty(key)
        key = get(ENV, "COMPANIES_HOUSE_API_KEY", "")
    end
    isempty(key) && throw(ArgumentError(
        "No Companies House API key set. Get a free key at " *
        "https://developer.company-information.service.gov.uk/ and set it with:\n" *
        "    set_credentials(CompaniesHouse(); api_key = \"your-key\")\n" *
        "or set the COMPANIES_HOUSE_API_KEY environment variable."))
    return ["Authorization" => "Basic " * base64encode(key * ":")]
end

# Parse a `Date` from a JSON string value, or `nothing`.
_ch_date(x) = x === nothing ? nothing : tryparse(Date, String(x))

# The accounting period end of a filing-history item: the made-up date when present (most precise),
# else the action date, else the filing date. `nothing` if none parse.
function _ch_period_end(item)
    dv = get(item, :description_values, nothing)
    if dv !== nothing
        d = _ch_date(get(dv, :made_up_date, nothing))
        d === nothing || return d
    end
    d = _ch_date(get(item, :action_date, nothing))
    d === nothing || return d
    return _ch_date(get(item, :date, nothing))
end

"""
    discover(::CompaniesHouseApi; company_number, category="accounts", size=100,
             type=nothing, year=nothing, from=nothing, to=nothing) -> Vector{FilingHandle}

Find a company's filings on Companies House by its registration `company_number` (e.g. `"06150195"`,
or with a prefix like `"SC123456"`). `category` filters the filing-history server-side (default
`"accounts"`; pass `""` for all); `size` caps how many items are requested. Returns
[`FilingHandle`](@ref)s tagged `CompaniesHouse()`, newest first, each carrying the filing's
document-metadata URL; fetch one with [`fetch_filing`](@ref). Requires an API key (see
[`CompaniesHouseApi`](@ref)).

Within a company, narrow the filings further: `type` keeps only the given filing-type code
(case-insensitive, e.g. `"AA"` full accounts, `"AA01"` accounting-reference-date change), and the
accounting period end (`period_end`) is bounded by either `year` (a single calendar year) or an
explicit `from`/`to` window (each a `Date`, inclusive). `year` is shorthand for the full calendar
year; an explicit `from` or `to` overrides the corresponding bound.

```julia
hs = discover(CompaniesHouseApi(); company_number = "06150195")   # Jupiter Fund Management plc
f  = fetch_filing(first(hs))
facts(f; classify = true)

# only full-accounts filings whose period ends in 2020 or later
discover(CompaniesHouseApi(); company_number = "00445790", type = "AA", from = Date(2020))
discover(CompaniesHouseApi(); company_number = "00445790", type = "AA", year = 2023)  # one year
```
"""
function discover(::CompaniesHouseApi; company_number::AbstractString,
                  category::AbstractString="accounts", size::Integer=100,
                  type::Union{Nothing,AbstractString}=nothing,
                  year::Union{Nothing,Integer}=nothing,
                  from::Union{Nothing,Date}=nothing, to::Union{Nothing,Date}=nothing)
    if year !== nothing                       # `year` fills whichever bound an explicit from/to leaves open
        from === nothing && (from = Date(year, 1, 1))
        to   === nothing && (to   = Date(year, 12, 31))
    end
    num = strip(company_number)
    url = "$_CH_API_BASE/company/$num/filing-history?items_per_page=$size" *
          (isempty(category) ? "" : "&category=$category")
    doc = _get_json(url; headers = system_headers(CompaniesHouse()))

    ftype = type === nothing ? nothing : uppercase(strip(type))
    handles = FilingHandle[]
    for item in get(doc, :items, ())
        ftype === nothing || uppercase(_str(get(item, :type, nothing))) == ftype || continue
        links = get(item, :links, nothing)
        links === nothing && continue
        meta = get(links, :document_metadata, nothing)
        (meta === nothing || isempty(String(meta))) && continue        # no document → not fetchable
        pe = _ch_period_end(item)
        from === nothing || (pe !== nothing && pe >= from) || continue
        to   === nothing || (pe !== nothing && pe <= to)   || continue
        push!(handles, FilingHandle(; system = CompaniesHouse(),
              entity = EntityId(:companies_house, String(num)),
              ref = String(get(item, :transaction_id, "")),
              url = String(meta), period_end = pe, country = "GB"))
    end
    sort!(handles; by = h -> something(h.period_end, Date(0)), rev = true)
    return handles
end

# Companies House fetch from a discovered handle. Two sources produce CH handles, distinguished by the
# handle's `url`: a `CompaniesHouseBulk` handle's `url` is a bulk-archive `.zip` (its `ref` is the
# entry name) → read the entry from the archive (keyless, see bulk.jl); any other `url` is a
# `CompaniesHouseApi` document-metadata URL → the authenticated Document-API path below.
fetch_filing(::CompaniesHouse, h::FilingHandle) =
    endswith(lowercase(h.url), ".zip") ? _ch_fetch_from_bulk(h) : _ch_fetch_from_api(h)

# The authenticated Document-API path: read the document metadata, then download the document content
# with the iXBRL `Accept` header. Prefers inline XBRL (`application/xhtml+xml`), then a classic XBRL
# instance (`application/xml`); a filing offering neither (paper/PDF) becomes a typed `:pdf` filing
# (empty content, content URL kept) for the PDF phase to handle. The company identity comes from the
# handle (discovery knew the number); only re-parsed from the instance if absent.
function _ch_fetch_from_api(h::FilingHandle)
    hdrs = system_headers(CompaniesHouse())
    meta = _get_json(h.url; headers = hdrs)
    resources = get(meta, :resources, nothing)
    content_url = rstrip(h.url, '/') * "/content"

    has_ixbrl = resources !== nothing && haskey(resources, Symbol("application/xhtml+xml"))
    has_xml   = resources !== nothing && haskey(resources, Symbol("application/xml"))
    if !(has_ixbrl || has_xml)
        return Filing(CompaniesHouse(), h.entity, h.ref, h.ref, content_url, :pdf, "")
    end

    accept = has_ixbrl ? "application/xhtml+xml" : "application/xml"
    bytes = fetch_url(content_url; headers = [hdrs; "Accept" => accept])
    bytes === nothing && error("could not fetch Companies House document content $(repr(content_url))")
    raw = Vector{UInt8}(bytes)
    _ch_is_pdf(raw) && return Filing(CompaniesHouse(), h.entity, h.ref, h.ref, content_url, :pdf, "")

    content = _ch_canonicalize(String(raw))
    ent = isempty(h.entity.value) ? EntityId(:companies_house, _ch_number(content)) : h.entity
    return Filing(CompaniesHouse(), ent, h.ref, h.ref, content_url, has_ixbrl ? :ixbrl : :xbrl, content)
end

# ── Company search (the generic `company_search` verb, CH method) ──────────────────────────────
# Companies House exposes two search endpoints, and `company_search(::CompaniesHouseApi, …)` routes
# between them by what you ask for:
#   • free-text only → `/search/companies?q=` — the registry's ranked name/number search (a `q` that
#     looks like a number matches the number), best for "find the company called X";
#   • any structured criterion (status/type/sic/incorporation/dissolution/location) → the
#     `/advanced-search/companies` endpoint, which filters server-side and treats the free text as
#     `company_name_includes`.
# Both item shapes were reconciled against live responses; `_ch_hit` reads whichever fields a given
# endpoint returns (`title` vs `company_name`, `address_snippet` vs `registered_office_address`) into
# the uniform `CompanyHit`.

# Stringify one criterion value for a query parameter: a `Date` as ISO `yyyy-mm-dd`, a list of codes
# space-joined (CH accepts space-separated `sic_codes`/`company_type`), anything else via `string`.
_ch_pval(x::Date) = string(x)
_ch_pval(x::AbstractVector) = join(string.(x), " ")
_ch_pval(x) = string(x)

# Join "k" => "v" pairs into a URL query, dropping empties and escaping each value.
_ch_querystr(pairs) = join(["$k=$(HTTP.escapeuri(v))" for (k, v) in pairs if !isempty(v)], "&")

# A one-line registered-address snippet: the basic endpoint hands us `address_snippet` ready-made;
# the advanced endpoint gives a structured `registered_office_address` we join in postal order.
function _ch_hit_address(item)
    snip = get(item, :address_snippet, nothing)
    snip === nothing || return _str(snip)
    addr = get(item, :registered_office_address, nothing)
    addr === nothing && return ""
    parts = String[]
    for k in (:premises, :address_line_1, :address_line_2, :locality, :region, :postal_code, :country)
        v = _str(get(addr, k, nothing))
        isempty(v) || push!(parts, v)
    end
    return join(parts, ", ")
end

# One search-result item (from either endpoint) → a uniform `CompanyHit`.
function _ch_hit(item)
    name = get(item, :title, nothing)
    name = name === nothing ? _str(get(item, :company_name, nothing)) : _str(name)
    num  = _str(get(item, :company_number, nothing))
    sic  = String[String(x) for x in get(item, :sic_codes, ())]
    return CompanyHit((name, EntityId(:companies_house, num),
                       _str(get(item, :company_status, nothing)),
                       _str(get(item, :company_type, nothing)),
                       _ch_date(get(item, :date_of_creation, nothing)),
                       sic, _ch_hit_address(item), "GB"))
end

"""
    company_search(::CompaniesHouseApi, query=""; status, type, sic,
                   incorporated_from, incorporated_to, dissolved_from, dissolved_to,
                   location, size=20, start=0) -> Vector{CompanyHit}

Search the Companies House register for companies, returning a uniform [`CompanyHit`](@ref) row table
(see that type for the fields). Take a hit's identity into discovery with
`discover(CompaniesHouseApi(); company_number = hit.id.value)`. Requires an API key (see
[`CompaniesHouseApi`](@ref)).

With only `query`, this is the registry's ranked free-text search over name and number. Supplying any
criterion switches to the advanced search, where `query` becomes a name-substring filter and the
criteria filter server-side:

- `status` — company status, e.g. `"active"`, `"dissolved"`, `"liquidation"`.
- `type` — company type, e.g. `"plc"`, `"ltd"`, `"llp"`.
- `sic` — a SIC code (or a vector of codes), e.g. `"47110"`.
- `incorporated_from`, `incorporated_to` — `Date` bounds on the incorporation date.
- `dissolved_from`, `dissolved_to` — `Date` bounds on the dissolution date.
- `location` — a registered-office locality, e.g. `"London"`.
- `size` caps the page (advanced search allows up to 5000); `start` is the result offset.

```julia
company_search(CompaniesHouseApi(), "tesco")                      # ranked free-text
company_search(CompaniesHouseApi(), "tesco"; status = "active", type = "plc", sic = "47110",
               incorporated_from = Date(1900), incorporated_to = Date(1990))
only(company_search(CompaniesHouseApi(), "445790")).id.value      # → "00445790"
```
"""
function company_search(::CompaniesHouseApi, query::AbstractString="";
                        status=nothing, type=nothing, sic=nothing,
                        incorporated_from=nothing, incorporated_to=nothing,
                        dissolved_from=nothing, dissolved_to=nothing,
                        location=nothing, size::Integer=20, start::Integer=0)
    hdrs = system_headers(CompaniesHouse())
    advanced = any(!isnothing, (status, type, sic, incorporated_from, incorporated_to,
                                dissolved_from, dissolved_to, location))
    if advanced
        params = Pair{String,String}["company_name_includes" => String(query),
                                     "size" => string(size), "start_index" => string(start)]
        status            === nothing || push!(params, "company_status"    => _ch_pval(status))
        type              === nothing || push!(params, "company_type"      => _ch_pval(type))
        sic               === nothing || push!(params, "sic_codes"         => _ch_pval(sic))
        incorporated_from === nothing || push!(params, "incorporated_from" => _ch_pval(incorporated_from))
        incorporated_to   === nothing || push!(params, "incorporated_to"   => _ch_pval(incorporated_to))
        dissolved_from    === nothing || push!(params, "dissolved_from"    => _ch_pval(dissolved_from))
        dissolved_to      === nothing || push!(params, "dissolved_to"      => _ch_pval(dissolved_to))
        location          === nothing || push!(params, "location"          => _ch_pval(location))
        url = "$_CH_API_BASE/advanced-search/companies?" * _ch_querystr(params)
    else
        url = "$_CH_API_BASE/search/companies?q=$(HTTP.escapeuri(String(query)))" *
              "&items_per_page=$size&start_index=$start"
    end
    doc = _get_json(url; headers = hdrs)
    return CompanyHit[_ch_hit(it) for it in get(doc, :items, ())]
end
