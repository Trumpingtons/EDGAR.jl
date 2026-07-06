# Russia discovery (R2) — the RFSD dataset as a FilingSource. Unlike every other system, discovery here
# is NOT a document listing: identity is resolved (a name/ticker → INN through the open MOEX ISS API, or
# a direct INN), and a "filing" is one (inn, year) row of the year-partitioned RFSD parquet. `discover`
# returns a FilingHandle whose `url` is the parquet partition and whose entity is the INN; `fetch_filing`
# runs the DuckDB query (the weakdep `_rfsd_query`, in EDGARDuckDBExt) to read that firm-year row and wrap
# it as an `:ras` Filing. See docs/dev/russia-plan.md and the manual chapter `sys:russia`.

"""
    RFSDFilings <: FilingSource

The **RFSD** (Russian Financial Statements Database) as a [`FilingSource`](@ref) — the route-1 door to
Russian **RAS** facts. Discovery resolves a filer to its **INN** (taxpayer number): pass a bare `inn`, or
a company `name` / `ticker` that the open, keyless **MOEX ISS** API resolves to one (`emitent_inn`). Each
[`discover`](@ref) call returns a [`FilingHandle`](@ref) for one `(inn, year)` row; [`fetch_filing`](@ref)
reads it from the year-partitioned RFSD parquet with DuckDB into an `:ras` [`Filing`](@ref).

```julia
h = only(discover(RFSDFilings(); ticker = "GAZP", year = 2023))   # Gazprom → its INN
facts(fetch_filing(h))                                            # RAS facts, one per OKUD line
```

The RFSD covers the **non-financial** universe only (banks/insurers are a separate CBR route). Reading it
needs DuckDB — run `using DuckDB` before `fetch_filing`.
"""
struct RFSDFilings <: FilingSource end

# The RFSD parquet on HuggingFace: year-partitioned `RFSD/year=YYYY/part-0.parquet`. The latest fully
# verified partition; a caller can pass any `year` in 2011..2024.
const _RFSD_HF_BASE   = "https://huggingface.co/datasets/irlspbru/RFSD/resolve/main/RFSD"
const RFSD_LATEST_YEAR = 2023

_rfsd_partition_url(year::Integer) = "$_RFSD_HF_BASE/year=$year/part-0.parquet"

# ── Local / cached partitions (R2c, bulk) ────────────────────────────────────────────────────────
# By default a query reads the remote parquet over httpfs. For repeated or bulk reads, either point at an
# existing local RFSD dataset (`set_rfsd_local(dir)`) or download a year once (`rfsd_download(year)`) into
# the cache dir (default `~/EDGAR-Reports/rfsd/`). `_rfsd_partition(year)` resolves local → cache → remote;
# DuckDB reads a local parquet path directly (no httpfs), so cached/local scans are fast and offline.
const _RFSD_LOCAL     = Ref{Union{Nothing,String}}(nothing)
const _RFSD_CACHE_DIR = Ref{String}("")

_rfsd_cache_dir() = isempty(_RFSD_CACHE_DIR[]) ? joinpath(homedir(), "EDGAR-Reports", "rfsd") : _RFSD_CACHE_DIR[]
_rfsd_rel(year::Integer) = joinpath("year=$year", "part-0.parquet")
_rfsd_cache_path(year::Integer) = joinpath(_rfsd_cache_dir(), _rfsd_rel(year))

"""
    set_rfsd_local(dir) / set_rfsd_local(nothing)

Use an existing local RFSD dataset for all queries — `dir` is laid out like the dataset
(`dir/year=YYYY/part-0.parquet`). Highest priority in partition resolution; `nothing` clears it.
"""
set_rfsd_local(dir::AbstractString) = (_RFSD_LOCAL[] = String(dir))
set_rfsd_local(::Nothing) = (_RFSD_LOCAL[] = nothing)

"""
    set_rfsd_cache_dir(dir)

Set the directory where [`rfsd_download`](@ref) stores downloaded partitions (default `~/EDGAR-Reports/rfsd/`).
"""
set_rfsd_cache_dir(dir::AbstractString) = (_RFSD_CACHE_DIR[] = String(dir))

# The parquet a read should use: a local-dataset file, else a cached file, else the remote URL.
function _rfsd_partition(year::Integer)
    for base in (_RFSD_LOCAL[], _rfsd_cache_dir())
        base === nothing && continue
        p = joinpath(base, _rfsd_rel(year))
        isfile(p) && return p
    end
    return _rfsd_partition_url(year)
end

"""
    rfsd_download(year) -> String

Download the RFSD `year` partition once (~550 MB) into the cache dir and return its local path (a no-op if
already present). Subsequent point / population / batch queries for that year then read the local file ---
fast and offline. Needs `using DuckDB`.
"""
function rfsd_download(year::Integer)
    dest = _rfsd_cache_path(year)
    isfile(dest) && return dest
    mkpath(dirname(dest))
    @info "Downloading RFSD year=$year partition (~550 MB) → $dest"
    _rfsd_download(_rfsd_partition_url(year), dest)
    return dest
end

# Resolve a company name or ticker to its INN via the open MOEX ISS securities API. Returns a
# NamedTuple `(inn, secid, title)` or `nothing`. Prefers an exact ticker (secid) match; else the first
# hit that carries an `emitent_inn`. Keyless — only the Russia browser headers.
function _moex_resolve_inn(query::AbstractString)
    url = "$_MOEX_ISS_BASE/iss/securities.json?q=$(HTTP.escapeuri(query))&iss.meta=off&limit=50"
    j = _get_json(url; headers = system_headers(Russia()))
    sec = j.securities
    cols = String.(sec.columns)
    idx = Dict(c => i for (i, c) in enumerate(cols))
    haskey(idx, "emitent_inn") || return nothing
    col(r, name) = (i = get(idx, name, 0); i == 0 ? nothing : r[i])
    best = nothing
    for r in sec.data
        inn = col(r, "emitent_inn")
        (inn === nothing || isempty(string(inn))) && continue
        hit = (inn = string(inn), secid = string(something(col(r, "secid"), "")),
               title = string(something(col(r, "emitent_title"), "")))
        uppercase(hit.secid) == uppercase(query) && return hit   # exact ticker wins
        best === nothing && (best = hit)
    end
    return best
end

# The RFSD dimension columns a population query filters on (name => the caller kwarg). Sector, legal form,
# ownership and geography — the OK-classifier axes. Matches are exact code equality.
const _RFSD_DIM_KWARGS = (:okved, :okved_section, :okopf, :okfc, :okogu, :region, :region_taxcode, :oktmo)

"""
    discover(::RFSDFilings; <point | population>; year=RFSD_LATEST_YEAR,
             filed=true, eligible=true, outlier=false, limit=100)

Return [`FilingHandle`](@ref)s for RFSD `(inn, year)` rows, in one of **two modes**:

- **Point** — one firm: pass `inn`, or a `name` / `ticker` resolved to an INN via MOEX ISS. Returns a
  one-element vector.
- **Population** — a cohort: pass one or more **dimension axes** — `okved` / `okved_section` (industry),
  `okopf` (legal form), `okfc` / `okogu` (ownership), `region` / `region_taxcode` / `oktmo` (geography) —
  and a single DuckDB scan enumerates the matching INNs (needs `using DuckDB`). The `filed` / `eligible` /
  `outlier` predicates default to a sound population (`filed & eligible & !outlier`) — which also excludes
  the withheld `filed=0` strategic firms — and `limit` bounds the result (a `@warn` fires if it is hit).

Point identity and population axes are mutually exclusive.

```julia
discover(RFSDFilings(); ticker = "GAZP", year = 2023)          # point
discover(RFSDFilings(); okved = "46.71", year = 2023, limit = 50)  # population: a sector cohort
```
"""
function discover(::RFSDFilings; inn=nothing, name=nothing, ticker=nothing,
                  year::Integer=RFSD_LATEST_YEAR, limit::Integer=100,
                  filed::Bool=true, eligible::Bool=true, outlier::Bool=false, dimkw...)
    dims = Dict{String,String}()
    for (k, v) in pairs(dimkw)
        k in _RFSD_DIM_KWARGS ||
            throw(ArgumentError("unknown discover keyword `$k` (RFSD axes: $(join(_RFSD_DIM_KWARGS, ", ")))"))
        v === nothing || (dims[String(k)] = string(v))
    end
    point = inn !== nothing || name !== nothing || ticker !== nothing
    url = _rfsd_partition_url(year)
    mkhandle(s) = FilingHandle(; system = Russia(), entity = EntityId(:inn, string(s)),
                               ref = "rfsd:$s:$year", url = url,
                               period_end = Date(year, 12, 31), country = "RU")

    if !isempty(dims)                                    # ── population ──
        point && throw(ArgumentError("discover(RFSDFilings(); …): give point identity " *
                                     "(inn/name/ticker) OR population axes, not both."))
        preds = (filed = filed, eligible = eligible, outlier = outlier)
        inns = _rfsd_discover(url, dims, preds, Int(limit))
        length(inns) ≥ limit &&
            @warn "RFSD population hit limit=$limit — narrow the axes or raise `limit` to see more."
        return [mkhandle(s) for s in inns]
    end
                                                         # ── point ──
    resolved = if inn !== nothing
        string(inn)
    elseif name !== nothing || ticker !== nothing
        q = string(something(name, ticker))
        r = _moex_resolve_inn(q)
        r === nothing && error("MOEX ISS could not resolve an INN for \"$q\" " *
                               "(unlisted names are not resolvable — pass `inn` directly).")
        r.inn
    else
        throw(ArgumentError("discover(RFSDFilings(); …) needs a point identity (`inn`/`name`/`ticker`) " *
                            "or population axes (`okved`, `region`, …)."))
    end
    return [mkhandle(resolved)]
end

# Fetch: read the (inn, year) row from the parquet partition (DuckDB, via the weakdep `_rfsd_query`) and
# wrap it as an `:ras` Filing whose JSON content the shared `_rfsd_facts` path (R1) turns into Facts.
function fetch_filing(::Russia, h::FilingHandle; allow_outliers::Bool=false)
    h.entity.scheme === :cbr_regnum && return _cbr_fetch(h)      # route 2 — CBR bank Form 101/102 (C2)
    inn  = h.entity.value
    yr   = h.period_end === nothing ? RFSD_LATEST_YEAR : year(h.period_end)
    json = _rfsd_query(_rfsd_partition(yr), inn, yr)
    isempty(json) && error("no RFSD row for INN $inn in year=$yr (non-financial filers only; " *
                           "check the INN, or try another year).")
    (!allow_outliers && _rfsd_json_outlier(json)) &&
        error("RFSD flags INN $inn (year=$yr) as anomalous (outlier=1); the authors recommend excluding " *
              "these ~436 firms. Pass allow_outliers=true to fetch it anyway.")
    return Filing(Russia(), h.entity, h.ref, "rfsd-$inn-$yr.json", h.url, :ras, json)
end

"""
    fetch_filing(::Russia, hs::AbstractVector{FilingHandle}) -> Vector{Filing}

Batch-fetch a whole cohort in **one** parquet scan per year (`WHERE inn IN (…)`) — the efficient path for a
population [`discover`](@ref) result, instead of one point query per firm. Returns an `:ras` [`Filing`](@ref)
for each handle that has a row (firms absent from the partition are dropped). Reads a local / cached
partition when available (see [`rfsd_download`](@ref)).
"""
function fetch_filing(::Russia, hs::AbstractVector{FilingHandle}; allow_outliers::Bool=false)
    isempty(hs) && return Filing[]
    all(h -> h.entity.scheme === :cbr_regnum, hs) &&        # route 2 — no batch scan; fetch each bank form
        return Filing[_cbr_fetch(h) for h in hs]
    byyear = Dict{Int,Vector{FilingHandle}}()
    for h in hs
        yr = h.period_end === nothing ? RFSD_LATEST_YEAR : year(h.period_end)
        push!(get!(byyear, yr, FilingHandle[]), h)
    end
    out = Filing[]; dropped = 0
    for (yr, hh) in byyear
        rows = _rfsd_query_many(_rfsd_partition(yr), String[h.entity.value for h in hh], yr)  # inn => JSON
        for h in hh
            json = get(rows, h.entity.value, "")
            isempty(json) && continue
            if !allow_outliers && _rfsd_json_outlier(json)
                dropped += 1; continue                       # author-flagged anomalous → excluded
            end
            push!(out, Filing(Russia(), h.entity, h.ref, "rfsd-$(h.entity.value)-$yr.json",
                              h.url, :ras, json))
        end
    end
    dropped > 0 &&
        @info "RFSD batch fetch dropped $dropped anomalous (outlier=1) firm-year(s); pass allow_outliers=true to keep them."
    return out
end
