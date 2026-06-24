# Faithful translation of edgartools' edgar/documents/extractors/hybrid_section_detector.py.
# Multi-strategy section detection: TOC (primary) -> heading (fallback) -> pattern (last resort), then a
# validation pipeline (cross-validate / boundaries / dedupe / confidence filter). The TOC and pattern
# strategies (TOCSectionDetector, SectionExtractor) and `detect_filing_agent` are translated separately;
# this is the orchestrator that calls them.

mutable struct HybridSectionDetector
    document::Document
    form::String
    thresholds::DetectionThresholds
    toc_detector::Any        # TOCSectionDetector
    pattern_extractor::Any   # SectionExtractor
end

function HybridSectionDetector(document::Document, form::AbstractString,
                               thresholds::Union{Nothing,DetectionThresholds} = nothing)
    th = thresholds === nothing ? DetectionThresholds() : thresholds
    agent = _detect_agent(document)
    HybridSectionDetector(document, String(form), th,
                          TOCSectionDetector(document; agent = agent), SectionExtractor(form))
end

function _detect_agent(document::Document)
    html_content = document.metadata.original_html
    html_content === nothing && return nothing
    try
        return detect_filing_agent(html_content)
    catch
        return nothing
    end
end

# detect_sections — try TOC, then heading, then pattern; validate the winner.
function detect_sections(d::HybridSectionDetector)
    secs = detect(d.toc_detector)
    if secs !== nothing && !isempty(secs)
        return _validate_pipeline(d, secs; enable_cross_validation = true)
    end
    secs = _try_heading_detection(d)
    if secs !== nothing && !isempty(secs)
        return _validate_pipeline(d, secs; enable_cross_validation = false)
    end
    secs = _try_pattern_detection(d)
    if secs !== nothing && !isempty(secs)
        return _validate_pipeline(d, secs; enable_cross_validation = false)
    end
    return Sections()
end

function _validate_pipeline(d::HybridSectionDetector, secs::Sections; enable_cross_validation::Bool = false)
    isempty(secs) && return secs
    (enable_cross_validation && d.thresholds.enable_cross_validation) && (secs = _cross_validate(d, secs))
    secs = _validate_boundaries(d, secs)
    secs = _deduplicate(d, secs)
    secs = _filter_by_confidence(d, secs)
    return secs
end

function _try_heading_detection(d::HybridSectionDetector)
    try
        hs = headings(d.document)
        isempty(hs) && return nothing
        secs = Sections()
        for heading in hs
            hi = get_metadata(heading, "header_info")
            hi === nothing && continue
            hi.confidence < 0.7 && continue
            hi.is_item || continue
            section = _extract_section_from_heading(d, heading, hi)
            if section !== nothing
                section.confidence = hi.confidence
                section.detection_method = "heading"
                secs[section.name] = section
            end
        end
        return isempty(secs) ? nothing : secs
    catch
        return nothing
    end
end

function _try_pattern_detection(d::HybridSectionDetector)
    try
        secs = extract(d.pattern_extractor, d.document)
        for section in values(secs)
            section.detection_method = "pattern"
        end
        return isempty(secs) ? nothing : secs
    catch
        return nothing
    end
end

function _extract_section_from_heading(d::HybridSectionDetector, heading::AbstractNode, header_info)
    try
        section_name = header_info.item_number !== nothing ?
            "item_$(replace(header_info.item_number, "." => "_"))" : "unknown"
        section_node = SectionNode(section_name = section_name)
        current_level = header_info.level
        parent = heading.parent
        parent === nothing && return nothing
        heading_index = findfirst(x -> x === heading, parent.children)
        heading_index === nothing && return nothing
        for i in (heading_index + 1):length(parent.children)
            child = parent.children[i]
            if child isa HeadingNode
                chi = get_metadata(child, "header_info")
                (chi !== nothing && chi.level <= current_level) && break
            end
            add_child!(section_node, child)
        end
        return Section(name = section_name, title = header_info.text, node = section_node,
                       start_offset = 0, end_offset = 0, confidence = header_info.confidence,
                       detection_method = "heading")
    catch
        return nothing
    end
end

function _cross_validate(d::HybridSectionDetector, secs::Sections)
    validated = Sections()
    pattern_sections = try
        extract(d.pattern_extractor, d.document)
    catch
        Sections()
    end
    for (name, section) in secs
        try
            found = false
            for ps in values(pattern_sections)
                if _sections_similar(section, ps)
                    found = true; break
                end
            end
            if found
                section.confidence = min(section.confidence * d.thresholds.cross_validation_boost, 1.0)
                section.validated = true
            else
                section.confidence *= d.thresholds.disagreement_penalty
                section.validated = false
            end
        catch
        end
        validated[name] = section
    end
    return validated
end

function _validate_boundaries(d::HybridSectionDetector, secs::Sections)
    isempty(secs) && return secs
    sorted_sections = sort(collect(secs); by = kv -> kv[2].start_offset)
    validated = Sections()
    prev = nothing
    for (name, section) in sorted_sections
        if prev !== nothing && section.start_offset > 0
            if section.start_offset < prev[2].end_offset
                gap_mid = (prev[2].end_offset + section.start_offset) ÷ 2
                prev[2].end_offset = gap_mid
                section.start_offset = gap_mid
                section.confidence *= d.thresholds.boundary_overlap_penalty
                prev[2].confidence *= d.thresholds.boundary_overlap_penalty
            elseif prev[2].end_offset > 0
                gap_size = section.start_offset - prev[2].end_offset
                gap_size > 100000 && (section.confidence *= 0.9)
            end
        end
        validated[name] = section
        prev = (name, section)
    end
    return validated
end

function _deduplicate(d::HybridSectionDetector, secs::Sections)
    length(secs) <= 1 && return secs
    groups = _group_similar_sections(d, secs)
    dedup = Sections()
    for group in groups
        if length(group) == 1
            dedup[group[1].name] = group[1]
        else
            best = group[1]
            for s in group
                s.confidence > best.confidence && (best = s)
            end
            methods = sort(unique(s.detection_method for s in group))
            if length(methods) > 1
                best.detection_method = join(methods, ",")
                best.confidence = min(best.confidence * 1.15, 1.0)
                best.validated = true
            end
            dedup[best.name] = best
        end
    end
    return dedup
end

function _group_similar_sections(d::HybridSectionDetector, secs::Sections)
    groups = Vector{Section}[]
    used = Set{String}()
    for (name1, section1) in secs
        name1 in used && continue
        group = Section[section1]
        push!(used, name1)
        for (name2, section2) in secs
            name2 in used && continue
            if _sections_similar(section1, section2)
                push!(group, section2); push!(used, name2)
            end
        end
        push!(groups, group)
    end
    return groups
end

function _sections_similar(section1::Section, section2::Section)
    name1 = strip(replace(lowercase(section1.name), "_" => " "))
    name2 = strip(replace(lowercase(section2.name), "_" => " "))
    name1 == name2 && return true
    strip(lowercase(section1.title)) == strip(lowercase(section2.title)) && return true
    if section1.start_offset > 0 && section2.start_offset > 0
        overlap_start = max(section1.start_offset, section2.start_offset)
        overlap_end = min(section1.end_offset, section2.end_offset)
        if overlap_end > overlap_start
            overlap_size = overlap_end - overlap_start
            min_size = min(section1.end_offset - section1.start_offset, section2.end_offset - section2.start_offset)
            min_size > 0 && overlap_size / min_size > 0.5 && return true
        end
    end
    return false
end

function _filter_by_confidence(d::HybridSectionDetector, secs::Sections)
    min_conf = d.thresholds.min_confidence
    if haskey(d.thresholds.thresholds_by_form, d.form)
        min_conf = get(d.thresholds.thresholds_by_form[d.form], "min_confidence", min_conf)
    end
    filtered = Sections()
    for (name, section) in secs
        section.confidence >= min_conf && (filtered[name] = section)
    end
    return filtered
end
