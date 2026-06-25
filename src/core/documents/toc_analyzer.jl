# Faithful translation of edgartools' edgar/documents/utils/toc_analyzer.py.
# Analyzes the Table of Contents to map section names -> anchor ids. Agent-specific parsers (Workiva /
# DFIN / Novaworks / Toppan) + a generic fallback, plus the ordering/normalization helpers. lxml XPath is
# translated to EzXML `findall`; `.text_content()`/`.getparent()`/… use the ezxml_dom.jl accessors.

struct TOCSection
    name::String
    anchor_id::String
    normalized_name::String
    section_type::String
    order::Int
    part::Union{Nothing,String}
end
TOCSection(; name, anchor_id, normalized_name, section_type, order, part = nothing) =
    TOCSection(name, anchor_id, normalized_name, section_type, order, part)

struct TOCAnalyzer
    section_patterns::Vector{Tuple{Regex,String}}
end
TOCAnalyzer() = TOCAnalyzer(Tuple{Regex,String}[
    (r"(?:item|part)\s+\d+[a-z]?"i, "item"), (r"business"i, "item"), (r"risk\s+factors?"i, "item"),
    (r"properties"i, "item"), (r"legal\s+proceedings"i, "item"), (r"management.*discussion"i, "item"),
    (r"md&a"i, "item"), (r"financial\s+statements?"i, "item"), (r"exhibits?"i, "item"),
    (r"signatures?"i, "item"), (r"part\s+[ivx]+"i, "part")])

_xpath(node, q) = findall(q, node)

# analyze_toc_structure — dispatch to the agent-specific parser, else generic.
function analyze_toc_structure(a::TOCAnalyzer, html_content::AbstractString; agent = nothing, tree = nothing)
    if agent == "Workiva"
        r = _analyze_workiva_toc(a, html_content; tree = tree); isempty(r) || return r
    elseif agent == "Donnelley"
        r = _analyze_dfin_toc(a, html_content; tree = tree); isempty(r) || return r
    elseif agent == "Novaworks"
        r = _analyze_novaworks_toc(a, html_content; tree = tree); isempty(r) || return r
    elseif agent == "Toppan Merrill"
        r = _analyze_toppan_toc(a, html_content; tree = tree); isempty(r) || return r
    end
    return _analyze_generic_toc(a, html_content; tree = tree)
end

function _ensure_tree(html_content::AbstractString, tree)
    tree !== nothing && return tree
    startswith(html_content, "<?xml") && (html_content = replace(html_content, r"<\?xml[^>]*\?>" => ""; count = 1))
    return EzXML.root(EzXML.parsehtml(html_content))
end

function _analyze_generic_toc(a::TOCAnalyzer, html_content::AbstractString; tree = nothing)
    section_mapping = Dict{String,String}()
    try
        tree = _ensure_tree(html_content, tree)
        anchor_links = _xpath(tree, "//a[@href]")
        toc_sections = TOCSection[]
        current_part = nothing
        for link in anchor_links
            href = strip(_attr(link, "href", ""))
            text_ = strip(_text_content(link))
            startswith(href, "#") || continue
            isempty(text_) && continue
            explicit_part = _extract_part_context(a, text_)
            if explicit_part !== nothing && match(r"item\s+\d+[a-z]?"i, text_) === nothing
                current_part = explicit_part
                continue
            end
            anchor_id = href[2:end]
            preceding_item = _extract_preceding_item_label(a, link)
            inferred_part = _infer_part_from_row_context(a, link)
            inferred_part !== nothing && (current_part = inferred_part)
            if _is_section_link(a, text_, anchor_id, preceding_item)
                if !isempty(find_anchor_targets(tree, anchor_id))
                    normalized_name = _normalize_section_name(a, text_, anchor_id, preceding_item)
                    section_type, order = _get_section_type_and_order(a, normalized_name)
                    push!(toc_sections, TOCSection(name = text_, anchor_id = anchor_id,
                        normalized_name = normalized_name, section_type = section_type,
                        order = order, part = current_part))
                end
            end
        end
        section_mapping = _build_section_mapping(a, toc_sections; tree = tree)
    catch
    end
    return section_mapping
end

# ---- TOC-table location ----
function _find_table_in_siblings(element)
    for following in _itersiblings(element)
        _tag(following) == "table" && return following
        tables = _xpath(following, ".//table")
        isempty(tables) || return tables[1]
    end
    return nothing
end

function _itersiblings(el)
    out = EzXML.Node[]; n = _getnext(el)
    while n !== nothing
        push!(out, n); n = _getnext(n)
    end
    return out
end

const _TOC_HEADING_TAGS = ("p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "b", "strong", "span", "td", "th", "center")

function _find_toc_table(a::TOCAnalyzer, tree, headings = nothing)
    headings === nothing && (headings = ["TABLE OF CONTENTS", "INDEX"])
    headings_upper = uppercase.(headings)
    q = join(("//" * t for t in _TOC_HEADING_TAGS), "|")
    for el in _xpath(tree, q)
        text_ = uppercase(strip(_text_content(el)))
        isempty(text_) && continue
        for heading in headings_upper
            if text_ == heading || text_ == heading * "."
                current = el
                for _ in 1:3
                    table = _find_table_in_siblings(current)
                    table !== nothing && return table
                    parent = _getparent(current)
                    parent === nothing && break
                    current = parent
                end
            end
        end
    end
    return nothing
end

function _parse_item_from_text(a::TOCAnalyzer, text_::AbstractString)
    text_ = strip(text_)
    text_ = replace(replace(replace(text_, "​" => ""), "‌" => ""), "‍" => "")
    m = match(r"^(?:item|ITEM)\s+(\d+[A-Za-z]?)"i, text_)
    m !== nothing && return "Item $(uppercase(m.captures[1]))"
    m = match(r"^(?:part|PART)\s+([IVXivx]+)"i, text_)
    m !== nothing && return "Part $(uppercase(m.captures[1]))"
    return nothing
end

function _item_from_anchor(a::TOCAnalyzer, anchor_id::AbstractString)
    anchor_lower = lowercase(anchor_id)
    m = match(r"item[_\s]*(\d+)([a-z]?)(?![a-z])", anchor_lower)
    if m !== nothing
        return "Item $(m.captures[1])$(uppercase(m.captures[2]))"
    end
    m = match(r"part[_\s]*([ivx]+)", anchor_lower)
    m !== nothing && return "Part $(uppercase(m.captures[1]))"
    return nothing
end

function _count_item_links(a::TOCAnalyzer, table)
    count_ = 0
    for link in _xpath(table, ".//a[@href]")
        href = strip(_attr(link, "href", ""))
        startswith(href, "#") || continue
        text_ = strip(_text_content(link))
        if match(r"item\s+\d"i, text_) !== nothing
            count_ += 1
        elseif match(r"item[_]?\d"i, href) !== nothing
            count_ += 1
        end
    end
    return count_
end

function _find_toc_table_by_links(a::TOCAnalyzer, tree)
    best_table = nothing; best_count = 0
    for table in _xpath(tree, "//table")
        c = _count_item_links(a, table)
        c > best_count && (best_count = c; best_table = table)
    end
    return best_count >= 5 ? best_table : nothing
end

function _find_best_toc_table(a::TOCAnalyzer, tree, headings)
    toc_table = _find_toc_table(a, tree, headings)
    (toc_table !== nothing && _count_item_links(a, toc_table) >= 5) && return toc_table
    return _find_toc_table_by_links(a, tree)
end

function _make_section_key(a::TOCAnalyzer, item_name::AbstractString, current_part)
    if current_part !== nothing
        part_key = replace(lowercase(current_part), " " => "_")
        item_key = replace(lowercase(item_name), " " => "_")
        return "$(part_key)_$(item_key)"
    end
    return String(item_name)
end

# ---- agent-specific parsers ----
function _analyze_workiva_toc(a::TOCAnalyzer, html_content; tree = nothing)
    try
        tree = _ensure_tree(html_content, tree)
        toc_table = _find_best_toc_table(a, tree, ["TABLE OF CONTENTS"])
        toc_table === nothing && return Dict{String,String}()
        mapping = Dict{String,String}(); current_part = nothing
        for row in _xpath(toc_table, ".//tr")
            links = _xpath(row, ".//a[@href]")
            isempty(links) && continue
            href_groups = Dict{String,Vector{String}}(); href_order = String[]
            for link in links
                href = strip(_attr(link, "href", ""))
                startswith(href, "#") || continue
                text_ = strip(_text_content(link)); isempty(text_) && continue
                if !haskey(href_groups, href)
                    href_groups[href] = String[]; push!(href_order, href)
                end
                push!(href_groups[href], text_)
            end
            for href in href_order
                texts = href_groups[href]; anchor_id = href[2:end]
                (length(texts) == 1 && match(r"^\d{1,3}$", texts[1]) !== nothing) && continue
                non_page = [t for t in texts if match(r"^\d{1,3}$", t) === nothing]
                combined = join(non_page, " ")
                parsed = _parse_item_from_text(a, combined)
                parsed === nothing && continue
                if startswith(parsed, "Part")
                    current_part = parsed; continue
                end
                if !isempty(find_anchor_targets(tree, anchor_id))
                    key = _make_section_key(a, parsed, current_part)
                    haskey(mapping, key) || (mapping[key] = anchor_id)
                end
            end
        end
        return mapping
    catch
        return Dict{String,String}()
    end
end

function _analyze_dfin_toc(a::TOCAnalyzer, html_content; tree = nothing)
    try
        tree = _ensure_tree(html_content, tree)
        toc_table = _find_toc_table(a, tree, ["INDEX", "TABLE OF CONTENTS"])
        toc_table === nothing && return _analyze_dfin_links(a, tree)
        mapping = Dict{String,String}(); current_part = nothing
        for row in _xpath(toc_table, ".//tr")
            row_text = strip(_text_content(row))
            links = _xpath(row, ".//a[@href]")
            if isempty(links)
                if !isempty(row_text)
                    pt = _parse_item_from_text(a, row_text)
                    (pt !== nothing && startswith(pt, "Part")) && (current_part = pt)
                end
                continue
            end
            for link in links
                href = strip(_attr(link, "href", "")); startswith(href, "#") || continue
                text_ = strip(_text_content(link)); isempty(text_) && continue
                anchor_id = href[2:end]
                match(r"^\d{1,3}$", text_) !== nothing && continue
                parsed = _item_from_anchor(a, anchor_id)
                parsed === nothing && (parsed = _parse_item_from_text(a, text_))
                parsed === nothing && continue
                if startswith(parsed, "Part")
                    current_part = parsed; continue
                end
                if !isempty(find_anchor_targets(tree, anchor_id))
                    key = _make_section_key(a, parsed, current_part)
                    haskey(mapping, key) || (mapping[key] = anchor_id)
                end
            end
        end
        return mapping
    catch
        return Dict{String,String}()
    end
end

function _analyze_dfin_links(a::TOCAnalyzer, tree)
    mapping = Dict{String,String}(); current_part = nothing
    for link in _xpath(tree, "//a[@href]")
        href = strip(_attr(link, "href", "")); startswith(href, "#") || continue
        anchor_id = href[2:end]
        parsed = _item_from_anchor(a, anchor_id)
        parsed === nothing && continue
        if startswith(parsed, "Part")
            current_part = parsed; continue
        end
        if !isempty(find_anchor_targets(tree, anchor_id))
            key = _make_section_key(a, parsed, current_part)
            haskey(mapping, key) || (mapping[key] = anchor_id)
        end
    end
    return mapping
end

function _analyze_novaworks_toc(a::TOCAnalyzer, html_content; tree = nothing)
    try
        tree = _ensure_tree(html_content, tree)
        toc_table = _find_best_toc_table(a, tree, ["INDEX", "TABLE OF CONTENTS"])
        toc_table === nothing && return Dict{String,String}()
        mapping = Dict{String,String}(); current_part = nothing
        for link in _xpath(toc_table, ".//a[@href]")
            href = strip(_attr(link, "href", "")); startswith(href, "#") || continue
            text_ = strip(_text_content(link)); isempty(text_) && continue
            anchor_id = href[2:end]
            match(r"^\d{1,3}$", text_) !== nothing && continue
            parsed = _parse_item_from_text(a, text_)
            parsed === nothing && continue
            if startswith(parsed, "Part")
                current_part = parsed; continue
            end
            if !isempty(find_anchor_targets(tree, anchor_id))
                key = _make_section_key(a, parsed, current_part)
                haskey(mapping, key) || (mapping[key] = anchor_id)
            end
        end
        return mapping
    catch
        return Dict{String,String}()
    end
end

function _analyze_toppan_toc(a::TOCAnalyzer, html_content; tree = nothing)
    try
        tree = _ensure_tree(html_content, tree)
        toc_table = _find_best_toc_table(a, tree, ["TABLE OF CONTENTS", "INDEX"])
        toc_table === nothing && return Dict{String,String}()
        mapping = Dict{String,String}(); current_part = nothing
        for row in _xpath(toc_table, ".//tr")
            links = _xpath(row, ".//a[@href]")
            isempty(links) && continue
            href_groups = Dict{String,Vector{String}}(); href_order = String[]
            for link in links
                href = strip(_attr(link, "href", "")); startswith(href, "#") || continue
                text_ = _text_content(link)
                text_ = replace(replace(replace(text_, "​" => ""), "‌" => ""), "‍" => "")
                text_ = strip(replace(text_, "\xa0" => " "))
                isempty(text_) && continue
                if !haskey(href_groups, href)
                    href_groups[href] = String[]; push!(href_order, href)
                end
                push!(href_groups[href], String(text_))
            end
            for href in href_order
                texts = href_groups[href]; anchor_id = href[2:end]
                non_page = [t for t in texts if match(r"^\d{1,3}$", t) === nothing]
                isempty(non_page) && continue
                combined = join(non_page, " ")
                parsed = _parse_item_from_text(a, combined)
                parsed === nothing && (parsed = _item_from_anchor(a, anchor_id))
                parsed === nothing && continue
                if startswith(parsed, "Part")
                    current_part = parsed; continue
                end
                if !isempty(find_anchor_targets(tree, anchor_id))
                    key = _make_section_key(a, parsed, current_part)
                    haskey(mapping, key) || (mapping[key] = anchor_id)
                end
            end
        end
        return mapping
    catch
        return Dict{String,String}()
    end
end

# ---- context/normalization helpers ----
function _extract_preceding_item_label(a::TOCAnalyzer, link_element)
    try
        current = link_element; td_element = nothing
        for _ in 1:5
            parent = _getparent(current)
            parent === nothing && break
            if _tag(parent) in ("td", "th")
                td_element = parent; break
            end
            current = parent
        end
        if td_element !== nothing
            prev_sibling = _getprevious(td_element)
            while prev_sibling !== nothing
                if _tag(prev_sibling) in ("td", "th")
                    prev_text = strip(_text_content(prev_sibling))
                    m = match(r"^(Item\s+\d+[A-Z]?)\.?\s*$"i, prev_text)
                    m !== nothing && return m.captures[1]
                    m = match(r"^([1-9]|1[0-5])([A-Z]?)\.?\s*$"i, prev_text)
                    m !== nothing && return "Item $(m.captures[1])$(m.captures[2])"
                    m = match(r"^(Part\s+[IVX]+)\.?\s*$"i, prev_text)
                    m !== nothing && return m.captures[1]
                    m = match(r"^([IVX]+)\.?\s*$", prev_text)
                    m !== nothing && return "Part $(m.captures[1])"
                end
                prev_sibling = _getprevious(prev_sibling)
            end
        end
        parent = _getparent(link_element)
        if parent !== nothing && _tag(parent) in ("div", "span", "p")
            text_before = strip(_lxtext(parent))
            m = match(r"(Item\s+\d+[A-Z]?)\.?\s*$"i, text_before)
            m !== nothing && return m.captures[1]
            m = match(r"(Part\s+[IVX]+)\.?\s*$"i, text_before)
            m !== nothing && return m.captures[1]
        end
    catch
    end
    return ""
end

function _extract_part_context(a::TOCAnalyzer, text_::AbstractString)
    m = match(r"^\s*part\s+([ivx]+)\b"i, text_)
    m === nothing && return nothing
    return "Part $(uppercase(m.captures[1]))"
end

function _infer_part_from_row_context(a::TOCAnalyzer, link_element)
    max_rows_to_scan = 200
    try
        current = link_element; row = nothing
        for _ in 1:10
            parent = _getparent(current)
            parent === nothing && break
            if _tag(parent) == "tr"
                row = parent; break
            end
            current = parent
        end
        row === nothing && return nothing
        prev = _getprevious(row); rows_scanned = 0
        while prev !== nothing && rows_scanned < max_rows_to_scan
            rows_scanned += 1
            if _tag(prev) == "tr"
                cells = _xpath(prev, "./td|./th")
                if !isempty(cells)
                    for cell in cells
                        part = _extract_part_context(a, strip(_text_content(cell)))
                        part !== nothing && return part
                    end
                else
                    part = _extract_part_context(a, strip(_text_content(prev)))
                    part !== nothing && return part
                end
            end
            prev = _getprevious(prev)
        end
    catch
        return nothing
    end
    return nothing
end

function _is_section_link(a::TOCAnalyzer, text_::AbstractString, anchor_id::AbstractString = "", preceding_item::AbstractString = "")
    isempty(text_) && return false
    isempty(preceding_item) || return true
    if !isempty(anchor_id)
        anchor_lower = lowercase(anchor_id)
        match(r"item_?\d+[a-z]?", anchor_lower) !== nothing && return true
        match(r"part_?[ivx]+", anchor_lower) !== nothing && return true
    end
    length(text_) > 150 && return false
    for (pattern, _) in a.section_patterns
        match(pattern, text_) !== nothing && return true
    end
    if length(text_) < 100 && any(kw -> occursin(kw, lowercase(text_)),
            ("item", "part", "business", "risk", "properties", "legal", "compensation", "ownership", "governance", "directors"))
        return true
    end
    return false
end

function _normalize_section_name(a::TOCAnalyzer, text_::AbstractString, anchor_id::AbstractString = "", preceding_item::AbstractString = "")
    text_ = strip(text_)
    if !isempty(preceding_item)
        m = match(r"^item\s+(\d+[a-z]?)"i, preceding_item)
        m !== nothing && return "Item $(uppercase(m.captures[1]))"
        m = match(r"^part\s+([ivx]+)"i, preceding_item)
        m !== nothing && return "Part $(uppercase(m.captures[1]))"
    end
    if !isempty(anchor_id)
        anchor_lower = lowercase(anchor_id)
        m = match(r"item_?(\d+[a-z]?)", anchor_lower)
        m !== nothing && return "Item $(uppercase(m.captures[1]))"
        m = match(r"part_?([ivx]+)", anchor_lower)
        m !== nothing && return "Part $(uppercase(m.captures[1]))"
    end
    m = match(r"^item\s+(\d+[a-z]?)"i, text_)
    m !== nothing && return "Item $(uppercase(m.captures[1]))"
    m = match(r"^part\s+([ivx]+)"i, text_)
    m !== nothing && return "Part $(uppercase(m.captures[1]))"
    tl = lowercase(text_)
    (occursin("business", tl) && !occursin("item", tl)) && return "Item 1"
    (occursin("risk factors", tl) && !occursin("item", tl)) && return "Item 1A"
    (occursin("properties", tl) && !occursin("item", tl)) && return "Item 2"
    (occursin("legal proceedings", tl) && !occursin("item", tl)) && return "Item 3"
    (occursin("management", tl) && occursin("discussion", tl)) && return "Item 7"
    occursin("financial statements", tl) && return "Item 8"
    occursin("exhibits", tl) && return "Item 15"
    return String(text_)
end

function _get_section_type_and_order(a::TOCAnalyzer, text_::AbstractString)
    tl = lowercase(text_)
    m = match(r"part_([ivx]+)_item[_\s]*(\d+)([a-z]?)", tl)
    if m !== nothing
        part_num = _roman_to_int(a, m.captures[1]); item_num = parse(Int, m.captures[2])
        il = m.captures[3]
        item_order = item_num * 1000 + (isempty(il) ? 0 : (Int(uppercase(il)[1]) - Int('A') + 1))
        return ("item", part_num * 100000 + item_order)
    end
    m = match(r"item[\s_]*(\d+)([a-z]?)", tl)
    if m !== nothing
        item_num = parse(Int, m.captures[1]); il = m.captures[2]
        return ("item", item_num * 1000 + (isempty(il) ? 0 : (Int(uppercase(il)[1]) - Int('A') + 1)))
    end
    m = match(r"part[\s_]*([ivx]+)", tl)
    m !== nothing && return ("part", _roman_to_int(a, m.captures[1]) * 100)
    occursin("business", tl) && return ("item", 1000)
    occursin("risk factors", tl) && return ("item", 1001)
    occursin("properties", tl) && return ("item", 2000)
    occursin("legal proceedings", tl) && return ("item", 3000)
    (occursin("management", tl) && occursin("discussion", tl)) && return ("item", 7000)
    occursin("financial statements", tl) && return ("item", 8000)
    occursin("exhibits", tl) && return ("item", 15000)
    return ("other", 99999)
end

function _roman_to_int(a::TOCAnalyzer, roman::AbstractString)
    roman_map = Dict('i' => 1, 'v' => 5, 'x' => 10, 'l' => 50, 'c' => 100, 'd' => 500, 'm' => 1000)
    roman = lowercase(roman); result = 0; prev = 0
    for char in reverse(collect(roman))
        value = get(roman_map, char, 0)
        result += value < prev ? -value : value
        prev = value
    end
    return result
end

function _build_section_mapping(a::TOCAnalyzer, toc_sections::Vector{TOCSection}; tree = nothing)
    # Stable sort + OrderedDict so equal-`order` sections keep TOC discovery order — Python's dict is
    # insertion-ordered and its sort is stable; a plain Julia Dict / unstable sort breaks the tie order.
    sort!(toc_sections; by = x -> x.order, alg = Base.Sort.DEFAULT_STABLE)
    mapping = OrderedDict{String,String}(); seen_names = Set{String}()
    for section in toc_sections
        if section.part !== nothing
            part_key = replace(lowercase(section.part), " " => "_")
            item_key = replace(lowercase(section.normalized_name), " " => "_")
            section_name = "$(part_key)_$(item_key)"
        else
            section_name = section.normalized_name
        end
        if section_name in seen_names
            if tree !== nothing && haskey(mapping, section_name)
                existing_anchor = mapping[section_name]; new_anchor = section.anchor_id
                if existing_anchor != new_anchor
                    if _anchor_matches_heading(a, tree, new_anchor, section.normalized_name) &&
                       !_anchor_matches_heading(a, tree, existing_anchor, section.normalized_name)
                        mapping[section_name] = new_anchor
                    end
                end
            end
            continue
        end
        mapping[section_name] = section.anchor_id
        push!(seen_names, section_name)
    end
    return mapping
end

# find_toc_boundaries — (start, end) byte positions of the TOC region (module-level fn in Python).
function find_toc_boundaries(html_content::AbstractString)
    isempty(html_content) && return (0, 0)
    startswith(html_content, "<?xml") && (html_content = replace(html_content, r"<\?xml[^>]*\?>" => ""; count = 1))
    r = findfirst("TABLE OF CONTENTS", html_content)
    toc_start = r === nothing ? -1 : first(r)
    if toc_start == -1
        r2 = findfirst("table of contents", lowercase(html_content))
        (r2 !== nothing && first(r2) > 0) && (toc_start = first(r2))
    end
    toc_start == -1 && (toc_start = _find_toc_table_start(html_content))
    toc_start == -1 && return (0, 0)
    sig = findnext("SIGNATURES", html_content, toc_start)
    sigp = sig === nothing ? -1 : first(sig)
    if sigp == -1
        s2 = findnext("signatures", lowercase(html_content), toc_start)
        (s2 !== nothing && first(s2) > 0) && (sigp = first(s2))
    end
    if sigp > 0
        te = findnext("</table>", html_content, sigp)
        te !== nothing && return (toc_start, last(te))
    end
    return (toc_start, min(toc_start + 50000, ncodeunits(html_content)))
end

function _find_toc_table_start(html_content::AbstractString)
    try
        tree = EzXML.root(EzXML.parsehtml(html_content))
        for table in _xpath(tree, "//table")
            rows = _xpath(table, ".//tr")
            length(rows) < 3 && continue
            toc_like = 0
            for row in rows[1:min(end, 20)]
                row_text = strip(_text_content(row))
                has_item = match(r"Item\s+\d"i, row_text) !== nothing
                has_page = match(r"\d{1,3}\s*$", row_text) !== nothing
                (has_item && has_page) && (toc_like += 1)
            end
            if toc_like >= 3
                first_row_text = strip(_text_content(rows[1]))
                if !isempty(first_row_text)
                    search_text = first(first_row_text, 30)
                    pos = findfirst(search_text, html_content)
                    pos !== nothing && first(pos) > 0 && return first(pos)
                end
            end
        end
    catch
    end
    return -1
end

function _anchor_matches_heading(a::TOCAnalyzer, tree, anchor_id::AbstractString, expected_name::AbstractString)
    targets = find_anchor_targets(tree, anchor_id)
    isempty(targets) && return false
    target = targets[1]
    try
        following = _xpath(target, "following::*")
        seen = 0
        for el in following
            el_text = strip(_text_content(el))
            length(el_text) > 3 || continue
            seen += 1; seen > 3 && break
            up = uppercase(first(el_text, 80))
            m = match(r"item\s+(\d+[a-z]?)"i, expected_name)
            if m !== nothing
                occursin("ITEM $(uppercase(m.captures[1]))", up) && return true
            end
        end
    catch
    end
    return false
end
