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
