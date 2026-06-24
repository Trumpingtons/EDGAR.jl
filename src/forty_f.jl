# 40-F AIF-exhibit discovery — a faithful port of edgartools' company_reports/forty_f.py
# (`_scan_attachments` / `_find_aif_attachment`). A 40-F's substance is the Canadian Annual Information
# Form, filed as an exhibit (EX-1 or, more often, an EX-99.x) rather than inline in the primary document.
# `aif_html` locates that exhibit so it can be segmented with the 40-F FormSpec. 🔵 SEC-specific.

const _AIF_CONTENT_SIGNALS = ("CORPORATE STRUCTURE", "DESCRIPTION OF THE BUSINESS",
                              "GENERAL DEVELOPMENT OF THE BUSINESS", "RISK FACTORS")
const _MAJOR_EXHIBIT_THRESHOLD = 100_000   # 100 KB — separates real docs from certs/consents

_unesc_sgml(s) = replace(s, "&lt;" => "<", "&gt;" => ">", "&amp;" => "&", "&#39;" => "'", "&quot;" => "\"")

# Parse the filing's SGML header (`<accession>-index-headers.html`) into (type, filename, description) per
# document, and read file sizes from index.json.
function _filing_documents(cik, accession)
    base = _filing_dir(cik, accession)
    body = fetch_url("$base/$accession-index-headers.html")
    body === nothing && return @NamedTuple{type::String, filename::String, description::String, size::Int}[]
    txt = _unesc_sgml(String(body))
    sizes = Dict{String,Int}()
    j = _get_json("$base/index.json")
    if j !== nothing
        for it in j.directory.item
            s = String(it.size); sizes[String(it.name)] = isempty(s) ? 0 : something(tryparse(Int, s), 0)
        end
    end
    docs = @NamedTuple{type::String, filename::String, description::String, size::Int}[]
    for block in split(txt, "<DOCUMENT>")[2:end]
        ty = match(r"<TYPE>([^\n<]*)", block); fn = match(r"<FILENAME>([^\n<]*)", block)
        de = match(r"<DESCRIPTION>([^\n<]*)", block)
        (ty === nothing || fn === nothing) && continue
        f = strip(fn.captures[1])
        push!(docs, (type = strip(ty.captures[1]), filename = f,
                     description = uppercase(de === nothing ? "" : strip(de.captures[1])),
                     size = get(sizes, f, 0)))
    end
    return docs
end

# Does a document contain NI 51-102 AIF section headings? (Scan the first 80 KB.)
function _has_aif_content(url)
    body = fetch_url(url)
    body === nothing && return false
    up = uppercase(first(String(body), 80_000))
    return any(s -> occursin(s, up), _AIF_CONTENT_SIGNALS)
end

"""
    aif_html(f::Filing) -> Union{String,Nothing}

For a 40-F, find and download the Annual Information Form exhibit's HTML (the substantive Canadian annual
report), following edgartools' priority chain: EX-1 → AIF in description → EX-99.x with AIF in filename →
content-sniffed EX-99.x (>100 KB with NI 51-102 headings) → inline 40-F. Returns `nothing` if not found.
"""
function aif_html(f::Filing)
    docs = _filing_documents(f.cik, f.accession)
    base = _filing_dir(f.cik, f.accession)
    htm(d) = endswith(lowercase(d.filename), ".htm") || endswith(lowercase(d.filename), ".html") ||
             endswith(lowercase(d.filename), ".xhtml")
    html = filter(htm, docs)
    _url(d) = "$base/$(d.filename)"
    pick(pred) = (i = findfirst(pred, html); i === nothing ? nothing : html[i])
    # P1: standard MJDS AIF exhibits.
    (d = pick(d -> d.type in ("EX-1", "EX-1.1", "EX-1.2"))) !== nothing && return _fetch_text(_url(d))
    # P2: description mentions the AIF.
    (d = pick(d -> occursin("ANNUAL INFORMATION", d.description) || occursin(r"\bAIF\b", d.description))) !== nothing && return _fetch_text(_url(d))
    # P3: EX-99.x with AIF/annual in the filename (prefer "aif").
    named = filter(d -> startswith(d.type, "EX-99") && occursin(r"aif|annual"i, d.filename), html)
    if !isempty(named)
        sp = filter(d -> occursin("aif", lowercase(d.filename)), named)
        return _fetch_text(_url(isempty(sp) ? named[1] : sp[1]))
    end
    # P4: content-sniff the major EX-99.x exhibits for NI 51-102 headings.
    for d in filter(d -> startswith(d.type, "EX-99") && d.size > _MAJOR_EXHIBIT_THRESHOLD, html)
        _has_aif_content(_url(d)) && return _fetch_text(_url(d))
    end
    # P5: inline AIF in the main 40-F document, else the first major exhibit.
    (d = pick(d -> d.type in ("40-F", "40-F/A"))) !== nothing && return _fetch_text(_url(d))
    major = filter(d -> d.size > _MAJOR_EXHIBIT_THRESHOLD, html)
    return isempty(major) ? nothing : _fetch_text(_url(major[1]))
end

_fetch_text(url) = (b = fetch_url(url); b === nothing ? nothing : String(b))

# --- AIF section extraction — faithful port of forty_f.py's plain-text pipeline -------------------------
# EzXML (libxml2) renders the AIF HTML to text (`_aif_plain_text`, matching bs4 `get_text()`); the section
# detection below is a verbatim translation of forty_f.py (`_find_section_positions` / `_extract_section_text` with the
# `_is_toc_entry` / `_is_cross_reference` filters). Patterns are forty_f.py's `_SECTION_PATTERNS`.

const _AIF_SECTION_PATTERNS = Regex[
    r"CORPORATE\s+STRUCTURE"i,
    r"GENERAL\s+DEVELOPMENT\s+OF\s+(?:THE\s+)?(?:[\w\-][\w\-'’]*\s+)?BUSINESS"i,
    r"(?:NARRATIVE\s+)?DESCRIPTION\s+OF\s+(?:THE\s+)?(?:\w[\w'’]*\s+)?BUSINESS(?:ES)?"i,
    r"BUSINESS\s+OF\s+(?:THE\s+)?(?:[\w][\w'’]*(?:\s+[\w][\w'’]*){0,3})"i,
    r"BUSINESS\s+OPERATIONS"i,
    r"DESCRIPTION\s+OF\s+CAPITAL\s+STRUCTURE"i,
    r"MARKET\s+FOR\s+SECURITIES"i,
    r"DIVIDENDS(?:\s+AND\s+DISTRIBUTIONS)?"i,
    r"DIRECTORS\s+AND\s+(?:EXECUTIVE\s+OFFICERS|OFFICERS|EXECUTIVE)"i,
    r"RISK\s+FACTORS"i,
    r"LEGAL\s+(?:PROCEEDINGS|MATTERS)"i,
    r"MATERIAL\s+PROPERTIES"i,
    r"CODE\s+OF\s+BUSINESS\s+CONDUCT"i,
    r"BUSINESS\s+OVERVIEW"i,
]

# Safe substring covering roughly byte range [a, b] (snapped to char boundaries).
function _span(text::AbstractString, a::Int, b::Int)
    nb = ncodeunits(text)
    a < 1 && (a = 1); b > nb && (b = nb)
    a > b && return ""
    ta = thisind(text, a); ta < a && (ta = nextind(text, ta))
    tb = thisind(text, b)
    return ta > tb ? "" : String(SubString(text, ta, tb))
end

# forty_f.py `_is_toc_entry`
function _aif_is_toc(text, m)
    after = _span(text, m.offset + ncodeunits(m.match), m.offset + ncodeunits(m.match) + 500)
    stripped = lstrip(after)
    if match(r"^\d+[.]\d", stripped) === nothing && match(r"^\d+(?:\s|$|[A-Z])", stripped) !== nothing
        return true
    end
    pn = collect(eachmatch(r"(?:^|\n)\s* ?\s*(\d{1,3}(?:[\-–—]\d{1,3})?)\s* ?\s*(?:\n|$)",
                           first(after, 300)))
    return length(pn) >= 2
end

# forty_f.py `_is_cross_reference`
function _aif_is_xref(text, m)
    before = _span(text, m.offset - 80, m.offset - 1)
    match(r"[\"“”]\s*$", before) !== nothing && return true
    match(r"\b(?:see|under)\s+[\"“]?\s*$"i, before) !== nothing && return true
    match(r"[\"“](?:Section|Item|Appendix)\s"i, before) !== nothing && return true
    ln = findlast('\n', before)
    gap = ln === nothing ? before : SubString(before, nextind(before, ln))
    if !isempty(strip(gap))
        match(r"[a-z][,;:]\s*$", gap) !== nothing && return true
        if match(r"[a-z]\s+$", gap) !== nothing
            words = split(strip(gap))
            !isempty(words) && islowercase(first(words[end])) && return true
        end
    end
    return false
end

# forty_f.py `_find_first_clean_match`
function _aif_first_clean(text, pat, minpos)
    for m in eachmatch(pat, text)
        m.offset > minpos && !_aif_is_toc(text, m) && !_aif_is_xref(text, m) && return m
    end
    return nothing
end

# forty_f.py `_find_section_positions`
function _aif_positions(text)
    minpos = min(max(5000, round(Int, ncodeunits(text) * 0.03)), 10_000)
    found = Tuple{Int,String}[]
    for pat in _AIF_SECTION_PATTERNS
        m = _aif_first_clean(text, pat, minpos)
        m !== nothing && push!(found, (m.offset, strip(replace(m.match, r"\s+" => " "))))
    end
    sort!(found, by = first)
    deduped = Tuple{Int,String}[]
    for (pos, name) in found
        (!isempty(deduped) && pos - deduped[end][1] < 200) && continue
        push!(deduped, (pos, name))
    end
    return deduped
end

# forty_f.py `_extract_section_text`
function _aif_section_text(text, positions, idx)
    start = positions[idx][1]
    stop = idx < length(positions) ? positions[idx + 1][1] - 1 : ncodeunits(text)
    return strip(replace(_span(text, start, stop), r"\s+" => " "))
end

# Plain text the way forty_f.py's `aif_text` does it: `BeautifulSoup(html, 'html.parser').get_text()` — every
# text node concatenated verbatim (default separator "", no whitespace folding, INCLUDING <script>/<style>
# text), preserving the source's whitespace/newlines so the position-based heuristics below line up. EzXML
# (libxml2) `nodecontent` is the faithful equivalent; Gumbo's walk skipped script/style and diverged.
function _aif_plain_text(html::AbstractString)
    s = String(html)
    startswith(s, "<?xml") && (s = replace(s, r"<\?xml[^>]*\?>" => ""; count = 1))
    return EzXML.nodecontent(EzXML.root(EzXML.parsehtml(s)))
end

"""
    forty_f_sections(f::Filing) -> Vector{@NamedTuple{item::String, text::String}}

Segment a 40-F's Annual Information Form into its NI 51-102 sections — a faithful port of edgartools'
`forty_f.py` plain-text pipeline, run on the AIF's `get_text()` rendering (same as edgartools).
"""
function forty_f_sections(f::Filing)
    aif = aif_html(f)
    aif === nothing && return @NamedTuple{item::String, text::String}[]
    text = _aif_plain_text(aif)
    pos = _aif_positions(text)
    return [(item = titlecase(pos[i][2]), text = _aif_section_text(text, pos, i)) for i in eachindex(pos)]
end
