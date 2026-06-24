# Faithful translation of edgartools' edgar/documents/extractors/text_extractor.py.
# Walks the node tree (with id de-dup), rendering each node type the way the old parser's block.get_text()
# did, joining parts with blank lines, then applying minimal document-level cleaning. This is exactly what
# Section.text() runs for heading/pattern-detected sections.

Base.@kwdef mutable struct TextExtractor
    clean::Bool = true
    include_tables::Bool = true
    include_metadata::Bool = false
    include_links::Bool = false
    max_length::Union{Nothing,Int} = nothing
    preserve_structure::Bool = false
    table_max_col_width::Union{Nothing,Int} = nothing
    _extracted_ids::Set{String} = Set{String}()
end

# extract — from the whole document.
function extract(ex::TextExtractor, document)
    parts = String[]
    empty!(ex._extracted_ids)
    _extract_from_node!(ex, document.root, parts, 0)
    text_ = ex.preserve_structure ? join(parts, "\n") : join(filter(!isempty, parts), "\n\n")
    ex.clean && (text_ = _clean_document_text(ex, text_))
    if ex.max_length !== nothing && length(text_) > ex.max_length
        text_ = _truncate_text(ex, text_, ex.max_length)
    end
    return text_
end

# extract_from_node — from a specific node (what Section.text() uses).
function extract_from_node(ex::TextExtractor, node::AbstractNode)
    parts = String[]
    empty!(ex._extracted_ids)
    _extract_from_node!(ex, node, parts, 0)
    text_ = join(filter(!isempty, parts), "\n\n")
    ex.clean && (text_ = _clean_document_text(ex, text_))
    return text_
end

function _extract_from_node!(ex::TextExtractor, node::AbstractNode, parts::Vector{String}, depth::Int)
    node.id in ex._extracted_ids && return
    push!(ex._extracted_ids, node.id)

    if node isa TableNode
        ex.include_tables && _extract_table!(ex, node, parts)
    elseif node isa HeadingNode
        _extract_heading!(ex, node, parts, depth)
    elseif node isa TextNode
        t = text(node)
        if !isempty(t)
            ex.clean && (t = _clean_text_content(ex, t))
            ex.include_metadata && !isempty(node.metadata) && (t = _annotate_with_metadata(t, node.metadata))
            push!(parts, t)
        end
    elseif node isa ParagraphNode
        t = text(node)
        if !isempty(t)
            ex.clean && (t = _clean_text_content(ex, t))
            ex.include_metadata && !isempty(node.metadata) && (t = _annotate_with_metadata(t, node.metadata))
            push!(parts, t)
        end
        return                                       # children already covered by paragraph text
    else
        if _is_bullet_point_container(ex, node)
            bullet_parts = String[]
            for child in node.children
                ct = text(child)
                isempty(strip(ct)) || push!(bullet_parts, strip(ct))
            end
            if !isempty(bullet_parts)
                t = join(bullet_parts, " ")
                ex.clean && (t = _clean_text_content(ex, t))
                ex.include_metadata && !isempty(node.metadata) && (t = _annotate_with_metadata(t, node.metadata))
                push!(parts, t)
            end
            return
        end
        if node.content isa AbstractString && !isempty(strip(node.content))
            t = node.content
            ex.clean && (t = _clean_text_content(ex, t))
            ex.include_metadata && !isempty(node.metadata) && (t = _annotate_with_metadata(t, node.metadata))
            push!(parts, t)
        end
    end

    for child in node.children
        _extract_from_node!(ex, child, parts, depth + 1)
    end
    return
end

function _extract_heading!(ex::TextExtractor, node::HeadingNode, parts::Vector{String}, depth::Int)
    t = text(node)
    isempty(t) && return
    ex.preserve_structure && (t = "#"^node.level * " " * t)
    ex.include_metadata && !isempty(node.metadata) && (t = _annotate_with_metadata(t, node.metadata))
    push!(parts, t)
    return
end

function _extract_table!(ex::TextExtractor, table::TableNode, parts::Vector{String})
    ex.preserve_structure && push!(parts, "[TABLE START]")
    if table.caption !== nothing && !isempty(table.caption)
        cap = table.caption
        ex.clean && (cap = _clean_text_content(ex, cap))
        push!(parts, ex.preserve_structure ? "Caption: $cap" : cap)
    end
    if ex.table_max_col_width !== nothing
        style = TableStyle(border_char = "", header_separator = "─", corner_char = "",
                           padding = 2, min_col_width = 6, max_col_width = ex.table_max_col_width)
        table_text = render_table_node(FastTableRenderer(style), table)
    else
        table_text = text(table)
    end
    isempty(table_text) || push!(parts, table_text)
    ex.preserve_structure && push!(parts, "[TABLE END]")
    return
end

function _annotate_with_metadata(text_::AbstractString, metadata::Dict)
    annotations = String[]
    haskey(metadata, "ix_tag") && push!(annotations, "[XBRL: $(metadata["ix_tag"])]")
    haskey(metadata, "section_name") && push!(annotations, "[Section: $(metadata["section_name"])]")
    haskey(metadata, "semantic_type") && push!(annotations, "[Type: $(metadata["semantic_type"])]")
    return isempty(annotations) ? text_ : "$(join(annotations, " ")) $text_"
end

function _clean_text_content(ex::TextExtractor, text_::AbstractString)
    isempty(text_) && return text_
    text_ = replace(text_, r" {2,}" => " ")
    text_ = replace(text_, r" *\n *" => "\n")
    text_ = join((strip(line) for line in split(text_, '\n')), "\n")
    return _normalize_punctuation(text_)
end

function _is_bullet_point_container(ex::TextExtractor, node::AbstractNode)
    (node isa ContainerNode || node isa SectionNode) || return false
    length(node.children) < 2 && return false
    all_text = text(node)
    isempty(all_text) && return false
    bullet_chars = ('•', '●', '▪', '▫', '◦', '‣', '-', '*')
    starts = any(c -> startswith(strip(all_text), c), bullet_chars)
    starts || return false
    if node.style.display == "flex"
        return true
    end
    if length(node.children) >= 2
        first_t = text(node.children[1]); second_t = text(node.children[2])
        if length(strip(first_t)) <= 3 && length(strip(second_t)) > 10
            return true
        end
    end
    return false
end

function _clean_document_text(ex::TextExtractor, text_::AbstractString)
    isempty(text_) && return text_
    text_ = replace(text_, r"\n{4,}" => "\n\n\n")
    return strip(text_)
end

function _normalize_punctuation(text_::AbstractString)
    # text_extractor.py lines 324-325 are all-ASCII (verified): replace('"','"') / replace("'","'") —
    # straight→straight no-ops, so curly quotes are PRESERVED. Reproduced faithfully as no-ops.
    text_ = replace(text_, "\"" => "\"")
    text_ = replace(text_, "'" => "'")
    text_ = replace(text_, '—' => " - ")
    text_ = replace(text_, '–' => " - ")
    text_ = replace(text_, r"\s+([.,;!?])" => s"\1")
    text_ = replace(text_, r"([,;])([A-Za-z])" => s"\1 \2")
    text_ = replace(text_, r"(?<=\w{2})([.!?])([A-Z])" => s"\1 \2")
    text_ = replace(text_, r"(?<=[0-9])([.!?])([A-Z])" => s"\1 \2")
    text_ = replace(text_, r"(%[.!?]?)([A-Za-z])" => s"\1 \2")
    text_ = replace(text_, r" {2,}" => " ")
    return strip(text_)
end

function _truncate_text(ex::TextExtractor, text_::AbstractString, max_length::Int)
    length(text_) <= max_length && return text_
    truncated = first(text_, max_length)
    last_period = findlast('.', truncated)
    last_newline = findlast('\n', truncated)
    lp = last_period === nothing ? 0 : last_period
    ln = last_newline === nothing ? 0 : last_newline
    truncate_at = max(lp, ln)
    if truncate_at > max_length * 0.8
        return strip(first(text_, truncate_at))
    end
    last_space = findlast(' ', truncated)
    ls = last_space === nothing ? 0 : last_space
    if ls > max_length * 0.9
        return strip(first(text_, ls - 1)) * "..."
    end
    return strip(first(text_, max_length - 3)) * "..."
end
