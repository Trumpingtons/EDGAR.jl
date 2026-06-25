# Generic text/HTML utilities (jurisdiction-agnostic): edit distance + fuzzy match, html_to_text/clean_text, and the heuristic extract_section.

function levenshtein(a::AbstractString, b::AbstractString)
    ca = collect(a)
    cb = collect(b)
    la = length(ca); lb = length(cb)
    if la == 0 return lb end
    if lb == 0 return la end
    d = Array{Int}(undef, la+1, lb+1)
    for i in 0:la
        d[i+1, 1] = i
    end
    for j in 0:lb
        d[1, j+1] = j
    end
    for i in 1:la
        for j in 1:lb
            cost = ca[i] == cb[j] ? 0 : 1
            d[i+1, j+1] = min(d[i, j+1] + 1, d[i+1, j] + 1, d[i, j] + cost)
        end
    end
    return d[la+1, lb+1]
end

function similarity_ratio(a::AbstractString, b::AbstractString)
    a2 = lowercase(strip(a)); b2 = lowercase(strip(b))
    if isempty(a2) && isempty(b2) return 1.0 end
    d = levenshtein(a2, b2)
    maxlen = max(length(a2), length(b2))
    return 1.0 - d / maxlen
end


function html_to_text(html::AbstractString)
    m = match(r"(?is)<body.*?</body>", html)
    body = m === nothing ? html : m.match
    txt = replace(body, r"(?is)<script.*?</script>" => "")
    txt = replace(txt, r"(?is)<style.*?</style>" => "")
    txt = replace(txt, r"<[^>]+>" => " ")
    txt = replace(txt, r"\s+" => " ")
    return strip(txt)
end


# Internal: the handful of named HTML entities common in filings, plus the ones
# that must be decoded last (so a literal "&amp;lt;" survives as "&lt;").
const _ENTITIES = ["&nbsp;" => " ", "&#160;" => " ", "&lt;" => "<", "&gt;" => ">",
                   "&quot;" => "\"", "&#39;" => "'", "&apos;" => "'", "&mdash;" => "—",
                   "&ndash;" => "–", "&rsquo;" => "’", "&lsquo;" => "‘",
                   "&amp;" => "&"]

# Internal: turn a fragment of filing HTML into plain text — drop <script>/<style>
# blocks, strip the remaining tags, decode the common HTML entities, and collapse
# runs of whitespace. Shared by every extraction path so output is uniform.
function clean_text(fragment::AbstractString)
    txt = replace(fragment, r"(?is)<script.*?</script>" => " ")
    txt = replace(txt, r"(?is)<style.*?</style>" => " ")
    txt = replace(txt, r"(?is)<[^>]+>" => " ")
    txt = replace(txt, r"&#(\d+);" => m -> string(Char(parse(Int, m[3:end-1]))))   # numeric entities
    txt = replace(txt, _ENTITIES...)                                               # &amp; decoded last
    txt = replace(txt, ' ' => ' ')                                            # NBSP -> space
    txt = replace(txt, r"\s+" => " ")
    return strip(txt)
end

# Block-level tags whose boundaries separate one paragraph from the next. Inline tags (span, b, a,
# ix:nonFraction, …) are NOT here, so a sentence broken up by inline markup stays one paragraph.
const _BLOCK_TAG = r"(?is)</?(?:p|div|h[1-6]|li|ul|ol|tr|table|thead|tbody|section|article|header|footer|figure|figcaption|blockquote|pre|br|hr|dd|dt|caption)\b[^>]*>"

# Internal: split a filing's HTML into plain-text paragraphs (block by block). Reduce to <body>, drop
# script/style, break at block-level tags, then `clean_text` each block (strip inline tags, decode
# entities, collapse whitespace). Empty blocks are dropped. Jurisdiction-agnostic.
function _paragraphs(html::AbstractString)
    bopen = match(r"(?is)<body\b[^>]*>", html)
    body = if bopen === nothing
        String(html)
    else
        bclose = findlast("</body>", html)
        String(html[bopen.offset:(bclose === nothing ? lastindex(html) : last(bclose))])
    end
    body = replace(body, r"(?is)<script.*?</script>" => " ")
    body = replace(body, r"(?is)<style.*?</style>" => " ")
    paras = String[]
    for chunk in split(replace(body, _BLOCK_TAG => "\n"), '\n')
        t = clean_text(chunk)
        isempty(t) || push!(paras, t)
    end
    return paras
end

"""
    find_paragraphs(f::Filing, query; ignorecase=true) -> Vector{@NamedTuple{index::Int, paragraph::String}}
    find_paragraphs(html::AbstractString, query; ignorecase=true) -> Vector{…}

Return the paragraphs of a filing whose text contains `query` — a **literal substring** match — each
paired with its `index` (1-based position among **all** the document's paragraphs), or an empty vector
if the phrase does not occur. This searches *within* one already-fetched filing (it is jurisdiction-
agnostic: it works on a SEC iXBRL document or an ESEF iXHTML report alike), unlike
[`filings_by_text`](@ref), which searches *across* SEC filings to find which ones to fetch.

The `index` locates the hit: it tells you where in the document the paragraph sits and lets you jump
back to it (and its neighbours) with `EDGAR._paragraphs(f.content)[index]`. The result is a
[Tables.jl](https://github.com/JuliaData/Tables.jl) row table, so it renders with `PrettyTables`,
filters, and converts to a `DataFrame` directly.

The markup is reduced to plain-text paragraphs (split at block-level HTML boundaries, inline markup
stripped, whitespace collapsed), so the match ignores tags and runs of whitespace. `ignorecase=true`
(the default) matches regardless of case; pass `false` for an exact-case match.

```julia
f = fetch_filing(320193, "0000320193-23-000106")
hits = find_paragraphs(f, "climate-related risks")   # [(index=312, paragraph="…"), …]  or  []
EDGAR._paragraphs(f.content)[hits[1].index]          # jump back to the located paragraph
```
"""
function find_paragraphs(html::AbstractString, query::AbstractString; ignorecase::Bool=true)
    q = ignorecase ? lowercase(query) : query
    out = @NamedTuple{index::Int, paragraph::String}[]
    for (i, p) in enumerate(_paragraphs(html))
        occursin(q, ignorecase ? lowercase(p) : p) && push!(out, (index = i, paragraph = p))
    end
    return out
end

"""
    extract_section(html, names; base_path=nothing) -> Dict{String,String}

Pull one or more named sections out of a filing's `html`, returning a dictionary
that maps each requested name to the matched text. Names that cannot be located
are simply absent from the result, so look them up with `get`.

Matching is heuristic and tried in order: the document's table of contents
(following anchor links), then the document's own headings (`h1`–`h6`), then a
plain-text search as a last resort. `base_path` lets table-of-contents links that
point to sibling files be resolved relative to it. Each section's full text is
returned (bounded only by where the next section starts).

```julia
sections = extract_section(html, ["Item 7", "Management's Discussion"])
println(get(sections, "Item 7", "(not found)"))
```
"""
function extract_section(html::AbstractString, names::Vector{String}; base_path::Union{Nothing,String}=nothing)
    results = Dict{String,String}()

    # Step 1 — reduce to the <body>. All later offsets are within `body`. Locate the
    # open/close tags with bounded searches rather than a `.*?` span — a 10-K can be
    # >10 MB, which overruns PCRE's backtracking limit on a lazy match.
    bopen = match(r"(?is)<body\b[^>]*>", html)
    if bopen === nothing
        body = String(html)
    else
        bclose = findlast("</body>", html)
        stop = bclose === nothing ? lastindex(html) : last(bclose)
        body = String(html[bopen.offset:stop])
    end

    # Label normaliser: drop tags, decode numeric entities and NBSP, collapse
    # whitespace. Filings write item numbers as "Item&#160;1A.", so decoding the
    # entity is what lets a query like "Item 1A" match the label.
    function norm(s)
        t = replace(s, r"<[^>]+>" => " ")
        t = replace(t, r"&#(\d+);" => m -> string(Char(parse(Int, m[3:end-1]))))
        t = replace(t, "&nbsp;" => " ", '\u00a0' => ' ')
        return strip(replace(t, r"\s+" => " "))
    end

    # Step 2 — collect heading markers: each <h1>-<h6> becomes a section start at
    # its offset, labelled by its (tag-stripped) inner text. (`\1` ties the close
    # tag to the same level as the open tag.)
    markers = Tuple{Int,String}[]
    for h in eachmatch(r"(?is)<(h[1-6])\b[^>]*>(.*?)</\1>", body)
        push!(markers, (h.offset, norm(h.captures[2])))
    end

    # Step 3 — parse the table of contents into an id -> label map, and add a
    # marker for each element the TOC targets. The TOC gives section anchors a
    # human label (and `toc_links` carries cross-file hrefs for Step 8).
    toc_links = Tuple{String,String}[]                      # (href, label)
    for a in eachmatch(r"(?is)<a\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", body)
        label = norm(a.captures[2])
        isempty(label) || push!(toc_links, (String(a.captures[1]), label))
    end
    # id -> label, for same-document (#id) targets. A TOC row is often several
    # links to the same target ("Item 1A." / "Risk Factors" / "5"); join them so
    # the section name is preserved rather than overwritten by the page number.
    id_label = Dict{String,String}()
    for (href, label) in toc_links
        startswith(href, "#") || continue
        id = href[2:end]
        id_label[id] = haskey(id_label, id) ? id_label[id] * " " * label : label
    end
    # Add a marker only for elements the TOC actually targets. Filings tag nearly
    # every inline value with an id (XBRL facts etc.); treating all of them as
    # section starts would chop a section at its first inline anchor, so we keep
    # only the TOC-target ids (real section starts) plus the headings from Step 2.
    for e in eachmatch(r"(?is)<[a-z][a-z0-9]*\b[^>]*\b(?:id|name)=[\"']([^\"']+)[\"'][^>]*>", body)
        id = String(e.captures[1])
        haskey(id_label, id) || continue
        # Fold the de-slugified id into the label as well. Some filers (e.g.
        # Microsoft) link only the section *title* in the TOC and put the item
        # number in the id ("item_1a_risk_factors"), so this lets a query like
        # "Item 1A" match too; an opaque id (Apple's "i7193…_94") is harmless noise.
        push!(markers, (e.offset, id_label[id] * " " * replace(id, r"[_\-]+" => " ")))
    end

    # Step 4 — merge into one document-order boundary list. Headings and anchors
    # often coincide (a heading just inside its anchored <div>); collapse the two
    # only when nothing but tags/whitespace separates them — never two markers with
    # real text between them — keeping the labelled one.
    sort!(markers, by = first)
    boundaries = Tuple{Int,String}[]
    for (off, label) in markers
        if !isempty(boundaries) &&
           isempty(strip(replace(body[first(boundaries[end]):prevind(body, off)], r"(?is)<[^>]*>" => "")))
            # same boundary as the previous marker: fill in a label if we lacked one
            isempty(last(boundaries[end])) && !isempty(label) && (boundaries[end] = (first(boundaries[end]), label))
        else
            push!(boundaries, (off, label))
        end
    end

    # Step 5 — match each requested name to its best boundary. An exact
    # case-insensitive substring (e.g. "Item 7" inside "Item 7. Management's…")
    # wins outright; otherwise fall back to fuzzy similarity. Records the index
    # into `boundaries` so Step 6 can slice to the next one.
    best_boundary = Dict{String,Int}()
    for name in names
        needle = lowercase(strip(name))
        best_i = 0; best_score = 0.0
        for (i, (_, label)) in enumerate(boundaries)
            isempty(label) && continue
            score = occursin(needle, lowercase(label)) ? 1.0 : similarity_ratio(name, label)
            if score > best_score
                best_score = score; best_i = i
            end
        end
        best_score > 0.6 && (best_boundary[name] = best_i)
    end

    # Step 6 — slice each matched section: from its boundary offset up to the start
    # of the *next* boundary (or end of body), then strip to plain text. Slicing to a
    # boundary is what makes nesting irrelevant.
    #
    # One refinement: a top-level "Item N" often contains its own sub-sections that
    # are themselves TOC targets (Item 8's Balance Sheets, Income Statements, Notes,
    # …). Stopping at the first of those would truncate the item to its heading, so
    # when the matched boundary names an item, the section runs to the next boundary
    # that names a *different* item — skipping the sub-sections in between.
    item_no(label) = (m = match(r"(?i)\bitem\s+(\d+[a-z]?)\b", label); m === nothing ? nothing : lowercase(m.captures[1]))
    for (name, i) in best_boundary
        start = first(boundaries[i])
        cur = item_no(boundaries[i][2])
        j = i + 1
        if cur !== nothing
            # advance past sub-sections (no item, or the same item) to the next
            # boundary that names a different item
            while j <= length(boundaries)
                nj = item_no(boundaries[j][2])
                (nj !== nothing && nj != cur) && break
                j += 1
            end
        end
        stop = j <= length(boundaries) ? prevind(body, first(boundaries[j])) : lastindex(body)
        results[name] = clean_text(body[start:stop])
    end

    # Step 8 — cross-file links. A TOC entry may point into another document
    # ("other_page.html#item7"). For any name not found in this body, match it
    # against the TOC link labels; if the best link carries a file part, load that
    # file (locally via `base_path`, or remotely) and extract the section from it.
    for name in names
        haskey(results, name) && continue
        needle = lowercase(strip(name))
        best_href = ""; best_score = 0.0
        for (href, label) in toc_links
            score = occursin(needle, lowercase(label)) ? 1.0 : similarity_ratio(name, label)
            if score > best_score
                best_score = score; best_href = href
            end
        end
        best_score > 0.6 || continue
        file = first(split(best_href, '#'))
        isempty(file) && continue                       # same-document, already handled
        other_html = if occursin("://", file) || startswith(file, "//")
            raw = fetch_url(file); raw === nothing ? nothing : String(raw)
        elseif base_path !== nothing
            p = joinpath(dirname(base_path), file); isfile(p) ? read(p, String) : nothing
        else
            nothing
        end
        other_html === nothing && continue
        sub = extract_section(other_html, [name])
        haskey(sub, name) && (results[name] = sub[name])
    end

    # Step 9 — last-resort plain-text fallback for a body with no usable TOC or
    # headings. Search the cleaned text for the name with flexible whitespace and
    # return from the match to the end of the text. The index comes from the *same*
    # string we searched, so it stays aligned (the previous implementation searched a
    # stripped copy but sliced the original, misaligning the result).
    local plain
    for name in names
        haskey(results, name) && continue
        @isdefined(plain) || (plain = clean_text(body))
        pat = Regex(join((replace(w, r"([\\^\$.|?*+()\[\]{}])" => s"\\\1") for w in split(strip(name))), "\\s+"), "i")
        r = findfirst(pat, plain)
        r === nothing && continue
        results[name] = strip(plain[first(r):end])
    end

    return results
end

