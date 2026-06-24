# Faithful translation of edgartools' edgar/documents/table_nodes.py.
# Cell / Row / TableNode and their numeric helpers. `TableNode.text()` follows the production default
# (`fast_table_rendering=True`): it renders via FastTableRenderer(TableStyle.simple()) — see fast_table.jl.
# (The optional Rich-renderer path is not translated; the fast renderer is edgartools' default and is what
# `obj()[item]` uses.)

# Strip ISO currency prefixes (US$, C$, A$, HK$, …).
const _CURRENCY_PREFIX_RE = r"^[A-Z]{0,3}\$"
# Numeric placeholder symbols.
const _NUMERIC_PLACEHOLDERS = Set(["—", "–", "-", "--", "N/A", "n/a", "NM", "nm"])

# table_nodes.py `_clean_numeric_text`.
function _clean_numeric_text(text_::AbstractString)
    clean = replace(text_, _CURRENCY_PREFIX_RE => "")
    clean = replace(replace(replace(clean, "," => ""), "\$" => ""), "%" => "")
    return replace(replace(clean, "(" => "-"), ")" => "")
end

"""
    Cell

A table cell (table_nodes.py `Cell`): `content` (a string or a node), `colspan`/`rowspan`,
`is_header`, and optional `align`.
"""
Base.@kwdef mutable struct Cell
    content::Union{String,AbstractNode} = ""
    colspan::Int = 1
    rowspan::Int = 1
    is_header::Bool = false
    align::Union{Nothing,String} = nothing
end
Cell(content) = Cell(content = content)

function cell_text(c::Cell)
    c.content isa AbstractString && return c.content
    c.content isa AbstractNode && return text(c.content)
    return ""
end

function cell_is_numeric(c::Cell)
    t = strip(cell_text(c))
    isempty(t) && return false
    t in _NUMERIC_PLACEHOLDERS && return true
    return tryparse(Float64, _clean_numeric_text(t)) !== nothing
end

function cell_numeric_value(c::Cell)
    cell_is_numeric(c) || return nothing
    t = strip(cell_text(c))
    t in _NUMERIC_PLACEHOLDERS && return 0.0
    return tryparse(Float64, _clean_numeric_text(t))
end

function cell_html(c::Cell)
    tag = c.is_header ? "th" : "td"
    attrs = String[]
    c.colspan > 1 && push!(attrs, "colspan=\"$(c.colspan)\"")
    c.rowspan > 1 && push!(attrs, "rowspan=\"$(c.rowspan)\"")
    c.align !== nothing && push!(attrs, "align=\"$(c.align)\"")
    attr_str = isempty(attrs) ? "" : " " * join(attrs, " ")
    return "<$tag$attr_str>$(cell_text(c))</$tag>"
end

"""
    Row

A table row (table_nodes.py `Row`): its `cells` and whether it `is_header`.
"""
Base.@kwdef mutable struct Row
    cells::Vector{Cell} = Cell[]
    is_header::Bool = false
end
Row(cells) = Row(cells = cells)

row_text(r::Row) = join((cell_text(c) for c in r.cells), " | ")
row_html(r::Row) = "<tr>$(join((cell_html(c) for c in r.cells), ""))</tr>"

function row_is_numeric(r::Row)
    numeric = count(cell_is_numeric, r.cells)
    return numeric > length(r.cells) / 2
end

function row_is_total(r::Row)
    isempty(r.cells) && return false
    first_cell = strip(lowercase(cell_text(r.cells[1])))
    for kw in ("total", "sum", "subtotal", "grand total", "net total")
        (first_cell == kw || startswith(first_cell, kw * " ")) && return true
    end
    return startswith(first_cell, "total ")
end

"""
    TableNode

A table in the document tree (table_nodes.py `TableNode`): multi-row `headers`, body `rows`, `footer`,
a `table_type`, and optional `caption`/`summary`. `text()` renders it via the fast renderer.
"""
Base.@kwdef mutable struct TableNode <: AbstractNode
    id::String = _next_id()
    type::NodeType = TABLE
    parent::Union{Nothing,AbstractNode} = nothing
    children::Vector{AbstractNode} = AbstractNode[]
    content::Any = nothing
    metadata::Dict{String,Any} = Dict{String,Any}()
    style::Style = Style()
    semantic_type::Union{Nothing,SemanticType} = nothing
    semantic_role::Union{Nothing,String} = nothing
    headers::Vector{Vector{Cell}} = Vector{Cell}[]
    rows::Vector{Row} = Row[]
    footer::Vector{Row} = Row[]
    table_type::TableType = GENERAL
    caption::Union{Nothing,String} = nothing
    summary::Union{Nothing,String} = nothing
end

# TableNode.text — production default (fast_table_rendering): FastTableRenderer(simple()).
text(t::TableNode) = _fast_text_rendering(t)

function html(t::TableNode)
    parts = String["<table>"]
    if !isempty(t.headers)
        push!(parts, "<thead>")
        for hrow in t.headers
            push!(parts, "<tr>" * join((cell_html(c) for c in hrow), "") * "</tr>")
        end
        push!(parts, "</thead>")
    end
    push!(parts, "<tbody>")
    for r in t.rows
        push!(parts, row_html(r))
    end
    push!(parts, "</tbody>")
    push!(parts, "</table>")
    return join(parts, "\n")
end

row_count(t::TableNode) = length(t.headers) + length(t.rows)
