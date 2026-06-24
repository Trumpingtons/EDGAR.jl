# Faithful translation of edgartools' edgar/documents/nodes.py.
# The document-tree node hierarchy. Julia has no class-field inheritance, so every concrete node carries
# the shared fields (id/type/parent/children/content/metadata/style/semantic_*) and the tree helpers
# (`add_child!`/`find_nodes`/`walk`/…) dispatch on the `AbstractNode` supertype. Each node's `text()` and
# `html()` are translated line-for-line from the Python `.text()`/`.html()` methods. `TableNode` lives in
# table_nodes.jl (it is large), but is part of this same hierarchy.

abstract type AbstractNode end

# Node ids back the TextExtractor's de-dup set; a monotonic counter gives each node a unique, stable id
# (uuid4 in Python — only uniqueness matters here).
const _NODE_ID = Ref(0)
_next_id() = string(_NODE_ID[] += 1)

# --- shared tree helpers (Node base methods) ----------------------------------------------------------

function add_child!(parent::AbstractNode, child::AbstractNode)
    child.parent = parent
    push!(parent.children, child)
    return nothing
end

function remove_child!(parent::AbstractNode, child::AbstractNode)
    i = findfirst(x -> x === child, parent.children)
    if i !== nothing
        deleteat!(parent.children, i)
        child.parent = nothing
    end
    return nothing
end

function insert_child!(parent::AbstractNode, index::Int, child::AbstractNode)
    child.parent = parent
    insert!(parent.children, index, child)
    return nothing
end

# Node.find — all nodes matching predicate (self first, then children, depth-first).
function find_nodes(node::AbstractNode, predicate)
    results = AbstractNode[]
    predicate(node) && push!(results, node)
    for child in node.children
        append!(results, find_nodes(child, predicate))
    end
    return results
end

# Node.find_first — first node matching predicate.
function find_first(node::AbstractNode, predicate)
    predicate(node) && return node
    for child in node.children
        r = find_first(child, predicate)
        r !== nothing && return r
    end
    return nothing
end

# Node.walk — depth-first preorder over the subtree.
function walk(node::AbstractNode)
    out = AbstractNode[node]
    for child in node.children
        append!(out, walk(child))
    end
    return out
end

# Node.depth
function depth(node::AbstractNode)
    d = 0; cur = node.parent
    while cur !== nothing
        d += 1; cur = cur.parent
    end
    return d
end

get_metadata(node::AbstractNode, key, default = nothing) = get(node.metadata, key, default)
set_metadata!(node::AbstractNode, key, value) = (node.metadata[key] = value)
has_metadata(node::AbstractNode, key) = haskey(node.metadata, key)

# --- node structs -------------------------------------------------------------------------------------

Base.@kwdef mutable struct DocumentNode <: AbstractNode
    id::String = _next_id()
    type::NodeType = DOCUMENT
    parent::Union{Nothing,AbstractNode} = nothing
    children::Vector{AbstractNode} = AbstractNode[]
    content::Any = nothing
    metadata::Dict{String,Any} = Dict{String,Any}()
    style::Style = Style()
    semantic_type::Union{Nothing,SemanticType} = nothing
    semantic_role::Union{Nothing,String} = nothing
end

Base.@kwdef mutable struct TextNode <: AbstractNode
    id::String = _next_id()
    type::NodeType = TEXT
    parent::Union{Nothing,AbstractNode} = nothing
    children::Vector{AbstractNode} = AbstractNode[]
    content::String = ""
    metadata::Dict{String,Any} = Dict{String,Any}()
    style::Style = Style()
    semantic_type::Union{Nothing,SemanticType} = nothing
    semantic_role::Union{Nothing,String} = nothing
end

Base.@kwdef mutable struct ParagraphNode <: AbstractNode
    id::String = _next_id()
    type::NodeType = PARAGRAPH
    parent::Union{Nothing,AbstractNode} = nothing
    children::Vector{AbstractNode} = AbstractNode[]
    content::Any = nothing
    metadata::Dict{String,Any} = Dict{String,Any}()
    style::Style = Style()
    semantic_type::Union{Nothing,SemanticType} = nothing
    semantic_role::Union{Nothing,String} = nothing
end

Base.@kwdef mutable struct HeadingNode <: AbstractNode
    id::String = _next_id()
    type::NodeType = HEADING
    parent::Union{Nothing,AbstractNode} = nothing
    children::Vector{AbstractNode} = AbstractNode[]
    content::Any = nothing
    metadata::Dict{String,Any} = Dict{String,Any}()
    style::Style = Style()
    semantic_type::Union{Nothing,SemanticType} = nothing
    semantic_role::Union{Nothing,String} = nothing
    level::Int = 1
end

Base.@kwdef mutable struct ContainerNode <: AbstractNode
    id::String = _next_id()
    type::NodeType = CONTAINER
    parent::Union{Nothing,AbstractNode} = nothing
    children::Vector{AbstractNode} = AbstractNode[]
    content::Any = nothing
    metadata::Dict{String,Any} = Dict{String,Any}()
    style::Style = Style()
    semantic_type::Union{Nothing,SemanticType} = nothing
    semantic_role::Union{Nothing,String} = nothing
    tag_name::String = "div"
end

# SectionNode is a ContainerNode subclass in Python; modelled here as its own node with the section name.
Base.@kwdef mutable struct SectionNode <: AbstractNode
    id::String = _next_id()
    type::NodeType = SECTION
    parent::Union{Nothing,AbstractNode} = nothing
    children::Vector{AbstractNode} = AbstractNode[]
    content::Any = nothing
    metadata::Dict{String,Any} = Dict{String,Any}()
    style::Style = Style()
    semantic_type::Union{Nothing,SemanticType} = nothing
    semantic_role::Union{Nothing,String} = nothing
    tag_name::String = "section"
    section_name::Union{Nothing,String} = nothing
end

Base.@kwdef mutable struct ListNode <: AbstractNode
    id::String = _next_id()
    type::NodeType = LIST
    parent::Union{Nothing,AbstractNode} = nothing
    children::Vector{AbstractNode} = AbstractNode[]
    content::Any = nothing
    metadata::Dict{String,Any} = Dict{String,Any}()
    style::Style = Style()
    semantic_type::Union{Nothing,SemanticType} = nothing
    semantic_role::Union{Nothing,String} = nothing
    ordered::Bool = false
end

Base.@kwdef mutable struct ListItemNode <: AbstractNode
    id::String = _next_id()
    type::NodeType = LIST_ITEM
    parent::Union{Nothing,AbstractNode} = nothing
    children::Vector{AbstractNode} = AbstractNode[]
    content::Any = nothing
    metadata::Dict{String,Any} = Dict{String,Any}()
    style::Style = Style()
    semantic_type::Union{Nothing,SemanticType} = nothing
    semantic_role::Union{Nothing,String} = nothing
end

Base.@kwdef mutable struct LinkNode <: AbstractNode
    id::String = _next_id()
    type::NodeType = LINK
    parent::Union{Nothing,AbstractNode} = nothing
    children::Vector{AbstractNode} = AbstractNode[]
    content::Any = nothing
    metadata::Dict{String,Any} = Dict{String,Any}()
    style::Style = Style()
    semantic_type::Union{Nothing,SemanticType} = nothing
    semantic_role::Union{Nothing,String} = nothing
    href::Union{Nothing,String} = nothing
    title::Union{Nothing,String} = nothing
end

Base.@kwdef mutable struct ImageNode <: AbstractNode
    id::String = _next_id()
    type::NodeType = IMAGE
    parent::Union{Nothing,AbstractNode} = nothing
    children::Vector{AbstractNode} = AbstractNode[]
    content::Any = nothing
    metadata::Dict{String,Any} = Dict{String,Any}()
    style::Style = Style()
    semantic_type::Union{Nothing,SemanticType} = nothing
    semantic_role::Union{Nothing,String} = nothing
    src::Union{Nothing,String} = nothing
    alt::Union{Nothing,String} = nothing
    width::Union{Nothing,Int} = nothing
    height::Union{Nothing,Int} = nothing
end

# --- text() ------------------------------------------------------------------------------------------

# DocumentNode.text — children joined by blank lines.
function text(n::DocumentNode)
    parts = String[]
    for child in n.children
        t = text(child)
        isempty(t) || push!(parts, t)
    end
    return join(parts, "\n\n")
end

# TextNode.text
text(n::TextNode) = n.content

# Python str helpers used by ParagraphNode.text.
_py_isalpha_char(c::AbstractChar) = isletter(c)

# ParagraphNode._is_abbreviation_ending
function _is_abbreviation_ending(text_::AbstractString)
    stripped = rstrip(text_)
    isempty(stripped) && return false
    if match(r"\b[A-Za-z]\.$", stripped) !== nothing
        if match(r"(?:Class|Series|Exhibit|Schedule|Part|Annex|Appendix|Grade|Tier|Type|Group|Tranche)\s+[A-Z]\.$", stripped) !== nothing
            return false
        end
        return true
    end
    if match(r"(?:Inc|Corp|Ltd|Jr|Sr|Dr|Mr|Mrs|Ms|vs|etc|approx|est|Vol|No|Dept)\.$", stripped) !== nothing
        return true
    end
    return false
end

# ParagraphNode.text — intelligent inline spacing (faithful port).
function text(n::ParagraphNode)
    parts = String[]
    for (i, child) in enumerate(n.children)
        t = text(child)
        isempty(t) && continue
        if i == 1
            push!(parts, t)
        else
            prev_child = n.children[i - 1]
            should_add_space = false
            if get_metadata(prev_child, "has_tail_whitespace") === true
                should_add_space = true
            elseif startswith(t, " ")
                should_add_space = true
                t = lstrip(t)
            elseif !isempty(parts) && !isempty(rstrip(parts[end])) && last(rstrip(parts[end])) in ('.', '!', '?', ':', ';')
                if !_is_abbreviation_ending(parts[end])
                    should_add_space = true
                end
            elseif !isempty(t) && _py_isalpha_char(first(t)) && !isempty(parts) && !isempty(parts[end]) &&
                   !endswith(parts[end], " ") && get_metadata(child, "original_tag") in ("span", "a", "em", "strong", "i", "b")
                should_add_space = true
            end
            if should_add_space
                push!(parts, " " * t)
            else
                if !isempty(parts)
                    parts[end] *= t
                else
                    push!(parts, t)
                end
            end
        end
    end
    return join(parts, "")
end

# HeadingNode.text
function text(n::HeadingNode)
    n.content isa AbstractString && return n.content
    parts = String[]
    for child in n.children
        t = text(child)
        isempty(t) || push!(parts, t)
    end
    return join(parts, " ")
end

# ContainerNode.text — children joined by single newlines.
function text(n::ContainerNode)
    parts = String[]
    for child in n.children
        t = text(child)
        isempty(t) || push!(parts, t)
    end
    return join(parts, "\n")
end

# SectionNode.text — inherits ContainerNode behaviour (children joined by newlines).
function text(n::SectionNode)
    parts = String[]
    for child in n.children
        t = text(child)
        isempty(t) || push!(parts, t)
    end
    return join(parts, "\n")
end

# ListNode.text — each item prefixed (numbered or bulleted), joined by newlines.
function text(n::ListNode)
    parts = String[]
    for (i, child) in enumerate(n.children)
        prefix = n.ordered ? "$(i). " : "• "
        t = text(child)
        isempty(t) || push!(parts, prefix * t)
    end
    return join(parts, "\n")
end

# ListItemNode.text — children joined by spaces.
function text(n::ListItemNode)
    parts = String[]
    for child in n.children
        t = text(child)
        isempty(t) || push!(parts, t)
    end
    return join(parts, " ")
end

# LinkNode.text
function text(n::LinkNode)
    n.content isa AbstractString && return n.content
    parts = String[]
    for child in n.children
        t = text(child)
        isempty(t) || push!(parts, t)
    end
    return join(parts, " ")
end

# ImageNode.text — alt text.
text(n::ImageNode) = something(n.alt, "")

# --- html() ------------------------------------------------------------------------------------------

_escape_html(text_::AbstractString) =
    replace(replace(replace(text_, "&" => "&amp;"), "<" => "&lt;"), ">" => "&gt;")

function html(n::DocumentNode)
    body = join((html(c) for c in n.children), "\n")
    return "<!DOCTYPE html>\n<html>\n<head>\n    <meta charset=\"utf-8\">\n    <title>Document</title>\n</head>\n<body>\n$body\n</body>\n</html>"
end

html(n::TextNode) = _escape_html(n.content)

function _para_style_attr(s::Style)
    styles = String[]
    s.text_align !== nothing && push!(styles, "text-align: $(s.text_align)")
    s.margin_top !== nothing && push!(styles, "margin-top: $(s.margin_top)px")
    s.margin_bottom !== nothing && push!(styles, "margin-bottom: $(s.margin_bottom)px")
    return isempty(styles) ? "" : " style=\"$(join(styles, "; "))\""
end

function html(n::ParagraphNode)
    content = join((html(c) for c in n.children), "")
    return "<p$(_para_style_attr(n.style))>$content</p>"
end

function _heading_style_attr(s::Style)
    styles = String[]
    s.text_align !== nothing && push!(styles, "text-align: $(s.text_align)")
    s.color !== nothing && push!(styles, "color: $(s.color)")
    return isempty(styles) ? "" : " style=\"$(join(styles, "; "))\""
end

function html(n::HeadingNode)
    level = max(1, min(6, n.level))
    return "<h$level$(_heading_style_attr(n.style))>$(text(n))</h$level>"
end

function _container_style_attr(s::Style)
    styles = String[]
    s.margin_top !== nothing && push!(styles, "margin-top: $(s.margin_top)px")
    s.margin_bottom !== nothing && push!(styles, "margin-bottom: $(s.margin_bottom)px")
    s.padding_left !== nothing && push!(styles, "padding-left: $(s.padding_left)px")
    return isempty(styles) ? "" : " style=\"$(join(styles, "; "))\""
end

function html(n::ContainerNode)
    content = join((html(c) for c in n.children), "\n")
    class_attr = n.semantic_role !== nothing ? " class=\"$(n.semantic_role)\"" : ""
    return "<$(n.tag_name)$(_container_style_attr(n.style))$class_attr>$content</$(n.tag_name)>"
end

function html(n::SectionNode)
    content = join((html(c) for c in n.children), "\n")
    class_attr = n.semantic_role !== nothing ? " class=\"$(n.semantic_role)\"" : ""
    return "<$(n.tag_name)$(_container_style_attr(n.style))$class_attr>$content</$(n.tag_name)>"
end

function html(n::ListNode)
    tag = n.ordered ? "ol" : "ul"
    items = join((html(c) for c in n.children), "\n")
    return "<$tag>\n$items\n</$tag>"
end

html(n::ListItemNode) = "<li>$(join((html(c) for c in n.children), ""))</li>"

function html(n::LinkNode)
    href_attr = n.href !== nothing ? " href=\"$(n.href)\"" : ""
    title_attr = n.title !== nothing ? " title=\"$(n.title)\"" : ""
    return "<a$href_attr$title_attr>$(text(n))</a>"
end

function html(n::ImageNode)
    src_attr = n.src !== nothing ? " src=\"$(n.src)\"" : ""
    alt_attr = n.alt !== nothing ? " alt=\"$(n.alt)\"" : ""
    width_attr = n.width !== nothing ? " width=\"$(n.width)\"" : ""
    height_attr = n.height !== nothing ? " height=\"$(n.height)\"" : ""
    return "<img$src_attr$alt_attr$width_attr$height_attr>"
end
