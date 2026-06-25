# Faithful translation of edgartools' edgar/documents/parser.py (HTMLParser) — the orchestration entry
# point. Preprocess -> parse with libxml2 (EzXML) -> build the node tree. (Streaming, XBRL pre-extraction,
# metadata sniffing and post-processing are edgartools side-features not needed for section/text parity;
# the core parse path is translated. The Document wrapper + section detection are added in document.jl.)

struct HTMLParser
    config::ParserConfig
end
HTMLParser() = HTMLParser(ParserConfig())

# parse — HTML string -> Document root node tree (DocumentNode). Mirrors HTMLParser.parse's core path.
function parse_to_root(p::HTMLParser, html::AbstractString)
    isempty(strip(html)) && return DocumentNode()
    # Large documents take the streaming path (no preprocessing), exactly as parser.py does before the
    # preprocess step.
    if ncodeunits(html) > p.config.streaming_threshold
        sp = StreamingParser(p.config)
        root = parse_stream(sp, html)
        postprocess!(DocumentPostprocessor(p.config), root)
        return root
    end
    pre = HTMLPreprocessor(p.config)
    html = preprocess(pre, html)
    html = remove_xml_declaration(html)
    doc = EzXML.parsehtml(html)
    tree = EzXML.root(doc)
    builder = DocumentBuilder(p.config)
    root = build(builder, tree)
    postprocess!(DocumentPostprocessor(p.config), root)   # remove empties, merge text, normalise headings
    return root
end

# Convenience: full-document plain text == edgartools Document.text() (default clean=True): TextExtractor
# over the root. (Document.text() also runs TOC/nav link filtering when clean — not yet translated.)
function document_text(p::HTMLParser, html::AbstractString)
    txt = extract(TextExtractor(clean = true), (root = parse_to_root(p, html),))
    # Document.text() clean path: anchor-cache nav filtering keyed off the ORIGINAL html, falling back to
    # the plain phrase filter (mirrors document.py's try/except).
    try
        return filter_with_cached_patterns(txt, html)
    catch
        return filter_toc_links(txt)
    end
end
