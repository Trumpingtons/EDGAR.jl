# ESEF report-package ZIP reader (offline). An ESEF filing is a "report package"
# (documentType `https://xbrl.org/report-package/2023`): a single ZIP holding `META-INF/`
# (reportPackage.json + the taxonomy package's catalog.xml), `reports/` (the primary report — an
# inline-XBRL `.xhtml` or a classic `.xbrl` instance), and the issuer's bundled extension taxonomy
# with its linkbases. Unlike SEC EDGAR — where the linkbases are loose sibling files fetched over
# HTTP from the filing's Archives directory — everything needed to parse AND classify an ESEF filing
# lives inside this one ZIP, so it is fully resolvable offline from local bytes.
#
# These helpers operate on the raw ZIP bytes via ZipArchives, so they are pure and testable from the
# committed fixture (test/data/esef/gleif-2024-min.zip).

using ZipArchives: ZipReader, zip_names, zip_readentry

# The file entries in a report package (directory entries — names ending in "/" — dropped).
_rp_names(z::ZipReader) = String[n for n in zip_names(z) if !endswith(n, "/")]

# Locate the primary report instance — an entry inside a `reports/` directory — preferring an inline
# (`.xhtml`/`.html`) document over a classic (`.xbrl`/`.xml`) instance, since a package may carry
# both. Returns `(name, kind)` with `kind ∈ (:ixbrl, :xbrl)`, or `nothing` if there is no report.
function _rp_primary_report(z::ZipReader)
    reports = filter(n -> occursin("/reports/", "/" * n), _rp_names(z))
    isempty(reports) && return nothing
    pick(exts) = findfirst(n -> any(e -> endswith(lowercase(n), e), exts), reports)
    i = pick((".xhtml", ".html")); i !== nothing && return (reports[i], :ixbrl)
    i = pick((".xbrl", ".xml"));   i !== nothing && return (reports[i], :xbrl)
    return nothing
end

# Read the text of a ZIP entry by exact name.
_rp_read(z::ZipReader, name::AbstractString) = zip_readentry(z, name, String)

# Read a bundled linkbase by suffix (`"pre"` presentation, `"cal"` calculation, `"lab"` label,
# `"def"` definition), returning its XML text or `""` if absent. ESEF label linkbases carry a
# LANGUAGE suffix (`…_lab-en.xml`, `…_lab-de.xml`), so the match is on the `_<suffix>` stem with an
# optional `-<lang>` tag before `.xml` — not the exact `_<suffix>.xml` an SEC file uses. The suffix
# values are fixed literals, so interpolating one into the `Regex` is safe.
function _rp_linkbase(z::ZipReader, suffix::AbstractString)
    pat = Regex("_" * suffix * "(-[a-z]+)?\\.xml\$")
    names = _rp_names(z)
    i = findfirst(n -> occursin(pat, lowercase(n)), names)
    return i === nothing ? "" : _rp_read(z, names[i])
end
