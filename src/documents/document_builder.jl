# Faithful translation of edgartools' edgar/documents/strategies/document_builder.py.
# Converts the parsed (EzXML/libxml2) HTML tree into the Document node tree: element→node mapping, inline
# vs block handling, page-number/page-break filtering, style extraction, and basic/advanced table dispatch.
# Uses the lxml accessors in ezxml_dom.jl so the walk mirrors lxml's `.text`/`.tail`/`getnext` semantics.

const _BLOCK_ELEMENTS = Set([
    "div", "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "hr",
    "table", "form", "fieldset", "address", "section", "article", "aside", "nav", "header", "footer", "main"])

const _INLINE_ELEMENTS = Set([
    "span", "a", "em", "strong", "b", "i", "u", "s", "small", "mark", "del", "ins", "sub", "sup",
    "code", "kbd", "var", "samp", "abbr", "cite", "q", "time", "font",
    "ix:nonfraction", "ix:footnote", "ix:fraction"])

const _SKIP_ELEMENTS = Set(["script", "style", "meta", "link", "noscript", "ix:exclude"])

# Exact strings from the Python set (note the unlowercased 'ix:nonNumeric' — tags are compared lowercased,
# so that one never matches; faithfully preserved).
const _SKIP_HEADER_DETECTION_TAGS = Set([
    "li", "td", "th", "option", "a", "button", "label",
    "ix:nonfraction", "ix:footnote", "ix:fraction", "ix:nonNumeric", "ix:continuation"])

mutable struct DocumentBuilder
    config::ParserConfig
    header_strategy::Union{Nothing,HeaderDetectionStrategy}
    table_strategy::Union{Nothing,TableProcessor}
    style_parser::StyleParser
    context::ParseContext
    xbrl_context_stack::Vector{Any}
end
# Strategies are gated by config exactly as parser.py's _init_strategies (header_detection when
# detect_sections, table_processing when table_extraction).
DocumentBuilder(config::ParserConfig) = DocumentBuilder(
    config,
    config.detect_sections ? HeaderDetectionStrategy(config) : nothing,
    config.table_extraction ? TableProcessor(config) : nothing,
    StyleParser(), ParseContext(), Any[])

# build — body (or whole tree) into a DocumentNode root.
function build(b::DocumentBuilder, tree)
    root = DocumentNode()
    body = _findfirst(tree, ".//body")
    body === nothing && (body = tree)
    _process_element(b, body, root)
    return root
end

function _add_tail!(b::DocumentBuilder, element, parent, node)
    tail = _lxtail(element)
    isempty(tail) && return
    if b.config.preserve_whitespace
        add_child!(parent, TextNode(content = tail))
    else
        st = strip(tail)
        if !isempty(st)
            add_child!(parent, TextNode(content = String(st)))
        elseif node !== nothing && _py_isspace(tail)
            set_metadata!(node, "has_tail_whitespace", true)
        end
    end
    return
end

function _process_element(b::DocumentBuilder, element, parent)
    tag = _tag(element)

    if tag in _SKIP_ELEMENTS
        tl = _lxtail(element)
        if !isempty(tl)
            if b.config.preserve_whitespace
                add_child!(parent, TextNode(content = tl))
            else
                st = strip(tl)
                isempty(st) || add_child!(parent, TextNode(content = String(st)))
            end
        end
        return nothing
    end

    (_is_page_number_container(b, element) || _is_page_break_element(b, element) ||
        _is_page_navigation_container(b, element)) && return nothing

    b.context.depth += 1
    try
        namespaced = startswith(nodename(element), "{")
        namespaced && _enter_xbrl_context(b, element)
        style = _extract_style(b, element)
        node = _create_node_for_element(b, element, style)

        if node !== nothing
            add_child!(parent, node)
            if _should_process_children(b, element, node)
                et = _lxtext(element)
                if !isempty(et)
                    if b.config.preserve_whitespace
                        add_child!(node, TextNode(content = et))
                    else
                        st = strip(et)
                        isempty(st) || add_child!(node, TextNode(content = String(st)))
                    end
                end
                for child in _children(element)
                    _process_element(b, child, node)
                end
                _add_tail!(b, element, parent, node)
            else
                _add_tail!(b, element, parent, node)
            end
        else
            for child in _children(element)
                _process_element(b, child, parent)
            end
            tl = _lxtail(element)
            if !isempty(tl)
                if b.config.preserve_whitespace
                    add_child!(parent, TextNode(content = tl))
                else
                    st = strip(tl)
                    isempty(st) || add_child!(parent, TextNode(content = String(st)))
                end
            end
        end

        namespaced && _exit_xbrl_context(b, element)
        return node
    finally
        b.context.depth -= 1
    end
end

function _create_node_for_element(b::DocumentBuilder, element, style::Style)
    tag = startswith(nodename(element), "{") ? nodename(element) : _tag(element)

    if tag in ("h1", "h2", "h3", "h4", "h5", "h6")
        level = parse(Int, string(tag[2]))
        text_ = _get_element_text(b, element)
        isempty(text_) || return HeadingNode(content = text_, level = level, style = style)
    end

    tag == "p" && return ParagraphNode(style = style)
    tag == "li" && return ListItemNode(style = style)

    if !(tag in _SKIP_HEADER_DETECTION_TAGS) && b.header_strategy !== nothing
        header_info = detect(b.header_strategy, element, b.context)
        if header_info !== nothing && header_info.confidence > b.config.header_detection_threshold
            text_ = _get_element_text(b, element)
            if !isempty(text_)
                node = HeadingNode(content = text_, level = header_info.level, style = style)
                set_metadata!(node, "detection_method", header_info.detection_method)
                set_metadata!(node, "confidence", header_info.confidence)
                if header_info.is_item
                    node.semantic_type = ITEM_HEADER
                    set_metadata!(node, "item_number", header_info.item_number)
                end
                return node
            end
        end
    end

    if tag == "table"
        if b.table_strategy !== nothing
            return process(b.table_strategy, element)
        else
            return _process_table_basic(b, element, style)
        end
    elseif tag in ("ul", "ol")
        return ListNode(ordered = (tag == "ol"), style = style)
    elseif tag == "li"
        return ListItemNode(style = style)
    elseif tag == "a"
        href = _attr(element, "href", "")
        title = _attr(element, "title", "")
        text_ = _get_element_text(b, element)
        return LinkNode(content = text_, href = href, title = title, style = style)
    elseif tag == "img"
        return ImageNode(src = _attr(element, "src"), alt = _attr(element, "alt"),
                         width = _parse_dimension(b, _attr(element, "width")),
                         height = _parse_dimension(b, _attr(element, "height")), style = style)
    elseif tag == "br"
        return TextNode(content = "\n")
    elseif tag in ("section", "article")
        return SectionNode(style = style)
    elseif tag == "div" || tag in _BLOCK_ELEMENTS
        if style.display in ("inline", "inline-block")
            text_ = _get_element_text(b, element)
            if !isempty(text_)
                tn = TextNode(content = text_, style = style)
                set_metadata!(tn, "original_tag", tag)
                set_metadata!(tn, "inline_via_css", true)
                return tn
            end
            return ContainerNode(tag_name = tag, style = style)
        end
        if _is_text_only_container(b, element)
            return ParagraphNode(style = style)
        else
            return ContainerNode(tag_name = tag, style = style)
        end
    elseif tag in _INLINE_ELEMENTS
        text_ = _get_element_text(b, element)
        if !isempty(text_)
            tn = TextNode(content = text_, style = style)
            set_metadata!(tn, "original_tag", tag)
            return tn
        end
    elseif tag in ("ix:nonnumeric", "ix:continuation")
        has_block_children = any(c -> _tag(c) in _BLOCK_ELEMENTS || _tag(c) in ("table", "div", "p"), _children(element))
        if !has_block_children
            text_ = _get_element_text(b, element)
            if !isempty(text_)
                tn = TextNode(content = text_, style = style)
                set_metadata!(tn, "original_tag", tag)
                set_metadata!(tn, "inline", true)
                return tn
            end
        end
        return ContainerNode(tag_name = tag, style = style)
    end

    return ContainerNode(tag_name = tag, style = style)
end

# --- page-number / page-break filtering ---------------------------------------------------------------
function _is_page_number_container(b::DocumentBuilder, element)
    text_content = strip(_text_content(element))
    (length(text_content) > 8 || length(text_content) == 0) && return false
    _is_page_number_content(b, text_content) || return false
    tag = _tag(element)
    tag == "div" && _is_flexbox_page_number(b, element) && return true
    tag == "p" && _is_aligned_page_number(b, element) && return true
    tag == "div" && _is_footer_page_number(b, element) && return true
    tag == "div" && _is_page_break_context(b, element) && return true
    return false
end

function _is_page_number_content(b::DocumentBuilder, text_)
    _py_isdigit(text_) && return true
    match(r"^[ivxlcdm]+$", lowercase(text_)) !== nothing && return true
    match(r"^page\s+\d+(\s+of\s+\d+)?$", lowercase(text_)) !== nothing && return true
    return false
end

function _is_flexbox_page_number(b::DocumentBuilder, element)
    style_attr = _attr(element, "style", "")
    isempty(style_attr) && return false
    return all(p -> match(p, style_attr) !== nothing,
               (r"display:\s*flex", r"justify-content:\s*flex-end", r"min-height:\s*1in"))
end

function _is_aligned_page_number(b::DocumentBuilder, element)
    style_attr = _attr(element, "style", "")
    match(r"text-align:\s*(center|right)", style_attr) === nothing && return false
    fm = match(r"font-size:\s*([0-9]+)pt", style_attr)
    if fm !== nothing
        parse(Int, fm.captures[1]) <= 12 && return true
    end
    return true
end

function _is_footer_page_number(b::DocumentBuilder, element)
    style_attr = _attr(element, "style", "")
    patterns = (r"bottom:\s*[0-9]", r"position:\s*absolute", r"margin-bottom:\s*0", r"text-align:\s*center")
    return count(p -> match(p, style_attr) !== nothing, patterns) >= 2
end

function _is_page_break_context(b::DocumentBuilder, element)
    next_elem = _getnext(element)
    if next_elem !== nothing && _tag(next_elem) == "hr"
        occursin("page-break", _attr(next_elem, "style", "")) && return true
    end
    occursin("page-break", _attr(element, "style", "")) && return true
    return false
end

function _is_page_break_element(b::DocumentBuilder, element)
    _tag(element) != "hr" && return false
    return occursin("page-break", _attr(element, "style", ""))
end

function _is_page_navigation_container(b::DocumentBuilder, element)
    _tag(element) != "div" && return false
    style_attr = _attr(element, "style", "")
    indicators = (r"padding-top:\s*0\.5in", r"min-height:\s*1in", r"box-sizing:\s*border-box")
    count(p -> match(p, style_attr) !== nothing, indicators) < 2 && return false
    tc = lowercase(strip(_text_content(element)))
    return any(phrase -> occursin(phrase, tc),
               ("table of contents", "index to financial statements", "table of content", "index to financial statement"))
end

# --- style / text helpers -----------------------------------------------------------------------------
function _extract_style(b::DocumentBuilder, element)
    style = parse_style(b.style_parser, _attr(element, "style", ""))
    tag = _tag(element)
    if tag == "b" || tag == "strong"
        style.font_weight = "bold"
    elseif tag == "i" || tag == "em"
        style.font_style = "italic"
    elseif tag == "u"
        style.text_decoration = "underline"
    end
    align = _attr(element, "align")
    align !== nothing && (style.text_align = align)
    return style
end

function _get_element_text(b::DocumentBuilder, element)
    text_parts = String[]
    tag = _tag(element)
    et = _lxtext(element)
    if !isempty(et)
        push!(text_parts, tag in _INLINE_ELEMENTS ? et : String(strip(et)))
    end
    if tag in _INLINE_ELEMENTS || tag in ("h1", "h2", "h3", "h4", "h5", "h6")
        for child in _children(element)
            if !(_tag(child) in _SKIP_ELEMENTS)
                ct = _text_content(child)
                if !isempty(ct)
                    push!(text_parts, tag in _INLINE_ELEMENTS ? ct : String(strip(ct)))
                end
            end
        end
    end
    if tag in _INLINE_ELEMENTS && length(text_parts) == 1
        return text_parts[1]
    else
        return join(text_parts, " ")
    end
end

function _is_text_only_container(b::DocumentBuilder, element)
    for child in _children(element)
        ct = _tag(child)
        ct in _BLOCK_ELEMENTS && return false
        ct == "table" && return false
    end
    return true
end

function _should_process_children(b::DocumentBuilder, element, node)
    (node isa TextNode || node isa HeadingNode) && return false
    node isa TableNode && return false
    return true
end

function _process_table_basic(b::DocumentBuilder, element, style::Style)
    table = TableNode(style = style)
    caption_elem = _findfirst(element, ".//caption")
    caption_elem !== nothing && (table.caption = String(strip(_text_content(caption_elem))))
    for tr in _findall(element, ".//tr")
        cells = Cell[]
        for td in vcat(_findall(tr, ".//td"), _findall(tr, ".//th"))
            push!(cells, Cell(content = String(strip(_text_content(td))),
                              colspan = parse(Int, _attr(td, "colspan", "1")),
                              rowspan = parse(Int, _attr(td, "rowspan", "1")),
                              is_header = (_tag(td) == "th"), align = _attr(td, "align")))
        end
        if !isempty(cells)
            is_h = _findfirst(tr, ".//th") !== nothing
            par = _getparent(tr)
            if (par !== nothing && _tag(par) == "thead") || is_h
                push!(table.headers, cells)
            else
                push!(table.rows, Row(cells = cells, is_header = is_h))
            end
        end
    end
    return table
end

function _parse_dimension(b::DocumentBuilder, value)
    (value === nothing || isempty(value)) && return nothing
    v = rstrip(strip(value), ['p', 'x'])
    return tryparse(Int, v)
end

# XBRL context — no-op (no xbrl_extraction strategy; iXBRL text reaches nodes as plain libxml2 text).
_enter_xbrl_context(b::DocumentBuilder, element) = nothing
_exit_xbrl_context(b::DocumentBuilder, element) = (isempty(b.xbrl_context_stack) || pop!(b.xbrl_context_stack); nothing)
