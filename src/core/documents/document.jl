# Faithful translation of edgartools' edgar/documents/document.py — the DocumentMetadata, Section, Sections
# and Document types (+ the sections property that dispatches to the detectors). Section.text() reproduces
# both paths: the TOC `_text_extractor` callback and the node-tree TextExtractor, then boundary cleanup.

Base.@kwdef mutable struct DocumentMetadata
    source::Union{Nothing,String} = nothing
    form::Union{Nothing,String} = nothing
    company::Union{Nothing,String} = nothing
    cik::Union{Nothing,String} = nothing
    accession_number::Union{Nothing,String} = nothing
    filing_date::Union{Nothing,String} = nothing
    report_date::Union{Nothing,String} = nothing
    url::Union{Nothing,String} = nothing
    size::Int = 0
    parse_time::Float64 = 0.0
    parser_version::String = "2.0.0"
    xbrl_data::Union{Nothing,Vector{XBRLFact}} = nothing
    preserve_whitespace::Bool = false
    original_html::Union{Nothing,String} = nothing
end

"""
    Section

A detected document section (document.py `Section`). `text()` extracts its content (via the TOC callback
when present, else the node-tree TextExtractor) and cleans boundary artifacts.
"""
Base.@kwdef mutable struct Section
    name::String
    title::String
    node::AbstractNode
    start_offset::Int = 0
    end_offset::Int = 0
    confidence::Float64 = 1.0
    detection_method::String = "unknown"
    validated::Bool = false
    part::Union{Nothing,String} = nothing
    item::Union{Nothing,String} = nothing
    _text_extractor::Union{Nothing,Function} = nothing
    _html_source::Union{Nothing,String} = nothing
    _section_extractor::Any = nothing
end

# Section.text — TOC sections use the lazy callback; heading/pattern sections extract from the node.
function section_text(s::Section; clean::Bool = true, include_tables::Bool = true,
                      include_metadata::Bool = false, max_length::Union{Nothing,Int} = nothing,
                      table_max_col_width::Union{Nothing,Int} = nothing)
    if s._text_extractor !== nothing
        text_ = s._text_extractor(s.name; clean = clean)
    else
        ex = TextExtractor(clean = clean, include_tables = include_tables,
                           include_metadata = include_metadata, max_length = max_length,
                           table_max_col_width = table_max_col_width)
        text_ = extract_from_node(ex, s.node)
    end
    return _clean_boundary_artifacts(text_)
end

# Section._clean_boundary_artifacts — strip interior/trailing page headers, footers, bleeding item
# headers and trailing page numbers (document.py).
function _clean_boundary_artifacts(text_::AbstractString)
    isempty(text_) && return text_
    # 1a. interior page header (10-K/10-Q): page number + PART + Item
    text_ = replace(text_, r"(?i)\n\s*\d{1,3}\s*\n\s*PART\s+[IVX]+\s*\n\s*Item\s+\d+[A-Za-z]?(?:,\s*\d+[A-Za-z]?)?\s*\n" => "\n\n")
    # 1b. interior page header (20-F): page number + Table of Contents
    text_ = replace(text_, r"(?i)\n\s*\d{1,3}\s*\n\s*Table of Contents\s*\n" => "\n\n")
    # 2a. trailing page footer (10-K/10-Q)
    text_ = replace(text_, r"(?i)\n\s*\d{1,3}\s*\n\s*PART\s+[IVX]+\s*\n\s*Item\s+\d+[A-Za-z]?(?:,\s*\d+[A-Za-z]?)?\s*$" => "")
    # 2b. trailing page footer (20-F)
    text_ = replace(text_, r"(?i)\n\s*\d{1,3}\s*\n\s*Table of Contents\s*$" => "")
    # 3. trailing Item header
    text_ = replace(text_, r"(?i)\n\s*Item\s+\d+[A-Za-z]?\.?\s*$" => "")
    # 4. trailing page number
    text_ = replace(text_, r"\n\s*\d{1,3}\s*$" => "")
    return rstrip(text_)
end

# Section.parse_section_name — "part_i_item_1" -> ("I","1"); "item_1a" -> (nothing,"1A").
function parse_section_name(name::AbstractString)
    m = match(r"^part_([ivx]+)_item_(\d+[a-z]?)$"i, name)
    m !== nothing && return (uppercase(m.captures[1]), uppercase(m.captures[2]))
    m = match(r"^item_(\d+[a-z]?)$"i, name)
    m !== nothing && return (nothing, uppercase(m.captures[1]))
    return (nothing, nothing)
end

# Sections — dict of name => Section (document.py `Sections(Dict)` wrapper; rich display omitted).
const Sections = Dict{String,Section}

"""
    Document

A parsed document (document.py `Document`): the node `root`, `metadata`, parser `config`, and cached
`sections`/`headings`.
"""
Base.@kwdef mutable struct Document
    root::AbstractNode
    metadata::DocumentMetadata = DocumentMetadata()
    config::Union{Nothing,ParserConfig} = nothing
    _sections::Union{Nothing,Sections} = nothing
    _headings::Union{Nothing,Vector{AbstractNode}} = nothing
end

function headings(doc::Document)
    doc._headings === nothing && (doc._headings = find_nodes(doc.root, n -> n isa HeadingNode))
    return doc._headings
end

# Document.sections — dispatch to HybridSectionDetector for 10-K/10-Q/8-K/20-F, else pattern extractor.
function sections(doc::Document)
    if doc._sections === nothing
        form = nothing
        if doc.config !== nothing && doc.config.form !== nothing
            form = doc.config.form
        elseif doc.metadata.form !== nothing
            form = doc.metadata.form
        end
        base_form = form === nothing ? nothing : replace(form, "/A" => "")
        if base_form !== nothing && base_form in ("10-K", "10-Q", "8-K", "20-F")
            thresholds = doc.config !== nothing ? doc.config.detection_thresholds : DetectionThresholds()
            detector = HybridSectionDetector(doc, base_form, thresholds)
            detected = detect_sections(detector)
        else
            extractor = form === nothing ? SectionExtractor() : SectionExtractor(form)
            detected = extract(extractor, doc)
        end
        doc._sections = detected
    end
    return doc._sections
end

# Parse a filing's HTML into a Document (root tree + metadata with original_html + config.form), so
# `sections(doc)` can run. `form` drives the detector dispatch.
function parse_filing(p::HTMLParser, html::AbstractString; form = nothing)
    root = parse_to_root(p, html)
    cfg = p.config
    form !== nothing && (cfg.form = form)
    meta = DocumentMetadata(form = form, original_html = html, preserve_whitespace = cfg.preserve_whitespace)
    return Document(root = root, metadata = meta, config = cfg)
end

# Document.text — TextExtractor over the root + nav-link filtering on the clean path (document.py).
function document_text(doc::Document; clean::Bool = true, include_tables::Bool = true,
                       include_metadata::Bool = false, max_length::Union{Nothing,Int} = nothing,
                       table_max_col_width::Union{Nothing,Int} = nothing)
    ex = TextExtractor(clean = clean, include_tables = include_tables, include_metadata = include_metadata,
                       max_length = max_length, table_max_col_width = table_max_col_width)
    text_ = extract(ex, doc)
    if clean
        try
            text_ = filter_with_cached_patterns(text_, doc.metadata.original_html)
        catch
            text_ = filter_toc_links(text_)
        end
    end
    return text_
end
