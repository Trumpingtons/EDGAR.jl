# =====================================================================================================
# DocParser — an isolated, faithful port of edgartools' new HTML document parser (edgar/documents/*).
# Built in its own module so it cannot affect the working `sections()` until it is validated end-to-end.
#
# Phase 0 (this file): the node model + CSS style parsing + a Gumbo-based document builder + table
# rendering + multi-strategy header detection (Style / Pattern / Structural / Contextual + combiner).
# Later phases add the section detectors (pattern / TOC / hybrid) on top of this node tree.
# =====================================================================================================
module DocParser

using Gumbo

# --- Style (types.py Style) ----------------------------------------------------------------------------

Base.@kwdef struct Style
    font_size::Union{Float64,Nothing} = nothing       # in pt
    font_weight::Union{String,Nothing} = nothing
    text_align::Union{String,Nothing} = nothing
    margin_top::Union{Float64,Nothing} = nothing
    margin_bottom::Union{Float64,Nothing} = nothing
    raw::String = ""
end

is_bold(s::Style) = s.font_weight !== nothing &&
    (s.font_weight in ("bold", "bolder") ||
     (something(tryparse(Int, s.font_weight), 0) >= 600))
is_centered(s::Style) = s.text_align == "center"

_len_pt(v, unit) = unit == "px" ? v * 0.75 : unit == "pt" ? v : v * 10.0   # em/rem ~ 10pt base

# Parse a CSS `style="..."` string into a Style (font-size→pt, weight, align, margins).
function parse_style(css::AbstractString, base::Style = Style())
    isempty(css) && return base
    fs = base.font_size; fw = base.font_weight; ta = base.text_align
    mt = base.margin_top; mb = base.margin_bottom
    for decl in split(css, ';')
        kv = split(decl, ':', limit = 2)
        length(kv) == 2 || continue
        prop = strip(lowercase(kv[1])); val = strip(lowercase(kv[2]))
        if prop == "font-size"
            m = match(r"([\d.]+)\s*(pt|px|em|rem)", val)
            m !== nothing && (fs = _len_pt(parse(Float64, m.captures[1]), m.captures[2]))
        elseif prop == "font-weight"
            fw = val
        elseif prop == "text-align"
            ta = val
        elseif prop == "margin-top"
            m = match(r"([\d.]+)", val); m !== nothing && (mt = parse(Float64, m.captures[1]))
        elseif prop == "margin-bottom"
            m = match(r"([\d.]+)", val); m !== nothing && (mb = parse(Float64, m.captures[1]))
        elseif prop == "font" && occursin("bold", val)
            fw = "bold"
        end
    end
    return Style(font_size = fs, font_weight = fw, text_align = ta, margin_top = mt, margin_bottom = mb, raw = css)
end

# --- Node model (nodes.py) -----------------------------------------------------------------------------

@enum NodeType DOCUMENT SECTION HEADING PARAGRAPH TABLE LISTNODE LISTITEM TEXTNODE CONTAINER

mutable struct Node
    type::NodeType
    tag::Symbol                       # original HTML tag (or :text / :document)
    text_content::String              # for TEXT nodes
    children::Vector{Node}
    parent::Union{Node,Nothing}
    style::Style
    level::Int                        # heading level (0 if n/a)
    align::String                     # element `align=` attribute
    rows::Vector{Vector{String}}      # for TABLE nodes
    bold::Bool                        # for TEXT nodes: is this run bold
end
Node(type, tag; text="", style=Style(), level=0, align="", bold=false) =
    Node(type, tag, text, Node[], nothing, style, level, align, Vector{String}[], bold)

addchild!(p::Node, c::Node) = (c.parent = p; push!(p.children, c); c)

# Collect all nodes (DFS, document order) matching a predicate.
function findall_nodes(node::Node, pred)
    out = Node[]
    pred(node) && push!(out, node)
    for c in node.children
        append!(out, findall_nodes(c, pred))
    end
    return out
end

# Sibling / parent navigation (lxml getnext/getprevious/getparent equivalents).
function _siblings_index(n::Node)
    n.parent === nothing && return (nothing, 0)
    sibs = n.parent.children
    return (sibs, findfirst(x -> x === n, sibs))
end
function nextsibling(n::Node)
    sibs, i = _siblings_index(n)
    (sibs === nothing || i === nothing || i == length(sibs)) ? nothing : sibs[i + 1]
end
function prevsibling(n::Node)
    sibs, i = _siblings_index(n)
    (sibs === nothing || i === nothing || i == 1) ? nothing : sibs[i - 1]
end

# --- Text extraction (Node.text) -----------------------------------------------------------------------

const _ABBREV = Set(["mr", "mrs", "ms", "dr", "inc", "ltd", "co", "corp", "no", "vs", "etc", "jr", "sr",
                     "st", "u.s", "u.k"])
_is_abbrev_ending(s) = (m = match(r"(\w+)\.\s*$", s); m !== nothing && lowercase(m.captures[1]) in _ABBREV)

# Render a table the way edgartools does: non-empty cells joined by " | ", rows by newline (SEC tables are
# riddled with empty spacer cells for alignment, which edgartools' renderer collapses).
_render_rows(rows) = join((join(filter(!isempty, r), " | ") for r in rows if any(!isempty, r)), "\n")

function nodetext(n::Node)::String
    n.type == TEXTNODE && return n.text_content
    n.type == TABLE && return _render_rows(n.rows)
    # Block/inline container: strip each child's text, join inline runs with a space and block children on
    # their own line (a robust approximation of ParagraphNode.text — no empty-string indexing).
    io = IOBuffer(); started = false; prevblock = false
    for c in n.children
        s = strip(nodetext(c))
        isempty(s) && continue
        blk = c.type in (PARAGRAPH, HEADING, TABLE, LISTNODE, LISTITEM, SECTION, CONTAINER)
        if !started
            print(io, s); started = true
        elseif blk || prevblock
            print(io, '\n', s)
        else
            print(io, ' ', s)
        end
        prevblock = blk
    end
    return String(take!(io))
end

# --- Document builder (Gumbo DOM -> Node tree; replaces strategies/document_builder.py) ----------------

const _SKIP_TAGS = Set([:script, :style, :head, :title, :noscript, :meta, :link])
const _BLOCK_TAGS = Set([:p, :div, :li, :h1, :h2, :h3, :h4, :h5, :h6, :section, :article, :blockquote,
                         :dt, :dd, :figure, :center, :caption, :ul, :ol, :header, :footer, :main, :aside])
const _INLINE_BOLD = Set([:b, :strong])
_heading_level(tag) = tag in (:h1, :h2, :h3, :h4, :h5, :h6) ? parse(Int, string(tag)[2]) : 0

# Render a <table> element into rows of cell texts (one Node of type TABLE).
function _build_table(el)
    rows = Vector{String}[]
    _collect_rows!(rows, el)
    node = Node(TABLE, :table)
    node.rows = rows
    return node
end
function _collect_rows!(rows, el)
    for c in el.children
        c isa HTMLElement || continue
        t = Gumbo.tag(c)
        if t === :tr
            cells = String[]
            _collect_cells!(cells, c)
            push!(rows, cells)
        else
            _collect_rows!(rows, c)
        end
    end
end
function _collect_cells!(cells, tr)
    for c in tr.children
        c isa HTMLElement || continue
        t = Gumbo.tag(c)
        if t in (:td, :th)
            push!(cells, _norm(_eltext(c)))
        elseif !(t in (:tr, :table))
            _collect_cells!(cells, c)
        end
    end
end

_norm(s) = strip(replace(s, r"[\s ]+" => " "))
function _eltext!(io, node)
    if node isa HTMLText
        print(io, node.text, " ")
    elseif node isa HTMLElement && !(Gumbo.tag(node) in _SKIP_TAGS)
        for c in node.children
            _eltext!(io, c)
        end
    end
end
function _eltext(node)
    io = IOBuffer()
    _eltext!(io, node)
    return String(take!(io))
end

# Walk the Gumbo tree, building a Node tree. `block` is the current enclosing block Node that inline text
# attaches to. Block-level elements create child block Nodes; inline elements merge text upward.
function _build!(block::Node, gnode, inh::Style)
    if gnode isa HTMLText
        s = gnode.text
        isempty(strip(s)) || addchild!(block, Node(TEXTNODE, :text; text = s, style = inh, bold = is_bold(inh)))
        return
    end
    gnode isa HTMLElement || return
    tag = Gumbo.tag(gnode)
    tag in _SKIP_TAGS && return
    if tag === :br
        addchild!(block, Node(TEXTNODE, :text; text = " ", style = inh))
        return
    end
    st = parse_style(get(gnode.attributes, "style", ""), inh)
    st = (tag in _INLINE_BOLD) ? Style(font_size = st.font_size, font_weight = "bold",
              text_align = st.text_align, margin_top = st.margin_top, margin_bottom = st.margin_bottom,
              raw = st.raw) : st
    if tag === :table
        tnode = _build_table(gnode); tnode.style = st
        addchild!(block, tnode)
        return
    end
    if tag in _BLOCK_TAGS
        lvl = _heading_level(tag)
        bnode = Node(PARAGRAPH, tag; style = st, level = lvl,
                     align = lowercase(get(gnode.attributes, "align", "")))
        addchild!(block, bnode)
        for c in gnode.children
            _build!(bnode, c, st)
        end
        # Classify only after children exist: a wrapper holding block children is a CONTAINER; an element
        # with only inline content is a PARAGRAPH candidate (so a styled <div>Item 1A</div> stays a candidate).
        bnode.type = lvl > 0 ? HEADING :
                     tag in (:ul, :ol) ? LISTNODE :
                     tag === :li ? LISTITEM :
                     any(c -> c.type in (PARAGRAPH, HEADING, TABLE, LISTNODE, CONTAINER, SECTION, LISTITEM),
                         bnode.children) ? CONTAINER : PARAGRAPH
        return
    end
    # inline element (span/a/i/em/font/...): attach its content to the current block
    for c in gnode.children
        _build!(block, c, st)
    end
end

function build(html::AbstractString)
    doc = Node(DOCUMENT, :document)
    _build!(doc, parsehtml(String(html)).root, Style())
    return doc
end

# --- Header detection (strategies/header_detection.py) -------------------------------------------------

const _HEADER_THRESHOLD = 0.6
const _BASE_FONT = 10.0

struct HeaderInfo
    level::Int
    confidence::Float64
    text::String
    detection_method::String
    is_item::Bool
    item_number::Union{String,Nothing}
end
function header_from_text(text, level, confidence, method)
    m = match(r"^(?:Item|ITEM)\s+(\d+[A-Z]?\.?)"i, strip(text))
    return HeaderInfo(level, confidence, text, method,
                      m !== nothing, m !== nothing ? rstrip(m.captures[1], '.') : nothing)
end

# Block nodes are the candidates the detectors run on.
_isblockcand(n::Node) = n.type in (HEADING, PARAGRAPH, LISTITEM)

# Style-based detector.
function detect_style(n::Node)
    s = n.style; text = strip(nodetext(n))
    (isempty(text) || length(text) > 200) && return nothing
    conf = 0.0; level = 3
    if s.font_size !== nothing
        r = s.font_size / _BASE_FONT
        if r >= 2.0; conf += 0.8; level = 1
        elseif r >= 1.5; conf += 0.7; level = 2
        elseif r >= 1.2; conf += 0.5; level = 3
        elseif r >= 1.1; conf += 0.3; level = 4
        end
    end
    is_bold(s) && (conf += 0.3; level == 3 && (level = 2))
    is_centered(s) && (conf += 0.2)
    (text == uppercase(text) && length(split(text)) <= 10) && (conf += 0.2)
    (s.margin_top !== nothing && s.margin_top > 20) && (conf += 0.1)
    (s.margin_bottom !== nothing && s.margin_bottom > 10) && (conf += 0.1)
    conf = min(conf, 1.0)
    return conf > 0.4 ? header_from_text(text, level, conf, "style") : nothing
end

const _PATTERNS = [
    (r"^(Item|ITEM)\s+(\d+[A-Z]?)[.\s]+(.+)$"i, 1, 0.95),
    (r"^Part\s+[IVX]+[.\s]*$"i, 1, 0.9),
    (r"^(BUSINESS|RISK FACTORS|PROPERTIES|LEGAL PROCEEDINGS)$"i, 2, 0.85),
    (r"^(Management'?s?\s+Discussion|MD&A)"i, 2, 0.85),
    (r"^(Financial\s+Statements|Consolidated\s+Financial\s+Statements)$"i, 2, 0.85),
    (r"^\d+\.\s+[A-Z][A-Za-z\s]+$", 3, 0.7),
    (r"^[A-Z]\.\s+[A-Z][A-Za-z\s]+$", 3, 0.7),
    (r"^\([a-z]\)\s+[A-Z][A-Za-z\s]+$", 4, 0.6),
    (r"^[A-Z][A-Za-z\s]+[A-Za-z]$", 3, 0.5),
    (r"^[A-Z\s]+$", 3, 0.6),
]
function detect_pattern(n::Node)
    text = strip(nodetext(n))
    (isempty(text) || length(text) > 200) && return nothing
    (length(text) == 1 && first(text) in '.':'.') && return nothing
    count(==('.'), text) > 2 && return nothing
    for (pat, level, base) in _PATTERNS
        if match(pat, text) !== nothing
            conf = base
            p = n.parent
            (p !== nothing && length(p.children) == 1) && (conf += 0.1)
            nx = nextsibling(n)
            (nx !== nothing && length(nodetext(nx)) > 100) && (conf += 0.1)
            return header_from_text(text, level, min(conf, 1.0), "pattern")
        end
    end
    return nothing
end

function detect_structural(n::Node)
    text = strip(nodetext(n))
    (isempty(text) || length(text) > 200) && return nothing
    conf = 0.0; level = 3
    if n.level > 0                                     # h1-h6
        return header_from_text(text, n.level, 1.0, "structural")
    end
    p = n.parent
    if p !== nothing
        p.tag in (:header, :thead, :caption) && (conf += 0.6; level = 2)
        length(p.children) <= 3 && (conf += 0.3)
        p.align == "center" && (conf += 0.2)
    end
    n.tag in (:strong, :b) && (conf += 0.3)
    n.align == "center" && (conf += 0.2)
    nx = nextsibling(n)
    (nx !== nothing && nx.tag in (:p, :div, :table, :ul, :ol)) && (conf += 0.2)
    (1 <= length(split(text)) <= 10) && (conf += 0.1)
    conf = min(conf, 1.0)
    return conf > 0.5 ? header_from_text(text, level, conf, "structural") : nothing
end

function _looks_like_header(text)
    length(split(text)) > 15 && return false
    endswith(rstrip(text), ('.', '!', '?', ';')) && return false
    (_istitle(text) || text == uppercase(text)) && return true
    return !isempty(text) && isuppercase(first(text))
end
# Python str.istitle for a phrase.
function _istitle(s)
    seen = false; prev_cased = false
    for c in s
        if isuppercase(c)
            prev_cased && return false; prev_cased = true; seen = true
        elseif islowercase(c)
            prev_cased || return false; prev_cased = true; seen = true
        else
            prev_cased = false
        end
    end
    return seen
end

function detect_contextual(n::Node)
    text = strip(nodetext(n))
    (isempty(text) || length(text) > 200) && return nothing
    conf = 0.0; level = 3
    _looks_like_header(text) && (conf += 0.4)
    pv = prevsibling(n)
    if pv !== nothing
        pt = strip(nodetext(pv))
        (!isempty(pt) && _looks_like_header(pt)) && (conf += 0.3; level = length(text) > length(pt) ? 2 : 3)
    end
    nx = nextsibling(n)
    if nx !== nothing
        ntxt = strip(nodetext(nx))
        length(ntxt) > length(text) * 3 && (conf += 0.3)
        occursin("margin-left", nx.style.raw) || occursin("padding-left", nx.style.raw) ? (conf += 0.2) : nothing
    end
    conf = min(conf, 1.0)
    return conf > 0.5 ? header_from_text(text, level, conf, "contextual") : nothing
end

const _DETECTOR_WEIGHTS = Dict("style" => 0.3, "pattern" => 0.4, "structural" => 0.2, "contextual" => 0.1)

# Combine the four detectors (weighted voting), exactly as HeaderDetectionStrategy.detect.
function detect_header(n::Node)
    text = strip(nodetext(n))
    isempty(text) && return nothing
    results = HeaderInfo[]
    for d in (detect_style, detect_pattern, detect_structural, detect_contextual)
        r = try d(n) catch; nothing end
        r !== nothing && push!(results, r)
    end
    isempty(results) && return nothing
    if length(results) == 1
        return results[1].confidence >= _HEADER_THRESHOLD ? results[1] : nothing
    end
    total_conf = 0.0; total_w = 0.0; level_votes = Dict{Int,Float64}()
    for r in results
        w = get(_DETECTOR_WEIGHTS, r.detection_method, 0.1)
        total_conf += r.confidence * w; total_w += w
        level_votes[r.level] = get(level_votes, r.level, 0.0) + r.confidence * w
    end
    final_conf = total_w > 0 ? total_conf / total_w : 0.0
    final_level = argmax(level_votes)
    is_item = any(r -> r.is_item, results)
    item_number = nothing
    for r in results; r.item_number !== nothing && (item_number = r.item_number; break); end
    return HeaderInfo(final_level, final_conf, text, "combined", is_item, item_number)
end

# --- FormSpec registry (declarative per-form structure; translated from edgartools SECTION_PATTERNS) ----
# The generic engine below reads a FormSpec; nothing form-specific lives in the engine. `item_titles` gives
# friendly names to generically-detected `Item N` headers; `named_patterns` detect *title-only* headers
# (no "Item N") and map them to a key; `part_qualified` turns on 10-Q-style Part keying; `size_bands` flag
# anomalous section sizes. Adding a form (or a jurisdiction's forms) = adding a FormSpec — never engine code.

struct FormSpec
    item_titles::Dict{String,String}                       # item number => friendly title
    named_patterns::Vector{Tuple{Regex,String,String}}     # (title-only regex, key, title)
    part_qualified::Bool
    size_bands::Dict{String,Tuple{Int,Int}}
end
FormSpec(; item_titles = Dict{String,String}(), named_patterns = Tuple{Regex,String,String}[],
         part_qualified = false, size_bands = Dict{String,Tuple{Int,Int}}()) =
    FormSpec(item_titles, named_patterns, part_qualified, size_bands)

const _10K_TITLES = Dict(
    "1" => "Business", "1A" => "Risk Factors", "1B" => "Unresolved Staff Comments", "1C" => "Cybersecurity",
    "2" => "Properties", "3" => "Legal Proceedings", "4" => "Mine Safety Disclosures",
    "5" => "Market for Registrant's Common Equity", "6" => "Selected Financial Data",
    "7" => "Management's Discussion and Analysis", "7A" => "Quantitative and Qualitative Disclosures About Market Risk",
    "8" => "Financial Statements and Supplementary Data", "9" => "Changes in and Disagreements with Accountants",
    "9A" => "Controls and Procedures", "9B" => "Other Information", "9C" => "Disclosure Regarding Foreign Jurisdictions",
    "10" => "Directors, Executive Officers and Corporate Governance", "11" => "Executive Compensation",
    "12" => "Security Ownership of Certain Beneficial Owners", "13" => "Certain Relationships and Related Transactions",
    "14" => "Principal Accountant Fees and Services", "15" => "Exhibits and Financial Statement Schedules",
    "16" => "Form 10-K Summary")

const _REGISTRY = Dict{String,FormSpec}(
    "10-K" => FormSpec(item_titles = _10K_TITLES,
        named_patterns = [
            (r"^Business\s*$"i, "1", "Business"), (r"^Business Overview"i, "1", "Business"),
            (r"^Our Business"i, "1", "Business"), (r"^Company Overview"i, "1", "Business"),
            (r"^Risk\s+Factors"i, "1A", "Risk Factors"), (r"^Factors\s+That\s+May\s+Affect"i, "1A", "Risk Factors"),
            (r"^Unresolved\s+Staff\s+Comments"i, "1B", "Unresolved Staff Comments"),
            (r"^Cybersecurity"i, "1C", "Cybersecurity"),
            (r"^Properties"i, "2", "Properties"), (r"^Real\s+Estate"i, "2", "Properties"),
            (r"^Legal\s+Proceedings"i, "3", "Legal Proceedings"), (r"^Litigation"i, "3", "Legal Proceedings"),
            (r"^Quantitative.*Qualitative.*Market\s+Risk"i, "7A", "Market Risk"), (r"^Market\s+Risk"i, "7A", "Market Risk"),
            (r"^Management.*Discussion.*Analysis"i, "7", "MD&A"), (r"^MD&A"i, "7", "MD&A"),
            (r"^Consolidated\s+Financial\s+Statements"i, "8", "Financial Statements"),
            (r"^Financial\s+Statements"i, "8", "Financial Statements"),
            (r"^Controls.*Procedures"i, "9A", "Controls and Procedures"), (r"^Internal\s+Control"i, "9A", "Controls and Procedures"),
        ],
        size_bands = Dict("1" => (8034, 321384), "1A" => (15978, 639136), "1C" => (1542, 61680),
                          "7" => (11440, 457616), "8" => (26136, 1045472), "9A" => (791, 31640), "16" => (410, 16400))),
    "10-Q" => FormSpec(item_titles = Dict("1" => "Financial Statements", "2" => "Management's Discussion and Analysis",
            "3" => "Quantitative and Qualitative Disclosures About Market Risk", "4" => "Controls and Procedures",
            "1A" => "Risk Factors", "5" => "Other Information", "6" => "Exhibits"),
        named_patterns = [
            (r"^Financial\s+Statements"i, "1", "Financial Statements"),
            (r"^Management.*Discussion.*Analysis"i, "2", "MD&A"), (r"^Market\s+Risk"i, "3", "Market Risk"),
            (r"^Controls.*Procedures"i, "4", "Controls and Procedures"),
            (r"^Legal\s+Proceedings"i, "1", "Legal Proceedings"), (r"^Risk\s+Factors"i, "1A", "Risk Factors"),
            (r"^Unregistered\s+Sales"i, "2", "Unregistered Sales"), (r"^Other\s+Information"i, "5", "Other Information"),
            (r"^Mine\s+Safety"i, "4", "Mine Safety"), (r"^Exhibits"i, "6", "Exhibits"),
        ],
        part_qualified = true,
        size_bands = Dict("1" => (18009, 720376), "2" => (10134, 405368), "6" => (518, 20720))),
    "20-F" => FormSpec(item_titles = Dict("1" => "Identity of Directors", "2" => "Offer Statistics",
            "3" => "Key Information", "4" => "Information on the Company", "4A" => "Unresolved Staff Comments",
            "5" => "Operating and Financial Review", "6" => "Directors, Senior Management and Employees",
            "7" => "Major Shareholders and Related Party Transactions", "8" => "Financial Information",
            "9" => "The Offer and Listing", "10" => "Additional Information",
            "11" => "Quantitative and Qualitative Disclosures About Market Risk", "12" => "Description of Securities",
            "13" => "Defaults", "14" => "Material Modifications", "15" => "Controls and Procedures", "16" => "Reserved",
            "16A" => "Audit Committee Financial Expert", "16B" => "Code of Ethics", "16C" => "Principal Accountant Fees",
            "16D" => "Audit Committee Exemptions", "16E" => "Purchases of Equity Securities", "16F" => "Accountant Change",
            "16G" => "Corporate Governance", "16H" => "Mine Safety", "16I" => "Foreign Jurisdiction Disclosure",
            "16J" => "Insider Trading Policies", "16K" => "Cybersecurity", "17" => "Financial Statements",
            "18" => "Financial Statements", "19" => "Exhibits"),
        named_patterns = [
            (r"^Key\s+Information"i, "3", "Key Information"), (r"^Risk\s+Factors"i, "3", "Risk Factors"),
            (r"^Information\s+on\s+the\s+Company"i, "4", "Information on the Company"),
            (r"^Operating.*Financial\s+Review"i, "5", "Operating and Financial Review"),
            (r"^Quantitative.*Qualitative.*Market\s+Risk"i, "11", "Market Risk"),
            (r"^Additional\s+Information"i, "10", "Additional Information"), (r"^Corporate\s+Governance"i, "16G", "Corporate Governance"),
            (r"^Code\s+of\s+Ethics"i, "16B", "Code of Ethics"), (r"^Cybersecurity"i, "16K", "Cybersecurity"),
        ]),
    "8-K" => FormSpec(item_titles = Dict(
            "1.01" => "Entry into Material Agreement", "1.02" => "Termination of Material Agreement",
            "1.03" => "Bankruptcy or Receivership", "1.05" => "Material Cybersecurity Incidents",
            "2.01" => "Completion of Acquisition", "2.02" => "Results of Operations", "2.03" => "Direct Financial Obligation",
            "2.05" => "Costs Associated with Exit", "2.06" => "Material Impairments", "3.01" => "Notice of Delisting",
            "3.02" => "Unregistered Sales of Equity", "3.03" => "Material Modification to Rights",
            "4.01" => "Changes in Certifying Accountant", "4.02" => "Non-Reliance on Financial Statements",
            "5.01" => "Changes in Control", "5.02" => "Departure/Election of Directors", "5.03" => "Amendments to Articles/Bylaws",
            "5.07" => "Submission of Matters to a Vote", "7.01" => "Regulation FD Disclosure", "8.01" => "Other Events",
            "9.01" => "Financial Statements and Exhibits"),
        named_patterns = [
            (r"^Results.*Operations"i, "2.02", "Results of Operations"),
            (r"^Departure.*Directors.*Officers"i, "5.02", "Director/Officer Changes"),
            (r"^Regulation\s+FD"i, "7.01", "Regulation FD"), (r"^Other\s+Events"i, "8.01", "Other Events"),
            (r"^Financial.*Exhibits"i, "9.01", "Financial Statements and Exhibits"),
        ]),
    "424B" => FormSpec(named_patterns = [
            (r"^About\s+This\s+Prospectus"i, "about_this_prospectus", "About This Prospectus"),
            (r"^(?:The\s+)?Offering\s*$"i, "summary", "The Offering"), (r"^Prospectus\s+Summary"i, "summary", "Prospectus Summary"),
            (r"^Summary\s*$"i, "summary", "Summary"), (r"^Risk\s+Factors\s*$"i, "risk_factors", "Risk Factors"),
            (r"^Use\s+of\s+Proceeds"i, "use_of_proceeds", "Use of Proceeds"), (r"^Dilution\s*$"i, "dilution", "Dilution"),
            (r"^Capitalization\s*$"i, "capitalization", "Capitalization"),
            (r"^Description\s+of\s+(?:Capital\s+)?Stock"i, "description_of_securities", "Description of Capital Stock"),
            (r"^Description\s+of\s+(?:the\s+)?Securities"i, "description_of_securities", "Description of Securities"),
            (r"^Description\s+of\s+(?:the\s+)?Notes"i, "description_of_securities", "Description of Notes"),
            (r"^Description\s+of\s+Debt\s+Securities"i, "description_of_debt", "Description of Debt Securities"),
            (r"^Description\s+of\s+Warrants"i, "description_of_warrants", "Description of Warrants"),
            (r"^Selling\s+(?:Stock|Security)\s*holders"i, "selling_stockholders", "Selling Stockholders"),
            (r"^Underwriting\s*$"i, "underwriting", "Underwriting"),
            (r"^Plan\s+of\s+Distribution"i, "plan_of_distribution", "Plan of Distribution"),
            (r"^Legal\s+Matters\s*$"i, "legal_matters", "Legal Matters"), (r"^Experts\s*$"i, "experts", "Experts"),
            (r"^(?:U\.?S\.?\s+)?(?:Federal\s+)?(?:Income\s+)?Tax\s+Considerations"i, "tax", "Tax Considerations"),
            (r"^Where\s+You\s+Can\s+Find\s+More\s+Information"i, "where_more_info", "Where You Can Find More Information"),
            (r"^Incorporation\s+(?:of\s+Certain\s+(?:Information|Documents)\s+)?by\s+Reference"i, "incorporation_by_reference", "Incorporation by Reference"),
        ]),
)

function _form_spec(form::AbstractString)
    f = uppercase(strip(form))
    startswith(f, "424B") && return get(_REGISTRY, "424B", nothing)
    f = replace(f, r"/A$" => "")
    return get(_REGISTRY, f, nothing)
end

"""
    register_form!(form, spec::FormSpec)

Register (or override) a filing form's structure. This is the extension point for new SEC forms and, later,
other jurisdictions' forms — the engine never changes, only the registry.
"""
register_form!(form::AbstractString, spec::FormSpec) = (_REGISTRY[uppercase(strip(form))] = spec)

# --- Step 2: forms edgartools does NOT segment (S-1 / S-4 / N-CSR) -------------------------------------
# Shared prospectus (Part I) sections, reused across registration-statement forms.
const _PROSPECTUS_PATTERNS = Tuple{Regex,String,String}[
    (r"^Prospectus\s+Summary"i, "summary", "Prospectus Summary"), (r"^Summary\s*$"i, "summary", "Summary"),
    (r"^(?:The\s+)?Offering\s*$"i, "the_offering", "The Offering"),
    (r"^Risk\s+Factors"i, "risk_factors", "Risk Factors"),
    (r"^(?:Special\s+Note\s+Regarding\s+)?Forward[- ]Looking"i, "forward_looking", "Forward-Looking Statements"),
    (r"^Use\s+of\s+Proceeds"i, "use_of_proceeds", "Use of Proceeds"),
    (r"^Dividend\s+Policy"i, "dividend_policy", "Dividend Policy"),
    (r"^Capitalization\s*$"i, "capitalization", "Capitalization"), (r"^Dilution\s*$"i, "dilution", "Dilution"),
    (r"^Selected\s+(?:Consolidated\s+)?Financial\s+Data"i, "selected_financial", "Selected Financial Data"),
    (r"^Management.?s\s+Discussion"i, "mda", "MD&A"),
    (r"^Business\s*$"i, "business", "Business"), (r"^Management\s*$"i, "management", "Management"),
    (r"^Executive\s+Compensation"i, "executive_compensation", "Executive Compensation"),
    (r"^Certain\s+Relationships"i, "related_transactions", "Certain Relationships and Related Transactions"),
    (r"^Principal\s+(?:and\s+Selling\s+)?(?:Stock|Security)holders"i, "principal_stockholders", "Principal Stockholders"),
    (r"^Description\s+of\s+(?:Capital\s+)?Stock"i, "description_capital_stock", "Description of Capital Stock"),
    (r"^Description\s+of\s+(?:the\s+)?Securities"i, "description_securities", "Description of Securities"),
    (r"^Shares\s+Eligible\s+for\s+Future\s+Sale"i, "shares_eligible", "Shares Eligible for Future Sale"),
    (r"^Underwriting\s*$"i, "underwriting", "Underwriting"),
    (r"^Plan\s+of\s+Distribution"i, "plan_of_distribution", "Plan of Distribution"),
    (r"^(?:Material\s+)?(?:U\.?S\.?\s+)?(?:Federal\s+)?(?:Income\s+)?Tax\s+(?:Considerations|Consequences)"i, "tax", "Tax Considerations"),
    (r"^Legal\s+Matters\s*$"i, "legal_matters", "Legal Matters"), (r"^Experts\s*$"i, "experts", "Experts"),
    (r"^Where\s+You\s+Can\s+Find"i, "where_more_info", "Where You Can Find More Information"),
]

register_form!("S-1", FormSpec(
    item_titles = Dict("13" => "Other Expenses of Issuance and Distribution",
        "14" => "Indemnification of Directors and Officers", "15" => "Recent Sales of Unregistered Securities",
        "16" => "Exhibits and Financial Statement Schedules", "17" => "Undertakings"),
    named_patterns = _PROSPECTUS_PATTERNS))

register_form!("S-4", FormSpec(
    item_titles = Dict("20" => "Indemnification of Directors and Officers",
        "21" => "Exhibits and Financial Statement Schedules", "22" => "Undertakings"),
    named_patterns = vcat(Tuple{Regex,String,String}[
        (r"^The\s+Merger\b"i, "the_merger", "The Merger"), (r"^The\s+Companies\b"i, "the_companies", "The Companies"),
        (r"^The\s+Special\s+Meeting"i, "special_meeting", "The Special Meeting"),
        (r"^Comparative\s+(?:Per\s+Share|Stock|Market)"i, "comparative", "Comparative Data"),
    ], _PROSPECTUS_PATTERNS)))

register_form!("N-CSR", FormSpec(item_titles = Dict(
    "1" => "Reports to Stockholders", "2" => "Code of Ethics", "3" => "Audit Committee Financial Expert",
    "4" => "Principal Accountant Fees and Services", "5" => "Audit Committee of Listed Registrants",
    "6" => "Investments", "7" => "Financial Statements and Financial Highlights",
    "8" => "Changes in and Disagreements with Accountants", "9" => "Proxy Disclosures",
    "10" => "Remuneration Paid to Directors and Officers",
    "11" => "Statement Regarding Basis for Approval of Investment Advisory Contract",
    "12" => "Disclosure of Proxy Voting Policies", "13" => "Portfolio Managers",
    "14" => "Purchases of Equity Securities", "15" => "Submission of Matters to a Vote",
    "16" => "Controls and Procedures",
    "17" => "Disclosure Regarding Recovery of Erroneously Awarded Compensation",
    "18" => "Recovery of Erroneously Awarded Compensation", "19" => "Exhibits")))

# 40-F — a Canadian issuer's annual report. The substance is the wrapped AIF (Annual Information Form):
# NI 51-102 disclosure sections, which edgartools parses from the AIF *exhibit* (EX-99.x), not the cover.
# Patterns copied faithfully from edgartools' company_reports/forty_f.py `_SECTION_PATTERNS`. NOTE: these
# headings live in the AIF exhibit — segmenting them requires fetching that exhibit (a fetch-layer change),
# since `fetch_filing` returns the primary cover document.
register_form!("40-F", FormSpec(named_patterns = Tuple{Regex,String,String}[
    (r"^Corporate\s+Structure"i, "corporate_structure", "Corporate Structure"),
    (r"^General\s+Development\s+of\s+(?:the\s+)?(?:[\w\-][\w\-'’]*\s+)?Business"i, "general_development", "General Development of the Business"),
    (r"^(?:Narrative\s+)?Description\s+of\s+(?:the\s+)?(?:\w[\w'’]*\s+)?Business(?:es)?"i, "description_business", "Description of the Business"),
    (r"^Business\s+of\s+(?:the\s+)?\w"i, "business_of", "Business of the Company"),
    (r"^Business\s+Operations"i, "business_operations", "Business Operations"),
    (r"^Description\s+of\s+Capital\s+Structure"i, "capital_structure", "Description of Capital Structure"),
    (r"^Market\s+for\s+Securities"i, "market_for_securities", "Market for Securities"),
    (r"^Dividends(?:\s+and\s+Distributions)?"i, "dividends", "Dividends"),
    (r"^Directors\s+and\s+(?:Executive\s+Officers|Officers|Executive)"i, "directors_officers", "Directors and Officers"),
    (r"^Risk\s+Factors"i, "risk_factors", "Risk Factors"),
    (r"^Legal\s+(?:Proceedings|Matters)"i, "legal_proceedings", "Legal Proceedings"),
    (r"^Material\s+Properties"i, "material_properties", "Material Properties"),
    (r"^Code\s+of\s+Business\s+Conduct"i, "code_of_conduct", "Code of Business Conduct"),
    (r"^Business\s+Overview"i, "business_overview", "Business Overview"),
]))

# --- Phase 1: pattern section extractor (extractors/pattern_section_extractor.py) ----------------------

const _ITEM_AT_START = r"^\s*(?:Item|ITEM)\s+(\d{1,2}\.\d{2}|\d{1,2}[A-Za-z]?)\b"   # 8-K decimal form first
const _PART_AT_START = r"^\s*PART\s+([IVXLC]+)\b"i
_is_main_header(t) = occursin(r"^\s*ITEM\s", t)                 # uppercase ITEM => main header, not a cross-ref

# Dense leading run of item headers ≈ the table of contents (entries are tightly packed); return its span.
function _toc_run(idxs::Vector{Int})
    length(idxs) < 5 && return (0, 0)
    run_end = 1
    for k in 2:length(idxs)
        idxs[k] - idxs[k - 1] <= 6 || break
        run_end = k
    end
    return run_end >= 5 ? (idxs[1], idxs[run_end]) : (0, 0)
end

_band_conf(bands, key, len) = (b = get(bands, uppercase(key), nothing);
    (b === nothing || len <= 0) ? 0.7 : (b[1] <= len <= b[2] ? 0.7 : 0.5))

"""
    extract_sections(doc::Node; form="") -> Vector{@NamedTuple{item,part,title,text,confidence}}

Registry-driven section extractor. The generic `Item N` backbone gives full item coverage; the form's
[`FormSpec`](@ref) augments it with friendly titles, title-only header patterns (`named_patterns`),
`part_qualified` Part keying, and size bands. Collects candidates, drops the TOC run, selects one header per
section (uppercase *main* header over cross-reference, else most following content), and assembles each
section's text. Unregistered forms fall through to the generic Item-N backbone only.
"""
function extract_sections(doc::Node; form::AbstractString = "")
    spec = _form_spec(form)
    content = findall_nodes(doc, n -> n.type in (PARAGRAPH, HEADING, LISTITEM, TABLE))
    Cand = @NamedTuple{idx::Int, key::String, title::String, main::Bool}
    EMPTY = @NamedTuple{item::String, part::String, title::String, text::String, confidence::Float64}[]
    cands = Cand[]; partmark = Tuple{Int,String}[]; found_item_n = false
    for (i, n) in enumerate(content)
        n.type == TABLE && continue
        t = strip(nodetext(n)); isempty(t) && continue
        m = match(_ITEM_AT_START, t)
        if m !== nothing                                                # generic Item-N backbone
            item = uppercase(m.captures[1]); found_item_n = true
            ttl = (spec !== nothing && haskey(spec.item_titles, item)) ? spec.item_titles[item] : _section_title(t)
            push!(cands, (idx = i, key = item, title = ttl, main = _is_main_header(t)))
        elseif spec !== nothing && length(t) < 100                      # title-only header from the registry
            for (re, key, ttl) in spec.named_patterns
                match(re, t) !== nothing && (push!(cands, (idx = i, key = key, title = ttl, main = t == uppercase(t))); break)
            end
        end
        pm = match(_PART_AT_START, t)
        (pm !== nothing && length(t) < 60) && push!(partmark, (i, "Part " * uppercase(pm.captures[1])))
    end
    # Strategy 4: table-cell fallback — triggered by the absence of *Item-N* headers (named title matches
    # don't count), so table-layout 10-Ks/8-Ks still recover their items even if a stray title matched.
    if !found_item_n
        for (i, n) in enumerate(content)
            n.type == TABLE || continue
            for row in n.rows
                m = match(_ITEM_AT_START, strip(join(row, " ")))
                if m !== nothing
                    item = uppercase(m.captures[1])
                    ttl = (spec !== nothing && haskey(spec.item_titles, item)) ? spec.item_titles[item] : item
                    push!(cands, (idx = i, key = item, title = ttl, main = false)); break
                end
            end
        end
    end
    isempty(cands) && return EMPTY
    ts, te = _toc_run([c.idx for c in cands])                           # drop the TOC run
    cands = filter(c -> !(ts <= c.idx <= te), cands)
    isempty(cands) && return EMPTY
    hdr_pos = sort(unique(vcat([c.idx for c in cands], [p[1] for p in partmark])))
    nextpos(i) = (j = findfirst(>(i), hdr_pos); j === nothing ? length(content) + 1 : hdr_pos[j])
    part_at(i) = (p = ""; for (pi, pn) in partmark; pi <= i && (p = pn); end; p)
    usepart = spec !== nothing && spec.part_qualified                   # Part keying only when the form needs it
    order = Tuple{String,String}[]; best = Dict{Tuple{String,String},Any}()
    for c in cands
        endp = nextpos(c.idx); csize = endp - c.idx; gkey = (usepart ? part_at(c.idx) : "", c.key)
        cur = get(best, gkey, nothing)
        if cur === nothing
            push!(order, gkey); best[gkey] = (c = c, endp = endp, csize = csize)
        elseif (c.main && !cur.c.main) || (c.main == cur.c.main && csize > cur.csize)
            best[gkey] = (c = c, endp = endp, csize = csize)
        end
    end
    bands = spec !== nothing ? spec.size_bands : Dict{String,Tuple{Int,Int}}()
    out = EMPTY
    for gkey in order
        b = best[gkey]; i = b.c.idx; endp = min(b.endp - 1, length(content))
        text = join((nodetext(content[j]) for j in i:endp if !isempty(strip(nodetext(content[j])))), "\n\n")
        isempty(strip(text)) && continue
        label = occursin(r"^\d", b.c.key) ? "Item $(b.c.key)" : b.c.title
        push!(out, (item = label, part = part_at(b.c.idx), title = b.c.title,
                    text = text, confidence = _band_conf(bands, b.c.key, length(text))))
    end
    return out
end

_section_title(text) = (line = first(split(text, '\n'));
    String(first(strip(replace(line, r"^\s*item\s+(?:\d{1,2}\.\d{2}|\d{1,2}[A-Za-z]?)\s*[.\-—:]*\s*"i => "")), 100)))

end # module DocParser
