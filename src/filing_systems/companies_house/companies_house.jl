# The Companies House FilingSystem (UK — the Registrar of Companies / FRC). The third `FilingSystem`
# after SEC and ESEF. Companies House holds the accounts of ALL UK companies (private + public), not
# just listed issuers, so it is a far larger and messier universe. Key differences from ESEF:
#
#   • Container: a SINGLE inline-XBRL accounts document (.xhtml/.html), NOT a report-package ZIP.
#   • Taxonomy: the PUBLISHED FRC standard taxonomy (FRS 101/102/105, UK-IFRS, the FRC `core` suite)
#     referenced by <link:schemaRef> — there is NO issuer extension and NO bundled linkbase. Real
#     labels/presentation therefore require fetching the standard taxonomy (N4 — deferred to C3); for
#     now classification works off the prefix-keyed UK-GAAP vocabulary (vocab_ukgaap.jl).
#   • Identity: the company registration number (scheme http://www.companieshouse.gov.uk/).
#   • Format axis: a large share of small/dormant/paper-filed accounts are PDF, not XBRL. A PDF input
#     is a TYPED, non-fatal `:pdf` filing (extraction is "Companies House II", a separate plan), not
#     an error. See docs/dev/companies-house-plan.md §1.
#
# C1 is the OFFLINE half: parse an iXBRL accounts document already on disk (or at a URL). Discovery
# and the authenticated Document-API fetch are C2; standard-taxonomy linkbases are C3.

"""
    CompaniesHouse <: FilingSystem

The UK Companies House (Registrar of Companies / FRC) regime: company accounts filed as inline-XBRL,
identified by company registration number and tagged against the published FRC taxonomy (FRS
101/102/105 or UK-IFRS) with no issuer extension. See [`fetch_filing(::CompaniesHouse, src)`](@ref).
"""
struct CompaniesHouse <: FilingSystem end

# The CREDENTIALS-registry key (N3). The Companies House API needs a key (HTTP Basic, key as username);
# `system_headers(::CompaniesHouse)` and discovery are wired in C2.
system_tag(::CompaniesHouse) = :companies_house

# The Companies House registration-number scheme carried by an accounts instance's context entity
# identifier.
const _CH_SCHEME = "http://www.companieshouse.gov.uk/"

# Parse the company registration number from a CH inline-XBRL instance — the `<identifier>` of a
# context entity whose `scheme` is the Companies House URI. Returns "" if none is present.
function _ch_number(content::AbstractString)
    m = match(r"(?is)<(?:\w+:)?identifier\b[^>]*\bscheme=\"[^\"]*companieshouse[^\"]*\"[^>]*>\s*([^<\s]+)", content)
    return m === nothing ? "" : String(m.captures[1])
end

# A PDF document begins with the "%PDF" magic bytes (0x25 0x50 0x44 0x46). Companies House serves many
# small/dormant accounts as PDF rather than iXBRL; we tag those `:pdf` (CH II territory) rather than
# trying to parse them as XBRL.
_ch_is_pdf(bytes::AbstractVector{UInt8}) =
    length(bytes) >= 4 && bytes[1] == 0x25 && bytes[2] == 0x50 && bytes[3] == 0x44 && bytes[4] == 0x46

"""
    fetch_filing(::CompaniesHouse, src::AbstractString; entity=nothing, ref="") -> Filing

Read a Companies House **accounts document** into a [`Filing`](@ref). `src` is a local path (offline)
or an `http(s)://` URL. An inline-XBRL document becomes an `:ixbrl` filing whose `entity` is the
company registration number (taken from `entity` when given — discovery already knows it — else parsed
from the instance). A **PDF** document — common for small/dormant/paper-filed accounts — becomes a
`:pdf` filing with empty `content`: a typed, non-fatal outcome (PDF extraction is a later phase,
"Companies House II"), with `url` kept so the source stays retrievable. `ref` is the opaque filing
reference, defaulting to the source basename.

The resulting iXBRL `Filing` flows through the same system-agnostic API as any other:
`facts(f; classify = true)` extracts and classifies its FRC/UK-GAAP facts using the prefix-keyed
UK-GAAP vocabulary (standardised labels need the FRC standard taxonomy — a later phase).

```julia
f = fetch_filing(CompaniesHouse(), "test/data/companies_house/example-frs102.html")
facts(f; classify = true)
```
"""
function fetch_filing(::CompaniesHouse, src::AbstractString;
                      entity::Union{EntityId,Nothing}=nothing, ref::AbstractString="")
    raw = if startswith(src, "http://") || startswith(src, "https://")
        b = fetch_url(src)
        b === nothing && error("could not fetch Companies House document $(repr(src))")
        Vector{UInt8}(b)
    else
        read(src)
    end
    r = isempty(ref) ? basename(src) : String(ref)
    if _ch_is_pdf(raw)
        ent = entity === nothing ? EntityId(:companies_house, "") : entity
        return Filing(CompaniesHouse(), ent, r, basename(src), src, :pdf, "")
    end
    content = String(raw)
    ent = entity === nothing ? EntityId(:companies_house, _ch_number(content)) : entity
    return Filing(CompaniesHouse(), ent, r, basename(src), src, :ixbrl, content)
end

# Companies House method of the per-system linkbase fetcher (see core/extract_xbrl.jl). CH accounts
# carry NO bundled linkbases and NO issuer extension — they reference the PUBLISHED FRC standard
# taxonomy by URL. Resolving that to fetch real presentation/calculation/label linkbases is N4 (C3);
# until then this returns "" (tolerated by classification, which falls back to the prefix-keyed
# UK-GAAP vocabulary). Face-statement classification therefore works; standardised labels do not yet.
_fetch_linkbase(::CompaniesHouse, f::Filing, suffix::AbstractString) = ""
