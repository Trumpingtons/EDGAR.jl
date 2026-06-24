# Faithful translation of edgartools' edgar/documents/extractors/toc_section_extractor.py.
# SECSectionExtractor: uses TOCAnalyzer to map sections->anchor ids, then extracts each section's text by a
# document-order walk between its start anchor and the next section's anchor (collecting .text/.tail, with a
# paragraph break after block-level elements), plus a short-content fallback that regex-finds the real ITEM
# header in the HTML. Operates on the EzXML tree parsed from the original HTML.

Base.@kwdef mutable struct SectionBoundary
    name::String
    anchor_id::String
    start_element_id::Union{Nothing,String} = nothing
    end_element_id::Union{Nothing,String} = nothing
    confidence::Float64 = 1.0
    detection_method::String = "unknown"
end

mutable struct SECSectionExtractor
    document::Document
    agent::Union{Nothing,String}
    section_map::Dict{String,String}
    section_boundaries::Dict{String,SectionBoundary}
    toc_analyzer::Any           # TOCAnalyzer
    _tree::Any                  # cached EzXML root element
    _clean_html::Union{Nothing,String}
end
function SECSectionExtractor(document::Document; agent::Union{Nothing,String} = nothing)
    ex = SECSectionExtractor(document, agent, Dict{String,String}(), Dict{String,SectionBoundary}(),
                             TOCAnalyzer(), nothing, nothing)
    _analyze_sections(ex)
    return ex
end

function _parse_html(ex::SECSectionExtractor, html_content::AbstractString)
    startswith(html_content, "<?xml") && (html_content = replace(html_content, r"<\?xml[^>]*\?>" => ""; count = 1))
    ex._clean_html = html_content
    ex._tree = EzXML.root(EzXML.parsehtml(html_content))
    return ex._tree
end

function _analyze_sections(ex::SECSectionExtractor)
    html_content = ex.document.metadata.original_html
    html_content === nothing && return
    tree = _parse_html(ex, html_content)
    toc_mapping = analyze_toc_structure(ex.toc_analyzer, html_content; agent = ex.agent, tree = tree)
    isempty(toc_mapping) && return
    sec_sections = Dict{String,Any}()
    for (section_name, anchor_id) in toc_mapping
        target_elements = find_anchor_targets(tree, anchor_id)
        if !isempty(target_elements)
            section_type, order = _get_section_type_and_order(ex.toc_analyzer, section_name)
            sec_sections[section_name] = Dict{String,Any}(
                "anchor_id" => anchor_id, "canonical_name" => section_name,
                "type" => section_type, "order" => order,
                "confidence" => 0.95, "detection_method" => "toc")
        end
    end
    isempty(sec_sections) && return
    sorted_sections = sort(collect(sec_sections); by = kv -> kv[2]["order"])
    for (i, (section_name, section_data)) in enumerate(sorted_sections)
        start_anchor = section_data["anchor_id"]
        end_anchor = nothing
        if i + 1 <= length(sorted_sections)
            end_anchor = sorted_sections[i + 1][2]["anchor_id"]
        end
        ex.section_boundaries[section_name] = SectionBoundary(
            name = section_name, anchor_id = start_anchor, end_element_id = end_anchor,
            confidence = get(section_data, "confidence", 0.95),
            detection_method = get(section_data, "detection_method", "toc"))
    end
    for (name, data) in sec_sections
        ex.section_map[name] = data["canonical_name"]
    end
    return
end

get_available_sections(ex::SECSectionExtractor) =
    sort(collect(keys(ex.section_boundaries)); by = x -> ex.section_boundaries[x].anchor_id)

function get_section_text(ex::SECSectionExtractor, section_name::AbstractString;
                          include_subsections::Bool = true, clean::Bool = true)
    normalized_name = _normalize_section_name(ex, section_name)
    haskey(ex.section_boundaries, normalized_name) || return nothing
    boundary = ex.section_boundaries[normalized_name]
    html_content = ex.document.metadata.original_html
    html_content === nothing && return nothing
    try
        section_text = _extract_section_content(ex, html_content, boundary, include_subsections, clean)
        # edgartools guards this with `if section_text and len(...) < 200`: an EMPTY string is falsy in
        # Python, so an empty extract skips _find_actual_item_content and falls through to subsection
        # aggregation (and, with no subsections, leaves the section out so the chunked fallback wins).
        if section_text !== nothing && !isempty(section_text) && length(strip(section_text)) < 200
            m = match(r"(?:part_[iv]+_)?item[_\s]*(\d+[a-z]?)"i, normalized_name)
            if m !== nothing
                item_num = uppercase(m.captures[1])
                actual = _find_actual_item_content(ex, html_content, item_num, boundary, clean)
                (actual !== nothing && length(actual) > length(section_text)) && (section_text = actual)
            end
        end
        if (section_text === nothing || isempty(section_text)) && include_subsections
            subsections = _get_subsections(ex, normalized_name)
            if !isempty(subsections)
                texts = String[]
                for sub in subsections
                    t = get_section_text(ex, sub; include_subsections = true, clean = clean)
                    (t !== nothing && !isempty(t)) && push!(texts, t)
                end
                isempty(texts) || (section_text = join(texts, "\n\n"))
            end
        end
        return section_text
    catch
        return nothing
    end
end

function _normalize_section_name(ex::SECSectionExtractor, section_name::AbstractString)
    name = strip(section_name)
    name = replace(name, r"[.:]$" => "")
    m = match(r"item\s+(\d+[a-z]?)"i, name)
    if match(r"item\s+\d+"i, name) !== nothing && m !== nothing
        name = "Item $(uppercase(m.captures[1]))"
    else
        mp = match(r"part\s+([ivx]+)"i, name)
        if match(r"part\s+[ivx]+"i, name) !== nothing && mp !== nothing
            name = "Part $(uppercase(mp.captures[1]))"
        end
    end
    return name
end

const _SEC_BLOCK_ELEMENTS = Set(["p", "div", "table", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6",
                                 "blockquote", "pre", "section", "article", "header", "footer"])

function _extract_section_content(ex::SECSectionExtractor, html_content, boundary::SectionBoundary,
                                  include_subsections::Bool, clean::Bool)
    tree = ex._tree
    if tree === nothing
        startswith(html_content, "<?xml") && (html_content = replace(html_content, r"<\?xml[^>]*\?>" => ""; count = 1))
        tree = EzXML.root(EzXML.parsehtml(html_content))
    end
    isempty(find_anchor_targets(tree, boundary.anchor_id)) && return ""
    all_text = String[]
    in_range = Ref(false); stop = Ref(false)
    function walk(el)
        stop[] && return
        # --- start event ---
        if is_anchor_match(el, boundary.anchor_id)
            in_range[] = true                              # 'continue': do not append this element's text
        elseif boundary.end_element_id !== nothing && is_anchor_match(el, boundary.end_element_id)
            in_range[] = false; stop[] = true; return
        elseif in_range[] && !include_subsections && _is_sibling_section(ex, _attr(el, "id", ""), boundary.name)
            in_range[] = false; stop[] = true; return
        elseif in_range[]
            t = _lxtext(el); isempty(t) || push!(all_text, t)
        end
        for c in _children(el)
            walk(c)
            stop[] && return
        end
        # --- end event ---
        if in_range[] && _tag(el) in _SEC_BLOCK_ELEMENTS
            push!(all_text, "\n\n")
        end
        if in_range[]
            tl = _lxtail(el); isempty(tl) || push!(all_text, tl)
        end
        return
    end
    walk(tree)
    combined = join(all_text, "")
    clean && (combined = _clean_section_text(ex, combined))
    return combined
end

function _is_sibling_section(ex::SECSectionExtractor, element_id::AbstractString, current_section::AbstractString)
    isempty(element_id) && return false
    if occursin("item", lowercase(current_section)) && occursin("item", lowercase(element_id))
        cm = match(r"item\s*(\d+)"i, current_section)
        om = match(r"item[\s_]*(\d+)"i, element_id)
        (cm !== nothing && om !== nothing) && return cm.captures[1] != om.captures[1]
    end
    return false
end

function _clean_section_text(ex::SECSectionExtractor, text_::AbstractString)
    text_ = replace(text_, r"\n\s*\n\s*\n" => "\n\n")
    html_content = ex.document.metadata.original_html
    html_content !== nothing && (text_ = filter_with_cached_patterns(text_, html_content))
    return strip(text_)
end

const _ITEM_TITLES = Dict("1" => "BUSINESS", "1A" => "RISK\\s*FACTORS?", "1B" => "UNRESOLVED\\s*STAFF\\s*COMMENTS?",
    "1C" => "CYBERSECURITY", "2" => "PROPERTIES", "3" => "LEGAL\\s*PROCEEDINGS?", "4" => "MINE\\s*SAFETY",
    "5" => "MARKET\\s*FOR", "6" => "(SELECTED|RESERVED)", "7" => "MANAGEMENT", "7A" => "QUANTITATIVE",
    "8" => "FINANCIAL\\s*STATEMENTS?", "9" => "CHANGES?\\s*IN", "9A" => "CONTROLS?", "9B" => "OTHER\\s*INFORMATION",
    "9C" => "DISCLOSURE")

function _find_actual_item_content(ex::SECSectionExtractor, html_content, item_num, boundary, clean)
    startswith(html_content, "<?xml") && (html_content = replace(html_content, r"<\?xml[^>]*\?>" => ""; count = 1))
    item_pattern = "ITEM[\\s&#;0-9xnbsp]+$(_re_escape(item_num))\\.?[\\s&#;0-9xnbsp]*"
    title_pattern = get(_ITEM_TITLES, item_num, "\\w+")
    full = Regex("$item_pattern$title_pattern", "i")
    m = match(full, html_content)
    m === nothing && return nothing
    start_pos = m.offset
    search_start = start_pos + ncodeunits(m.match)
    nextm = match(r"ITEM[\s&#;0-9xnbsp]*\d+[A-Z]?\.?\s*[A-Z]"i, SubString(html_content, thisind(html_content, min(search_start, ncodeunits(html_content)))))
    # Python uses html_content[start_pos:end_pos] (end-EXCLUSIVE); _byte_span is end-INCLUSIVE, so subtract
    # one extra to stop just before the next-item match (otherwise the [A-Z] it matched leaks in as one char).
    if nextm !== nothing
        end_pos = search_start + nextm.offset - 2
    elseif boundary.end_element_id !== nothing
        idx = findfirst("id=\"$(boundary.end_element_id)\"", html_content)
        end_pos = (idx !== nothing && first(idx) > start_pos) ? first(idx) - 1 : ncodeunits(html_content)
    else
        end_pos = ncodeunits(html_content)
    end
    section_html = _byte_span(html_content, start_pos, end_pos)
    try
        text_ = nodecontent(EzXML.root(EzXML.parsehtml("<div>$section_html</div>")))
        clean && (text_ = _clean_section_text(ex, text_))
        return strip(text_)
    catch
        return nothing
    end
end

_re_escape(s) = replace(s, r"([.\\+*?\[\]^$(){}=!<>|:\-#])" => s"\\\1")
function _byte_span(s::AbstractString, a::Int, b::Int)
    nb = ncodeunits(s); a = max(a, 1); b = min(b, nb)
    a > b && return ""
    ta = thisind(s, a); ta < a && (ta = nextind(s, ta)); tb = thisind(s, b)
    return ta > tb ? "" : String(SubString(s, ta, tb))
end

function get_section_info(ex::SECSectionExtractor, section_name::AbstractString)
    normalized_name = _normalize_section_name(ex, section_name)
    haskey(ex.section_boundaries, normalized_name) || return nothing
    boundary = ex.section_boundaries[normalized_name]
    return Dict{String,Any}("name" => boundary.name, "anchor_id" => boundary.anchor_id,
        "available" => true, "estimated_length" => nothing, "canonical_name" => boundary.name,
        "subsections" => _get_subsections(ex, normalized_name))
end

function _get_subsections(ex::SECSectionExtractor, parent_section::AbstractString)
    subsections = String[]
    for section_name in keys(ex.section_boundaries)
        section_name == parent_section && continue
        if startswith(section_name, parent_section)
            remainder = section_name[nextind(section_name, 0, length(parent_section) + 1):end]
            if !isempty(remainder) && isletter(first(remainder))
                push!(subsections, section_name)
            elseif !isempty(remainder) && first(remainder) in (' ', '-', '.', ':')
                push!(subsections, section_name)
            end
        end
    end
    return sort(subsections)
end
