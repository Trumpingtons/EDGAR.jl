# Cross-Reference Index strategy — a faithful port of edgartools' edgar/documents/cross_reference_index.py.
# A few 10-Ks (GE, Henry Schein — issue #107) carry no in-body "Item N" headers at all; instead a
# "FORM 10-K CROSS-REFERENCE INDEX" table maps each item to PAGE ranges, and content is sliced out between
# page-break markers (<hr|div style="page-break-after:always">). `sections()` prefers this whenever the
# index is present, exactly as edgartools' TenK.__getitem__ does.

"""A page or inclusive page range from a cross-reference index."""
struct PageRange
    start::Int
    stop::Int
end

# PageRange.parse — "26-33", "4-7, 9-11", "25", "77-78, (a)" → [PageRange...].
function _parse_pageranges(page_str::AbstractString)
    (isempty(page_str) || lowercase(strip(page_str)) == "not applicable") && return PageRange[]
    s = replace(page_str, "&#8211;" => "-", "–" => "-")
    out = PageRange[]
    for part0 in split(s, ',')
        part = strip(part0)
        any(isdigit, part) || continue
        part = strip(replace(part, r"\([^)]*\)" => ""))
        isempty(part) && continue
        if occursin('-', part)
            a, b = split(part, '-', limit = 2)
            sa = tryparse(Int, strip(a)); sb = tryparse(Int, strip(b))
            (sa === nothing || sb === nothing) && continue
            push!(out, PageRange(sa, sb))
        else
            p = tryparse(Int, strip(part)); p === nothing && continue
            push!(out, PageRange(p, p))
        end
    end
    return out
end

"""One row of a cross-reference index: an item, its title, and the pages its content spans."""
mutable struct IndexEntry
    item_number::String
    item_title::String
    pages::Vector{PageRange}
    part::Union{Nothing,String}
end

const _CROSS_REF_HEADING = r"FORM\s+10-K\s+CROSS[- ]?REFERENCE\s+INDEX"i

# has_index — the heading plus a recognisable Item 1A / Risk Factors / page-number row.
function _has_cross_ref_index(html::AbstractString)
    occursin(_CROSS_REF_HEADING, html) || return false
    return occursin(r"<td[^>]*>.*?(?:Item\s+)?1A\..*?</td>.*?<td[^>]*>.*?Risk\s+Factors.*?</td>.*?<td[^>]*>.*?\d+(?:(?:&#8211;|-)\d+)?.*?</td>"is, html)
end

# _find_index_table — the heading may appear twice (TOC link + real table); use the last, and handle the
# heading being inside the table (GE) or just before it (Citigroup).
function _find_index_table(html::AbstractString)
    ms = collect(eachmatch(_CROSS_REF_HEADING, html))
    isempty(ms) && return nothing
    hpos = ms[end].offset
    lo = max(1, hpos - 5000)
    preceding = SubString(html, thisind(html, lo), prevind(html, hpos))
    lopen = findlast("<table", preceding)
    lclose = findlast("</table>", preceding)
    if lopen !== nothing && (lclose === nothing || first(lopen) > first(lclose))
        table_start = thisind(html, lo) + first(lopen) - 1
    else
        f = findnext("<table", html, hpos)
        f === nothing && return nothing
        table_start = first(f)
    end
    e = findnext("</table>", html, table_start)
    e === nothing && return nothing
    return SubString(html, table_start, last(e))
end

# Minimal HTML-entity unescape for index cell titles.
function _unescape(s::AbstractString)
    s = replace(s, r"&#(\d+);" => m -> string(Char(parse(Int, m[3:end-1]))))
    s = replace(s, r"&#[xX]([0-9A-Fa-f]+);" => m -> string(Char(parse(Int, m[4:end-1], base = 16))))
    for (e, c) in ("&amp;" => "&", "&nbsp;" => " ", "&lt;" => "<", "&gt;" => ">", "&#160;" => " ")
        s = replace(s, e => c)
    end
    return s
end

# CrossReferenceIndex.parse — rows → IndexEntry, with Part headers and page-continuation rows. Ordered.
function _parse_index(html::AbstractString)
    table = _find_index_table(html)
    entries = IndexEntry[]
    table === nothing && return entries
    current_part = nothing
    last_entry = nothing
    for row in eachmatch(r"<tr[^>]*>(.*?)</tr>"s, table)
        cell_texts = String[]
        for cell in eachmatch(r"<td[^>]*>(.*?)</td>"s, row.captures[1])
            t = strip(replace(cell.captures[1], r"<[^>]+>" => ""))
            (isempty(t) || t == "&#160;" || t == " ") || push!(cell_texts, String(t))
        end
        isempty(cell_texts) && continue
        pm = match(r"^Part\s+(I+|IV)"i, cell_texts[1])
        if pm !== nothing
            current_part = "Part " * uppercase(pm.captures[1])
            continue
        end
        im = match(r"^(?:Item\s+)?(\d+[A-Z]?)\.?$"i, cell_texts[1])
        if im !== nothing
            title = length(cell_texts) > 1 ? _unescape(cell_texts[2]) : ""
            page_str = length(cell_texts) > 2 ? cell_texts[3] : ""
            entry = IndexEntry(uppercase(im.captures[1]), title, _parse_pageranges(page_str), current_part)
            push!(entries, entry); last_entry = entry
            continue
        end
        combined = join(cell_texts, " ")
        if last_entry !== nothing && match(r"^[\d,\s&#;.\-–]+$", combined) !== nothing
            append!(last_entry.pages, _parse_pageranges(combined))
        end
    end
    return entries
end

# find_page_breaks — char positions just after each page-break element (document start is page 1).
function _find_page_breaks(html::AbstractString)
    breaks = Int[1]
    for pat in (r"<hr\s+[^>]*style=\"[^\"]*page-break-after\s*:\s*always[^\"]*\"[^>]*/?>"i,
                r"<div\s+[^>]*style=\"[^\"]*page-break-after\s*:\s*always[^\"]*\"[^>]*>"i)
        for m in eachmatch(pat, html)
            push!(breaks, thisind(html, min(ncodeunits(html), m.offset + ncodeunits(m.match))))
        end
    end
    return sort!(unique!(breaks))
end

# extract_content_by_page_range — the HTML between the page-break markers bounding the range.
function _extract_by_pagerange(html::AbstractString, breaks::Vector{Int}, pr::PageRange)
    length(breaks) < pr.stop && return nothing
    start_idx = breaks[pr.start]
    end_idx = pr.stop >= length(breaks) ? lastindex(html) : prevind(html, breaks[pr.stop + 1])
    return SubString(html, start_idx, end_idx)
end

# extract_item_content — concatenated HTML for all of an item's page ranges.
function _extract_item_content(html::AbstractString, breaks, entry::IndexEntry)
    isempty(entry.pages) && return nothing
    parts = String[]
    for pr in entry.pages
        c = _extract_by_pagerange(html, breaks, pr)
        c !== nothing && push!(parts, String(c))
    end
    return isempty(parts) ? nothing : join(parts, "\n")
end

# Build item sections from a filing that uses the cross-reference index format.
function _sections_cross_ref(html::AbstractString)
    entries = _parse_index(html)
    breaks = _find_page_breaks(html)
    out = @NamedTuple{item::String, title::String, text::String}[]
    for e in entries
        htmlslice = _extract_item_content(html, breaks, e)
        htmlslice === nothing && continue
        text = join((b.text for b in _dom_blocks(htmlslice)), "\n\n")
        isempty(strip(text)) && continue
        push!(out, (item = "Item $(e.item_number)", title = String(first(e.item_title, 100)), text = text))
    end
    return out
end
