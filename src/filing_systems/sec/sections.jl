# Item segmentation. `sections(::AbstractString)` now delegates to the faithful EzXML `ChunkedDoc` module
# (chunked_document.jl), which is the char-validated port of edgartools' `ChunkedDocument`. The legacy
# in-file block/chunk/segment machinery below (TextAnalysis / _chunks / _segment) is superseded and unused;
# the only piece still live is `_dom_blocks` (now on EzXML), used by cross_reference.jl's cross-ref-index
# path. The cross-reference-index strategy (GE/Henry-Schein) is still preferred when present.

# --- HTML -> text blocks (EzXML/libxml2 DOM) — used by cross_reference.jl's cross-ref-index path ------

const _BLOCK_TAGS = Set([:p, :div, :li, :h1, :h2, :h3, :h4, :h5, :h6, :section, :article, :blockquote,
                         :dt, :dd, :figure, :center, :caption])
const _SKIP_TAGS = Set([:script, :style, :head, :title, :noscript])

"""One block of filing text. `table` marks a block rendered from an HTML table (its own chunk)."""
struct Block
    text::String
    table::Bool
end

_norm(s::AbstractString) = strip(replace(s, r"[\s ]+" => " "))   # fold whitespace + nbsp (libxml2 decodes entities)

_tagsym(node) = Symbol(lowercase(EzXML.nodename(node)))   # EzXML/libxml2 element tag as a Symbol

# All descendant text of a node, joined — used to render a <table> as one block.
function _alltext(node, io)
    if EzXML.istext(node)
        print(io, EzXML.nodecontent(node), " ")
    elseif EzXML.iselement(node) && !(_tagsym(node) in _SKIP_TAGS)
        for c in EzXML.eachnode(node)
            _alltext(c, io)
        end
    end
    return io
end

# Walk the DOM, pushing one `Block` per block-level element (a <table> becomes a single table block).
# Returns this node's inline text contribution so an enclosing block can gather it.
function _emit!(blocks::Vector{Block}, node)
    EzXML.istext(node) && return EzXML.nodecontent(node)
    EzXML.iselement(node) || return ""
    tag = _tagsym(node)
    tag in _SKIP_TAGS && return ""
    tag === :br && return " "
    if tag === :table
        t = _norm(String(take!(_alltext(node, IOBuffer()))))
        isempty(t) || push!(blocks, Block(t, true))
        return ""
    end
    buf = IOBuffer()
    for ch in EzXML.eachnode(node)
        print(buf, _emit!(blocks, ch))
    end
    inline = String(take!(buf))
    if tag in _BLOCK_TAGS
        t = _norm(inline)
        isempty(t) || push!(blocks, Block(t, false))
        return ""
    end
    return inline
end

function _dom_blocks(html::AbstractString)
    s = String(html)
    startswith(s, "<?xml") && (s = replace(s, r"<\?xml[^>]*\?>" => ""; count = 1))
    blocks = Block[]
    _emit!(blocks, EzXML.root(EzXML.parsehtml(s)))
    return blocks
end

# The human title: the heading line with its "Item N" prefix removed (or the line that follows).
function _title(text)
    lines = split(text, '\n')
    t = strip(replace(lines[1], r"^\s*item\s+\d{1,2}[A-Z]?\s*[.\-—:]*\s*"i => ""))
    isempty(t) && length(lines) > 1 && (t = strip(lines[2]))
    return String(first(t, 100))
end

"""
    sections(f::Filing; form="10-K") -> Vector{@NamedTuple{item::String, title::String, text::String}}
    sections(html; form="10-K") -> …

Segment a filing's text into its **items** (`"Item 1"`, `"Item 1A"`, …), in document order. This is a
form-agnostic port of edgartools' `ChunkedDocument`: blocks are grouped into chunks, each chunk's leading
`Item N` line sets its item, the table-of-contents chunk is dropped by item density, the item label is
forward-filled, and the signature block truncates the tail — so the same logic serves 10-K, 10-Q, 20-F,
8-K and other item-structured forms without a per-form catalogue. `form` is accepted for symmetry with
[`extract_section`](@ref) but does not drive the algorithm.
"""
function sections(html::AbstractString; form::AbstractString = "10-K")
    # Some filings (GE, Henry Schein) have no in-body "Item N" headers — only a cross-reference index that
    # maps items to page ranges. Prefer it when present, exactly as edgartools does.
    _has_cross_ref_index(html) && return _sections_cross_ref(html)
    # Otherwise delegate to the faithful EzXML ChunkedDocument port (char-identical to edgartools), instead
    # of the older in-file Gumbo block/chunk/segment machinery.
    cd = ChunkedDoc.ChunkedDocument(html; item_detector = ChunkedDoc.detect_int_item)
    out = @NamedTuple{item::String, title::String, text::String}[]
    for it in ChunkedDoc.list_items(cd)
        t = ChunkedDoc.getindex_item(cd, it)
        t === nothing && continue
        push!(out, (item = it, title = _title(t), text = t))
    end
    return out
end

# Logical order for a detected Document section (part then item, e.g. Part I < Part II; Item 1 < Item 1A < Item 2).
function _doc_section_order(s)
    p = s.part === nothing ? 0 : something(findfirst(==(uppercase(s.part)), ("I", "II", "III", "IV", "V")), 9)
    i = 9999
    if s.item !== nothing
        m = match(r"(\d+)([A-Za-z]?)", s.item)
        m !== nothing && (i = parse(Int, m.captures[1]) * 100 + (isempty(m.captures[2]) ? 0 : Int(uppercase(m.captures[2])[1]) - Int('A') + 1))
    end
    return p * 100000 + i
end

"""
    sections(f::Filing; form="10-K") -> Vector{@NamedTuple{item::String, title::String, text::String}}

Segment a filing into its items/sections using the faithful [`Documents`](@ref) parser — a Julia port of
edgartools' `edgar/documents` document parser + multi-strategy section detection (TOC → heading → pattern).
Falls back to the form-agnostic [`sections(::AbstractString)`](@ref) ChunkedDocument segmentation if
detection yields nothing.
"""
function sections(f::Filing; form::AbstractString = "10-K")
    try
        doc = Documents.parse_filing(Documents.HTMLParser(), f.content; form = form)
        secs = Documents.sections(doc)
        if !isempty(secs)
            out = @NamedTuple{item::String, title::String, text::String}[]
            for s in sort(collect(values(secs)); by = _doc_section_order)
                item = s.item === nothing ? s.title :
                       (s.part === nothing ? "Item $(s.item)" : "Part $(s.part), Item $(s.item)")
                push!(out, (item = item, title = s.title, text = Documents.section_text(s)))
            end
            return out
        end
    catch
    end
    return sections(f.content; form)   # fallback: form-agnostic ChunkedDocument segmentation
end

"""
    extract_items_from_sections(secs, pattern::Regex) -> Vector{String}

Extract item identifiers from a [`sections`](@ref) result by matching `pattern` (which must contain a
capture group) against each section's `title`. When the title does not start with the pattern, falls back
to the text before `" - "`, else the whole title. A faithful port of edgartools' shared
`extract_items_from_sections` (e.g. `r"(Item\\s+\\d+\\.\\s*\\d+)"` for 8-K, `r"(Item\\s+\\d+[A-Z]?)"` for 20-F).
"""
function extract_items_from_sections(secs, pattern::Regex)
    items = String[]
    for s in secs
        title = s.title
        m = match(pattern, title)
        if m !== nothing && m.offset == 1
            push!(items, String(m.captures[1]))
        elseif occursin(" - ", title)
            push!(items, String(strip(first(split(title, " - ")))))
        else
            push!(items, String(title))
        end
    end
    return items
end
