# Faithful translation of edgartools' (deprecated) ChunkedDocument: edgar/files/html_documents.py +
# edgar/files/htmltools.py. Parses with EzXML (libxml2 = the same engine as edgartools' BeautifulSoup
# 'lxml'), builds the Block model, removes page numbers / TOC links / comments, compresses blocks, groups
# them into item chunks, and renders item text via the faithful table renderer. Used as TwentyF's item
# fallback (items the Documents parser's TOC detection misses). edgartools is retiring this in v6.0; when
# it does, we follow.
module ChunkedDoc

using EzXML

# --- EzXML DOM helpers mirroring the BeautifulSoup API the source uses --------------------------------
_iscomment(n) = nodetype(n) == EzXML.COMMENT_NODE
_name(n) = iselement(n) ? lowercase(nodename(n)) : nothing      # Tag.name (None for NavigableString/Comment)
_attr(n, k, d = "") = (iselement(n) && haskey(n, k)) ? n[k] : d
_textcontent(n) = nodecontent(n)                                # Tag.get_text() / .text
_childnodes(n) = collect(eachnode(n))                           # .children/.contents (text+elem+comment)
function _find_all(n, tags)                                     # descendant elements whose name ∈ tags (pre-order)
    out = EzXML.Node[]
    for c in eachnode(n)
        if iselement(c)
            lowercase(nodename(c)) in tags && push!(out, c)
            append!(out, _find_all(c, tags))
        end
    end
    return out
end
_find_first(n, tag) = (r = _find_all(n, Set([tag])); isempty(r) ? nothing : r[1])

# --- Block model (html_documents.py) ------------------------------------------------------------------
abstract type Block end
mutable struct TextBlock <: Block
    text::String
    inline::Bool
    element::Union{Nothing,String}
    # Inner constructor with defaults: `new` converts args to the field types (as the auto-generated
    # constructor would) while *suppressing* the auto-generated 3-arg default constructor. Defining the
    # defaults as a same-signature OUTER constructor instead overwrites that default constructor — a
    # method overwrite Julia ≥1.12 rejects during precompilation. Behavior is unchanged.
    TextBlock(text, inline = false, element = nothing) = new(text, inline, element)
end
mutable struct TableBlock <: Block
    table_element::Any
    _cached::Union{Nothing,String}
end
TableBlock(el) = TableBlock(el, nothing)
mutable struct LinkBlock <: Block
    text::String
    tag::String
    alt::String
    src::String
    inline::Bool
end
LinkBlock(text, tag, alt, src) = LinkBlock(text, tag, alt, src, true)

get_text(b::TextBlock) = b.text
get_text(b::LinkBlock) = "<$(b.tag) alt=\"$(b.alt)\" src=\"$(b.src)\">"
function get_text(b::TableBlock)
    b._cached === nothing && (b._cached = "\n" * table_to_text(b.table_element) * "\n")
    return b._cached
end
to_markdown(b::TextBlock) = b.text
to_markdown(b::LinkBlock) = "![alt  $(b.alt)]($(b.src))\n"
to_markdown(b::TableBlock) = table_to_markdown(b.table_element)   # detection-phase rendering
is_empty(b::Block) = !is_linebreak(b) && isempty(strip(get_text(b)))
is_linebreak(b::Block) = (t = get_text(b); t != "" && isempty(strip(t, ['\n'])))
is_empty(b::TableBlock) = false
is_linebreak(b::TableBlock) = false
block_inline(b::TextBlock) = b.inline
block_inline(b::LinkBlock) = b.inline
block_inline(b::TableBlock) = false
block_element(b::TextBlock) = b.element
block_element(b::Block) = nothing

# --- text helpers -------------------------------------------------------------------------------------
fixup(text::AbstractString) = replace(text, r"\xa0|[^\S\n]+" => " ")
replace_inline_newlines(text::AbstractString) = replace(text, "\n" => " ")
const _COMMON_WORDS = Set(["and","or","but","the","a","an","in","with","for","on","at","to","of","by","as"])
_py_isalpha(w) = !isempty(w) && all(isletter, w)
_py_isupper(w) = any(isuppercase, w) && !any(islowercase, w)
function _py_istitle(w)
    seen = false; prev = false
    for c in w
        if isuppercase(c); prev && return false; prev = true; seen = true
        elseif islowercase(c); prev || return false; prev = true; seen = true
        else; prev = false; end
    end
    return seen
end

function is_header(text::AbstractString)
    trimmed = replace(text, r"^(\d+\.|\w\.\s|\(\d+\)\s)" => ""; count = 1)
    isempty(trimmed) && return false
    words = [w for w in split(trimmed) if _py_isalpha(w)]
    isempty(words) && return false
    tc = count(w -> _py_istitle(w) || lowercase(w) in _COMMON_WORDS, words)
    uc = count(_py_isupper, words)
    return tc / length(words) > 0.6 || uc / length(words) > 0.6
end

# TextAnalysis (html_documents.py)
struct TextAnalysis
    num_words::Int
    num_upper::Int
    num_title::Int
end
function TextAnalysis(text::AbstractString)
    trimmed = replace(text, r"[^a-zA-Z0-9\s]+" => "")
    words = [w for w in split(trimmed) if _py_isalpha(w)]
    TextAnalysis(length(words), count(_py_isupper, words), count(_py_istitle, words))
end
ta_is_header(a::TextAnalysis) = a.num_words > 0 && (a.num_title / a.num_words > 0.6 || a.num_upper / a.num_words > 0.6)
ta_is_regular_text(a::TextAnalysis) = a.num_words > 25

const _ITEM_PATTERN = r"(?:ITEM|Item)\s+(?:[0-9]{1,2}[A-Z]?\.?|[0-9]{1,2}\.[0-9]{2})"   # re.match (anchored)
const _PART_PATTERN = r"^\b(PART\s+[IVXLC]+)\b"i
_match_start(re, s) = (m = match(re, s); m !== nothing && m.offset == 1)

# --- table renderers (html_documents.py) --------------------------------------------------------------
_clean_column_text(s::AbstractString) = strip(replace(s, r"\s+" => " "))

function clean_cell_text(col)
    t = replace(string(col), r"<br\s*/?>" => "\n")
    t = replace(t, r"<[^>]+>" => "")
    lines = [join(split(strip(line)), " ") for line in split(t, '\n') if !isempty(strip(line))]
    return join(lines, "\n")
end

function process_row(row)
    cells = _find_all(row, Set(["td", "th"]))
    out = Tuple{String,Int,Int}[]
    i = 1
    while i <= length(cells)
        content = clean_cell_text(cells[i])
        colspan = something(tryparse(Int, _attr(cells[i], "colspan", "1")), 1)
        rowspan = something(tryparse(Int, _attr(cells[i], "rowspan", "1")), 1)
        if content == "\$" && i + 1 <= length(cells)
            nxt = clean_cell_text(cells[i + 1])
            content = "\$$nxt"
            colspan += something(tryparse(Int, _attr(cells[i + 1], "colspan", "1")), 1)
            i += 1
        elseif isempty(strip(content)) && i + 1 <= length(cells)
            nxt = clean_cell_text(cells[i + 1])
            if _py_isdigit(replace(nxt, "." => ""; count = 1))
                content = nxt
                colspan += something(tryparse(Int, _attr(cells[i + 1], "colspan", "1")), 1)
                i += 1
            end
        end
        push!(out, (content, colspan, rowspan))
        i += 1
    end
    return out
end
_py_isdigit(s) = !isempty(s) && all(isdigit, s)

function detect_header_rows(rows)
    header_rows = EzXML.Node[]
    for row in rows
        if _find_first(row, "th") !== nothing
            push!(header_rows, row)
        elseif isempty(header_rows)
            push!(header_rows, row)
        else
            break
        end
    end
    return header_rows
end

function merge_header_rows(header_rows_processed)
    processed = [[(split(content, '\n'), colspan) for (content, colspan, _) in row] for row in header_rows_processed]
    isempty(processed) && return Vector{Tuple{String,Int}}[]
    max_lines = maximum((length(lines) for row in processed for (lines, _) in row); init = 1)
    merged = Vector{Tuple{String,Int}}[]
    for i in 1:max_lines
        line = Tuple{String,Int}[]
        for row in processed
            for (lines, colspan) in row
                push!(line, (i <= length(lines) ? String(lines[i]) : "", colspan))
            end
        end
        push!(merged, line)
    end
    if all(isempty(line[1][1]) for line in merged if !isempty(line))
        for line in merged
            isempty(line) || (line[1] = (" ", line[1][2]))
        end
    end
    return merged
end

is_numeric_or_financial(value::AbstractString) = match(r"^[\$€£(-]?\s{0,2}\d", strip(value)) !== nothing

function determine_column_justification(all_rows)
    max_cols = maximum((sum(c for (_, c, _) in row; init = 0) for row in all_rows); init = 0)
    just = fill("left", max_cols)
    for col in 0:(max_cols - 1)
        numeric = 0; total = 0; colspan_at = 1
        for row in all_rows
            ci = 0
            for (content, colspan, _) in row
                if ci <= col < ci + colspan
                    if !isempty(strip(content))
                        total += 1
                        is_numeric_or_financial(content) && (numeric += 1)
                    end
                    colspan_at = colspan
                    break
                end
                ci += colspan
            end
        end
        if numeric > 1 && total > 0 && numeric / total > 0.5
            for i in col:min(col + colspan_at - 1, max_cols - 1)
                just[i + 1] = "right"
            end
        end
    end
    return just
end

_pyljust(s, w) = length(s) >= w ? String(s) : s * " "^(w - length(s))
_pyrjust(s, w) = length(s) >= w ? String(s) : " "^(w - length(s)) * s
function _pycenter(s, w)
    n = length(s); n >= w && return String(s)
    tot = w - n; l = tot ÷ 2; r = tot - l
    return " "^l * s * " "^r
end

function table_to_text(table_tag)
    try
        rows = _find_all(table_tag, Set(["tr"]))
        isempty(rows) && return ""
        header_rows = detect_header_rows(rows)
        all_processed = [process_row(r) for r in rows]
        header_processed = all_processed[1:length(header_rows)]
        data_processed = all_processed[length(header_rows)+1:end]
        merged_header = merge_header_rows(header_processed)
        header_is_empty = all(isempty(strip(content)) for hl in merged_header for (content, _) in hl)
        max_cols = maximum((sum(c for (_, c, _) in row; init = 0) for row in all_processed); init = 0)
        col_widths = zeros(Int, max_cols); non_empty = Set{Int}()
        if !header_is_empty
            for hl in merged_header
                ci = 0
                for (content, colspan) in hl
                    if !isempty(strip(content))
                        cw = maximum((length(l) for l in split(content, '\n')); init = 0)
                        for i in 0:(colspan - 1)
                            if ci + i < max_cols
                                col_widths[ci + i + 1] = max(col_widths[ci + i + 1], cw ÷ max(colspan, 1))
                                push!(non_empty, ci + i)
                            end
                        end
                    end
                    ci += colspan
                end
            end
        end
        for pr in data_processed
            ci = 0
            for (content, colspan, _) in pr
                if !isempty(strip(content))
                    cw = maximum((length(l) for l in split(content, '\n')); init = 0)
                    for i in 0:(colspan - 1)
                        if ci + i < max_cols
                            col_widths[ci + i + 1] = max(col_widths[ci + i + 1], cw ÷ max(colspan, 1))
                            push!(non_empty, ci + i)
                        end
                    end
                end
                ci += colspan
            end
        end
        col_widths = [w for (i, w) in enumerate(col_widths) if (i - 1) in non_empty]
        isempty(col_widths) && return ""
        just = determine_column_justification(all_processed)
        just = [j for (i, j) in enumerate(just) if (i - 1) in non_empty]
        out = String[]
        if !header_is_empty
            for hl in merged_header
                rc = String[]; ci = 0; nec = 0
                for (content, colspan) in hl
                    if any((ci + i) in non_empty for i in 0:(colspan - 1))
                        width = sum(col_widths[nec+1:min(nec + colspan, length(col_widths))]) + 3 * (colspan - 1)
                        push!(rc, _pycenter(content, width))
                        nec += colspan
                    end
                    ci += colspan
                end
                push!(out, join(rc, "   "))
            end
            push!(out, "-"^(sum(col_widths) + 3 * (length(col_widths) - 1)))
        end
        for pr in data_processed
            nonempty_contents = [content for (content, _, _) in pr if !isempty(strip(content))]
            isempty(nonempty_contents) && continue
            nlines = maximum((length(split(c, '\n')) for c in nonempty_contents); init = 1)
            for li in 1:nlines
                ci = 0; cells = String[]; nec = 0
                for (content, colspan, _) in pr
                    if any((ci + i) in non_empty for i in 0:(colspan - 1))
                        width = sum(col_widths[nec+1:min(nec + colspan, length(col_widths))]) + 3 * (colspan - 1)
                        lines = split(content, '\n')
                        if li <= length(lines)
                            if nec < length(just) && just[nec + 1] == "right"
                                push!(cells, _pyrjust(lines[li], width))
                            else
                                push!(cells, _pyljust(lines[li], width))
                            end
                        else
                            push!(cells, " "^width)
                        end
                        nec += colspan
                    end
                    ci += colspan
                end
                push!(out, join(cells, "   "))
            end
        end
        return join(out, "\n")
    catch
        return ""
    end
end

function table_to_markdown(table_tag)
    rows = _find_all(table_tag, Set(["tr"]))
    col_widths = Int[]; col_has = Bool[]
    for row in rows
        cols = _find_all(row, Set(["td", "th"]))
        for (i, col) in enumerate(cols)
            w = length(strip(_textcontent(col)))
            if length(col_widths) < i
                push!(col_widths, w); push!(col_has, w > 0)
            else
                col_widths[i] = max(col_widths[i], w)
                w > 0 && (col_has[i] = true)
            end
        end
    end
    idxs = [i for i in 1:length(col_has) if col_has[i]]
    cw = [col_widths[i] for i in idxs]
    out = ""
    for (index, row) in enumerate(rows)
        cols = _find_all(row, Set(["td", "th"]))
        row_text = String[]
        for (i, col) in enumerate(cols)
            if i in idxs
                ni = findfirst(==(i), idxs)
                push!(row_text, _pyljust(_clean_column_text(_textcontent(col)), cw[ni]))
            end
        end
        if any(!isempty(strip(t)) for t in row_text)
            out *= join(row_text, " | ") * "\n"
            index == 1 && (out *= join(("-"^length(t) for t in row_text), "-+-") * "\n")
        end
    end
    return out
end

# --- DOM cleanup (html_documents.py) ------------------------------------------------------------------
function decompose_toc_links(root)
    for a in _find_all(root, Set(["a"]))
        match(r"Table [Oo]f [cC]ontents", _textcontent(a)) !== nothing && unlink!(a)
    end
end

function decompose_page_numbers(root)
    # edgartools matches BeautifulSoup `string=re.compile(r'^\d{1,3}$')` — the span's text must be EXACTLY a
    # 1-3 digit number (no stripping). Stripping first would wrongly catch numeric table cells that sit next
    # to zero-width spaces, deleting real data. Match the exact (unstripped) text content.
    spans = [s for s in _find_all(root, Set(["span"])) if match(r"^\d{1,3}$", _textcontent(s)) !== nothing]
    current = EzXML.Node[]; prev = nothing
    flush() = (length(current) > 1 && foreach(unlink!, current))
    for tag in spans
        _find_first(tag, "a") !== nothing && continue
        t = _textcontent(tag); isempty(t) && continue
        num = parse(Int, t)
        if prev === nothing || num == prev + 1
            push!(current, tag)
        else
            flush(); current = EzXML.Node[tag]
        end
        prev = num
    end
    flush()
end

function clean_html_root(root)
    for t in _find_all(root, Set(["ix:header"])); unlink!(t); end
    decompose_toc_links(root)
    for t in _find_all(root, Set(["script", "style"])); unlink!(t); end
    _remove_comments(root)
    return root
end

function _remove_comments(n)
    for c in collect(eachnode(n))
        if _iscomment(c)
            unlink!(c)
        elseif iselement(c)
            _remove_comments(c)
        end
    end
end

# --- block extraction + compression (html_documents.py) ----------------------------------------------
const _INLINE_ELEMENTS = Set(["a","span","strong","em","b","i","u","small","font","big","sub","sup","img","label","input","button"])
function is_inline(el)
    nm = _name(el)
    nm === nothing && return false
    nm in _INLINE_ELEMENTS && return true
    startswith(nm, "ix:") && return true
    if iselement(el) && haskey(el, "style")
        for st in split(el["style"], ';')
            s = strip(lowercase(st))
            if startswith(s, "display")
                pv = split(s, ':')
                length(pv) > 1 && strip(pv[2]) == "inline" && return true
            end
        end
    end
    return false
end

function extract_and_format_content(el)
    nm = _name(el)
    if nm == "table"
        return Block[TableBlock(el)]
    elseif nm in ("ul", "ol")
        return Block[TextBlock(fixup(_textcontent(el)), false, nm)]
    elseif nm == "img"
        return Block[LinkBlock(string(el), nm, _attr(el, "alt"), _attr(el, "src"))]
    elseif istext(el)
        return Block[TextBlock(fixup(nodecontent(el)), false, nothing)]
    else
        inline = is_inline(el)
        blocks = Block[]
        kids = _childnodes(el)
        len_children = length(kids)
        for (index, child) in enumerate(kids)
            if _name(child) !== nothing                       # element child
                append!(blocks, extract_and_format_content(child))
                if !inline && !isempty(blocks) && !(blocks[end] isa TableBlock)
                    if !block_inline(blocks[end]) || index == len_children
                        if !isempty(strip(_btext(blocks[end])))
                            _setbtext!(blocks[end], _btext(blocks[end]) * "\n")
                        else
                            _setbtext!(blocks[end], "\n")
                        end
                    end
                end
            elseif istext(child)                              # NavigableString
                s = fixup(replace_inline_newlines(nodecontent(child)))
                if isempty(strip(s)) && !isempty(blocks) && isempty(strip(get_text(blocks[end])))
                    if !endswith(get_text(blocks[end]), "\n")
                        _setbtext!(blocks[end], _btext(blocks[end]) * s)
                    end
                else
                    push!(blocks, TextBlock(s, inline, nm))
                end
            end
        end
        return blocks
    end
end
_btext(b::TextBlock) = b.text
_btext(b::LinkBlock) = b.text
_btext(b::TableBlock) = ""
_setbtext!(b::TextBlock, v) = (b.text = v)
_setbtext!(b::LinkBlock, v) = (b.text = v)
_setbtext!(b::TableBlock, v) = nothing

# edgartools _compress_blocks operates on the raw `.text` field throughout (NOT get_text). This matters for
# LinkBlock/TableBlock, whose `.text` (e.g. "<img…/>\n") differs from get_text() ("<img alt src>"): the
# trailing "\n" on an image block must be seen so it flushes and doesn't swallow the following caption.
_t_is_linebreak(b::Block) = (t = _btext(b); t != "" && isempty(strip(t, ['\n'])))
_t_is_empty(b::Block) = !_t_is_linebreak(b) && isempty(strip(_btext(b)))

function compress_blocks(blocks::Vector{Block})
    compressed = Block[]
    current = nothing
    for b in blocks
        if b isa TableBlock
            current !== nothing && (push!(compressed, current); current = nothing)
            push!(compressed, b)
        else
            if endswith(_btext(b), "\n")
                if current !== nothing
                    if block_inline(current) && block_inline(b)
                        _setbtext!(current, _btext(current) * _btext(b)); push!(compressed, current); current = nothing
                    else
                        push!(compressed, current); push!(compressed, b); current = nothing
                    end
                else
                    push!(compressed, b)
                end
            elseif _t_is_empty(b)
                if current === nothing
                    current = b
                else
                    _setbtext!(current, _btext(current) * _btext(b))
                end
            else
                if current !== nothing
                    _t_is_empty(current) && (current isa TextBlock && (current.inline = block_inline(b)))
                    _setbtext!(current, _btext(current) * _btext(b))
                else
                    current = b
                end
            end
        end
    end
    current !== nothing && !_t_is_empty(current) && push!(compressed, current)
    if !isempty(compressed)
        _setbtext!(compressed[1], lstrip(get_text(compressed[1])))
    end
    return compressed
end

function get_root(html::AbstractString)
    startswith(html, "<?xml") && (html = replace(html, r"<\?xml[^>]*\?>" => ""; count = 1))
    doc = EzXML.parsehtml(html)
    root = EzXML.root(doc)
    _remove_comments(root)
    return root
end

function extract_text(root)
    decompose_page_numbers(root)
    blocks = extract_and_format_content(root)
    return compress_blocks(blocks)
end

function blocks_from_html(html::AbstractString)
    root = get_root(html)
    root === nothing && return Block[]
    root = clean_html_root(root)
    return extract_text(root)
end

# --- generate_chunks (html_documents.py) --------------------------------------------------------------
function generate_chunks(blocks::Vector{Block})
    chunks = Vector{Block}[]
    current = Block[]
    accumulating = false; header_detected = false; item_header = false
    nonempty(c) = any(!isempty(strip(get_text(b))) for b in c)
    for (i, b) in enumerate(blocks)
        if b isa TableBlock || block_element(b) in ("ol", "ul")
            if !isempty(current)
                nonempty(current) && push!(chunks, current)
                current = Block[]
            end
            push!(chunks, Block[b])
            accumulating = false; header_detected = false; item_header = false
        elseif b isa TextBlock
            analysis = TextAnalysis(b.text)
            is_regular = ta_is_regular_text(analysis)
            is_item = _match_start(_ITEM_PATTERN, b.text)
            is_part = _match_start(_PART_PATTERN, b.text)
            if is_part
                if !isempty(current)
                    nonempty(current) && push!(chunks, current)
                    push!(chunks, Block[b])
                else
                    push!(chunks, Block[b])
                end
                current = Block[]
                item_header = true; header_detected = true; accumulating = false
            elseif is_item
                if !isempty(current)
                    nonempty(current) && push!(chunks, current)
                end
                current = Block[b]
                item_header = true; header_detected = true; accumulating = false
            elseif ta_is_header(analysis)
                if !isempty(current) && !accumulating && !item_header
                    nonempty(current) && push!(chunks, current)
                    current = Block[]
                end
                header_detected = true; accumulating = false
                push!(current, b); item_header = false
            elseif is_regular && (header_detected || accumulating)
                push!(current, b); accumulating = true; item_header = false
            else
                if accumulating || item_header
                    nonempty(current) && push!(chunks, current)
                    current = Block[]; accumulating = false; header_detected = false; item_header = false
                end
                push!(current, b)
            end
        elseif b isa LinkBlock
            push!(chunks, Block[b])
        end
        if i == length(blocks) && !isempty(current)
            nonempty(current) && push!(chunks, current)
        end
    end
    return chunks
end

# --- detectors (htmltools.py) -------------------------------------------------------------------------
const _INT_ITEM = r"(?im)^(Item\s{1,3}[0-9]{1,2}[A-Z]?)\.?"
const _DECIMAL_ITEM = r"(?im)^(Item\s{1,3}[0-9]{1,2}\.[0-9]{2})\.?"
detect_int_item(text) = (m = match(_INT_ITEM, text); m === nothing ? nothing : m.captures[1])
detect_decimal_item(text) = (m = match(_DECIMAL_ITEM, text); m === nothing ? nothing : m.captures[1])
detect_part(text) = (m = match(r"(?im)^\b(PART\s+[IVXLC]+)\b", text); m === nothing ? nothing : uppercase(replace(m.captures[1], r"\s+" => " ")))
# NOTE: edgartools uses re.match (anchored at STRING start, not per-line) — `^SIGNATURE` only at text[0].
detect_signature(text) = match(r"(?i)^SIGNATURE", text) !== nothing || occursin("to be signed on its behalf by the undersigned", text)
detect_toc(text) = count(_ -> true, eachmatch(r"item"i, text)) > 10

_render_for_detection(chunk) = strip(join((b isa TableBlock ? table_to_markdown(b.table_element) : get_text(b) for b in chunk), ""))

# --- chunks2df (htmltools.py) -------------------------------------------------------------------------
mutable struct ChunkRow
    Text::String
    Table::Bool
    Signature::Bool
    Toc::Bool
    Empty::Bool
    Part::String
    Item::String
end

function chunks2df(chunks::Vector{Vector{Block}}; item_detector = detect_int_item)
    rows = ChunkRow[]
    for (i, chunk) in enumerate(chunks)
        text = _render_for_detection(chunk)
        toc = i <= 100 ? detect_toc(text) : false      # df.Text.head(100)
        part = something(detect_part(text), missing)
        item = something(item_detector(text), missing)
        push!(rows, ChunkRow(text, any(b -> b isa TableBlock, chunk), detect_signature(text),
                             toc, match(r"^$", text) !== nothing, part === missing ? "" : part,
                             item === missing ? "\0" : item))   # "\0" = NaN sentinel for ffill
    end
    # toc rows clear item
    for r in rows; r.Toc && (r.Item = ""); end
    # forward-fill Item/Part (sentinel "\0" = NaN)
    last_item = "\0"; last_part = ""
    for r in rows
        r.Item == "\0" ? (r.Item = last_item) : (last_item = r.Item)
        isempty(r.Part) ? (r.Part = last_part) : (last_part = r.Part)
    end
    # signature truncation
    sig = findfirst(r -> r.Signature, rows)
    sig !== nothing && for k in sig:length(rows); rows[k].Item = "\0"; end
    # fillna("") + title-case + normalize spaces
    for r in rows
        r.Item = r.Item == "\0" ? "" : titlecase(replace(strip(r.Item), r"\s+" => " "))
        r.Part = titlecase(strip(replace(r.Part, r"\s+" => " ")))
    end
    return rows
end

# --- ChunkedDocument (htmltools.py) -------------------------------------------------------------------
struct ChunkedDocument
    chunks::Vector{Vector{Block}}
    data::Vector{ChunkRow}
end
function ChunkedDocument(html::AbstractString; item_detector = detect_int_item)
    chunks = generate_chunks(blocks_from_html(html))
    ChunkedDocument(chunks, chunks2df(chunks; item_detector = item_detector))
end

list_items(cd::ChunkedDocument) = (out = String[]; for r in cd.data; (!isempty(r.Item) && !(r.Item in out)) && push!(out, r.Item); end; out)

# _chunks_for(item, 'Item') with the longest-continuous-segment selection
function _chunks_for(cd::ChunkedDocument, item_or_part::AbstractString, col::Symbol = :Item)
    pat = Regex("^" * replace(item_or_part, "." => "\\.") * "\$", "i")
    idxs = Int[]
    for (i, r) in enumerate(cd.data)
        val = col === :Item ? r.Item : r.Part
        (_match_start(pat, val) && val == strip(val) && !r.Toc && !r.Empty) && length(val) > 0 && push!(idxs, i)
    end
    # edgartools' _chunks_for (Item-only, used by chunks_for_item) yields ALL matching chunks; only the
    # part+item method (_chunks_mul_for) keeps the longest continuous segment. Do NOT filter here, or the
    # trailing real `ITEM N … / Not applicable.` chunk (a second segment) gets dropped.
    return idxs
end

# __getitem__ (no prefix_src): join over chunks of join(get_text(block))
function getindex_item(cd::ChunkedDocument, item::AbstractString)
    idxs = _chunks_for(cd, item, :Item)
    isempty(idxs) && return nothing
    return join((join((get_text(b) for b in cd.chunks[i]), "") for i in idxs), "")
end

end # module ChunkedDoc
