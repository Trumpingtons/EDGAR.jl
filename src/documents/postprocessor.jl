# Faithful translation of edgartools' edgar/documents/processors/postprocessor.py.
# Final pass over the built tree: remove empty nodes (this is what drops bare ImageNodes etc.), merge
# adjacent plain text nodes, and normalise heading levels. (`_enhance_sections` runs only under eager
# extraction — default off; `_add_statistics`/`_validate_structure` don't change text and are omitted.)

struct DocumentPostprocessor
    config::ParserConfig
end

function postprocess!(p::DocumentPostprocessor, root::AbstractNode)
    _remove_empty_nodes!(root)
    p.config.merge_adjacent_nodes && _merge_adjacent_nodes!(root)
    _normalize_heading_levels!(root)
    return root
end

function _remove_empty_nodes!(node::AbstractNode)
    to_remove = AbstractNode[]
    for child in node.children
        _remove_empty_nodes!(child)
        _is_empty_node(child) && push!(to_remove, child)
    end
    for child in to_remove
        remove_child!(node, child)
    end
    return
end

function _is_empty_node(node::AbstractNode)
    node.type == TABLE && return false
    isempty(node.metadata) || return false
    node isa TextNode && return isempty(strip(text(node)))
    node.content isa AbstractString && return isempty(strip(node.content))
    isempty(node.children) && return true
    return false
end

function _merge_adjacent_nodes!(node::AbstractNode)
    isempty(node.children) && return
    for child in node.children
        _merge_adjacent_nodes!(child)
    end
    merged_children = AbstractNode[]
    i = 1
    n = length(node.children)
    while i <= n
        current = node.children[i]
        if _can_merge(current)
            group = AbstractNode[current]
            j = i + 1
            while j <= n && _can_merge_with(current, node.children[j])
                push!(group, node.children[j]); j += 1
            end
            if length(group) > 1
                push!(merged_children, _merge_nodes(group)); i = j
            else
                push!(merged_children, current); i += 1
            end
        else
            push!(merged_children, current); i += 1
        end
    end
    node.children = merged_children
    for child in node.children
        child.parent = node
    end
    return
end

_can_merge(node::AbstractNode) = node isa TextNode && isempty(node.metadata)

function _can_merge_with(node1::AbstractNode, node2::AbstractNode)
    typeof(node1) === typeof(node2) || return false
    _compatible_styles(node1.style, node2.style) || return false
    (isempty(node1.metadata) && isempty(node2.metadata)) || return false
    return true
end

_compatible_styles(s1::Style, s2::Style) =
    s1.font_size == s2.font_size && s1.font_weight == s2.font_weight && s1.text_align == s2.text_align

function _merge_nodes(nodes::Vector{AbstractNode})
    merged = nodes[1]
    if merged isa TextNode
        merged.content = join((text(n) for n in nodes), "\n")
    elseif merged isa ParagraphNode
        for nd in nodes[2:end]
            append!(merged.children, nd.children)
        end
    end
    return merged
end

function _normalize_heading_levels!(node::AbstractNode)
    headings = HeadingNode[]
    _collect_headings(node, headings)
    isempty(headings) && return
    levels_used = Set(h.level for h in headings)
    if !(1 in levels_used) && !isempty(levels_used)
        adjustment = minimum(levels_used) - 1
        for h in headings
            h.level = max(1, h.level - adjustment)
        end
    end
    return
end

function _collect_headings(node::AbstractNode, headings::Vector{HeadingNode})
    node isa HeadingNode && push!(headings, node)
    for child in node.children
        _collect_headings(child, headings)
    end
    return
end
