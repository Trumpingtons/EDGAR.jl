# DART discovery — the OpenDART REST API (opendart.fss.or.kr) as a `FilingSource`. Unlike EDINET's
# date-only listing, DART has a clean entity resolver (`corpCode.xml`: corp_code ↔ stock_code ↔ name), so
# discovery is **by company** (`corp_code` / `stock_code`) over a date range, via `/list.json`. Each result's
# `rcept_no` resolves to a `fnlttXbrl` ZIP-acquisition URL (the financial-statement XBRL) that fetch_filing
# downloads. Shapes verified against the OpenDART spec + dart-fss (2026-06); see docs/dev/dart-plan.md.

"""
    OpenDARTApi <: FilingSource

The OpenDART REST API as a [`FilingSource`](@ref). Requires a free `crtfc_key` — set it with
`set_credentials(DART(); api_key = "…")` (or the `DART_API_KEY` / `OPENDART_API_KEY` environment
variable). Discovery is **by company** over a date range (see [`discover(::OpenDARTApi)`](@ref)); resolve
a name/ticker to a `corp_code` with [`dart_corp_code`](@ref).
"""
struct OpenDARTApi <: FilingSource end

_dart_date(x) = x === nothing ? nothing : (x isa Date ? x : Date(String(x), dateformat"yyyymmdd"))

# Period-end guess from a Korean report name like "사업보고서 (2023.12)" → 2023-12-31 (best-effort; the
# list endpoint carries no explicit period_end). Returns nothing if no (YYYY.MM) is present.
function _dart_period(report_nm::AbstractString)
    m = match(r"\((\d{4})\.(\d{2})\)", report_nm)
    m === nothing && return nothing
    y, mo = parse(Int, m.captures[1]), parse(Int, m.captures[2])
    return Date(y, mo, daysinmonth(Date(y, mo, 1)))
end

"""
    discover(::OpenDARTApi; corp_code=nothing, stock_code=nothing, bgn_de, end_de=nothing,
             pblntf_ty="A", reprt_code="11011", annual_only=true) -> Vector{FilingHandle}

List OpenDART disclosures for a company over `[bgn_de, end_de]` (`Date`s or `"YYYYMMDD"` strings),
narrowed by `corp_code` (8-digit DART code) **or** `stock_code` (6-digit KRX ticker; resolved to a
`corp_code` via [`dart_corp_code`](@ref)). `pblntf_ty="A"` = periodic disclosure (annual/half/quarter
reports). With `annual_only=true` (default) only 사업보고서 (annual business reports) are kept. Returns
[`FilingHandle`](@ref)s tagged `DART()`, each carrying the `fnlttXbrl` ZIP-acquisition URL for
`reprt_code` (default `"11011"` = annual); fetch one with [`fetch_filing`](@ref). Requires a key.

```julia
hs = discover(OpenDARTApi(); stock_code = "005930", bgn_de = "20240101", end_de = "20241231")  # Samsung
f  = fetch_filing(first(hs))
facts(f; classify = true)
```
"""
function discover(::OpenDARTApi; corp_code=nothing, stock_code=nothing, bgn_de, end_de=nothing,
                  pblntf_ty::AbstractString="A", reprt_code::AbstractString="11011", annual_only::Bool=true)
    cc = corp_code !== nothing ? String(corp_code) :
         stock_code !== nothing ? dart_corp_code(String(stock_code)) : nothing
    cc === nothing && throw(ArgumentError("discover(OpenDARTApi(); …) needs a corp_code or stock_code"))

    bgn = _dart_date(bgn_de); ed = _dart_date(end_de)
    url = _dart_url("list.json"; corp_code = cc,
                    bgn_de = Dates.format(bgn, dateformat"yyyymmdd"),
                    end_de = ed === nothing ? nothing : Dates.format(ed, dateformat"yyyymmdd"),
                    pblntf_ty = pblntf_ty, page_count = 100)
    doc = _get_json(url; headers = system_headers(DART()), cache_mode = effective_cache_mode(DART()))
    _str(get(doc, :status, nothing)) == "000" ||
        error("OpenDART list error: $(_str(get(doc, :message, "unknown")))")

    handles = FilingHandle[]
    for r in get(doc, :list, ())
        report_nm = _str(get(r, :report_nm, nothing))
        (!annual_only || occursin("사업보고서", report_nm)) || continue
        rcept = _str(get(r, :rcept_no, nothing)); isempty(rcept) && continue
        push!(handles, FilingHandle(; system = DART(),
              entity = EntityId(:corp_code, cc),
              ref = rcept,
              url = _dart_url("fnlttXbrl.xml"; rcept_no = rcept, reprt_code = reprt_code),
              period_end = _dart_period(report_nm),
              country = "KR"))
    end
    sort!(handles; by = h -> something(h.period_end, Date(0)), rev = true)
    return handles
end

# Fetch from a discovered handle: download the authenticated fnlttXbrl ZIP and route to the offline parser.
fetch_filing(::DART, h::FilingHandle) = fetch_filing(DART(), h.url; entity = h.entity, ref = h.ref)

# ── corp_code resolver (the index EDINET lacked) ────────────────────────────────────────────────────
# OpenDART's `/corpCode.xml` returns a ZIP containing CORPCODE.xml — the full corp_code ↔ stock_code ↔
# name mapping for EVERY Korean entity (~100k `<list>` rows). The key (corp_code) is what every other
# endpoint takes; stock_code (6-digit KRX) is the public ticker. Two caches keep this off the hot path:
# the parsed index is held in-process (`_DART_CORP_INDEX`) AND persisted to disk as TSV
# (`_dart_index_path`), so a fresh session skips both the slow download and the parse. The download
# itself is also HTTP-cached by `fetch_url`. Parsing is a single linear `eachelement` pass — NOT a
# per-row XPath query (`findfirst(tag, node)` over 100k rows is pathologically slow).

const _DART_CORPCODE = NamedTuple{(:corp_code,:corp_name,:stock_code),Tuple{String,String,String}}
const _DART_CORP_INDEX = Ref{Union{Nothing,Vector{_DART_CORPCODE}}}(nothing)

# Backstop staleness for the on-disk index: the corp_code↔stock_code mapping is stable (new *listings*
# are the only meaningful change, and `dart_corp_code`'s miss-refresh catches those), so the index does
# NOT follow the global 24h HTTP `cache_ttl` — re-downloading a 5-minute file daily would be wasteful.
# Instead it is rebuilt only when older than this jurisdiction-specific TTL (default 30 days), tunable.
const _DART_INDEX_TTL = Ref{Int}(30 * 24 * 3600)

"""
    dart_index_ttl!(days::Real) -> Int

Set the backstop staleness (in days) of the on-disk OpenDART corp-code index — past this age it is
re-downloaded + reparsed on next use (default **30 days**). Lower it if you need newly-listed companies
picked up sooner without relying on the automatic miss-refresh in [`dart_corp_code`](@ref). Returns the
new TTL in seconds.

```julia
dart_index_ttl!(7)     # refresh the corp-code index if older than a week
```
"""
dart_index_ttl!(days::Real) = (_DART_INDEX_TTL[] = round(Int, days * 24 * 3600))

# On-disk location of the parsed index (TSV). Follows DART's effective cache mode (N6) — so it lands in
# the persistent root (`~/.cache/EDGAR.jl`) only when DART is `:persistent`, and a per-process temp dir
# otherwise, exactly like every other DART download. corpCode.xml is rarely-changing reference data whose
# download is very slow (OpenDART throttles it, minutes), so persisting it (one `set_cache_policy(DART();
# cache=:persistent)`) means the multi-minute fetch + parse is paid once, ever, across all later sessions.
_dart_index_path() = joinpath(get_cache_dir(effective_cache_mode(DART())), "dart_corpcode_index.tsv")

# Parse CORPCODE.xml → rows, in ONE linear pass over `<result>`'s `<list>` children (no XPath per row).
function _dart_parse_corpcode(xml::AbstractString)
    doc = EzXML.parsexml(xml)
    out = _DART_CORPCODE[]
    for ln in EzXML.eachelement(EzXML.root(doc))
        EzXML.nodename(ln) == "list" || continue
        cc = nm = sc = ""
        for fld in EzXML.eachelement(ln)
            t = EzXML.nodename(fld)
            if     t == "corp_code";  cc = strip(EzXML.nodecontent(fld))
            elseif t == "corp_name";  nm = strip(EzXML.nodecontent(fld))
            elseif t == "stock_code"; sc = strip(EzXML.nodecontent(fld))
            end
        end
        push!(out, (corp_code = cc, corp_name = nm, stock_code = sc))
    end
    return out
end

_dart_write_index_tsv(path, idx) = open(path, "w") do io
    for e in idx; println(io, e.corp_code, '\t', e.corp_name, '\t', e.stock_code); end
end

function _dart_read_index_tsv(path)
    out = _DART_CORPCODE[]
    for line in eachline(path)
        p = split(line, '\t')
        length(p) >= 3 && push!(out, (corp_code = String(p[1]), corp_name = String(p[2]), stock_code = String(p[3])))
    end
    return out
end

# Load (and cache) the corp-code index: in-process → on-disk TSV (if within the TTL) → download+parse
# (then persist). `force=true` bypasses every cache layer (in-process, disk, and the HTTP cache) for a
# fresh network rebuild — used by the manual/miss refresh in `dart_corp_code`.
function _dart_corp_index(; force::Bool=false)
    force || _DART_CORP_INDEX[] === nothing || return _DART_CORP_INDEX[]
    use_disk = effective_cache_mode(DART()) !== :off
    p = _dart_index_path()
    if !force && use_disk && isfile(p) && (time() - mtime(p) <= _DART_INDEX_TTL[])
        idx = try _dart_read_index_tsv(p) catch; _DART_CORPCODE[] end
        if !isempty(idx); _DART_CORP_INDEX[] = idx; return idx; end
    end
    z = ZipReader(_dart_zip_bytes(_dart_url("corpCode.xml"); use_cache = !force))
    names = _rp_names(z)
    xi = findfirst(n -> endswith(lowercase(n), ".xml"), names)
    xi === nothing && error("corpCode.xml ZIP has no XML entry")
    idx = _dart_parse_corpcode(_rp_read(z, names[xi]))
    use_disk && try mkpath(dirname(p)); _dart_write_index_tsv(p, idx) catch end   # persist (timestamp = now)
    _DART_CORP_INDEX[] = idx
    return idx
end

# 6-digit numeric → match stock_code; otherwise match the company name.
_dart_match(idx, q) = occursin(r"^\d{6}$", q) ?
    filter(e -> e.stock_code == q, idx) : filter(e -> e.corp_name == q, idx)

"""
    dart_corp_code(query; refresh=false) -> String

Resolve a 6-digit KRX `stock_code` or a company name to its 8-digit OpenDART `corp_code` (the key every
other OpenDART endpoint takes), using the cached `corpCode.xml` index. Throws if no unique match. Requires
a key (the index is itself an OpenDART download).

The index is rebuilt only when older than its TTL (default 30 days, see [`dart_index_ttl!`](@ref)). As a
self-heal for newly-listed companies, a **ticker** (6-digit) lookup that misses triggers ONE fresh
re-download and retry — so a just-listed firm absent from a month-old index still resolves. (Name misses
do not auto-refresh, as they are usually spelling variance, not new listings.) Pass `refresh=true` to
force a fresh index regardless.

```julia
dart_corp_code("005930")              # → "00126380"  (Samsung Electronics)
dart_corp_code("000660"; refresh=true) # force a fresh corpCode.xml first
```
"""
function dart_corp_code(query::AbstractString; refresh::Bool=false)
    q = strip(query)
    idx = _dart_corp_index(; force = refresh)
    hits = _dart_match(idx, q)
    if isempty(hits) && !refresh && occursin(r"^\d{6}$", q)   # ticker miss → maybe a new listing: refresh once
        idx = _dart_corp_index(; force = true)
        hits = _dart_match(idx, q)
    end
    isempty(hits) && throw(ArgumentError("no OpenDART corp_code for $(repr(query))"))
    length(hits) > 1 && throw(ArgumentError("ambiguous OpenDART query $(repr(query)) — $(length(hits)) matches"))
    return first(hits).corp_code
end
