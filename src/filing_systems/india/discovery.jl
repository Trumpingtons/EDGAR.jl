# India discovery — the NSE corporate-filings "financial results" API as a FilingSource. Keyless but
# cookie-gated (the NSE session helpers live in india.jl): a query by ticker symbol returns a JSON array,
# one record per results filing, each carrying a direct Ind-AS XBRL URL plus the ISIN, the
# consolidated/standalone flag, the audited flag and the financial year — the EDINET-style
# discovery→XBRL seam. See docs/dev/india-plan.md (I2).

"""
    NSEFilings <: FilingSource

The NSE corporate-filings financial-results API as a [`FilingSource`](@ref). Keyless, but cookie-gated
(the NSE session is bootstrapped automatically). Discovery is **by ticker symbol** (see
[`discover(::NSEFilings)`](@ref)); each result carries a direct Ind-AS XBRL URL that
[`fetch_filing`](@ref) downloads.
"""
struct NSEFilings <: FilingSource end

const _NSE_RESULTS_API = "https://www.nseindia.com/api/corporates-financial-results"

# "31-Mar-2024" → Date(2024, 3, 31); nothing on absent/unparseable input.
function _nse_date(v)
    (v === nothing || isempty(string(v))) && return nothing
    try Date(string(v), dateformat"d-u-y") catch; nothing end
end

# A record field as a String, with null/absent → "".
_nse_str(r, k) = (v = get(r, k, nothing); v === nothing ? "" : string(v))

# A yes/no flag ("Consolidated"/"Audited"/…) lower-cased for comparison; "" when absent.
_nse_flag(r, k) = (v = get(r, k, nothing); v === nothing ? "" : lowercase(strip(string(v))))

# Turn the parsed results-API array into FilingHandles. PURE (no network) — testable offline against a
# saved results JSON. Keeps only records that carry an XBRL url, narrowed by consolidated/audited (each
# `nothing` = don't filter). Identity is the record's ISIN (falling back to the queried `sym`), the ref
# is the NSE sequence number, and `period_end` is the results' `toDate`. Newest first.
function _nse_result_handles(records, sym::AbstractString;
                             consolidated::Union{Bool,Nothing}, audited::Union{Bool,Nothing})
    handles = FilingHandle[]
    for r in records
        url = _nse_str(r, :xbrl); isempty(url) && continue
        consolidated === nothing || _nse_flag(r, :consolidated) == (consolidated ? "consolidated" : "non-consolidated") || continue
        audited === nothing      || _nse_flag(r, :audited)      == (audited ? "audited" : "unaudited")               || continue
        isin = _nse_str(r, :isin)
        ent  = isempty(isin) ? EntityId(:nse_symbol, sym) : EntityId(:isin, isin)
        ref  = _nse_str(r, :seqNumber); isempty(ref) && (ref = basename(url))
        push!(handles, FilingHandle(; system = India(), entity = ent, ref = ref, url = url,
              period_end = _nse_date(_nse_str(r, :toDate)), country = "IN"))
    end
    sort!(handles; by = h -> something(h.period_end, Date(0)), rev = true)
    return handles
end

"""
    discover(::NSEFilings; symbol, period="Annual", consolidated=true, audited=true) -> Vector{FilingHandle}

List a company's financial-results filings from the NSE corporate-filings API, by ticker `symbol` (e.g.
`"RELIANCE"`). `period` is `"Annual"` or `"Quarterly"`. `consolidated` / `audited` narrow the results
(`true` / `false`, or `nothing` to keep both). Returns [`FilingHandle`](@ref)s tagged `India()`, each
carrying the Ind-AS XBRL URL and the record's ISIN as identity, newest first; fetch one with
[`fetch_filing`](@ref). Keyless, but cookie-gated — the NSE session is bootstrapped (and refreshed on a
failed call) automatically.

```julia
hs = discover(NSEFilings(); symbol = "RELIANCE")   # annual, consolidated, audited
f  = fetch_filing(first(hs))
facts(f)
```
"""
function discover(::NSEFilings; symbol=nothing, period::AbstractString="Annual",
                  consolidated::Union{Bool,Nothing}=true, audited::Union{Bool,Nothing}=true)
    symbol === nothing && throw(ArgumentError("discover(NSEFilings(); …) needs a ticker `symbol`"))
    sym = uppercase(strip(String(symbol)))
    url = string(_NSE_RESULTS_API, "?index=equities",
                 "&symbol=", HTTP.URIs.escapeuri(sym), "&period=", HTTP.URIs.escapeuri(period))
    records = try
        _get_json(url; headers = _nse_headers(), use_cache = false)
    catch                                   # usually a stale cookie — re-bootstrap once and retry
        _get_json(url; headers = _nse_headers(; force = true), use_cache = false)
    end
    return _nse_result_handles(records, sym; consolidated = consolidated, audited = audited)
end

# Fetch from a discovered handle: download the Ind-AS XBRL at `h.url` (with the NSE session) and route to
# the offline parser, carrying the discovered identity (the ISIN) and reference.
fetch_filing(::India, h::FilingHandle) = fetch_filing(India(), h.url; entity = h.entity, ref = h.ref)
