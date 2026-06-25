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

# Single-slot memo of the last report-package ZIP fetched, keyed by source. A `Filing`'s linkbase
# reads (`statement_map`/`label_map`/`calculations` ⇒ pre/cal/lab) each need the whole package, and
# the HTTP layer does NOT disk-cache bodies over its size limit (ESEF packages frequently exceed it),
# so without this every linkbase read would re-download the multi-MB ZIP. One slot bounds memory to a
# single package and covers the common "work on one filing at a time" flow.
const _ESEF_PKG_MEMO = Ref{Tuple{String,Vector{UInt8}}}(("", UInt8[]))

# The report-package ZIP bytes for a source — a local path or an `http(s)://` URL. Remote fetches go
# through the cached, User-Agent-aware `fetch_url` and are memoised (see `_ESEF_PKG_MEMO`). Throws if
# a remote package cannot be fetched.
function _esef_zip_bytes(src::AbstractString)
    src == _ESEF_PKG_MEMO[][1] && return _ESEF_PKG_MEMO[][2]
    bytes = if startswith(src, "http://") || startswith(src, "https://")
        b = fetch_url(src)
        b === nothing && error("could not fetch ESEF report package $(repr(src))")
        Vector{UInt8}(b)
    else
        read(src)
    end
    _ESEF_PKG_MEMO[] = (src, bytes)
    return bytes
end

"""
    fetch_filing(::ESEF, src::AbstractString; entity=nothing, ref="") -> Filing

Read an ESEF **report-package ZIP** into a [`Filing`](@ref). `src` is either a **local path** to a
package on disk (offline) or an `http(s)://` **URL** to one (e.g. the `package_url` from a
[`FilingHandle`](@ref) discovered via [`discover`](@ref); fetched through the cached, User-Agent-aware
[`fetch_url`](@ref)). The package's primary report — inline `.xhtml` preferred, else a classic
`.xbrl` instance under `reports/` — becomes the filing `content`; `kind` is `:ixbrl` or `:xbrl`
accordingly, and `url` is `src` so the bundled linkbases stay resolvable (see
`_fetch_linkbase(::ESEF, …)`). The filer's `entity` is taken from `entity` when given (discovery
already knows the LEI), else read from the instance; `ref` is the opaque filing reference (the
discovered filing id), defaulting to the package basename.

The resulting `Filing` flows through the same system-agnostic API as an SEC filing:
`facts(f; classify=true, labels=true)` extracts and classifies its IFRS facts using the linkbases
bundled in the package.

```julia
f = fetch_filing(ESEF(), "test/data/esef/gleif-2024-min.zip")   # local, offline
h = first(discover(FilingsXBRLOrg(); lei = "549300P8N0P6KDGTJ206"))
f = fetch_filing(h)                                             # remote, via the handle
facts(f; classify = true, labels = true)
```
"""
function fetch_filing(::ESEF, src::AbstractString;
                      entity::Union{EntityId,Nothing}=nothing, ref::AbstractString="")
    z = ZipReader(_esef_zip_bytes(src))
    rep = _rp_primary_report(z)
    rep === nothing && error("no report instance (reports/*.xhtml|*.xbrl) in ESEF report package $(repr(src))")
    name, kind = rep
    content = _rp_read(z, name)
    ent = entity === nothing ? EntityId(:lei, _esef_lei(content)) : entity
    return Filing(ESEF(), ent, isempty(ref) ? basename(src) : String(ref), basename(name), src, kind, content)
end

# ESEF method of the per-system linkbase fetcher (see core/extract_xbrl.jl): the presentation /
# calculation / label linkbases are bundled in the report-package ZIP, so re-read it from the source
# stored in `f.url` (local path or remote URL, both via the memoised `_esef_zip_bytes`) and read the
# entry by suffix. Returns "" if the package can't be read or the linkbase is absent (which the
# classification path tolerates).
function _fetch_linkbase(::ESEF, f::Filing, suffix::AbstractString)
    bytes = try
        _esef_zip_bytes(f.url)
    catch
        return ""
    end
    return _rp_linkbase(ZipReader(bytes), suffix)
end
