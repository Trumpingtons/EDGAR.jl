# Item segmentation — a faithful port of edgartools' `ChunkedDocument` (edgar/files/htmltools.py +
# html_documents.py). The approach is *form-agnostic*: there is no per-form item catalogue. The document is
# split into text blocks, blocks are grouped into chunks (a new chunk begins at each Item / Part / header
# block; a table is its own chunk), each chunk's leading line decides its Item via a generic `^Item N`
# regex, the table-of-contents chunk is detected by item density and cleared, the Item label is
# forward-filled down the chunks, the signature block truncates the tail, and chunks are grouped by Item.
# Header vs. regular-text is decided purely by word case (title/upper ratios) and word count — exactly as
# edgartools does — so the same code serves 10-K, 10-Q, 20-F, 8-K and the rest. The only substitution from
# the Python original is HTML→text-blocks, where we walk Gumbo's DOM instead of edgartools' tokenizer.

# --- HTML -> text blocks (Gumbo DOM) -------------------------------------------------------------------

const _BLOCK_TAGS = Set([:p, :div, :li, :h1, :h2, :h3, :h4, :h5, :h6, :section, :article, :blockquote,
                         :dt, :dd, :figure, :center, :caption])
const _SKIP_TAGS = Set([:script, :style, :head, :title, :noscript])

"""One block of filing text. `table` marks a block rendered from an HTML table (its own chunk)."""
struct Block
    text::String
    table::Bool
end

_norm(s::AbstractString) = strip(replace(s, r"[\s ]+" => " "))   # fold whitespace + nbsp (Gumbo decodes entities)

# All descendant text of a node, joined — used to render a <table> as one block.
function _alltext(node, io)
    if node isa HTMLText
        print(io, node.text, " ")
    elseif node isa HTMLElement && !(Gumbo.tag(node) in _SKIP_TAGS)
        for c in node.children
            _alltext(c, io)
        end
    end
    return io
end

# Walk the DOM, pushing one `Block` per block-level element (a <table> becomes a single table block).
# Returns this node's inline text contribution so an enclosing block can gather it.
function _emit!(blocks::Vector{Block}, node)
    node isa HTMLText && return node.text
    node isa HTMLElement || return ""
    tag = Gumbo.tag(node)
    tag in _SKIP_TAGS && return ""
    tag === :br && return " "
    if tag === :table
        t = _norm(String(take!(_alltext(node, IOBuffer()))))
        isempty(t) || push!(blocks, Block(t, true))
        return ""
    end
    buf = IOBuffer()
    for ch in node.children
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
    blocks = Block[]
    _emit!(blocks, parsehtml(String(html)).root)
    return blocks
end

# --- TextAnalysis (html_documents.py) — header / regular-text by word case, verbatim -------------------

# Python str.isalpha / isupper / istitle for a single token.
_py_isalpha(w) = !isempty(w) && all(isletter, w)
_py_isupper(w) = any(isuppercase, w) && !any(islowercase, w)
function _py_istitle(w)
    seen = false; prev_cased = false
    for c in w
        if isuppercase(c)
            prev_cased && return false
            prev_cased = true; seen = true
        elseif islowercase(c)
            prev_cased || return false
            prev_cased = true; seen = true
        else
            prev_cased = false
        end
    end
    return seen
end

struct TextAnalysis
    num_words::Int
    num_upper::Int
    num_title::Int
end
function TextAnalysis(text::AbstractString)
    trimmed = replace(text, r"[^a-zA-Z0-9\s]+" => "")           # _get_alpha_words: strip punctuation, keep digits/space
    words = filter(_py_isalpha, split(trimmed))                  # then keep purely-alphabetic tokens
    TextAnalysis(length(words), count(_py_isupper, words), count(_py_istitle, words))
end
_is_header(a::TextAnalysis) = a.num_words > 0 &&
    (a.num_title / a.num_words > 0.6 || a.num_upper / a.num_words > 0.6)
_is_regular_text(a::TextAnalysis) = a.num_words > 25

# --- Item / Part / TOC / signature detectors (htmltools.py + html_documents.py), verbatim --------------

const _ITEM_HEADER_RE = r"^(?:ITEM|Item)\s+(?:[0-9]{1,2}[A-Z]?\.?|[0-9]{1,2}\.[0-9]{2})"   # chunker (re.match)
const _INT_ITEM_RE = r"(?im)^(Item\s{1,3}[0-9]{1,2}[A-Z]?)\.?"                              # chunks2df extractor
const _PART_RE = r"(?im)^\b(PART\s+[IVXLC]+)\b"

_detect_toc(text) = count(_ -> true, eachmatch(r"item"i, text)) > 10        # text.lower().count('item') > 10
_detect_signature(text) = match(r"(?im)^SIGNATURE", text) !== nothing ||
                          occursin("to be signed on its behalf by the undersigned", text)

# --- generate_chunks (html_documents.py 511-587), ported flag-for-flag ---------------------------------

function _chunks(blocks::Vector{Block})
    chunks = Vector{Block}[]
    cur = Block[]
    nonempty(c) = any(b -> !isempty(strip(b.text)), c)
    flush!() = (nonempty(cur) && push!(chunks, copy(cur)); empty!(cur))
    accumulating = false; header_detected = false; item_header = false
    for b in blocks
        if b.table
            flush!()
            push!(chunks, [b])
            accumulating = false; header_detected = false; item_header = false
            continue
        end
        a = TextAnalysis(b.text)
        is_item = match(_ITEM_HEADER_RE, b.text) !== nothing
        is_part = match(_PART_RE, b.text) !== nothing
        if is_part
            flush!()
            push!(chunks, [b])
            item_header = true; header_detected = true; accumulating = false
        elseif is_item
            flush!()
            push!(cur, b)
            item_header = true; header_detected = true; accumulating = false
        elseif _is_header(a)
            if !isempty(cur) && !accumulating && !item_header
                flush!()
            end
            header_detected = true; accumulating = false
            push!(cur, b); item_header = false
        elseif _is_regular_text(a) && (header_detected || accumulating)
            push!(cur, b); accumulating = true; item_header = false
        else
            if accumulating || item_header
                flush!()
                accumulating = false; header_detected = false; item_header = false
            end
            push!(cur, b)
        end
    end
    nonempty(cur) && push!(chunks, copy(cur))
    return chunks
end

# --- chunks2df + forward-fill (htmltools.py 268-330), ported ------------------------------------------

_chunk_text(c::Vector{Block}) = join((b.text for b in c), "\n")

# Forward-fill: `nothing` carries the previous label down; an explicit value (including "") sets it.
function _ffill(detected::Vector{Union{Nothing,String}})
    out = Vector{String}(undef, length(detected)); last = ""
    for i in eachindex(detected)
        detected[i] !== nothing && (last = detected[i])
        out[i] = last
    end
    return out
end

function _segment(chunks::Vector{Vector{Block}})
    n = length(chunks)
    texts = _chunk_text.(chunks)
    detected = Union{Nothing,String}[nothing for _ in 1:n]
    for i in 1:n
        m = match(_INT_ITEM_RE, texts[i])
        m !== nothing && (detected[i] = titlecase(replace(m.captures[1], r"\s+" => " ")))
    end
    # Table-of-contents chunks (item density) clear the item, within the first 100 chunks (df.Text.head(100)).
    for i in 1:min(n, 100)
        _detect_toc(texts[i]) && (detected[i] = "")
    end
    items = _ffill(detected)
    # The signature block truncates everything after it.
    sig = findfirst(_detect_signature, texts)
    sig !== nothing && (for i in sig:n; items[i] = ""; end)
    # Group chunks by item, in first-appearance order.
    order = String[]; buckets = Dict{String,Vector{Int}}()
    for i in 1:n
        it = items[i]; isempty(it) && continue
        haskey(buckets, it) || (push!(order, it); buckets[it] = Int[])
        push!(buckets[it], i)
    end
    return [(item = it, text = join((texts[i] for i in buckets[it]), "\n\n")) for it in order]
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
    segs = _segment(_chunks(_dom_blocks(html)))
    return [(item = s.item, title = _title(s.text), text = s.text) for s in segs]
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
