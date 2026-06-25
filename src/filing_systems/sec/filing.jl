# Fetch, open and save a filing from the SEC EDGAR Archives. SEC-specific.

# Internal: the base Archives URL for a filing's directory. A SEC `Filing`'s identity is a CIK
# (`entity.value`) + accession (`ref`); the `::Filing` overload reads them off the filing.
_filing_dir(cik, accession) =
    "https://www.sec.gov/Archives/edgar/data/$(parse(Int, _normalize_cik(cik)))/$(replace(accession, "-" => ""))"
_filing_dir(f::Filing) = _filing_dir(f.entity.value, f.ref)

# Internal: locate the XBRL *instance* document in a filing's directory (via its
# `index.json` file list), skipping the schema (`.xsd`) and the linkbases
# (`_cal`/`_def`/`_lab`/`_pre`/`_ref`.xml). Prefers the iXBRL-extracted `_htm.xml`.
function _xbrl_instance(base)
    names = String[String(it.name) for it in _get_json("$base/index.json").directory.item]
    xml = filter(n -> endswith(lowercase(n), ".xml") &&
                      !occursin(r"_(cal|def|lab|pre|ref)\.xml$"i, n), names)
    isempty(xml) && error("no XBRL instance (.xml) found in $base")
    j = findfirst(n -> endswith(lowercase(n), "_htm.xml"), xml)
    return j === nothing ? first(xml) : xml[j]
end

# Internal: locate a filing by accession across a filer's *entire* submissions
# history and return the fields `fetch_filing` needs (`primaryDocument` and the
# `isInlineXBRL`/`isXBRL` flags), or `nothing` if the accession is not found.
#
# The submissions document only inlines the most recent ~1000 filings under
# `filings.recent`; for a prolific filer (Apple files Form 4s almost daily) older
# filings spill into additional JSON pages listed in `filings.files`. Those pages
# carry the same column arrays at their top level, so the same scan works on both.
function _find_filing(cik, accession)
    sub = _fetch_submissions(cik)
    function scan(rec)
        i = findfirst(a -> String(a) == accession, rec.accessionNumber)
        i === nothing && return nothing
        flag(arr) = (v = arr[i]; v !== nothing && v == 1)
        return (primaryDocument = String(rec.primaryDocument[i]),
                isInlineXBRL = flag(rec.isInlineXBRL),
                isXBRL = flag(rec.isXBRL))
    end
    r = scan(sub.filings.recent)
    r === nothing || return r
    for f in get(sub.filings, :files, ())
        page = _get_json("https://data.sec.gov/submissions/$(String(f.name))")
        r = scan(page)
        r === nothing || return r
    end
    return nothing
end

"""
    fetch_filing(cik, accession; kind=:auto) -> Filing

Fetch a single filing's document into memory (no disk write) as a [`Filing`](@ref).
`cik` may be an integer or string; `accession` is the dashed accession number
(e.g. `"0000320193-26-000011"`). The fetch goes through [`fetch_url`](@ref), so it
is cached and uses the configured User-Agent.

`kind` selects which document:
- `:auto` (default) — the **inline-XBRL** primary document if the filing has it
  (`isInlineXBRL`), else the classic **XBRL** instance if it has one (`isXBRL`),
  else the plain primary HTML.
- `:ixbrl` / `:html` — the primary document (`primaryDocument` from submissions).
- `:xbrl` — the classic XBRL instance (`.xml`), located via the filing's `index.json`.

The filing is located anywhere in the filer's submissions history: the recent
window plus the older paginated pages, so even a long-past accession from a prolific
filer is found. Save the result with `save_filing(f; destdir)`.

```julia
f = fetch_filing(320193, "0000320193-26-000011")   # :auto -> iXBRL for a recent 10-K/8-K
f.kind, f.document
save_filing(f; destdir = "filings")
```
"""
function fetch_filing(cik::Union{Integer,AbstractString}, accession::AbstractString; kind::Symbol=:auto)
    cik10 = _normalize_cik(cik)
    base = _filing_dir(cik, accession)
    info = _find_filing(cik, accession)
    info === nothing && error("filing $(accession) was not found in $(cik10)'s submissions history")
    want = kind === :auto ? (info.isInlineXBRL ? :ixbrl :
                             info.isXBRL ? :xbrl : :html) : kind
    doc = if want === :ixbrl || want === :html
        info.primaryDocument
    elseif want === :xbrl
        _xbrl_instance(base)
    else
        throw(ArgumentError("`kind` must be :auto, :ixbrl, :xbrl or :html, got $(repr(kind))"))
    end
    url = "$base/$doc"
    body = fetch_url(url)
    body === nothing && error("could not fetch $url")
    return Filing(cik10, accession, doc, url, want, String(body))
end

# Internal: the directory URL a filing was fetched from — everything up to and
# including the final slash of `f.url` — against which the relative asset
# references (images, stylesheets) inside the filing HTML are resolved.
_filing_base_url(f::Filing) = f.url[1:something(findlast('/', f.url), 0)]

# Internal: file extensions of the relative assets worth downloading to make a
# saved filing self-contained — chiefly the embedded images, plus any external
# CSS/JS. Extensions outside this list (e.g. `.htm` links to sibling filings, or
# document anchors) are deliberately skipped.
const _ASSET_EXT = (".jpg", ".jpeg", ".png", ".gif", ".svg", ".webp", ".bmp", ".ico", ".css", ".js")

"""
    download_assets(f::Filing; destdir=".") -> Vector{String}

Download the relative assets — chiefly the embedded images — that a fetched
[`Filing`](@ref)'s HTML references, writing each next to the document under
`destdir` so the saved filing renders self-contained (a filing's images live
beside it in the EDGAR Archives directory, and [`fetch_filing`](@ref) downloads
only the primary document). The `src`/`href` attributes are scanned; only relative
URLs with a known asset extension ([`_ASSET_EXT`]) are taken, so links to sibling
filings and in-page anchors are skipped. Each asset is fetched through the cached
[`fetch_url`](@ref) and written preserving any sub-path. The download is
best-effort: a reference that cannot be fetched is skipped. Returns the filenames
written. Called automatically by [`open_filing`](@ref) and [`save_filing`](@ref).
"""
function download_assets(f::Filing; destdir=".")
    base = _filing_base_url(f)
    isempty(base) && return String[]
    seen = Set{String}()
    written = String[]
    for m in eachmatch(r"(?:src|href)\s*=\s*[\"']([^\"'#?]+)"i, f.content)
        rel = strip(m.captures[1])
        (isempty(rel) || rel in seen) && continue
        (startswith(rel, "http://") || startswith(rel, "https://") || startswith(rel, "//") ||
         startswith(rel, "data:") || startswith(rel, "mailto:")) && continue
        any(e -> endswith(lowercase(rel), e), _ASSET_EXT) || continue
        push!(seen, rel)
        cleaned = startswith(rel, "./") ? rel[3:end] : rel
        body = fetch_url(base * cleaned)
        body === nothing && continue
        dest = joinpath(destdir, cleaned)
        mkpath(dirname(dest))
        write(dest, body)
        push!(written, cleaned)
    end
    return written
end

"""
    open_filing(f::Filing; assets=true) -> String

View a fetched [`Filing`](@ref) in your default browser. A browser can only open a
file or URL, not an in-memory string, so this writes `f` to a fresh **temporary**
directory (under the filename `f.document`, so the extension/title are right) and
opens it, returning that path. This is a throwaway view — use [`save_filing`](@ref)
to keep a copy.

With `assets=true` (the default) the filing's relative assets — chiefly its
embedded images — are downloaded beside the document via [`download_assets`](@ref)
so they render; pass `assets=false` to open just the HTML (faster, no extra
requests, but images referenced relatively appear blank).
"""

function open_filing(f::Filing; assets::Bool=true)
    # cleanup=true (the default, made explicit) registers an atexit hook that
    # removes this directory — the document and its downloaded images together —
    # when the Julia process exits, so nothing lingers in the temp dir. Deletion
    # waits until exit (not right after `run`) since the browser opens the file
    # asynchronously and must still be able to read it.
    dir = mktempdir(; prefix="EDGAR_filing_", cleanup=true)
    path = joinpath(dir, f.document)
    write(path, f.content)
    assets && download_assets(f; destdir=dir)
    return _open_in_default_app(path)
end

"""
    open_filing(path::AbstractString) -> String

Open a filing **already saved on disk** in your default browser, returning `path` —
the on-disk counterpart to [`open_filing(f::Filing)`](@ref). Use it to view a filing
written with [`save_filing`](@ref), or any HTML page you saved yourself (an extracted
section such as a balance sheet, say — still part of the filing). The path must exist
(an `ArgumentError` is thrown otherwise); an `http(s)://` URL is passed through as-is.

```julia
path = save_filing(f; destdir = "filings")
open_filing(path)                            # reload from disk and view
```
"""
function open_filing(path::AbstractString)
    is_url = startswith(path, "http://") || startswith(path, "https://")
    is_url || isfile(path) || throw(ArgumentError("no such file to open: $(repr(path))"))
    return _open_in_default_app(path)
end

"""
    open_filing(cik, accession; kind=:auto, assets=true) -> String

Fetch a filing and view it in your default browser in one step — the convenience
combination of [`fetch_filing`](@ref) and [`open_filing`](@ref). `cik`, `accession`
and `kind` are exactly as in [`fetch_filing`](@ref); `assets` is as in
[`open_filing`](@ref). Returns the temporary file path that was opened.

```julia
open_filing(320193, "0000320193-25-000079")   # fetch the 10-K and open it
```
"""
open_filing(cik::Union{Integer,AbstractString}, accession::AbstractString; kind::Symbol=:auto, assets::Bool=true) =
    open_filing(fetch_filing(cik, accession; kind); assets)

# Internal: image extensions → MIME type, for the `data:` URIs used to inline a
# filing's images when rendering it self-contained in a notebook.
const _IMAGE_MIME = Dict(".jpg"=>"image/jpeg", ".jpeg"=>"image/jpeg", ".png"=>"image/png",
                         ".gif"=>"image/gif", ".svg"=>"image/svg+xml", ".webp"=>"image/webp",
                         ".bmp"=>"image/bmp", ".ico"=>"image/x-icon")

# Internal: return `f.content` with every relative image reference rewritten to a
# self-contained base64 `data:` URI, so the HTML renders with its images and no
# external files — the in-memory equivalent of `download_assets`, used by the
# notebook `show` method (which renders an HTML string in-page, where relative
# `src` paths cannot resolve). Each image is fetched once through the cached
# `fetch_url`; a reference that fails to download is left untouched.
function _inline_images(f::Filing)
    base = _filing_base_url(f)
    isempty(base) && return f.content
    html = f.content
    uris = Dict{String,String}()
    for m in eachmatch(r"(src|href)\s*=\s*([\"'])([^\"'#?]+)\2"i, f.content)
        rel = strip(m.captures[3])
        (startswith(rel, "http://") || startswith(rel, "https://") || startswith(rel, "//") ||
         startswith(rel, "data:") || startswith(rel, "mailto:")) && continue
        mime = get(_IMAGE_MIME, lowercase(splitext(rel)[2]), nothing)
        mime === nothing && continue
        if !haskey(uris, rel)
            body = fetch_url(base * (startswith(rel, "./") ? rel[3:end] : rel))
            uris[rel] = body === nothing ? "" : "data:$mime;base64,$(base64encode(body))"
        end
        isempty(uris[rel]) && continue
        html = replace(html, m.match => "$(m.captures[1])=$(m.captures[2])$(uris[rel])$(m.captures[2])")
    end
    return html
end

# Render a Filing inline in notebook front-ends (Jupyter/IJulia, Pluto, …) that
# request `text/html`. iXBRL/HTML filings are emitted with their images inlined as
# `data:` URIs (via `_inline_images`) so the document renders self-contained; a
# classic XBRL instance is XML, not HTML, so its source is shown escaped inside a
# <pre> instead of being interpreted as markup.
function Base.show(io::IO, ::MIME"text/html", f::Filing)
    if f.kind === :xbrl
        esc = replace(f.content, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
        print(io, "<pre>", esc, "</pre>")
    else
        print(io, _inline_images(f))
    end
end
"""
    save_filing(f::Filing; destdir=".", assets=true) -> String

Persist a fetched [`Filing`](@ref) (iXBRL/XBRL/HTML) verbatim to
`<destdir>/<f.document>`, creating `destdir` if needed, and return the path written
— the save half of what the old `download_filing` did, now separate from
[`fetch_filing`](@ref). With `assets=true` (the default) the filing's relative
assets — chiefly its embedded images — are also downloaded into `destdir` via
[`download_assets`](@ref) so the saved copy renders self-contained; pass
`assets=false` to write only the document.
"""
function save_filing(f::Filing; destdir=".", assets::Bool=true)
    isdir(destdir) || mkpath(destdir)
    path = joinpath(destdir, f.document)
    write(path, f.content)
    assets && download_assets(f; destdir)
    return path
end
