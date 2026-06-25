# Faithful translation of edgartools' edgar/documents/strategies/style_parser.py.
# Parses inline CSS `style="..."` strings into Style objects. (edgartools caches parsed styles for speed;
# the cache is a pure optimisation and is omitted — output is identical.)

const _STYLE_ABSOLUTE_UNITS = Set(["px", "pt", "pc", "cm", "mm", "in"])
const _STYLE_RELATIVE_UNITS = Set(["em", "rem", "ex", "ch", "vw", "vh", "%"])
const _FONT_WEIGHT_MAP = Dict("normal" => "400", "bold" => "700", "bolder" => "800", "lighter" => "300")

struct StyleParser end

# StyleParser.parse
function parse_style(::StyleParser, style_string::AbstractString)
    isempty(style_string) && return Style()
    style = Style()
    for (prop, value) in _split_declarations(style_string)
        _apply_property!(style, prop, value)
    end
    return style
end
parse_style(s::AbstractString) = parse_style(StyleParser(), s)

function _split_declarations(style_string::AbstractString)
    declarations = Pair{String,String}[]
    for part in split(style_string, ';')
        p = strip(part)
        isempty(p) && continue
        if occursin(':', p)
            kv = split(p, ':', limit = 2)
            prop = lowercase(strip(kv[1])); value = strip(kv[2])
            (!isempty(prop) && !isempty(value)) && push!(declarations, String(prop) => String(value))
        end
    end
    return declarations
end

function _apply_property!(style::Style, prop::AbstractString, value::AbstractString)
    if prop == "font-size"
        size = _parse_length(value); size !== nothing && (style.font_size = size)
    elseif prop == "font-weight"
        style.font_weight = _normalize_font_weight(value)
    elseif prop == "font-style"
        if value in ("italic", "oblique")
            style.font_style = "italic"
        elseif value == "normal"
            style.font_style = "normal"
        end
    elseif prop == "text-align"
        value in ("left", "right", "center", "justify") && (style.text_align = String(value))
    elseif prop == "text-decoration"
        style.text_decoration = String(value)
    elseif prop == "color"
        style.color = _normalize_color(value)
    elseif prop in ("background-color", "background")
        color = _extract_background_color(value); color !== nothing && (style.background_color = color)
    elseif prop == "margin"
        _parse_box_property!(style, "margin", value)
    elseif prop == "margin-top"
        m = _parse_length(value); m !== nothing && (style.margin_top = m)
    elseif prop == "margin-bottom"
        m = _parse_length(value); m !== nothing && (style.margin_bottom = m)
    elseif prop == "margin-left"
        m = _parse_length(value); m !== nothing && (style.margin_left = m)
    elseif prop == "margin-right"
        m = _parse_length(value); m !== nothing && (style.margin_right = m)
    elseif prop == "padding"
        _parse_box_property!(style, "padding", value)
    elseif prop == "padding-top"
        p = _parse_length(value); p !== nothing && (style.padding_top = p)
    elseif prop == "padding-bottom"
        p = _parse_length(value); p !== nothing && (style.padding_bottom = p)
    elseif prop == "padding-left"
        p = _parse_length(value); p !== nothing && (style.padding_left = p)
    elseif prop == "padding-right"
        p = _parse_length(value); p !== nothing && (style.padding_right = p)
    elseif prop == "display"
        style.display = String(value)
    elseif prop == "width"
        style.width = _parse_dimension(value)
    elseif prop == "height"
        style.height = _parse_dimension(value)
    elseif prop == "line-height"
        lh = _parse_line_height(value); lh !== nothing && (style.line_height = lh)
    end
    return nothing
end

function _parse_length(value::AbstractString)
    v = lowercase(strip(value))
    v in ("0", "auto", "inherit", "initial") && return v == "0" ? 0.0 : nothing
    m = match(r"^(-?\d*\.?\d+)\s*([a-z%]*)$", v)
    m === nothing && return nothing
    num = tryparse(Float64, m.captures[1]); num === nothing && return nothing
    unit = m.captures[2]
    (isempty(unit) || unit == "px") && return num
    unit == "pt" && return num * 1.333
    unit == "em" && return num * 16
    unit == "rem" && return num * 16
    unit == "%" && return nothing
    unit == "in" && return num * 96
    unit == "cm" && return num * 37.8
    unit == "mm" && return num * 3.78
    return nothing
end

function _parse_dimension(value::AbstractString)
    v = strip(value)
    endswith(v, "%") && return String(v)
    return _parse_length(v)
end

function _parse_line_height(value::AbstractString)
    v = strip(value)
    f = tryparse(Float64, v)
    f !== nothing && return f
    return _parse_length(v)
end

function _normalize_font_weight(value::AbstractString)
    v = lowercase(strip(value))
    haskey(_FONT_WEIGHT_MAP, v) && return _FONT_WEIGHT_MAP[v]
    if _py_isdigit(v)
        iv = parse(Int, v)
        100 <= iv <= 900 && return v
    end
    return String(v)
end

function _normalize_color(value::AbstractString)
    v = lowercase(strip(value))
    (startswith(v, "rgb(") || startswith(v, "rgba(")) && return String(v)
    if startswith(v, "#")
        length(v) == 4 && return "#" * join(string(c, c) for c in v[2:end])
        return String(v)
    end
    return String(v)
end

function _extract_background_color(value::AbstractString)
    for part in split(value)
        (startswith(part, "#") || startswith(part, "rgb")) && return _normalize_color(part)
        if !any(unit -> occursin(unit, part), union(_STYLE_ABSOLUTE_UNITS, _STYLE_RELATIVE_UNITS))
            return String(part)
        end
    end
    return nothing
end

function _parse_box_property!(style::Style, prop_type::AbstractString, value::AbstractString)
    lengths = Float64[]
    for part in split(value)
        l = _parse_length(part); l !== nothing && push!(lengths, l)
    end
    isempty(lengths) && return nothing
    set(side, v) = setfield!(style, Symbol("$(prop_type)_$(side)"), v)
    n = length(lengths)
    if n == 1
        v = lengths[1]; set("top", v); set("right", v); set("bottom", v); set("left", v)
    elseif n == 2
        vert, horiz = lengths[1], lengths[2]
        set("top", vert); set("bottom", vert); set("left", horiz); set("right", horiz)
    elseif n == 3
        top, horiz, bottom = lengths[1], lengths[2], lengths[3]
        set("top", top); set("bottom", bottom); set("left", horiz); set("right", horiz)
    else
        set("top", lengths[1]); set("right", lengths[2]); set("bottom", lengths[3]); set("left", lengths[4])
    end
    return nothing
end

merge_styles(::StyleParser, base::Style, override::Style) = merge_style(base, override)
