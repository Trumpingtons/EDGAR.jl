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
`url` (the source URL to fetch), and the discovery facets `period_end` and `country` (for choosing
among an entity's filings). Pass it straight to `fetch_filing(h)`.
"""
struct FilingHandle
    system::FilingSystem
    entity::EntityId
    ref::String
    url::String
    period_end::Union{Date,Nothing}
    country::String
end

FilingHandle(; system, entity, ref, url, period_end=nothing, country="") =
    FilingHandle(system, entity, ref, url, period_end, country)

Base.show(io::IO, h::FilingHandle) =
    print(io, "FilingHandle(", nameof(typeof(h.system)), ", ", h.entity,
          h.period_end === nothing ? "" : ", $(h.period_end)",
          isempty(h.country) ? "" : " [$(h.country)]", ")")

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
fetch_filing(h::FilingHandle) = fetch_filing(h.system, h)
