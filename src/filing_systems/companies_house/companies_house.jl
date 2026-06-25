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

# Polite client identifier for Companies House's PUBLIC, keyless endpoints — the bulk Accounts Data
# Product (download.companieshouse.gov.uk) and the FRC standard taxonomy (xbrl.frc.org.uk). Supplied
# explicitly so these requests don't take `fetch_url`'s default SEC-User-Agent path (which demands a
# SEC contact UA). The authenticated REST/Document API uses `system_headers(::CompaniesHouse)` instead.
const _CH_TAXONOMY_HEADERS = ["User-Agent" => "EDGAR.jl (https://github.com/Trumpingtons/EDGAR.jl)"]

# The Companies House registration-number scheme carried by an accounts instance's context entity
# identifier.
const _CH_SCHEME = "http://www.companieshouse.gov.uk/"

# Parse the company registration number from a CH inline-XBRL instance — the `<identifier>` of a
# context entity whose `scheme` is the Companies House URI. Returns "" if none is present.
function _ch_number(content::AbstractString)
    m = match(r"(?is)<(?:\w+:)?identifier\b[^>]*\bscheme=\"[^\"]*companieshouse[^\"]*\"[^>]*>\s*([^<\s]+)", content)
    return m === nothing ? "" : String(m.captures[1])
end

# ── FRC namespace canonicalization (prefix instability) ─────────────────────────────────────────
#
# Companies House filers bind the SAME FRC taxonomy namespace to DIFFERENT prefixes: one filing tags
# `uk-core:TurnoverRevenue`, another `ns5:TurnoverRevenue` — both are
# http://xbrl.frc.org.uk/fr/<date>/core. The XBRL extractor keeps the concept verbatim with the
# document's prefix (fine for SEC us-gaap / ESEF ifrs-full, whose prefixes are conventionally fixed),
# so a prefix-keyed vocabulary would classify the `uk-core` filers and silently miss the `ns5` ones.
# We therefore canonicalize CH content at fetch time: resolve each declared prefix to its namespace
# URI and rewrite every FRC-namespace concept's prefix to a canonical one (`uk-core`, `uk-bus`, …), so
# classification (vocab_ukgaap) is by namespace, not prefix. CH-only — the SEC/ESEF parse path is
# untouched. Only `name="…"` attribute prefixes change (invisible in rendering, semantically identical).

# Canonical FRC prefix by the trailing segment of an FRC namespace URI (…/<date>/<segment>).
const _FRC_CANONICAL = Dict(
    "core" => "uk-core", "business" => "uk-bus", "direp" => "uk-direp", "aurep" => "uk-aurep",
    "countries" => "uk-countries", "currencies" => "uk-curr", "languages" => "uk-lang",
)

# The canonical FRC prefix for a namespace URI, or `nothing` if it is not an FRC namespace.
function _frc_canonical_prefix(ns::AbstractString)
    occursin("xbrl.frc.org.uk", ns) || return nothing
    return get(_FRC_CANONICAL, String(last(split(ns, '/'))), nothing)
end

# Map each `xmlns:<prefix>="<uri>"` in the instance to a canonical FRC prefix (only FRC namespaces).
function _ch_prefix_map(content::AbstractString)
    pm = Dict{String,String}()
    for m in eachmatch(r"xmlns:([A-Za-z0-9._-]+)\s*=\s*\"([^\"]*)\"", content)
        canon = _frc_canonical_prefix(m.captures[2])
        canon === nothing || (pm[m.captures[1]] = canon)
    end
    return pm
end

# Rewrite FRC-namespace concept prefixes in `name="…"` attributes to their canonical form. No-op when
# the instance declares no FRC namespaces or already uses canonical prefixes.
function _ch_canonicalize(content::AbstractString)
    pm = _ch_prefix_map(content)
    isempty(pm) && return content
    return replace(content, r"(?i)(\bname\s*=\s*[\"'])([A-Za-z0-9._-]+):" => function (s)
        m = match(r"(?i)(\bname\s*=\s*[\"'])([A-Za-z0-9._-]+):", s)
        canon = get(pm, m.captures[2], nothing)
        canon === nothing ? s : string(m.captures[1], canon, ":")
    end)
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
    content = _ch_canonicalize(String(raw))
    ent = entity === nothing ? EntityId(:companies_house, _ch_number(content)) : entity
    return Filing(CompaniesHouse(), ent, r, basename(src), src, :ixbrl, content)
end

# ── Standard-taxonomy linkbase delegation (N4 / C3) ─────────────────────────────────────────────
#
# CH accounts carry NO bundled linkbases and NO issuer extension — they reference the PUBLISHED FRC
# standard taxonomy by URL. The financial-statement concepts live in the FRC `core` namespace
# (http://xbrl.frc.org.uk/fr/<date>/core); its **label** linkbase is published at a derivable URL
# alongside the schema, so we fetch it to give real human-readable labels (classification already
# works via vocab_ukgaap without it). The linkbase keys concepts by the schema's element-id prefix
# `core_` (→ `core:…`); the instance's concepts are canonicalized to `uk-core:…` (see
# `_ch_canonicalize`), so we rewrite `#core_` → `#uk-core_` in the linkbase before parsing so the keys
# match. Presentation/calculation linkbases are not fetched yet (vocab classification suffices).

# The FRC `core` label-linkbase URL derived from the core namespace declared in a CH instance, or
# `nothing`. Namespace `http://xbrl.frc.org.uk/fr/<date>/core` ⇒ label
# `https://xbrl.frc.org.uk/fr/<date>/core/frc-core-<date>-label.xml`.
function _frc_core_label_url(content::AbstractString)
    m = match(r"https?://xbrl\.frc\.org\.uk/fr/(\d{4}-\d{2}-\d{2})/core", content)
    m === nothing && return nothing
    date = m.captures[1]
    return "https://xbrl.frc.org.uk/fr/$date/core/frc-core-$date-label.xml"
end

# Companies House method of the per-system linkbase fetcher (see core/extract_xbrl.jl). Only the FRC
# `core` LABEL linkbase is resolved (the financial concepts' human labels); presentation/calculation
# return "" (classification falls back to the prefix-keyed UK-GAAP vocabulary, which works). The fetch
# is a public, keyless GET of the standard taxonomy; "" on any failure (tolerated downstream).
function _fetch_linkbase(::CompaniesHouse, f::Filing, suffix::AbstractString)
    suffix == "lab" || return ""
    url = _frc_core_label_url(f.content)
    url === nothing && return ""
    xml = fetch_url(url; headers = _CH_TAXONOMY_HEADERS)
    xml === nothing && return ""
    return replace(String(xml), "#core_" => "#uk-core_")   # element-id prefix → canonical instance prefix
end
