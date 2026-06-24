# Faithful translation of edgartools' edgar/documents/extractors/toc_section_detector.py.
# TOC-based section detection (confidence 0.95) — wraps SECSectionExtractor (toc_section_extractor.jl),
# which does the real TOC parsing + section-text extraction from the original HTML.

mutable struct TOCSectionDetector
    document::Document
    agent::Union{Nothing,String}
    extractor::Any   # SECSectionExtractor
end
TOCSectionDetector(document::Document; agent::Union{Nothing,String} = nothing) =
    TOCSectionDetector(document, agent, SECSectionExtractor(document; agent = agent))

function detect(d::TOCSectionDetector)
    html_content = d.document.metadata.original_html
    html_content === nothing && return nothing
    try
        available = get_available_sections(d.extractor)
        isempty(available) && return nothing
        secs = Sections()
        for section_name in available
            section_info = get_section_info(d.extractor, section_name)
            section_info === nothing && continue
            section_text = get_section_text(d.extractor, section_name; include_subsections = true)
            has_subsections = get(section_info, "subsections", String[])
            (isempty(something(section_text, "")) && isempty(has_subsections)) && continue
            section_node = SectionNode(section_name = section_name)
            section_length = section_text === nothing ? 0 : length(section_text)
            # Lazy text-extractor closure (captures the extractor + this section's name).
            extractor = d.extractor
            nm = section_name
            make_extract = (sname = nothing; clean = true, kwargs...) ->
                something(get_section_text(extractor, nm; include_subsections = true, clean = clean), "")
            part, item = parse_section_name(section_name)
            html_source = d.document.metadata.original_html
            secs[section_name] = Section(
                name = section_name,
                title = get(section_info, "canonical_name", section_name),
                node = section_node, start_offset = 0, end_offset = section_length,
                confidence = 0.95, detection_method = "toc", part = part, item = item,
                _text_extractor = make_extract, _html_source = html_source, _section_extractor = extractor)
        end
        return isempty(secs) ? nothing : secs
    catch
        return nothing
    end
end
