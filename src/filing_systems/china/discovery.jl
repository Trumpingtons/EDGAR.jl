# China discovery (C1) — the CNINFO portal as a keyless FilingSource. Two POST JSON endpoints,
# browser-headed, no key and no cookie bootstrap: `topSearch` resolves a 6-digit code or company name to a
# {code, orgId} pair (CNINFO's live per-query analogue of DART's bulk corpCode index), and `hisAnnouncement`
# lists a company's annual-report announcements, each carrying a direct PDF `adjunctUrl` on the static host.
# Unlike every other system the discovered document is a PDF, so a FilingHandle's `url` points at a `.PDF`
# that fetch_filing (C2) downloads for the PDF extractor. See docs/dev/china-plan.md.

"""
    CNINFOFilings <: FilingSource

The CNINFO national-portal disclosure API as a [`FilingSource`](@ref). **Keyless** — a browser
User-Agent and a CNINFO Referer, no API key and no cookie bootstrap. Discovery is **by six-digit exchange
code or company name** (see [`discover(::CNINFOFilings)`](@ref)); each result carries a direct annual-report
**PDF** URL that [`fetch_filing`](@ref) downloads. Identity is the packed
`EntityId(:cninfo, "code,orgId")`, resolved from the query by [`cninfo_org`](@ref).
"""
struct CNINFOFilings <: FilingSource end

const _CNINFO_TOPSEARCH = "$_CNINFO_BASE/new/information/topSearch/query"
const _CNINFO_HISANN    = "$_CNINFO_BASE/new/hisAnnouncement/query"

# CNINFO's annual-report category code; the same code serves all three boards.
const _CNINFO_CAT_ANNUAL = "category_ndbg_szsh"

# A CNINFO JSON POST: browser headers + the form content-type, body folded into the cache key by fetch_url.
# CNINFO's query layer is POST-only (a GET returns nothing), so this is the one shared request primitive.
function _cninfo_post_json(url::AbstractString, form::AbstractString)
    hdrs = copy(system_headers(China()))
    push!(hdrs, "Content-Type"     => "application/x-www-form-urlencoded; charset=UTF-8")
    push!(hdrs, "X-Requested-With" => "XMLHttpRequest")
    body = fetch_url(url; method = :POST, body = form, headers = hdrs,
                     cache_mode = effective_cache_mode(China()))
    body === nothing && error("CNINFO request failed: $url")
    return JSON3.read(body)
end

# A record field as a String, null/absent → "".
_cninfo_str(r, k) = (v = get(r, k, nothing); v === nothing ? "" : string(v))

# Board (the `column` query parameter) from the six-digit code's leading digit: SSE 6xxxxx; SZSE 0/3xxxxx
# (main/SME + ChiNext); Beijing 4/8/9xxxxx (NEEQ-origin, 8-series and the 920 series). Defaults to szse.
function _cninfo_board(code::AbstractString)
    isempty(code) && return "szse"
    c = first(code)
    c == '6'               ? "sse"  :
    (c == '0' || c == '3') ? "szse" :
    (c == '4' || c == '8' || c == '9') ? "bj" : "szse"
end

"""
    cninfo_org(query) -> (code, orgId)

Resolve a six-digit exchange `code` (e.g. `"000001"`) or a company name to CNINFO's `(code, orgId)` pair
via the portal's live `topSearch` autocomplete — the identity every `hisAnnouncement` query needs (the
`orgId`, e.g. `"gssz0000001"`, is CNINFO's internal organisation id). For a six-digit query the exact-code
match is returned; for a name, the first hit. Throws if nothing matches. Keyless.

```julia
cninfo_org("000001")     # -> ("000001", "gssz0000001")  (Ping An Bank)
```
"""
function cninfo_org(query::AbstractString)
    q = strip(String(query))
    isempty(q) && throw(ArgumentError("cninfo_org needs a code or name"))
    arr = _cninfo_post_json(_CNINFO_TOPSEARCH, "keyWord=$(HTTP.URIs.escapeuri(q))&maxNum=10")
    (arr === nothing || isempty(arr)) && throw(ArgumentError("no CNINFO match for $(repr(query))"))
    if occursin(r"^\d{6}$", q)                       # exact six-digit code → match it explicitly
        for e in arr
            _cninfo_str(e, :code) == q && return (q, _cninfo_str(e, :orgId))
        end
    end
    e = first(arr)
    return (_cninfo_str(e, :code), _cninfo_str(e, :orgId))
end

# Turn a parsed `hisAnnouncement` announcements array into FilingHandles. PURE (no network) — testable
# offline against a saved query JSON. Drops the English and cancelled variants (a language duplicate / an
# invalid filing, matched on the title tokens below), then tags the report SCOPE and lets `prefer_statements`
# keep the best per year: the report SUMMARY (摘要) carries none of the detailed statements — a thin sibling
# of the full 年度报告 for the same fiscal year — so it is tagged `:summary` and drops out whenever the full
# report is present (and is still surfaced, honestly thin, for a filer who published only a summary). The
# fiscal year is parsed from the title — the four digits preceding the report-title token — into a 31-Dec
# period end (Chinese fiscal years end 31 December). Identity is the packed `:cninfo` code+orgId; url is the
# PDF on the static host. Newest first.
function _cninfo_annual_handles(records, sec::AbstractString, org::AbstractString)
    ent = EntityId(:cninfo, string(sec, ",", org))
    handles = FilingHandle[]
    for r in records
        title = _cninfo_str(r, :announcementTitle)
        occursin("年度报告", title) || continue
        (occursin("英文", title) || occursin("取消", title)) && continue   # language duplicate / cancelled: not a scope choice
        adj = _cninfo_str(r, :adjunctUrl); isempty(adj) && continue
        dt = occursin("摘要", title) ? :summary : :annual    # summary (thin) vs the full statements-bearing report
        m = match(r"(\d{4})年?年度报告", title)
        pend = m === nothing ? nothing : Date(parse(Int, m.captures[1]), 12, 31)
        ref = _cninfo_str(r, :announcementId); isempty(ref) && (ref = basename(adj))
        push!(handles, FilingHandle(; system = China(), entity = ent, ref = ref, url = string(_CNINFO_STATIC, "/", adj),
              period_end = pend, country = "CN", doc_type = dt))
    end
    sort!(handles; by = h -> something(h.period_end, Date(0)), rev = true)
    return prefer_statements(handles)
end

"""
    discover(::CNINFOFilings; code=nothing, name=nothing, board=:auto, from=nothing, to=nothing,
             years=8, pagesize=30) -> Vector{FilingHandle}

List a company's **annual-report** filings from CNINFO, by six-digit exchange `code` (e.g. `"000001"`) or
company `name`. The issuer is resolved to its `(code, orgId)` via [`cninfo_org`](@ref); `board` selects the
exchange `column` (`:auto` → detected from the code: `sse`/`szse`/`bj`). The date window is `[from, to]`
(`Date`s or `"YYYY-MM-DD"` strings); by default the last `years` (8) up to today. Returns
[`FilingHandle`](@ref)s tagged `China()`, newest first — each `url` a direct annual-report **PDF** on
`static.cninfo.com.cn`; fetch one with [`fetch_filing`](@ref) (C2). The paired report *summary* is
filtered out. Keyless — no API key and no cookie bootstrap.

```julia
hs = discover(CNINFOFilings(); code = "000001")   # Ping An Bank annual reports, newest first
f  = fetch_filing(first(hs))                        # downloads the CAS annual-report PDF (C2)
```
"""
function discover(::CNINFOFilings; code=nothing, name=nothing, board::Symbol=:auto,
                  from=nothing, to=nothing, years::Int=8, pagesize::Int=30)
    q = code !== nothing ? String(code) : name !== nothing ? String(name) : nothing
    q === nothing && throw(ArgumentError("discover(CNINFOFilings(); …) needs a `code` or `name`"))
    sec, org = cninfo_org(q)
    isempty(org) && throw(ArgumentError("could not resolve a CNINFO orgId for $(repr(q))"))
    col = board === :auto ? _cninfo_board(sec) : String(board)

    _asdate(x, dflt) = x === nothing ? dflt : (x isa Date ? x : Date(String(x)))
    hi = _asdate(to, Dates.today())
    lo = _asdate(from, hi - Dates.Year(years))
    seDate = string(Dates.format(lo, dateformat"yyyy-mm-dd"), "~", Dates.format(hi, dateformat"yyyy-mm-dd"))

    form = string("stock=", sec, ",", org, "&tabName=fulltext&pageNum=1&pageSize=", pagesize,
                  "&column=", col, "&category=", _CNINFO_CAT_ANNUAL, "&seDate=", seDate, "&isHLtitle=false")
    resp = _cninfo_post_json(_CNINFO_HISANN, form)
    records = get(resp, :announcements, nothing)
    records === nothing && return FilingHandle[]
    return _cninfo_annual_handles(records, sec, org)
end

# Fetch a discovered handle (C2): download the annual-report PDF at `h.url` and build the :pdf Filing,
# carrying the discovered `:cninfo` identity and reference.
fetch_filing(::China, h::FilingHandle) = fetch_filing(China(), h.url; entity = h.entity, ref = h.ref)
