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

"""
    discover(::RFSDFilings; inn=nothing, name=nothing, ticker=nothing, year=RFSD_LATEST_YEAR)

Resolve a Russian non-financial filer to a [`FilingHandle`](@ref) for its `(inn, year)` RFSD row. Pass a
bare `inn`, or a `name` / `ticker` resolved to an INN via MOEX ISS. Returns a one-element vector (the
handle), or throws if no INN can be resolved.
"""
function discover(::RFSDFilings; inn=nothing, name=nothing, ticker=nothing,
                  year::Integer=RFSD_LATEST_YEAR)
    resolved = if inn !== nothing
        string(inn)
    elseif name !== nothing || ticker !== nothing
        q = string(something(name, ticker))
        r = _moex_resolve_inn(q)
        r === nothing && error("MOEX ISS could not resolve an INN for \"$q\" " *
                               "(unlisted names are not resolvable — pass `inn` directly).")
        r.inn
    else
        throw(ArgumentError("discover(RFSDFilings(); …) needs one of `inn`, `name` or `ticker`."))
    end
    h = FilingHandle(; system = Russia(), entity = EntityId(:inn, resolved),
                     ref = "rfsd:$resolved:$year", url = _rfsd_partition_url(year),
                     period_end = Date(year, 12, 31), country = "RU")
    return [h]
end

# Fetch: read the (inn, year) row from the parquet partition (DuckDB, via the weakdep `_rfsd_query`) and
# wrap it as an `:ras` Filing whose JSON content the shared `_rfsd_facts` path (R1) turns into Facts.
function fetch_filing(::Russia, h::FilingHandle)
    inn  = h.entity.value
    yr   = h.period_end === nothing ? RFSD_LATEST_YEAR : year(h.period_end)
    json = _rfsd_query(h.url, inn, yr)
    isempty(json) && error("no RFSD row for INN $inn in year=$yr (non-financial filers only; " *
                           "check the INN, or try another year).")
    return Filing(Russia(), h.entity, h.ref, "rfsd-$inn-$yr.json", h.url, :ras, json)
end
