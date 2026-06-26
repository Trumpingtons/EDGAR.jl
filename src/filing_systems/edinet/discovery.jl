# EDINET discovery — the EDINET REST API (api.edinet-fsa.go.jp) as a `FilingSource`. Unlike Companies
# House (per-company) or filings.xbrl.org (per-LEI), EDINET discovery is **date-based**: list a day's
# submissions, then filter client-side by `edinetCode` / `docTypeCode`. Each result's `docID` resolves
# to an authenticated ZIP-acquisition URL (`/documents/{docID}?type=1`) that fetch_filing downloads.
# Shapes verified against the EDINET API v2 spec (2026-06); see docs/dev/edinet-plan.md.

"""
    EDINETApi <: FilingSource

The EDINET REST API as a [`FilingSource`](@ref). Requires a free Subscription-Key — set it with
`set_credentials(EDINET(); api_key = "…")` (or the `EDINET_API_KEY` environment variable). Discovery is
**by date** (see [`discover(::EDINETApi)`](@ref)).
"""
struct EDINETApi <: FilingSource end

_edinet_period(x) = x === nothing ? nothing : tryparse(Date, String(x))

"""
    discover(::EDINETApi; date, edinet_code=nothing, doc_type="120") -> Vector{FilingHandle}

List EDINET filings submitted on `date` (a `Date` or `"YYYY-MM-DD"` string), optionally narrowed to one
`edinet_code` (`"E#####"`) and a `doc_type` (default `"120"` = annual securities report 有価証券報告書;
pass `""` for all types). Returns [`FilingHandle`](@ref)s tagged `EDINET()`, each carrying the
document's ZIP-acquisition URL; fetch one with [`fetch_filing`](@ref). Documents without XBRL are
skipped. Requires an API key (see [`EDINETApi`](@ref)).

```julia
hs = discover(EDINETApi(); date = "2024-06-21", edinet_code = "E02144")   # Toyota's annual report day
f  = fetch_filing(first(hs))
facts(f; classify = true)
```
"""
function discover(::EDINETApi; date, edinet_code=nothing, doc_type::AbstractString="120")
    d = date isa Date ? date : Date(String(date))
    url = "$_EDINET_API_BASE/documents.json?date=$d&type=2"
    doc = _get_json(url; headers = system_headers(EDINET()))

    handles = FilingHandle[]
    for r in get(doc, :results, ())
        _str(get(r, :xbrlFlag, nothing)) == "1" || continue          # need a structured (XBRL) document
        dt = _str(get(r, :docTypeCode, nothing))
        (isempty(doc_type) || dt == doc_type) || continue
        ec = _str(get(r, :edinetCode, nothing))
        (edinet_code === nothing || ec == String(edinet_code)) || continue
        docid = _str(get(r, :docID, nothing)); isempty(docid) && continue
        push!(handles, FilingHandle(; system = EDINET(),
              entity = EntityId(:edinet, ec),
              ref = docid,
              url = "$_EDINET_API_BASE/documents/$docid?type=1",        # ZIP; key added as a header at fetch
              period_end = _edinet_period(get(r, :periodEnd, nothing)),
              country = "JP"))
    end
    sort!(handles; by = h -> something(h.period_end, Date(0)), rev = true)
    return handles
end

# Fetch from a discovered handle: download the authenticated document ZIP and route to the offline parser.
fetch_filing(::EDINET, h::FilingHandle) = fetch_filing(EDINET(), h.url; entity = h.entity, ref = h.ref)
