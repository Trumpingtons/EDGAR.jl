# Faithful Julia translation of edgartools' edgar/documents/ HTML-document parser.
# Built file-for-file against the Python package so the section/table/text output matches `obj()[item]`.
# The HTML→tree builder parses with EzXML.jl, which wraps libxml2 — the same engine edgartools' lxml uses.
module Documents

using EzXML
using OrderedCollections   # OrderedDict: preserve TOC discovery order (Python dict is insertion-ordered)

# ---- parser core: 🟢 jurisdiction-agnostic HTML -> Document tree / text / tables (reusable for any
#      HTML/XHTML filing — ESEF, EDINET, etc.; nothing here knows about SEC Items/Parts) ----
include("types.jl")            # NodeType / SemanticType / TableType / Style / HeaderInfo / XBRLFact / ParseContext
include("nodes.jl")            # Node hierarchy + text()/html()
include("style_parser.jl")     # CSS style="..." -> Style
include("table_nodes.jl")      # Cell / Row / TableNode (+ numeric helpers)
include("table_matrix.jl")     # colspan/rowspan -> 2D grid
include("fast_table.jl")       # FastTableRenderer (production default)
include("text_extractor.jl")   # TextExtractor (Section.text())
include("config.jl")           # ParserConfig defaults
include("ezxml_dom.jl")        # lxml HtmlElement accessors over EzXML
include("header_detection.jl") # multi-strategy header detection
include("table_processing.jl") # HTML <table> -> TableNode
include("document_builder.jl") # EzXML tree -> Document node tree
include("preprocessor.jl")     # raw HTML cleanup before parsing
include("postprocessor.jl")    # remove empty nodes / merge text / normalise headings
include("toc_filter.jl")       # strip repetitive navigation links (Document.text clean path)
include("streaming.jl")        # streaming parser for >10MB filings (no preprocessing, coarse tree)
include("parser.jl")           # HTMLParser entry point (preprocess -> parse -> build -> postprocess)

# ---- section detection: 🔵 SEC-specific (Item/Part patterns, US filing-agent TOC, cross-form structure;
#      no ESEF/EDINET analog) — layered on the 🟢 parser core above ----
include("document.jl")              # Section / Sections / Document / DocumentMetadata + sections dispatch
include("anchor_targets.jl")        # anchor id/name resolution
include("agents.jl")                # filing-agent detection
include("toc_analyzer.jl")          # TOCAnalyzer (TOC -> section->anchor map) + find_toc_boundaries
include("toc_section_extractor.jl") # SECSectionExtractor (section text between anchors)
include("toc_section_detector.jl")  # TOCSectionDetector (TOC strategy)
include("pattern_section_extractor.jl") # SectionExtractor (pattern/regex fallback)
include("hybrid_section_detector.jl")   # HybridSectionDetector (TOC -> heading -> pattern)

end # module Documents
