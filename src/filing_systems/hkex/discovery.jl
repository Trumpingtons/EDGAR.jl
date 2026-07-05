# Hong Kong discovery + fetch (HK1) — the HKEXnews portal as a keyless FilingSource. Two browser-headed
# endpoints, no key and no cookie bootstrap: `prefix.do` resolves a five-digit stock code or company name to a
# {code, stockId} pair (HKEXnews's live analogue of DART's corpCode index or CNINFO's topSearch), and
# `titleSearchServlet.do` lists an issuer's documents, each carrying a direct PDF `FILE_LINK` on the portal.
# Like China the discovered document is a PDF, so a FilingHandle's `url` points at a `.pdf` that fetch_filing
# downloads for the shared PDF extractor. See docs/dev/hkex-plan.md.

"""
    HKEXFilings <: FilingSource

The HKEXnews portal disclosure API as a [`FilingSource`](@ref). **Keyless** — a browser User-Agent and an
HKEXnews Referer, no API key and no cookie bootstrap. Discovery is **by five-digit stock code or company
name** (see [`discover(::HKEXFilings)`](@ref)); each result carries a direct annual-report **PDF** URL that
[`fetch_filing`](@ref) downloads. Identity is `EntityId(:hkex, "00700")`, resolved from the query by
[`hkex_stock`](@ref).
"""
struct HKEXFilings <: FilingSource end

const _HKEX_PREFIX  = "$_HKEXNEWS_BASE/search/prefix.do"
const _HKEX_TITLE   = "$_HKEXNEWS_BASE/search/titleSearchServlet.do"

# A record field as a String, null/absent → "".
_hkex_str(r, k) = (v = get(r, k, nothing); v === nothing ? "" : string(v))

# An HKEXnews GET returning the raw body as a String (browser-headed, keyless).
function _hkex_get(url::AbstractString)
    body = fetch_url(url; headers = system_headers(HKEX()), cache_mode = effective_cache_mode(HKEX()))
    body === nothing && error("HKEXnews request failed: $url")
    return String(body)
end

# Strip a JSONP wrapper `callback(<json>);` to the bare JSON between the first '(' and the last ')'.
function _hkex_unjsonp(body::AbstractString)
    i = findfirst('(', body); j = findlast(')', body)
    (i === nothing || j === nothing || j <= i) && return body      # already bare JSON
    return body[nextind(body, i):prevind(body, j)]
end

"""
    hkex_stock(query) -> (code, stockId)

Resolve a five-digit stock `code` (e.g. `"00700"`) or a company name to HKEXnews's `(code, stockId)` pair
via the portal's live `prefix.do` autocomplete — the identity every `titleSearchServlet.do` query needs (the
`stockId`, e.g. `7609`, is HKEXnews's internal id). Keyless.

`prefix.do` exposes two indexes and NEITHER is complete: `type=A` is the live-issuer index (correct current
name + id for most codes — Tencent 00700 → 7609) but omits some issuers (Hang Seng Bank 00011 is absent);
`type=I` covers those (00011 → 18) but carries stale entries for others (00700 → the delisted "Yaohan"). So a
numeric code is matched by its **exact code** in `type=A` first, then `type=I` — and if neither index carries
that exact code we THROW, never silently return a different company (returning the first fuzzy hit is what once
resolved "0011" to the unrelated CFH/China~Fortune 00110). A name query prefers a hit whose name contains it.

```julia
hkex_stock("00700")   # -> ("00700", "7609")  (Tencent, via type=A)
hkex_stock("00011")   # -> ("00011", "18")    (Hang Seng Bank, via type=I fallback)
```
"""
function hkex_stock(query::AbstractString; market::AbstractString = "SEHK")
    q = strip(String(query))
    isempty(q) && throw(ArgumentError("hkex_stock needs a code or name"))
    _arr(typ) = (p = JSON3.read(_hkex_unjsonp(_hkex_get(string(_HKEX_PREFIX, "?callback=cb&lang=EN&type=", typ,
                     "&name=", HTTP.URIs.escapeuri(q), "&market=", market)))); get(p, :stockInfo, nothing))
    if occursin(r"^\d{1,5}$", q)                                  # numeric → five-digit code, matched EXACTLY
        q = lpad(q, 5, '0')
        for typ in ("A", "I")                                     # live-issuer index first, then the fallback index
            arr = _arr(typ)
            arr === nothing && continue
            for e in arr
                _hkex_str(e, :code) == q && return (q, _hkex_str(e, :stockId))
            end
        end
        throw(ArgumentError("no HKEXnews issuer carries stock code $(repr(q))"))
    end
    # name query: try both indexes; prefer a hit whose name contains the query, else the first hit
    ql = lowercase(q)
    for typ in ("A", "I")
        arr = _arr(typ)
        (arr === nothing || isempty(arr)) && continue
        for e in arr
            occursin(ql, lowercase(_hkex_str(e, :name))) && return (_hkex_str(e, :code), _hkex_str(e, :stockId))
        end
    end
    arr = _arr("A")
    (arr === nothing || isempty(arr)) && throw(ArgumentError("no HKEXnews match for $(repr(query))"))
    e = first(arr)
    return (_hkex_str(e, :code), _hkex_str(e, :stockId))
end

# Turn a parsed `titleSearchServlet.do` document array into report FilingHandles. PURE (no network) — testable
# offline against a saved query JSON. Keeps documents whose headline category matches `category` (the [Annual
# Report] or [Interim/Half-Year Report] subtype), dropping the paired [Summary Financial Report]. HK fiscal
# years VARY (Dec-31 is common but many issuers close 31 Mar / 30 Jun); the report year is parsed from the
# TITLE ("ANNUAL REPORT 2024") into a NOMINAL period end (`nominal` month/day — 31 Dec for an annual report,
# 30 Jun for an interim) — the exact fiscal date is recovered from the statements at extraction. Newest first.
function _hkex_report_handles(records, code::AbstractString, stockId::AbstractString;
                              category::Regex, nominal::Tuple{Int,Int})
    ent = EntityId(:hkex, code)
    handles = FilingHandle[]
    for r in records
        long = _hkex_str(r, :LONG_TEXT)
        occursin(category, long) || continue                      # the target category subtype
        occursin("Summary", long) && continue                     # drop the Summary Financial Report
        link = _hkex_str(r, :FILE_LINK); isempty(link) && continue
        title = _hkex_str(r, :TITLE)
        m = match(r"\b((?:19|20)\d{2})\b", title)
        m === nothing && (m = match(r"\b((?:19|20)\d{2})\b", long))
        pend = m === nothing ? nothing : Date(parse(Int, m.captures[1]), nominal[1], nominal[2])
        ref = _hkex_str(r, :NEWS_ID); isempty(ref) && (ref = basename(link))
        url = startswith(link, "http") ? link : string(_HKEXNEWS_BASE, link)
        push!(handles, FilingHandle(; system = HKEX(), entity = ent, ref = ref,
              url = url, period_end = pend, country = "HK"))
    end
    sort!(handles; by = h -> something(h.period_end, Date(0)), rev = true)
    return handles
end

"""
    discover(::HKEXFilings; code=nothing, name=nothing, market=:sehk, from=nothing, to=nothing,
             years=8, rowrange=100) -> Vector{FilingHandle}

List a company's periodic-report filings from HKEXnews, by five-digit stock `code` (e.g. `"00700"`) or company
`name`. `report` selects the form: `:annual` (the annual report, default) or `:interim` (the interim /
half-year report) — both full HKFRS statement sets, same seam and extractor. The issuer is resolved to its
`(code, stockId)` via [`hkex_stock`](@ref); `market` selects the board (`:sehk` Main Board, `:gem`). The date
window is `[from, to]` (`Date`s or `"YYYY-MM-DD"` strings); by default the last `years` (8) up to today. Returns
[`FilingHandle`](@ref)s tagged `HKEX()`, newest first — each `url` a direct **PDF** on `www1.hkexnews.hk`; fetch
one with [`fetch_filing`](@ref). Keyless — no API key and no cookie bootstrap.

```julia
hs = discover(HKEXFilings(); code = "00700")                    # Tencent annual reports, newest first
hi = discover(HKEXFilings(); code = "00700", report = :interim) # …its half-year reports
f  = fetch_filing(first(hs))                                    # downloads the HKFRS PDF
```
"""
function discover(::HKEXFilings; code=nothing, name=nothing, market::Symbol=:sehk,
                  from=nothing, to=nothing, years::Int=8, rowrange::Int=100, report::Symbol=:annual)
    q = code !== nothing ? String(code) : name !== nothing ? String(name) : nothing
    q === nothing && throw(ArgumentError("discover(HKEXFilings(); …) needs a `code` or `name`"))
    # form → (title text search, LONG_TEXT category match, nominal period-end month/day)
    title, category, nominal =
        report === :annual  ? ("Annual Report",  r"Annual Report",     (12, 31)) :
        report === :interim ? ("Interim Report", r"Interim|Half-Year", (6, 30))  :
        throw(ArgumentError("discover(HKEXFilings(); report=…) must be :annual or :interim, got $(repr(report))"))
    mkt = uppercase(String(market))
    sec, stockId = hkex_stock(q; market = mkt)
    isempty(stockId) && throw(ArgumentError("could not resolve an HKEXnews stockId for $(repr(q))"))

    _asdate(x, dflt) = x === nothing ? dflt : (x isa Date ? x : Date(String(x)))
    hi = _asdate(to, Dates.today())
    lo = _asdate(from, hi - Dates.Year(years))
    fmt(d) = Dates.format(d, dateformat"yyyymmdd")

    url = string(_HKEX_TITLE, "?sortDir=0&sortByOptions=DateTime&category=0&market=", mkt,
                 "&stockId=", stockId, "&documentType=-1",
                 "&fromDate=", fmt(lo), "&toDate=", fmt(hi),
                 "&title=", HTTP.URIs.escapeuri(title), "&searchType=1",
                 "&t1code=-2&t2Gcode=-2&t2code=-2&rowRange=", rowrange, "&lang=E")
    outer = JSON3.read(_hkex_get(url))
    result = get(outer, :result, nothing)
    (result === nothing || isempty(string(result))) && return FilingHandle[]
    records = JSON3.read(String(result))                          # result is a JSON-encoded string
    return _hkex_report_handles(records, sec, stockId; category, nominal)
end

# ── fetch → PDF Filing ──────────────────────────────────────────────────────────────────────────
# An HKEX filing is a PDF, so fetch_filing downloads the annual-report PDF (or takes a local path) and builds
# a `:pdf` Filing whose `content` is the on-disk path — the contract the shared PDF extractor consumes
# (`facts(f)` → extract_pdf; `narratives(f)` → structured_document).

# On-disk path for a downloaded HKEXnews PDF, under HKEX's cache dir. Keyed on the FILE_LINK basename
# (portal basenames like "2025040800667.pdf" are date+sequence and globally unique), so a re-fetch is a no-op.
function _hkex_pdf_path(src::AbstractString)
    name = basename(src)
    (isempty(name) || !occursin('.', name)) && (name = string(isempty(name) ? "hkex" : name, ".pdf"))
    return joinpath(get_cache_dir(effective_cache_mode(HKEX())), "hkex", name)
end

"""
    fetch_filing(::HKEX, src; entity=nothing, ref="") -> Filing

Fetch a Hong Kong annual report into a `:pdf` [`Filing`](@ref). `src` is an HKEXnews PDF URL (from
[`discover(::HKEXFilings)`](@ref)) or a local PDF path; the bytes are saved under HKEX's cache dir and the
Filing's `content` is that on-disk path — the source the shared PDF extractor reads. `entity` defaults from
discovery (the `:hkex` code).
"""
function fetch_filing(::HKEX, src::AbstractString; entity::Union{EntityId,Nothing}=nothing, ref::AbstractString="")
    path = if isfile(src)
        src
    else
        p = _hkex_pdf_path(src)
        if !isfile(p)
            bytes = fetch_url(src; headers = system_headers(HKEX()), use_cache = false,
                              cache_mode = effective_cache_mode(HKEX()))
            bytes === nothing && error("could not fetch HKEXnews PDF $(repr(src))")
            mkpath(dirname(p)); write(p, bytes)
        end
        p
    end
    ent = entity === nothing ? EntityId(:hkex, "") : entity
    return Filing(HKEX(), ent, isempty(ref) ? basename(src) : String(ref), basename(path), src, :pdf, path)
end

# Fetch a discovered handle: download the annual-report PDF at `h.url` and build the :pdf Filing, carrying the
# discovered `:hkex` identity and reference.
fetch_filing(::HKEX, h::FilingHandle) = fetch_filing(HKEX(), h.url; entity = h.entity, ref = h.ref)
