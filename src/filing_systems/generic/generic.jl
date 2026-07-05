# Generic Filing — the shared core exposed with NO jurisdiction adapter. Every specialised FilingSystem is
# `Generic` + three things: discovery (the repository's API), a national-taxonomy vocabulary, and quirk
# handling (the overfitted per-jurisdiction fixes). Strip those away and the format-appropriate GENERIC
# extractor still recovers the statements: `extract_xbrl` for a tagged filing (classified by the filing's OWN
# presentation linkbase — XBRL is self-describing), `extract_ifrs_pdf` for an English IFRS PDF. You supply the
# document (already obtained from whatever foreign repository — Australia, Brazil, Canada, Sweden, …); Generic
# sniffs its format and routes `facts` / `narratives` / `toc` through the core. Broad coverage without the
# overfitting of a specialised path; the trade is no discovery, no national-taxonomy standardisation, no quirk
# fixes — a floor, not a ceiling (a jurisdiction is "promoted" to specialised by adding just those three).

struct Generic <: FilingSystem end
system_tag(::Generic) = :generic

const _GENERIC_UA = "Mozilla/5.0 (compatible; EDGAR.jl generic filing fetcher)"
system_headers(::Generic) = ["User-Agent" => _GENERIC_UA, "Accept" => "*/*"]

# Sniff a document's format from its leading bytes: a PDF magic number, an inline-XBRL (`ix:`) HTML document, a
# plain HTML document, or a classic XBRL / XML instance. Format — not jurisdiction — is all the core needs.
function _generic_kind(path::AbstractString)
    head = open(io -> read(io, min(8192, filesize(path))), path)
    # binary magic numbers first (their bytes are not valid UTF-8, so decode them by byte, not as text)
    length(head) >= 4 && head[1:4] == b"%PDF" && return :pdf
    length(head) >= 2 && head[1:2] == b"PK" &&                 # a ZIP — an ESEF/EDINET/DART report package
        throw(ArgumentError("Generic: $(repr(basename(path))) is a ZIP report package (ESEF / EDINET / DART) — " *
              "use the specialised system for it, or unzip and pass the XBRL instance directly"))
    low = try lowercase(String(copy(head))) catch; "" end      # text formats — safe on any leading bytes
    if occursin("<html", low) || occursin("<!doctype html", low)
        return (occursin("xmlns:ix", low) || occursin("<ix:", low)) ? :ixbrl : :html
    end
    (occursin("<xbrl", low) || occursin("xbrli", low) || occursin("www.xbrl.org", low) ||
     occursin("<?xml", low)) && return :xbrl
    throw(ArgumentError("Generic: could not recognise the format of $(repr(basename(path))) — expected a PDF, " *
          "an XBRL / inline-XBRL instance, or an HTML document"))
end

function _generic_download(url::AbstractString)
    r = HTTP.get(url; headers = system_headers(Generic()), status_exception = false, redirect = true)
    r.status == 200 || throw(ArgumentError("Generic: download of $(repr(url)) failed (HTTP $(r.status))"))
    dest = tempname() * "_" * basename(HTTP.URIs.URI(url).path)
    write(dest, r.body)
    return dest
end

"""
    fetch_filing(::Generic, src) -> Filing

Open a filing from ANY jurisdiction that has no specialised `FilingSystem`. `src` is a **local path** (or an
`http(s)` URL) to a document you already obtained from its repository. Its format is sniffed — PDF, inline
XBRL, classic XBRL, or HTML — and the returned [`Filing`](@ref) runs [`facts`](@ref) / [`narratives`](@ref) /
[`toc`](@ref) through the shared, jurisdiction-agnostic core: `extract_xbrl` for a tagged filing (classified by
its OWN presentation linkbase), the `ifrs-full` English-PDF extractor for an IFRS report. No discovery, no
national-taxonomy standardisation, no quirk fixes — broad coverage without a specialised path's overfitting.

```julia
f = fetch_filing(Generic(), "sydney_airport_annual_report.pdf")   # an Australian IFRS PDF
facts(f); toc(f); narratives(f)                                   # the shared accessors, unchanged
```
"""
function fetch_filing(system::Generic, src::AbstractString)
    path = occursin(r"^https?://", src) ? _generic_download(src) : String(src)
    isfile(path) || throw(ArgumentError("Generic: no file at $(repr(src))"))
    kind = _generic_kind(path)
    content = kind === :pdf ? path : read(path, String)   # :pdf keeps the path (the extractor reads bytes)
    Filing(system, EntityId(:generic, basename(path)), basename(path), basename(path), String(src), kind, content)
end
