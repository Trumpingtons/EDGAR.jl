# =====================================================================================================
# DocTOC — faithful port of edgartools' TOC-anchored section detector, on EzXML (libxml2 + XPath, the same
# C library lxml wraps), running edgartools' verbatim XPath queries. Ports:
#   - edgar/documents/form_schema.py            (FormSchema + 10-K/10-Q vocab)
#   - edgar/documents/utils/anchor_targets.py   (find_anchor_targets)
#   - edgar/documents/utils/toc_analyzer.py      (_analyze_generic_toc + helpers; agent parsers deferred)
# Produces {section_key => anchor_id}; boundaries/extraction are layered on top (Phase 2d).
# =====================================================================================================
module DocTOC

using EzXML

# --- form_schema.py ------------------------------------------------------------------------------------

struct TextItemRule
    item::String
    keywords::Vector{String}
    exclusions::Vector{String}
end
function _rule_matches(r::TextItemRule, text_lower::AbstractString; use_exclusions::Bool = true)
    all(k -> occursin(k, text_lower), r.keywords) || return false
    (use_exclusions && any(e -> occursin(e, text_lower), r.exclusions)) && return false
    return true
end

struct FormSchema
    max_bare_item::Int
    text_rules::Vector{TextItemRule}
    skip_unmatched_text::Bool
    item_part_ranges::Vector{Tuple{Int,Int,String}}
    repeating_parts::Vector{String}
end
function match_text(s::FormSchema, text_lower::AbstractString; use_exclusions::Bool = true)
    for r in s.text_rules
        _rule_matches(r, text_lower; use_exclusions) && return r.item
    end
    return nothing
end
function part_for_item(s::FormSchema, item_name::AbstractString)
    isempty(s.item_part_ranges) && return nothing
    m = match(r"item\s*(\d+)"i, item_name); m === nothing && return nothing
    num = parse(Int, m.captures[1])
    for (lo, hi, roman) in s.item_part_ranges
        lo <= num <= hi && return "Part $roman"
    end
    return nothing
end
seed_part(s::FormSchema) = isempty(s.repeating_parts) ? nothing : "Part $(s.repeating_parts[1])"

const _TEN_K_RULES = [
    TextItemRule("Item 1", ["business"], ["item"]), TextItemRule("Item 1A", ["risk factors"], ["item"]),
    TextItemRule("Item 2", ["properties"], ["item"]), TextItemRule("Item 3", ["legal proceedings"], ["item"]),
    TextItemRule("Item 7", ["management", "discussion"], String[]),
    TextItemRule("Item 8", ["financial statements"], String[]), TextItemRule("Item 15", ["exhibits"], String[])]
const _TEN_Q_RULES = [TextItemRule("Item 1A", ["risk factors"], ["item"])]
const _TEN_K_RANGES = [(1, 4, "I"), (5, 9, "II"), (10, 14, "III"), (15, 16, "IV")]
const TEN_K_SCHEMA = FormSchema(15, _TEN_K_RULES, false, _TEN_K_RANGES, String[])
const TEN_Q_SCHEMA = FormSchema(6, _TEN_Q_RULES, true, Tuple{Int,Int,String}[], ["I", "II"])
const DEFAULT_SCHEMA = FormSchema(15, TextItemRule[], false, Tuple{Int,Int,String}[], String[])
function get_form_schema(form)
    f = uppercase(strip(form === nothing ? "10-K" : String(form)))
    (f == "10-K" || f == "10-K/A") && return TEN_K_SCHEMA
    (f == "10-Q" || f == "10-Q/A") && return TEN_Q_SCHEMA
    return DEFAULT_SCHEMA
end

# --- EzXML helpers (lxml getparent/getprevious/text_content/tag equivalents) ---------------------------

_tag(n) = EzXML.iselement(n) ? lowercase(EzXML.nodename(n)) : ""
_attr(n, k) = (EzXML.iselement(n) && haskey(n, k)) ? n[k] : ""
_text(n) = strip(EzXML.nodecontent(n))
_getparent(n) = (EzXML.hasparentnode(n) && (p = EzXML.parentnode(n); EzXML.iselement(p)) ? p : nothing)
_getprevious(n) = (EzXML.hasprevelement(n) ? EzXML.prevelement(n) : nothing)
_xq(s) = occursin("'", s) ? "concat('" * replace(s, "'" => "',\"'\",'") * "')" : "'$s'"   # xpath-quote

# anchor_targets.py: find elements matching an anchor by id or <a name>.
function find_anchor_targets(root, anchor_id::AbstractString)
    isempty(anchor_id) && return EzXML.Node[]
    q = _xq(anchor_id)
    try
        return findall("//*[@id=$q or (self::a and @name=$q)]", root)
    catch
        return EzXML.Node[]
    end
end

# --- toc_analyzer.py helpers ---------------------------------------------------------------------------

function _roman_to_int(roman::AbstractString)
    m = Dict('i'=>1,'v'=>5,'x'=>10,'l'=>50,'c'=>100,'d'=>500,'m'=>1000)
    res = 0; prev = 0
    for ch in reverse(lowercase(roman))
        v = get(m, ch, 0)
        res += v < prev ? -v : v
        prev = v
    end
    return res
end

_extract_part_context(text) = (m = match(r"^\s*part\s+([ivx]+)\b"i, text);
    m === nothing ? nothing : "Part $(uppercase(m.captures[1]))")

# _extract_preceding_item_label: item/part label from a preceding table cell (or inline parent text).
function _extract_preceding_item_label(link, schema::FormSchema)
    current = link; td = nothing
    for _ in 1:5
        p = _getparent(current); p === nothing && break
        if _tag(p) in ("td", "th"); td = p; break; end
        current = p
    end
    if td !== nothing
        prev = _getprevious(td)
        while prev !== nothing
            if _tag(prev) in ("td", "th")
                t = _text(prev)
                m = match(r"(Item\s+\d+[A-Z]?)\.?\s*$"i, t); m !== nothing && return m.captures[1]
                bm = match(r"^([1-9]\d?)([A-Za-z]?)\.?\s*$"i, t)
                (bm !== nothing && 1 <= parse(Int, bm.captures[1]) <= schema.max_bare_item) &&
                    return "Item $(bm.captures[1])$(uppercase(bm.captures[2]))"
                pm = match(r"(Part\s+[IVX]+)\.?\s*$"i, t); pm !== nothing && return pm.captures[1]
                bp = match(r"^([IVX]+)\.?\s*$", t); bp !== nothing && return "Part $(bp.captures[1])"
            end
            prev = _getprevious(prev)
        end
    end
    return ""
end

# _infer_part_from_row_context: nearest preceding standalone "PART X" row.
function _infer_part_from_row_context(link)
    current = link; row = nothing
    for _ in 1:10
        p = _getparent(current); p === nothing && break
        if _tag(p) == "tr"; row = p; break; end
        current = p
    end
    row === nothing && return nothing
    prev = _getprevious(row); scanned = 0
    while prev !== nothing && scanned < 200
        scanned += 1
        if _tag(prev) == "tr"
            cells = findall("./td|./th", prev)
            if !isempty(cells)
                for c in cells
                    p = _extract_part_context(_text(c)); p !== nothing && return p
                end
            else
                p = _extract_part_context(_text(prev)); p !== nothing && return p
            end
        end
        prev = _getprevious(prev)
    end
    return nothing
end

const _SECTION_KEYWORDS = ("item", "part", "business", "risk", "properties", "legal",
                           "compensation", "ownership", "governance", "directors")
function _is_section_link(text, anchor_id, preceding_item, schema::FormSchema)
    isempty(text) && return false
    !isempty(preceding_item) && return true
    if !isempty(anchor_id)
        al = lowercase(anchor_id)
        occursin(r"item_?\d+[a-z]?", al) && return true
        occursin(r"part_?[ivx]+", al) && return true
    end
    length(text) > 150 && return false
    (match(r"^(Item|ITEM)\s+\d+[A-Z]?"i, text) !== nothing ||
     match(r"^Part\s+[IVX]+"i, text) !== nothing) && return true
    match_text(schema, lowercase(text); use_exclusions = false) !== nothing && return true
    (length(text) < 100 && any(k -> occursin(k, lowercase(text)), _SECTION_KEYWORDS)) && return true
    return false
end

function _normalize_section_name(text, anchor_id, preceding_item, schema::FormSchema)
    text = strip(text)
    if !isempty(preceding_item)
        im = match(r"item\s+(\d+[a-z]?)"i, preceding_item); im !== nothing && return "Item $(uppercase(im.captures[1]))"
        pm = match(r"part\s+([ivx]+)"i, preceding_item); pm !== nothing && return "Part $(uppercase(pm.captures[1]))"
    end
    if !isempty(anchor_id)
        al = lowercase(anchor_id)
        im = match(r"item_?(\d+[a-z]?)", al); im !== nothing && return "Item $(uppercase(im.captures[1]))"
        pm = match(r"part_?([ivx]+)", al); pm !== nothing && return "Part $(uppercase(pm.captures[1]))"
    end
    im = match(r"item\s+(\d+[a-z]?)"i, text); im !== nothing && return "Item $(uppercase(im.captures[1]))"
    pm = match(r"part\s+([ivx]+)"i, text); pm !== nothing && return "Part $(uppercase(pm.captures[1]))"
    matched = match_text(schema, lowercase(text); use_exclusions = true)
    matched !== nothing && return matched
    return schema.skip_unmatched_text ? "" : text
end

function _get_section_type_and_order(text, schema::FormSchema)
    tl = lowercase(text)
    pa = match(r"part_([ivx]+)_item[_\s]*(\d+)([a-z]?)", tl)
    if pa !== nothing
        part_num = _roman_to_int(pa.captures[1]); item_num = parse(Int, pa.captures[2])
        letter = pa.captures[3]; il = isempty(letter) ? 0 : Int(uppercase(letter)[1]) - Int('A') + 1
        return ("item", part_num * 100000 + item_num * 1000 + il)
    end
    im = match(r"item[\s_]*(\d+)([a-z]?)", tl)
    if im !== nothing
        item_num = parse(Int, im.captures[1]); letter = im.captures[2]
        il = isempty(letter) ? 0 : Int(uppercase(letter)[1]) - Int('A') + 1
        return ("item", item_num * 1000 + il)
    end
    pm = match(r"part[\s_]*([ivx]+)", tl)
    pm !== nothing && return ("part", _roman_to_int(pm.captures[1]) * 100)
    matched = match_text(schema, tl; use_exclusions = false)
    if matched !== nothing
        m = match(r"item\s+(\d+)([a-z]?)"i, matched)
        if m !== nothing
            item_num = parse(Int, m.captures[1]); letter = m.captures[2]
            il = isempty(letter) ? 0 : Int(uppercase(letter)[1]) - Int('A') + 1
            return ("item", item_num * 1000 + il)
        end
    end
    return ("other", 99999)
end

_part_rank(label) = (m = match(r"[ivxlcdm]+"i, label === nothing ? "" : label);
    m === nothing ? nothing : _roman_to_int(m.match))

function _make_section_key(item_name, current_part, schema::FormSchema)
    canonical = part_for_item(schema, item_name)
    if current_part !== nothing
        if canonical !== nothing
            cr = _part_rank(current_part); kr = _part_rank(canonical)
            (cr !== nothing && kr !== nothing && cr > kr) && return nothing   # back-reference
        end
        effective = current_part
    else
        effective = canonical
    end
    effective === nothing && return item_name
    return "$(replace(lowercase(effective), " " => "_"))_$(replace(lowercase(item_name), " " => "_"))"
end

const _KNOWN_NAMED = Set(["signatures"])
const _CANONICAL_ITEM_KEY = r"^(part_[ivxlcdm]+_)?item_\d+[a-z]?$"i
const _BARE_ITEM_KEY = r"^Item\s+\d+[A-Z]?$"i
_is_valid_section_key(key, normalized) =
    match(_CANONICAL_ITEM_KEY, key) !== nothing || match(_BARE_ITEM_KEY, key) !== nothing ||
    lowercase(strip(normalized)) in _KNOWN_NAMED

# _anchor_matches_heading: does content right after the anchor target contain the expected item heading?
function _anchor_matches_heading(root, anchor_id, expected_name)
    targets = find_anchor_targets(root, anchor_id); isempty(targets) && return false
    im = match(r"item\s+(\d+[a-z]?)"i, expected_name); im === nothing && return false
    want = "ITEM $(uppercase(im.captures[1]))"
    try
        for el in findall("following::*[string-length(normalize-space(text())) > 3][position() <= 3]", targets[1])
            occursin(want, uppercase(first(_text(el), 80))) && return true
        end
    catch
    end
    return false
end

struct TOCSection
    name::String
    anchor_id::String
    normalized_name::String
    section_type::String
    order::Int
    part::Union{String,Nothing}
end

function _build_section_mapping(toc_sections::Vector{TOCSection}, root, schema::FormSchema)
    sort!(toc_sections, by = s -> s.order)
    mapping = String[]; keys_ = String[]; anchors = String[]; seen = Set{String}()
    for s in toc_sections
        isempty(s.normalized_name) && continue
        match(r"^Part\s+[IVXLCDM]+$"i, s.normalized_name) !== nothing && continue
        key = _make_section_key(s.normalized_name, s.part, schema)
        (key === nothing || !_is_valid_section_key(key, s.normalized_name)) && continue
        if key in seen
            idx = findfirst(==(key), keys_)
            if idx !== nothing && anchors[idx] != s.anchor_id &&
               _anchor_matches_heading(root, s.anchor_id, s.normalized_name) &&
               !_anchor_matches_heading(root, anchors[idx], s.normalized_name)
                anchors[idx] = s.anchor_id
            end
            continue
        end
        push!(keys_, key); push!(anchors, s.anchor_id); push!(seen, key)
    end
    return [keys_[i] => anchors[i] for i in eachindex(keys_)]
end

# _analyze_generic_toc: scan all internal anchor links, build the section→anchor mapping.
function analyze_generic_toc(root, schema::FormSchema)
    toc_sections = TOCSection[]
    current_part = seed_part(schema)
    for link in findall("//a[@href]", root)
        href = strip(_attr(link, "href")); text = _text(link)
        (startswith(href, "#") && !isempty(text)) || continue
        ep = _extract_part_context(text)
        if ep !== nothing && match(r"item\s+\d+[a-z]?"i, text) === nothing
            current_part = ep; continue
        end
        anchor_id = href[2:end]
        preceding = _extract_preceding_item_label(link, schema)
        inferred = _infer_part_from_row_context(link); inferred !== nothing && (current_part = inferred)
        if _is_section_link(text, anchor_id, preceding, schema)
            isempty(find_anchor_targets(root, anchor_id)) && continue
            nn = _normalize_section_name(text, anchor_id, preceding, schema)
            st, order = _get_section_type_and_order(nn, schema)
            push!(toc_sections, TOCSection(text, anchor_id, nn, st, order, current_part))
        end
    end
    return _build_section_mapping(toc_sections, root, schema)
end

"""
    analyze_toc_structure(html, form) -> Vector{Pair{String,String}}

Section-key => anchor-id mapping from a filing's table of contents (generic anchor-link analysis; the
agent-specific Workiva/DFIN/Novaworks/Toppan parsers are deferred). Faithful port of edgartools'
`TOCAnalyzer.analyze_toc_structure` generic path.
"""
function analyze_toc_structure(html::AbstractString, form = "10-K")
    schema = get_form_schema(form)
    local doc
    try
        doc = parsehtml(String(html))
    catch
        return Pair{String,String}[]
    end
    return analyze_generic_toc(root(doc), schema)
end

# --- toc_section_extractor.py: anchor boundaries + document-order text extraction ----------------------

# anchor_targets.py is_anchor_match
is_anchor_match(el, anchor_id) = !isempty(anchor_id) && EzXML.iselement(el) &&
    (_attr(el, "id") == anchor_id || (_tag(el) == "a" && _attr(el, "name") == anchor_id))

const _BLOCK_ELEMENTS = Set(["p", "div", "table", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6",
                             "blockquote", "pre", "section", "article", "header", "footer"])

# _extract_section_content: document-order traversal from the start anchor to the end anchor (iterwalk),
# collecting text + a paragraph break after each block element.
function _extract_between(root_el, start_id, end_id)
    parts = String[]; state = Ref(0)            # 0=before start, 1=in range, 2=done
    function walk(n)
        state[] == 2 && return
        if EzXML.iselement(n)
            if state[] == 0 && is_anchor_match(n, start_id)
                state[] = 1
            elseif state[] == 1 && !isempty(end_id) && is_anchor_match(n, end_id)
                state[] = 2; return
            end
            for c in EzXML.eachnode(n)
                walk(c); state[] == 2 && return
            end
            state[] == 1 && _tag(n) in _BLOCK_ELEMENTS && push!(parts, "\n\n")
        elseif EzXML.istext(n) && state[] == 1
            push!(parts, EzXML.nodecontent(n))
        end
    end
    walk(root_el)
    return join(parts)
end

_clean_section_text(text) = strip(replace(text, r"\n\s*\n\s*\n" => "\n\n"))

function _key_to_label(key)
    im = match(r"item_(\d+[a-z]?)"i, key)
    item = im === nothing ? key : "Item $(uppercase(im.captures[1]))"
    pm = match(r"^part_([ivxlcdm]+)_"i, key)
    part = pm === nothing ? "" : "Part $(uppercase(pm.captures[1]))"
    return (item, part)
end

"""
    extract_sections(html, form="10-K") -> Vector{@NamedTuple{item,part,text}}

TOC-anchored section extraction: build the section→anchor map, then slice each section's text from its
anchor to the next section's anchor in document order. Faithful port of edgartools' `TOCSectionExtractor`.
"""
function extract_sections(html::AbstractString, form = "10-K")
    EMPTY = @NamedTuple{item::String, part::String, text::String}[]
    schema = get_form_schema(form)
    local doc
    try
        doc = parsehtml(String(html))
    catch
        return EMPTY
    end
    rt = root(doc)
    m = analyze_generic_toc(rt, schema)
    isempty(m) && return EMPTY
    out = EMPTY
    for i in eachindex(m)
        anchor = m[i].second
        endanchor = i < length(m) ? m[i + 1].second : ""
        text = _clean_section_text(_extract_between(rt, anchor, endanchor))
        item, part = _key_to_label(m[i].first)
        push!(out, (item = item, part = part, text = text))
    end
    return out
end

end # module DocTOC
