# The ESEF FilingSystem (EU — European Single Electronic Format). The second `FilingSystem` after
# SEC, and the one that exercises the seam: filings are report-package ZIPs (not loose Archives
# files), identity is an LEI (not a CIK), the taxonomy is `ifrs-full` + an issuer extension (not
# us-gaap), and the linkbases are bundled inside the package. The XBRL PARSING is unchanged — the
# standard-agnostic core in extract_xbrl.jl already handles ESEF/IFRS instances (both the inline
# `.xhtml` and the classic `.xbrl`). What ESEF supplies is only its `fetch`/identity/linkbase slice.
#
# B1 is the OFFLINE half: read a report package already on disk. Discovery and HTTP fetch
# (filings.xbrl.org / national OAMs) are B2.

"""
    ESEF <: FilingSystem

The EU's ESEF (European Single Electronic Format) regime: annual financial reports filed as XBRL
report-package ZIPs, identified by LEI and tagged against the `ifrs-full` taxonomy plus an issuer
extension. See [`fetch_filing(::ESEF, path)`](@ref).
"""
struct ESEF <: FilingSystem end

# The ISO 17442 (LEI) scheme URI carried by an ESEF instance's context entity identifier.
const _LEI_SCHEME = "http://standards.iso.org/iso/17442"

# Parse the filer's LEI from a (classic or inline) XBRL instance — the `<identifier>` of any context
# entity, whose `scheme` is the ISO 17442 URI. Returns "" if none is present.
function _esef_lei(content::AbstractString)
    m = match(r"(?is)<(?:\w+:)?identifier\b[^>]*\bscheme=\"[^\"]*17442\"[^>]*>\s*([^<\s]+)", content)
    return m === nothing ? "" : String(m.captures[1])
end

"""
    fetch_filing(::ESEF, path::AbstractString) -> Filing

Read an ESEF **report-package ZIP** already on disk at `path` into a [`Filing`](@ref) (offline; no
network). The package's primary report — inline `.xhtml` preferred, else a classic `.xbrl` instance
under `reports/` — becomes the filing `content`; the filer's `entity` is its LEI
(`EntityId(:lei, …)`, read from the instance), `kind` is `:ixbrl` or `:xbrl` accordingly, and `url`
is the local ZIP path so the bundled linkbases stay resolvable (see `_fetch_linkbase(::ESEF, …)`).

The resulting `Filing` flows through the same system-agnostic API as an SEC filing:
`facts(f; classify=true, labels=true)` extracts and classifies its IFRS facts using the linkbases
bundled in the package.

```julia
f = fetch_filing(ESEF(), "test/data/esef/gleif-2024-min.zip")
facts(f; classify = true, labels = true)
```
"""
function fetch_filing(::ESEF, path::AbstractString)
    z = ZipReader(read(path))
    rep = _rp_primary_report(z)
    rep === nothing && error("no report instance (reports/*.xhtml|*.xbrl) in ESEF report package $(repr(path))")
    name, kind = rep
    content = _rp_read(z, name)
    return Filing(ESEF(), EntityId(:lei, _esef_lei(content)), basename(path), basename(name), path, kind, content)
end

# ESEF method of the per-system linkbase fetcher (see core/extract_xbrl.jl): the presentation /
# calculation / label linkbases are bundled in the report-package ZIP, so re-open it from the local
# path stored in `f.url` and read the entry by suffix. Returns "" if the path is gone or the linkbase
# is absent (which the classification path tolerates).
function _fetch_linkbase(::ESEF, f::Filing, suffix::AbstractString)
    isfile(f.url) || return ""
    return _rp_linkbase(ZipReader(read(f.url)), suffix)
end
