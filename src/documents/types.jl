# Faithful translation of edgartools' edgar/documents/types.py.
# Type definitions for the HTML parser: node/semantic/table enums, the unified Style, HeaderInfo,
# XBRLFact and the parse context. Field names mirror the Python source (snake_case) so the translation
# of the rest of the parser reads line-for-line against edgartools.

# NodeType — types of nodes in the document tree (types.py NodeType).
@enum NodeType begin
    DOCUMENT
    SECTION
    HEADING
    PARAGRAPH
    TABLE
    LIST
    LIST_ITEM
    LINK
    IMAGE
    XBRL_FACT
    TEXT
    CONTAINER
end

# SemanticType — semantic types for document understanding (types.py SemanticType).
@enum SemanticType begin
    TITLE
    HEADER
    BODY_TEXT
    FOOTNOTE
    TABLE_OF_CONTENTS
    FINANCIAL_STATEMENT
    DISCLOSURE
    ITEM_HEADER
    SECTION_HEADER
    SIGNATURE
    EXHIBIT
end

# TableType — types of tables for semantic understanding (types.py TableType).
@enum TableType begin
    FINANCIAL
    METRICS
    REFERENCE
    GENERAL
    TT_TABLE_OF_CONTENTS
    EXHIBIT_INDEX
end

"""
    Style

Unified style representation — a faithful port of types.py `Style`. Every property is optional
(`nothing` when unset); `width`/`height` may be a number or a string (e.g. `"100%"`).
"""
Base.@kwdef mutable struct Style
    font_size::Union{Nothing,Float64} = nothing
    font_weight::Union{Nothing,String} = nothing
    font_style::Union{Nothing,String} = nothing
    text_align::Union{Nothing,String} = nothing
    text_decoration::Union{Nothing,String} = nothing
    color::Union{Nothing,String} = nothing
    background_color::Union{Nothing,String} = nothing
    margin_top::Union{Nothing,Float64} = nothing
    margin_bottom::Union{Nothing,Float64} = nothing
    margin_left::Union{Nothing,Float64} = nothing
    margin_right::Union{Nothing,Float64} = nothing
    padding_top::Union{Nothing,Float64} = nothing
    padding_bottom::Union{Nothing,Float64} = nothing
    padding_left::Union{Nothing,Float64} = nothing
    padding_right::Union{Nothing,Float64} = nothing
    display::Union{Nothing,String} = nothing
    width::Union{Nothing,Float64,String} = nothing
    height::Union{Nothing,Float64,String} = nothing
    line_height::Union{Nothing,Float64} = nothing
end

# Merge this style with another, with `other` taking precedence (Style.merge).
function merge_style(self::Style, other::Style)
    merged = Style()
    for f in fieldnames(Style)
        ov = getfield(other, f)
        setfield!(merged, f, ov !== nothing ? ov : getfield(self, f))
    end
    return merged
end

is_bold(s::Style) = s.font_weight in ("bold", "700", "800", "900")
is_italic(s::Style) = s.font_style == "italic"
is_centered(s::Style) = s.text_align == "center"

"""
    HeaderInfo

Information about a detected header (types.py `HeaderInfo`): `level` (1–6), `confidence` (0–1),
`text`, `detection_method`, and whether it is an SEC item header (`is_item`/`item_number`).
"""
Base.@kwdef struct HeaderInfo
    level::Int
    confidence::Float64
    text::String
    detection_method::String
    is_item::Bool = false
    item_number::Union{Nothing,String} = nothing
end

# HeaderInfo.from_text — create a HeaderInfo, detecting whether the text is an "Item N" header.
function header_info_from_text(text::AbstractString, level::Int, confidence::Float64, method::AbstractString)
    m = match(r"^(Item|ITEM)\s+(\d+[A-Z]?\.?)"i, strip(text))
    is_item = m !== nothing
    item_number = is_item ? rstrip(m.captures[2], '.') : nothing
    return HeaderInfo(level = level, confidence = confidence, text = text,
                      detection_method = method, is_item = is_item, item_number = item_number)
end

"""
    XBRLFact

An XBRL fact extracted from inline XBRL (types.py `XBRLFact`).
"""
Base.@kwdef mutable struct XBRLFact
    concept::String
    value::String
    context_ref::Union{Nothing,String} = nothing
    unit_ref::Union{Nothing,String} = nothing
    decimals::Union{Nothing,String} = nothing
    scale::Union{Nothing,String} = nothing
    format::Union{Nothing,String} = nothing
    sign::Union{Nothing,String} = nothing
    context::Union{Nothing,Dict{String,Any}} = nothing
    unit::Union{Nothing,String} = nothing
    metadata::Union{Nothing,Dict{String,Any}} = nothing
end

function numeric_value(f::XBRLFact)
    v = tryparse(Float64, replace(f.value, "," => ""))
    return v
end
is_numeric(f::XBRLFact) = numeric_value(f) !== nothing

"""
    ParseContext

Parsing context (types.py `ParseContext`): the base font size, current section, in-table/in-list flags,
depth, and a stack of styles whose combination gives the effective style.
"""
Base.@kwdef mutable struct ParseContext
    base_font_size::Float64 = 10.0
    current_section::Union{Nothing,String} = nothing
    in_table::Bool = false
    in_list::Bool = false
    depth::Int = 0
    style_stack::Vector{Style} = Style[]
end

push_style!(c::ParseContext, style::Style) = push!(c.style_stack, style)
pop_style!(c::ParseContext) = (isempty(c.style_stack) || pop!(c.style_stack))
function get_current_style(c::ParseContext)
    isempty(c.style_stack) && return Style()
    result = c.style_stack[1]
    for s in c.style_stack[2:end]
        result = merge_style(result, s)
    end
    return result
end
