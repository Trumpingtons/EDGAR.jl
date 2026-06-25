# Faithful translation of edgartools' edgar/documents/utils/streaming.py (StreamingParser), used for
# filings larger than streaming_threshold (10MB). Every method is translated exactly. One adaptation is
# forced by the runtime: Python uses lxml.etree.iterparse (an incremental reader) whose tree is partial at
# 'start' and complete at 'end'. EzXML wraps libxml2's HTML parser as a DOM (like lxml.html), so we parse
# once and emit iterparse's *exact* (start, …children…, end) event order by DFS, applying the same loop
# body per event. `elem.clear()` is applied on 'end' (where iterparse's subtree is complete) so ancestor
# text reads see emptied subtrees — identical output. (iterparse's previous-sibling deletion and the
# byte-size accounting are pure memory management with no effect on the produced text.)

mutable struct StreamingParser
    config::ParserConfig
    header_strategy::Union{Nothing,HeaderDetectionStrategy}
    table_strategy::Union{Nothing,TableProcessor}
    # state (_reset_state)
    current_section::Union{Nothing,AbstractNode}
    node_buffer::Vector{AbstractNode}
    meta::Dict{String,Any}
    root::DocumentNode
    current_parent::AbstractNode
    tag_stack::Vector{String}
    text_buffer::Vector{String}
    in_table::Bool
    table_depth::Int
    table_buffer::Vector{Any}
    bytes_processed::Int
end

function StreamingParser(config::ParserConfig)
    sp = StreamingParser(config,
        config.detect_sections ? HeaderDetectionStrategy(config) : nothing,
        config.table_extraction ? TableProcessor(config) : nothing,
        nothing, AbstractNode[], Dict{String,Any}(), DocumentNode(), DocumentNode(),
        String[], String[], false, 0, Any[], 0)
    sp.current_parent = sp.root
    return sp
end

const _MAX_NODE_BUFFER = 1000   # streaming.py MAX_NODE_BUFFER

# StreamingParser.parse — returns the root DocumentNode (post-processed). (Document wrapper + metadata
# object are added with document.jl; metadata fields are collected into sp.meta for parity.)
function parse_stream(sp::StreamingParser, html::AbstractString)
    doc = EzXML.parsehtml(html)
    _emit_events(sp, EzXML.root(doc))
    _flush_buffer!(sp)                                   # final flush
    sp.meta["original_html"] = html
    postprocess!(DocumentPostprocessor(sp.config), sp.root)
    return sp.root
end

# DFS reproducing iterparse's event order, with the per-event loop body from parse().
function _emit_events(sp::StreamingParser, elem)
    # --- 'start' event ---
    _handle_start_tag!(sp, elem)
    length(sp.node_buffer) >= _MAX_NODE_BUFFER && _flush_buffer!(sp)
    # (no clear on 'start': iterparse's subtree is empty there; here it is not, so clearing would be wrong)
    for child in collect(_children(elem))
        _emit_events(sp, child)
    end
    # --- 'end' event ---
    _handle_end_tag!(sp, elem)
    length(sp.node_buffer) >= _MAX_NODE_BUFFER && _flush_buffer!(sp)
    sp.table_depth == 0 && _clear_elem!(elem)
    return
end

function _handle_start_tag!(sp::StreamingParser, elem)
    tag = _tag(elem)
    push!(sp.tag_stack, tag)
    if tag == "title"
        et = _lxtext(elem); isempty(et) || _extract_title_metadata(sp, et)
    elseif tag == "meta"
        _extract_meta_metadata(sp, elem)
    end
    if tag == "body"
        body = ContainerNode(tag_name = "body")
        add_child!(sp.root, body)
        sp.current_parent = body
    elseif tag in ("h1", "h2", "h3", "h4", "h5", "h6")
        _start_heading!(sp, elem)
    elseif tag == "p"
        _start_paragraph!(sp, elem)
    elseif tag == "table"
        _start_table!(sp, elem)
    elseif tag == "section"
        _start_section!(sp, elem)
    end
    return
end

function _handle_end_tag!(sp::StreamingParser, elem)
    tag = _tag(elem)
    (!isempty(sp.tag_stack) && sp.tag_stack[end] == tag) && pop!(sp.tag_stack)
    if tag in ("h1", "h2", "h3", "h4", "h5", "h6")
        _end_heading!(sp, elem)
    elseif tag == "p"
        _end_paragraph!(sp, elem)
    elseif tag == "table"
        _end_table!(sp, elem)
    elseif tag == "section"
        _end_section!(sp, elem)
    elseif tag == "body"
        _flush_buffer!(sp)
    end
    # streaming.py appends elem.text/elem.tail (stripped) to text_buffer; text_buffer is never flushed to
    # nodes (it is only cleared by heading/paragraph handlers), so it has no effect on output. Kept faithful.
    et = _lxtext(elem); isempty(strip(et)) || push!(sp.text_buffer, String(strip(et)))
    tl = _lxtail(elem); isempty(strip(tl)) || push!(sp.text_buffer, String(strip(tl)))
    return
end

function _start_heading!(sp::StreamingParser, elem)
    level = parse(Int, string(_tag(elem)[2]))
    text_ = _get_text_content(sp, elem)
    heading = HeadingNode(level = level, content = text_)
    if sp.header_strategy !== nothing && is_section_header(sp.header_strategy, text_, elem)
        heading.semantic_type = SECTION_HEADER
    end
    push!(sp.node_buffer, heading)
    return
end

function _end_heading!(sp::StreamingParser, elem)
    text_ = _get_text_content(sp, elem)
    if !isempty(text_) && !isempty(sp.node_buffer) && sp.node_buffer[end] isa HeadingNode
        sp.node_buffer[end].content = text_
    end
    empty!(sp.text_buffer)
    return
end

function _start_paragraph!(sp::StreamingParser, elem)
    para = ParagraphNode()
    style_attr = _attr(elem, "style")
    style_attr !== nothing && (para.style = parse_style(style_attr))
    push!(sp.node_buffer, para)
    return
end

function _end_paragraph!(sp::StreamingParser, elem)
    text_ = _get_text_content(sp, elem)
    if !isempty(text_) && !isempty(sp.node_buffer) && sp.node_buffer[end] isa ParagraphNode
        add_child!(sp.node_buffer[end], TextNode(content = text_))
    end
    empty!(sp.text_buffer)
    return
end

function _start_table!(sp::StreamingParser, elem)
    sp.table_depth += 1
    sp.in_table = true
    empty!(sp.table_buffer)
    return
end

function _end_table!(sp::StreamingParser, elem)
    sp.table_depth -= 1
    sp.in_table = sp.table_depth > 0
    if sp.table_strategy !== nothing
        push!(sp.node_buffer, process(sp.table_strategy, elem))
    else
        push!(sp.node_buffer, TableNode())
    end
    empty!(sp.table_buffer)
    return
end

function _start_section!(sp::StreamingParser, elem)
    section = SectionNode()
    sid = _attr(elem, "id"); sid !== nothing && (section.metadata["id"] = sid)
    sclass = _attr(elem, "class"); sclass !== nothing && (section.metadata["class"] = sclass)
    sp.current_section = section
    push!(sp.node_buffer, section)
    return
end

_end_section!(sp::StreamingParser, elem) = (sp.current_section = nothing)

function _flush_buffer!(sp::StreamingParser)
    target = sp.current_section !== nothing ? sp.current_section : sp.current_parent
    for node in sp.node_buffer
        add_child!(target, node)
    end
    empty!(sp.node_buffer)
    return
end

# streaming.py `_get_text_content` — recursive, space-joined, each piece stripped.
function _get_text_content(sp::StreamingParser, elem)
    parts = String[]
    et = _lxtext(elem)
    isempty(strip(et)) || push!(parts, String(strip(et)))
    for child in _children(elem)
        ct = _get_text_content(sp, child)
        isempty(ct) || push!(parts, ct)
        tl = _lxtail(child)
        isempty(strip(tl)) || push!(parts, String(strip(tl)))
    end
    return join(parts, " ")
end

# lxml elem.clear(): drop the element's children, text and tail.
function _clear_elem!(elem)
    if EzXML.hasnextnode(elem)
        nx = nextnode(elem)
        istext(nx) && unlink!(nx)
    end
    for c in collect(eachnode(elem))
        unlink!(c)
    end
    return
end

function _extract_title_metadata(sp::StreamingParser, title::AbstractString)
    parts = split(title, " - ")
    if length(parts) >= 2
        sp.meta["company"] = String(strip(parts[1]))
        sp.meta["form"] = String(strip(parts[2]))
        length(parts) >= 3 && (sp.meta["filing_date"] = String(strip(parts[3])))
    end
    return
end

function _extract_meta_metadata(sp::StreamingParser, elem)
    name = lowercase(_attr(elem, "name", ""))
    content = _attr(elem, "content", "")
    if !isempty(name) && !isempty(content)
        name == "company" && (sp.meta["company"] = content)
        name == "filing-type" && (sp.meta["form"] = content)
        name == "cik" && (sp.meta["cik"] = content)
        name == "filing-date" && (sp.meta["filing_date"] = content)
        name == "accession-number" && (sp.meta["accession_number"] = content)
    end
    return
end
