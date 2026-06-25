# Faithful translation of edgartools' company_reports/twenty_f.py (TwentyF) + the FilingStructure it uses
# (_structures.py). This is the company-reports view of a 20-F — distinct from the raw document parser:
# `items`/`__getitem__` PREFER the ChunkedDocument segmentation (EDGAR's `sections(::AbstractString)`,
# the faithful ChunkedDocument port) because the pattern/TOC document parser handles the 20-F TOC poorly,
# falling back to `document.sections` (the Documents parser). This is why `obj()[item]` exposes all ~31
# items while `document.sections` alone yields fewer. 🔵 SEC-specific.
# NOTE: `to_context` (the AI-context string) is omitted — it depends on the Financials/display layer not
# ported here; everything governing section/item extraction is translated exactly.

# --- _structures.FilingStructure (used as TwentyF.structure) -------------------------------------------
struct FilingStructure
    structure::Dict{String,Any}
end
get_part(fs::FilingStructure, part::AbstractString) = get(fs.structure, uppercase(part), nothing)
function get_item(fs::FilingStructure, item::AbstractString, part = nothing)
    item = uppercase(item)
    if part !== nothing
        pd = get_part(fs, part)
        return pd === nothing ? nothing : get(pd, item, nothing)
    end
    for (_, items) in fs.structure
        haskey(items, item) && return items[item]
    end
    return nothing
end
is_valid_item(fs::FilingStructure, item::AbstractString, part = nothing) = get_item(fs, item, part) !== nothing

const _TWENTYF_STRUCTURE = FilingStructure(Dict{String,Any}(
    "PART I" => Dict("ITEM 1" => Dict("Title" => "Identity of Directors, Senior Management, and Advisers"),
        "ITEM 2" => Dict("Title" => "Offer Statistics and Expected Timetable"),
        "ITEM 3" => Dict("Title" => "Key Information"),
        "ITEM 4" => Dict("Title" => "Information on the Company"),
        "ITEM 4A" => Dict("Title" => "Unresolved Staff Comments")),
    "PART II" => Dict("ITEM 5" => Dict("Title" => "Operating and Financial Review and Prospects"),
        "ITEM 6" => Dict("Title" => "Directors, Senior Management, and Employees"),
        "ITEM 7" => Dict("Title" => "Major Shareholders and Related Party Transactions"),
        "ITEM 8" => Dict("Title" => "Financial Information"),
        "ITEM 9" => Dict("Title" => "The Offer and Listing")),
    "PART III" => Dict("ITEM 10" => Dict("Title" => "Additional Information"),
        "ITEM 11" => Dict("Title" => "Quantitative and Qualitative Disclosures About Market Risk"),
        "ITEM 12" => Dict("Title" => "Description of Securities Other Than Equity Securities")),
    "PART IV" => Dict("ITEM 13" => Dict("Title" => "Defaults, Dividend Arrearages, and Delinquencies"),
        "ITEM 14" => Dict("Title" => "Material Modifications to the Rights of Security Holders and Use of Proceeds"),
        "ITEM 15" => Dict("Title" => "Controls and Procedures"),
        "ITEM 16" => Dict("Title" => "Various Disclosures")),
    "PART V" => Dict("ITEM 17" => Dict("Title" => "Financial Statements"),
        "ITEM 18" => Dict("Title" => "Financial Statements"),
        "ITEM 19" => Dict("Title" => "Exhibits"))))

"""
    TwentyF(f::Filing)

The company-reports view of a Form 20-F — a faithful port of edgartools' `TwentyF`. Use [`tf_items`](@ref),
`tf_section(tf, "Item 5")`, and the convenience accessors. Mirrors edgartools: items prefer the
ChunkedDocument segmentation, falling back to the Documents parser's `sections`.
"""
mutable struct TwentyF
    filing::Filing
    structure::FilingStructure
    _document::Any            # cached Documents.Document
    _document_set::Bool
    _chunked::Any             # cached ChunkedDocument items (Vector of (item,title,text))
    _chunked_set::Bool
end
TwentyF(f::Filing) = TwentyF(f, _TWENTYF_STRUCTURE, nothing, false, nothing, false)

# TwentyF.document — parse with the Documents HTMLParser at form=20-F.
function tf_document(tf::TwentyF)
    if !tf._document_set
        html = tf.filing.content
        tf._document = isempty(html) ? nothing : Documents.parse_filing(Documents.HTMLParser(), html; form = "20-F")
        tf._document_set = true
    end
    return tf._document
end

# TwentyF.sections — the Documents parser's detected sections (Dict name=>Section), or empty.
function tf_sections(tf::TwentyF)
    doc = tf_document(tf)
    return doc === nothing ? Documents.Sections() : Documents.sections(doc)
end

# CompanyReport.chunked_document — EDGAR's faithful ChunkedDocument port (chunked_document.jl, on EzXML).
function tf_chunked(tf::TwentyF)
    if !tf._chunked_set
        tf._chunked = isempty(tf.filing.content) ? nothing :
                      ChunkedDoc.ChunkedDocument(tf.filing.content; item_detector = ChunkedDoc.detect_int_item)
        tf._chunked_set = true
    end
    return tf._chunked
end

_chunked_list_items(tf::TwentyF) = (cd = tf_chunked(tf); cd === nothing ? String[] : ChunkedDoc.list_items(cd))
_chunked_getitem(tf::TwentyF, item_name::AbstractString) =
    (cd = tf_chunked(tf); cd === nothing ? nothing : ChunkedDoc.getindex_item(cd, item_name))

"""
    tf_items(tf::TwentyF) -> Vector{String}

Detected item names. Prefers the ChunkedDocument segmentation (best for the 20-F TOC format), falling
back to the Documents parser's sections. Faithful port of `TwentyF.items`.
"""
function tf_items(tf::TwentyF)
    ci = _chunked_list_items(tf)
    isempty(ci) || return ci
    secs = tf_sections(tf)
    if !isempty(secs)
        return extract_items_from_sections(collect(values(secs)), r"(Item\s+\d+[A-Z]?)"i)
    end
    return String[]
end

"""
    tf_section(tf::TwentyF, item_name) -> Union{String,Nothing}

Text of a section by item name/number (`"Item 5"`, `"5"`, `"item_5"`, …) — faithful port of
`TwentyF.__getitem__`: tries the Documents parser's sections (direct key, part-prefixed, item key,
friendly key), then falls back to the ChunkedDocument segmentation.
"""
function tf_section(tf::TwentyF, item_name::AbstractString)
    secs = tf_sections(tf)
    if !isempty(secs)
        haskey(secs, item_name) && return Documents.section_text(secs[item_name])
        m = match(r"(?:item\s*)?(\d+[a-z]?)"i, lowercase(strip(item_name)))
        if m !== nothing
            item_num = lowercase(m.captures[1])
            for part in ("i", "ii", "iii", "iv", "v")
                key = "part_$(part)_item_$(item_num)"
                haskey(secs, key) && return Documents.section_text(secs[key])
            end
            item_key = "item_$(item_num)"
            haskey(secs, item_key) && return Documents.section_text(secs[item_key])
            friendly_key = "Item $(uppercase(item_num))"
            haskey(secs, friendly_key) && return Documents.section_text(secs[friendly_key])
        end
    end
    return _chunked_getitem(tf, item_name)
end

# Convenience accessors (faithful to TwentyF's properties).
key_information(tf::TwentyF) = tf_section(tf, "Item 3")
risk_factors(tf::TwentyF) = tf_section(tf, "Item 3")
business(tf::TwentyF) = tf_section(tf, "Item 4")
company_information(tf::TwentyF) = tf_section(tf, "Item 4")
operating_review(tf::TwentyF) = tf_section(tf, "Item 5")
management_discussion(tf::TwentyF) = tf_section(tf, "Item 5")
directors_and_employees(tf::TwentyF) = tf_section(tf, "Item 6")
major_shareholders(tf::TwentyF) = tf_section(tf, "Item 7")
financial_information(tf::TwentyF) = tf_section(tf, "Item 8")
controls_and_procedures(tf::TwentyF) = tf_section(tf, "Item 15")
