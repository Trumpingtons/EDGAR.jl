# Discovery: finding filings to fetch (the third axis — see docs/dev/filing-systems.md §5).
#
# Discovery is a separate axis from the FilingSystem: ONE source can feed MANY systems
# (filings.xbrl.org indexes ESEF + UKSEF + …; an EDINET/OpenDART/Companies-House API each feeds one).
# So the index abstraction is a `FilingSource` that yields system-tagged `FilingHandle`s — not an
# "ESEFIndex". A handle is the portable currency between discovery and fetch (N2/D2): it carries
# everything `fetch_filing` needs (which system, the filer's identity, the opaque filing reference,
# and a fetchable source URL), so a system's filing reference can stay an opaque token the core never
# has to understand.

"""
    FilingSource

A place filings can be *discovered* from — an aggregator or a per-system API. Concrete sources
implement [`discover`](@ref), which returns [`FilingHandle`](@ref)s tagged with the
[`FilingSystem`](@ref) each filing belongs to. One source may span several systems
(e.g. [`FilingsXBRLOrg`](@ref) covers ESEF and other XBRL-International regimes).
"""
abstract type FilingSource end

"""
    FilingHandle

A discovered, fetchable reference to one filing — the unit [`discover`](@ref) returns and
[`fetch_filing`](@ref) consumes. It is self-describing: `system` (the [`FilingSystem`](@ref) it
belongs to), `entity` (the filer's [`EntityId`](@ref)), `ref` (the system's opaque filing reference),
`url` (the source URL to fetch), and the discovery facets `period_end`, `country`, and `doc_type` (for
choosing among an entity's filings). Pass it straight to `fetch_filing(h)`.

`doc_type` names the document's *scope* — `:statements` (a dedicated financial-statements document),
`:annual` (a full annual report, which embeds the statements), `:integrated` / `:summary` (a thin
report that carries none of the detailed statements — the Vale case), or the neutral default `:report`.
Only this facet distinguishes competing documents for the same filer-period; [`prefer_statements`](@ref)
ranks by it. A source that leaves it at `:report` is unaffected.
"""
struct FilingHandle
    system::FilingSystem
    entity::EntityId
    ref::String
    url::String
    period_end::Union{Date,Nothing}
    country::String
    doc_type::Symbol
end

FilingHandle(; system, entity, ref, url, period_end=nothing, country="", doc_type=:report) =
    FilingHandle(system, entity, ref, url, period_end, country, doc_type)

Base.show(io::IO, h::FilingHandle) =
    print(io, "FilingHandle(", nameof(typeof(h.system)), ", ", h.entity,
          h.period_end === nothing ? "" : ", $(h.period_end)",
          isempty(h.country) ? "" : " [$(h.country)]",
          h.doc_type === :report ? "" : " <$(h.doc_type)>", ")")

# Document-scope preference. A source may surface, for ONE filer-period, several documents of different
# scope: a dedicated financial-statements document, the full annual report (which embeds the statements),
# and a thin integrated/summary report that carries none of the detailed statements (the Vale case — see the
# 2R.F document-scope guard in extractors/ifrs_pdf.jl, which returns no facts for such a report). The
# `doc_type` facet is the only thing that tells them apart. Rank: a dedicated `:statements` doc beats
# everything; an `:integrated`/`:summary` doc loses to anything else; every other type (`:annual`, `:report`,
# the default) is neutral. Only the highest-rank members of each (entity, period_end) group survive — so a
# source that leaves `doc_type` at its default has every handle neutral and is passed through untouched.
_doc_rank(t::Symbol) = t === :statements ? 2 :
                       (t === :integrated || t === :summary) ? 0 : 1

"""
    prefer_statements(handles) -> Vector{FilingHandle}

Collapse a filer's discovered [`FilingHandle`](@ref)s to the best-scoped document per reporting period.
When a source surfaces, for the same `(entity, period_end)`, both a document that bears the detailed
financial statements and one that does not, keep the former: a `:statements` document wins over all, and
an `:integrated`/`:summary` report loses to any sibling (an `:annual` report, or anything not so marked).
Input order is preserved, so a newest-first result stays newest-first. Handles left at the default
`:report` scope are all neutral, so an unclassified source is returned unchanged.

Use it inside a [`discover`](@ref) method after building the per-record handles (as `CNINFOFilings` does),
or on a merged handle list from several categories, to prefer the statements-bearing document.
"""
function prefer_statements(handles::AbstractVector{FilingHandle})
    isempty(handles) && return FilingHandle[]
    best = Dict{Tuple{EntityId,Union{Date,Nothing}},Int}()
    for h in handles
        k = (h.entity, h.period_end)
        r = _doc_rank(h.doc_type)
        best[k] = haskey(best, k) ? max(best[k], r) : r
    end
    return [h for h in handles if _doc_rank(h.doc_type) == best[(h.entity, h.period_end)]]
end

"""
    discover(source::FilingSource; kwargs...) -> Vector{FilingHandle}

Find filings from `source`, returning system-tagged [`FilingHandle`](@ref)s to fetch with
[`fetch_filing`](@ref). The accepted keywords depend on the source (e.g. [`FilingsXBRLOrg`](@ref)
takes `lei`, `country`, `year`). The result is the discovery half of the pipeline; `fetch_filing(h)`
is the fetch half.
"""
function discover end

"""
    fetch_filing(h::FilingHandle) -> Filing

Fetch a discovered filing into memory as a [`Filing`](@ref). Dispatches to the handle's
[`FilingSystem`](@ref) (e.g. ESEF downloads and reads the report-package ZIP at `h.url`), so a single
call resolves any handle [`discover`](@ref) produced regardless of which system it came from.
"""
fetch_filing(h::FilingHandle; kwargs...) = fetch_filing(h.system, h; kwargs...)

"""
    fetch_filing(hs::AbstractVector{FilingHandle}) -> Vector{Filing}

Fetch many discovered filings at once. Dispatches to the handles' [`FilingSystem`](@ref); the default
fetches each in turn, but a system may override with a batch path — e.g. Russia reads a whole RFSD cohort
in a single parquet scan (`WHERE inn IN (…)`) rather than one query per firm. System-specific keywords pass
through (e.g. Russia's `allow_outliers`).
"""
fetch_filing(hs::AbstractVector{FilingHandle}; kwargs...) =
    isempty(hs) ? Filing[] : fetch_filing(first(hs).system, hs; kwargs...)
fetch_filing(sys::FilingSystem, hs::AbstractVector{FilingHandle}; kwargs...) =
    Filing[fetch_filing(sys, h; kwargs...) for h in hs]

# ── Entity (company) search ────────────────────────────────────────────────────────────────────
# The step *before* discovery: finding the entity whose filings you then `discover`. Discovery keys
# off a filer identity (a CIK, a company number, an LEI); `company_search` turns a name or a set of
# criteria into those identities. Like `discover`, it is a generic verb dispatched on a
# `FilingSource`, returning a uniform, system-neutral row table so the same downstream code works
# whichever registry produced the hits.

"""
    CompanyHit

One row of a [`company_search`](@ref) result — a matched entity, system-neutral so every registry
returns the same shape. Fields: `name` (registered name), `id` (the system-tagged [`EntityId`](@ref),
e.g. `EntityId(:companies_house, "00445790")`; the bare identifier is `hit.id.value`), `status`
(e.g. `"active"`, `"dissolved"`), `type` (the registry's company-type code, e.g. `"plc"`, `"ltd"`),
`incorporated` (date of creation, or `nothing`), `sic` (Standard Industrial Classification codes,
possibly empty), `address` (a one-line registered-address snippet), and `country`.

The vector of `CompanyHit`s is a [Tables.jl](https://github.com/JuliaData/Tables.jl) row table, so it
drops straight into `DataFrames`, `CSV`, Arrow, or DuckDB, and indexes/slices as a plain `Vector`.
"""
const CompanyHit = @NamedTuple{name::String, id::EntityId, status::String, type::String,
                               incorporated::Union{Date,Nothing}, sic::Vector{String},
                               address::String, country::String}

"""
    company_search(source::FilingSource, query=""; kwargs...) -> Vector{CompanyHit}

Find entities (companies) in `source`'s registry by name and/or criteria, returning a uniform
[`CompanyHit`](@ref) row table. This is the lookup step before [`discover`](@ref): take a hit's
identity and pass it on (e.g. `discover(CompaniesHouseApi(); company_number = hit.id.value)`).

The accepted criteria depend on the source (e.g. [`CompaniesHouseApi`](@ref) takes `status`, `type`,
`sic`, `incorporated_from`/`incorporated_to`). Dispatched on the source, so each registry implements
its own method while callers get the same result shape.
"""
function company_search end
