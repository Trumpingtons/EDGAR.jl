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
    discover(::CompaniesHouseApi; company_number, category="accounts", size=100) -> Vector{FilingHandle}

Find a company's filings on Companies House by its registration `company_number` (e.g. `"06150195"`,
or with a prefix like `"SC123456"`). `category` filters the filing-history server-side (default
`"accounts"`; pass `""` for all); `size` caps how many items are requested. Returns
[`FilingHandle`](@ref)s tagged `CompaniesHouse()`, newest first, each carrying the filing's
document-metadata URL; fetch one with [`fetch_filing`](@ref). Requires an API key (see
[`CompaniesHouseApi`](@ref)).

```julia
hs = discover(CompaniesHouseApi(); company_number = "06150195")   # Jupiter Fund Management plc
f  = fetch_filing(first(hs))
facts(f; classify = true)
```
"""
function discover(::CompaniesHouseApi; company_number::AbstractString,
                  category::AbstractString="accounts", size::Integer=100)
    num = strip(company_number)
    url = "$_CH_API_BASE/company/$num/filing-history?items_per_page=$size" *
          (isempty(category) ? "" : "&category=$category")
    doc = _get_json(url; headers = system_headers(CompaniesHouse()))

    handles = FilingHandle[]
    for item in get(doc, :items, ())
        links = get(item, :links, nothing)
        links === nothing && continue
        meta = get(links, :document_metadata, nothing)
        (meta === nothing || isempty(String(meta))) && continue        # no document → not fetchable
        push!(handles, FilingHandle(; system = CompaniesHouse(),
              entity = EntityId(:companies_house, String(num)),
              ref = String(get(item, :transaction_id, "")),
              url = String(meta), period_end = _ch_period_end(item), country = "GB"))
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
