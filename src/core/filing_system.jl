# The FilingSystem seam (see docs/dev/filing-systems.md).
#
# Each electronic financial-reporting system — US SEC EDGAR, EU ESEF, JP EDINET, UK Companies House,
# KR DART, … — is a subtype of `FilingSystem`. A system implements a SUBSET of three responsibilities
# (capability decomposition, D10):
#
#   • discover — find filings (per-system API / aggregator / OAM); some systems can't (private
#     tax-filing systems like HK IRD), expressed simply by defining no `discover` method for them.
#   • fetch    — retrieve a filing's bytes (loose files / report-package ZIP / single iXBRL / API).
#   • parse    — resolve XBRL contexts/units/facts. This is the COMMON CORE (extract_xbrl.jl) and is
#                NOT per-system: a new system supplies only its fetch/identity/linkbase-location slice.
#
# `parse` works on any iXBRL/XBRL document (validated against ESEF/IFRS, not just SEC us-gaap), so
# adding a system is mostly a fetch/identity adapter plus declaring which taxonomies it uses. The
# taxonomy axis (us-gaap / ifrs-full / … vocabularies) is orthogonal to the FilingSystem axis.
#
# Linkbase location is part of `fetch` and is per-system (N4/D5): SEC linkbases are sibling files in
# the Archives dir; ESEF/EDINET bundle them in the report-package ZIP; Companies House filings carry
# NO extension taxonomy at all, so their linkbase lookup must delegate to the published *standard*
# taxonomy for the concept's prefix. A per-system linkbase fetcher may therefore legitimately answer
# "not in the filing — use the standard taxonomy", which classification must tolerate.
abstract type FilingSystem end

"""
    SEC <: FilingSystem

The U.S. Securities and Exchange Commission's EDGAR system — the first (and, today, only)
[`FilingSystem`](@ref) implemented. (Named `SEC` rather than `EDGAR` in code to avoid clashing with
the `EDGAR` module; the system is EDGAR.)
"""
struct SEC <: FilingSystem end

"""
    EntityId(scheme::Symbol, value::AbstractString)

A filer's identity as a typed `(scheme, value)` pair — never a bare string, because identity schemes
differ per [`FilingSystem`](@ref) (and one entity may carry several): `:cik` (SEC), `:lei` (ESEF),
`:edinet` / `:corporate_number` (EDINET), `:companies_house` (UK), `:corp_code` / `:stock_code`
(DART), `:brn` (HK), … The scheme set is open-ended (a `Symbol`), so a new system adds *data*, not a
new type. `value` is stored as a `String`.

```julia
EntityId(:cik, "0000320193")     # Apple, on SEC EDGAR
EntityId(:lei, "529900T8BM49AURSDO55")
```
"""
struct EntityId
    scheme::Symbol
    value::String
end

Base.show(io::IO, id::EntityId) = print(io, id.scheme, ":", id.value)

# ── Per-system credentials & request headers (N3) ───────────────────────────────────────────────
#
# Each `FilingSystem` authenticates its HTTP requests differently: SEC requires a descriptive
# `User-Agent` (with contact info), while keyed APIs (Companies House, EDINET) require an API key. The
# credential *store* is `CREDENTIALS` in core/config.jl; the per-system *behaviour* lives here, where
# the `FilingSystem` types are defined. `system_tag` maps a system to its `CREDENTIALS` key;
# `set_credentials` writes; `get_credential` reads; `system_headers` turns stored credentials into the
# HTTP headers a request to that system needs. `fetch_url` will consult `system_headers` (C0 step 3);
# until then SEC keeps injecting its User-Agent directly.

"""
    system_tag(::FilingSystem) -> Symbol

The [`CREDENTIALS`](@ref)-registry key for a [`FilingSystem`](@ref) (e.g. `:sec`). A new system
defines its own one-line method (`:companies_house`, `:edinet`, …).
"""
system_tag(::SEC) = :sec

"""
    set_credentials(system::FilingSystem; kwargs...) -> Dict{Symbol,String}

Store the access credentials for a [`FilingSystem`](@ref) — the keyed values its API needs, passed as
keywords (e.g. `set_credentials(CompaniesHouse(); api_key = "…")`). Values are merged into any already
stored for that system and returned. Credentials are consumed by [`system_headers`](@ref) when a
request is made. For SEC, [`set_user_agent`](@ref) remains the dedicated entry point (the SEC needs
only a descriptive User-Agent, not a key).

```julia
set_credentials(CompaniesHouse(); api_key = "your-companies-house-key")
```
"""
function set_credentials(system::FilingSystem; kwargs...)
    store = get!(() -> Dict{Symbol,String}(), CREDENTIALS, system_tag(system))
    for (k, v) in kwargs
        store[k] = String(v)
    end
    return store
end

"""
    set_credentials(::SEC; user_agent) -> String

SEC's only "credential" is its descriptive `User-Agent` (the SEC needs no API key), which lives in its
dedicated config slot, not the `CREDENTIALS` registry. This method routes to [`set_user_agent`](@ref)
so the unified `set_credentials` API also covers SEC and the User-Agent is validated/stored the one
correct way; [`set_user_agent`](@ref) remains the direct SEC entry point. Returns the stored value.
"""
function set_credentials(::SEC; user_agent=nothing)
    user_agent === nothing &&
        throw(ArgumentError("set_credentials(SEC(); user_agent = \"…\") requires `user_agent` " *
                            "(SEC authenticates with a User-Agent, not an API key); or use set_user_agent."))
    return set_user_agent(user_agent)
end

"""
    get_credential(system::FilingSystem, key::Symbol) -> Union{String,Nothing}

Return one stored credential value for a [`FilingSystem`](@ref) (see [`set_credentials`](@ref)), or
`nothing` if the system has no credentials or no value under `key`.
"""
function get_credential(system::FilingSystem, key::Symbol)
    store = get(CREDENTIALS, system_tag(system), nothing)
    return store === nothing ? nothing : get(store, key, nothing)
end

"""
    system_headers(system::FilingSystem) -> Vector{Pair{String,String}}

The HTTP headers a request to `system` must carry, built from its stored credentials. SEC returns its
descriptive `User-Agent` (via [`get_user_agent`](@ref), which throws if unset); keyed systems return
their authorization header. A new system adds a method here. (`fetch_url` will use this from C0 step
3; today SEC injects the User-Agent itself.)
"""
system_headers(::SEC) = ["User-Agent" => get_user_agent()]
