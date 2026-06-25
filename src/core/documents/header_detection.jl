# Faithful translation of edgartools' edgar/documents/strategies/header_detection.py.
# Multi-strategy header detection (style / pattern / structural / contextual) combined by weighted voting.
# Each detector takes an EzXML element + the ParseContext and returns a HeaderInfo or nothing.

# --- StyleBasedDetector -------------------------------------------------------------------------------
function detect_style(element, context::ParseContext)
    style = get_current_style(context)
    text_ = strip(_text_content(element))
    (isempty(text_) || length(text_) > 200) && return nothing
    confidence = 0.0; level = 3
    if style.font_size !== nothing && context.base_font_size != 0
        size_ratio = style.font_size / context.base_font_size
        if size_ratio >= 2.0
            confidence += 0.8; level = 1
        elseif size_ratio >= 1.5
            confidence += 0.7; level = 2
        elseif size_ratio >= 1.2
            confidence += 0.5; level = 3
        elseif size_ratio >= 1.1
            confidence += 0.3; level = 4
        end
    end
    if is_bold(style)
        confidence += 0.3
        level == 3 && (level = 2)
    end
    is_centered(style) && (confidence += 0.2)
    (_py_isupper(text_) && length(split(text_)) <= 10) && (confidence += 0.2)
    (style.margin_top !== nothing && style.margin_top > 20) && (confidence += 0.1)
    (style.margin_bottom !== nothing && style.margin_bottom > 10) && (confidence += 0.1)
    confidence = min(confidence, 1.0)
    confidence > 0.4 && return header_info_from_text(text_, level, confidence, "style")
    return nothing
end

# --- PatternBasedDetector -----------------------------------------------------------------------------
const _HEADER_PATTERNS = Tuple{Regex,Int,Float64}[
    (r"^(Item|ITEM)\s+(\d+[A-Z]?)[.\s]+(.+)$"i, 1, 0.95),
    (r"^Part\s+[IVX]+[.\s]*$"i, 1, 0.9),
    (r"^PART\s+[IVX]+[.\s]*$"i, 1, 0.9),
    (r"^(BUSINESS|RISK FACTORS|PROPERTIES|LEGAL PROCEEDINGS)$"i, 2, 0.85),
    (r"^(Management'?s?\s+Discussion|MD&A)"i, 2, 0.85),
    (r"^(Financial\s+Statements|Consolidated\s+Financial\s+Statements)$"i, 2, 0.85),
    (r"^\d+\.\s+[A-Z][A-Za-z\s]+$"i, 3, 0.7),
    (r"^[A-Z]\.\s+[A-Z][A-Za-z\s]+$"i, 3, 0.7),
    (r"^\([a-z]\)\s+[A-Z][A-Za-z\s]+$"i, 4, 0.6),
    (r"^[A-Z][A-Za-z\s]+[A-Za-z]$"i, 3, 0.5),
    (r"^[A-Z\s]+$"i, 3, 0.6),
]

function detect_pattern(element, context::ParseContext)
    text_ = strip(_text_content(element))
    (isempty(text_) || length(text_) > 200) && return nothing
    (length(text_) == 1 && occursin(text_, ".,!?;:()[]{}")) && return nothing
    count(==('.'), text_) > 2 && return nothing
    for (pattern, level, base_confidence) in _HEADER_PATTERNS
        if match(pattern, text_) !== nothing
            confidence = base_confidence
            p = _getparent(element)
            (p !== nothing && _nchildren(p) == 1) && (confidence += 0.1)
            nxt = _getnext(element)
            (nxt !== nothing && length(_text_content(nxt)) > 100) && (confidence += 0.1)
            confidence = min(confidence, 1.0)
            return header_info_from_text(text_, level, confidence, "pattern")
        end
    end
    return nothing
end

# --- StructuralDetector -------------------------------------------------------------------------------
function detect_structural(element, context::ParseContext)
    text_ = strip(_text_content(element))
    (isempty(text_) || length(text_) > 200) && return nothing
    (length(text_) == 1 && occursin(text_, ".,!?;:()[]{}")) && return nothing
    confidence = 0.0; level = 3
    tag = _tag(element)
    if tag in ("h1", "h2", "h3", "h4", "h5", "h6")
        return header_info_from_text(text_, parse(Int, string(tag[2])), 1.0, "structural")
    end
    parent = _getparent(element)
    if parent !== nothing
        parent_tag = _tag(parent)
        if parent_tag in ("header", "thead", "caption")
            confidence += 0.6; level = 2
        end
        _nchildren(parent) <= 3 && (confidence += 0.3)
        _attr(parent, "align") == "center" && (confidence += 0.2)
    end
    tag in ("strong", "b") && (confidence += 0.3)
    _attr(element, "align") == "center" && (confidence += 0.2)
    nxt = _getnext(element)
    if nxt !== nothing
        _tag(nxt) in ("p", "div", "table", "ul", "ol") && (confidence += 0.2)
    end
    nwords = length(split(text_))
    (1 <= nwords <= 10) && (confidence += 0.1)
    confidence = min(confidence, 1.0)
    confidence > 0.5 && return header_info_from_text(text_, level, confidence, "structural")
    return nothing
end

# --- ContextualDetector -------------------------------------------------------------------------------
function _looks_like_header(text_::AbstractString)
    length(split(text_)) > 15 && return false
    endswith(rstrip(text_), ('.', '!', '?', ';')) && return false
    (_py_istitle(text_) || _py_isupper(text_)) && return true
    (!isempty(text_) && isuppercase(first(text_))) && return true
    return false
end

function detect_contextual(element, context::ParseContext)
    text_ = strip(_text_content(element))
    (isempty(text_) || length(text_) > 200) && return nothing
    (length(text_) == 1 && occursin(text_, ".,!?;:()[]{}")) && return nothing
    confidence = 0.0; level = 3
    _looks_like_header(text_) && (confidence += 0.4)
    prev_elem = _getprevious(element)
    if prev_elem !== nothing
        prev_text = strip(_text_content(prev_elem))
        if !isempty(prev_text) && _looks_like_header(prev_text)
            confidence += 0.3
            level = length(text_) > length(prev_text) ? 2 : 3
        end
    end
    nxt = _getnext(element)
    if nxt !== nothing
        next_text = strip(_text_content(nxt))
        length(next_text) > length(text_) * 3 && (confidence += 0.3)
        next_style = _attr(nxt, "style", "")
        (occursin("margin-left", next_style) || occursin("padding-left", next_style)) && (confidence += 0.2)
    end
    (context.current_section === nothing && context.depth < 5) && (confidence += 0.2)
    confidence = min(confidence, 1.0)
    confidence > 0.5 && return header_info_from_text(text_, level, confidence, "contextual")
    return nothing
end

# --- HeaderDetectionStrategy --------------------------------------------------------------------------
struct HeaderDetectionStrategy
    config::ParserConfig
end

_header_detectors() = (detect_style, detect_pattern, detect_structural, detect_contextual)

function detect(s::HeaderDetectionStrategy, element, context::ParseContext)
    text_ = strip(_text_content(element))
    isempty(text_) && return nothing
    results = HeaderInfo[]
    for detector in _header_detectors()
        try
            r = detector(element, context)
            r !== nothing && push!(results, r)
        catch
            continue
        end
    end
    isempty(results) && return nothing
    if length(results) == 1
        results[1].confidence >= s.config.header_detection_threshold && return results[1]
        return nothing
    end
    return _combine_results(results, text_)
end

# HeaderDetectionStrategy.is_section_header — heuristic check used by the streaming parser.
const _MAJOR_SECTIONS = Set(["BUSINESS", "RISK FACTORS", "PROPERTIES", "LEGAL PROCEEDINGS",
    "FINANCIAL STATEMENTS", "CONSOLIDATED FINANCIAL STATEMENTS",
    "QUANTITATIVE AND QUALITATIVE DISCLOSURES ABOUT MARKET RISK"])
function is_section_header(s::HeaderDetectionStrategy, text_::AbstractString, element)
    (isempty(text_) || length(text_) > 200) && return false
    match(r"^(Item|ITEM)\s+(\d+[A-Z]?)", text_) !== nothing && return true
    match(r"^(Part|PART)\s+[IVX]+", text_) !== nothing && return true
    uppercase(text_) in _MAJOR_SECTIONS && return true
    (occursin("MANAGEMENT", uppercase(text_)) && occursin("DISCUSSION", uppercase(text_))) && return true
    return false
end

const _DETECTOR_WEIGHTS = Dict("style" => 0.3, "pattern" => 0.4, "structural" => 0.2, "contextual" => 0.1, "ml" => 0.5)

function _combine_results(results::Vector{HeaderInfo}, text_::AbstractString)
    total_confidence = 0.0; total_weight = 0.0
    level_votes = Dict{Int,Float64}()
    level_order = Int[]                              # first-appearance order (Python dict insertion order)
    for r in results
        weight = get(_DETECTOR_WEIGHTS, r.detection_method, 0.1)
        total_confidence += r.confidence * weight
        total_weight += weight
        haskey(level_votes, r.level) || push!(level_order, r.level)
        level_votes[r.level] = get(level_votes, r.level, 0.0) + r.confidence * weight
    end
    final_confidence = total_weight > 0 ? total_confidence / total_weight : 0.0
    # most-voted level; ties resolve to the first inserted (faithful to Python max(items, key=...))
    final_level = level_order[1]
    for lvl in level_order
        level_votes[lvl] > level_votes[final_level] && (final_level = lvl)
    end
    is_item = any(r -> r.is_item, results)
    item_number = nothing
    for r in results
        if r.item_number !== nothing
            item_number = r.item_number; break
        end
    end
    return HeaderInfo(level = final_level, confidence = final_confidence, text = text_,
                      detection_method = "combined", is_item = is_item, item_number = item_number)
end
