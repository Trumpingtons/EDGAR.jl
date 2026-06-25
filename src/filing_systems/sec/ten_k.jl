# Faithful translation of edgartools' company_reports/ten_k.py (TenK) — the company-reports view of a
# Form 10-K, parallel to TwentyF. `tk_section`/`tk_items` reproduce `TenK.__getitem__`/`TenK.items`: prefer
# the Documents parser's `sections` (part-prefixed/friendly keys), then the cross-reference index
# (GE/Henry-Schein class), then the deprecated ChunkedDocument. The Financials/statement-object layer and
# `to_context` are omitted (they depend on display/financials code not ported here), exactly as in the
# TwentyF port. 🔵 SEC-specific. Reuses `FilingStructure` (twenty_f.jl) and the cross_reference.jl helpers.

const _TENK_STRUCTURE = FilingStructure(Dict{String,Any}(
    "PART I" => Dict("ITEM 1" => Dict("Title" => "Business"),
        "ITEM 1A" => Dict("Title" => "Risk Factors"),
        "ITEM 1B" => Dict("Title" => "Unresolved Staff Comments"),
        "ITEM 1C" => Dict("Title" => "Cybersecurity"),
        "ITEM 2" => Dict("Title" => "Properties"),
        "ITEM 3" => Dict("Title" => "Legal Proceedings"),
        "ITEM 4" => Dict("Title" => "Mine Safety Disclosures")),
    "PART II" => Dict("ITEM 5" => Dict("Title" => "Market for Registrant's Common Equity"),
        "ITEM 6" => Dict("Title" => "Selected Financial Data"),
        "ITEM 7" => Dict("Title" => "Management's Discussion and Analysis (MD&A)"),
        "ITEM 7A" => Dict("Title" => "Quantitative and Qualitative Disclosures About Market Risk"),
        "ITEM 8" => Dict("Title" => "Financial Statements"),
        "ITEM 9" => Dict("Title" => "Controls and Procedures"),
        "ITEM 9A" => Dict("Title" => "Controls and Procedures"),
        "ITEM 9B" => Dict("Title" => "Other Information"),
        "ITEM 9C" => Dict("Title" => "Disclosure Regarding Foreign Jurisdictions That Prevent Inspections")),
    "PART III" => Dict("ITEM 10" => Dict("Title" => "Directors, Executive Officers, and Corporate Governance"),
        "ITEM 11" => Dict("Title" => "Executive Compensation"),
        "ITEM 12" => Dict("Title" => "Security Ownership of Certain Beneficial Owners and Management"),
        "ITEM 13" => Dict("Title" => "Certain Relationships and Related Transactions, and Director Independence"),
        "ITEM 14" => Dict("Title" => "Principal Accounting Fees and Services")),
    "PART IV" => Dict("ITEM 15" => Dict("Title" => "Exhibits, Financial Statement Schedules"),
        "ITEM 16" => Dict("Title" => "Form 10-K Summary"))))

# ten_k.py item<->friendly-name maps (verbatim).
const _TENK_ITEM_TO_SECTION = Dict(
    "Item 1" => "business", "Item 1A" => "risk_factors", "Item 1B" => "unresolved_staff_comments",
    "Item 1C" => "cybersecurity", "Item 2" => "properties", "Item 3" => "legal_proceedings",
    "Item 4" => "mine_safety", "Item 5" => "market_equity", "Item 6" => "selected_financial_data",
    "Item 7" => "mda", "Item 7A" => "market_risk", "Item 8" => "financial_statements",
    "Item 9" => "controls_procedures", "Item 9A" => "controls_procedures_9a",
    "Item 9B" => "other_information", "Item 9C" => "foreign_jurisdictions",
    "Item 10" => "directors_officers", "Item 11" => "executive_compensation",
    "Item 12" => "security_ownership", "Item 13" => "relationships_transactions",
    "Item 14" => "accounting_fees", "Item 15" => "exhibits", "Item 16" => "summary")
const _TENK_SECTION_TO_ITEM = Dict(v => k for (k, v) in _TENK_ITEM_TO_SECTION)
# _CROSS_REF_ITEM_MAP — "Item 1A" -> "1A" (the cross-reference index's item ids).
const _TENK_CROSS_REF_ITEM_MAP = Dict(k => strip(k[6:end]) for k in keys(_TENK_ITEM_TO_SECTION))

"""
    TenK(f::Filing)

The company-reports view of a Form 10-K — a faithful port of edgartools' `TenK`. Use [`tk_items`](@ref)
and `tk_section(tk, "Item 7")`. Items prefer the [`Documents`](@ref) parser's `sections`, then the
cross-reference index (GE-class filings), then the ChunkedDocument segmentation — exactly as edgartools does.
"""
mutable struct TenK
    filing::Filing
    structure::FilingStructure
    _document::Any
    _document_set::Bool
    _chunked::Any
    _chunked_set::Bool
    _xref::Any
    _xref_set::Bool
end
TenK(f::Filing) = TenK(f, _TENK_STRUCTURE, nothing, false, nothing, false, nothing, false)

# TenK.document — the Documents HTMLParser at form=10-K.
function tk_document(tk::TenK)
    if !tk._document_set
        html = tk.filing.content
        tk._document = isempty(html) ? nothing : Documents.parse_filing(Documents.HTMLParser(), html; form = "10-K")
        tk._document_set = true
    end
    return tk._document
end

# TenK.sections — the Documents parser's detected sections (Dict name=>Section), or empty.
tk_sections(tk::TenK) = (doc = tk_document(tk); doc === nothing ? Documents.Sections() : Documents.sections(doc))

# TenK.chunked_document — the faithful ChunkedDocument port.
function tk_chunked(tk::TenK)
    if !tk._chunked_set
        tk._chunked = isempty(tk.filing.content) ? nothing :
                      ChunkedDoc.ChunkedDocument(tk.filing.content; item_detector = ChunkedDoc.detect_int_item)
        tk._chunked_set = true
    end
    return tk._chunked
end

# TenK._cross_reference_index — parsed cross-reference index (entries + page breaks), or nothing.
function tk_cross_ref(tk::TenK)
    if !tk._xref_set
        html = tk.filing.content
        tk._xref = (!isempty(html) && _has_cross_ref_index(html)) ?
                   (entries = _parse_index(html), breaks = _find_page_breaks(html), html = html) : nothing
        tk._xref_set = true
    end
    return tk._xref
end

# __getitem__'s trailing-PART cleanup: rstrip, then (edgartools quirk) rstrip the SET of chars in the last
# line when that line begins with "PART <roman>".
function _tk_clean_tail(text::AbstractString)
    text = rstrip(text)
    last_line = last(split(text, "\n"; keepempty = true))
    if match(r"^\s*PART\s+[IVXLC]+\b"i, last_line) !== nothing
        text = rstrip(text, Set(last_line))
    end
    return text
end

"""
    tk_items(tk::TenK) -> Vector{String}

Detected item names in `"Item X"` form — faithful port of `TenK.items`: maps Documents-parser sections to
item numbers, falling back to the ChunkedDocument segmentation.
"""
function tk_items(tk::TenK)
    secs = tk_sections(tk)
    if !isempty(secs)
        items = String[]
        for (key, section) in secs
            if section.item !== nothing && !isempty(section.item)
                push!(items, "Item $(section.item)")
            elseif haskey(_TENK_SECTION_TO_ITEM, key)
                push!(items, _TENK_SECTION_TO_ITEM[key])
            elseif startswith(key, "Item ")
                push!(items, key)
            end
        end
        isempty(items) || return items
    end
    cd = tk_chunked(tk)
    return cd === nothing ? String[] : ChunkedDoc.list_items(cd)
end

"""
    tk_section(tk::TenK, item_or_part) -> Union{String,Nothing}

Text of a 10-K item by name/number (`"Item 7"`, `"7"`, `"mda"`, …) — faithful port of `TenK.__getitem__`.
For cross-reference-index (GE-class) filings the result is the page-range HTML, exactly as edgartools returns.
"""
function tk_section(tk::TenK, item_or_part::AbstractString)
    secs = tk_sections(tk)
    if !isempty(secs)
        normalized = strip(item_or_part)
        # item number ("1", "1a") from "Item X" / short / friendly name
        item_num = nothing
        if startswith(normalized, "Item ")
            item_num = lowercase(strip(normalized[6:end]))
        elseif match(r"^\d+[A-Za-z]?$", normalized) !== nothing
            item_num = lowercase(normalized)
        elseif haskey(_TENK_SECTION_TO_ITEM, normalized)
            item_num = lowercase(strip(_TENK_SECTION_TO_ITEM[normalized][6:end]))
        end
        if item_num !== nothing
            # PRIORITY 1: part-prefixed keys.
            for p in ("i", "ii", "iii", "iv")
                key = "part_$(p)_item_$(item_num)"
                if haskey(secs, key)
                    t = Documents.section_text(secs[key])
                    isempty(strip(t)) || return t
                end
            end
            # PRIORITY 1.5: combined-items keys (e.g. part_i_items_1_and_2).
            cpat = Regex("part_[iv]+_items_(?:$(item_num)_and_\\d+|\\d+_and_$(item_num))")
            for key in keys(secs)
                if match(cpat, key) !== nothing
                    t = Documents.section_text(secs[key])
                    isempty(strip(t)) || return t
                end
            end
        end
        # PRIORITY 2: direct key.
        haskey(secs, item_or_part) && return Documents.section_text(secs[item_or_part])
        # PRIORITY 3: friendly name -> Item key.
        if haskey(_TENK_SECTION_TO_ITEM, item_or_part)
            ik = _TENK_SECTION_TO_ITEM[item_or_part]
            haskey(secs, ik) && return Documents.section_text(secs[ik])
        end
        # PRIORITY 4: "Item X" -> friendly name.
        if haskey(_TENK_ITEM_TO_SECTION, normalized)
            fn = _TENK_ITEM_TO_SECTION[normalized]
            haskey(secs, fn) && return Documents.section_text(secs[fn])
        end
        # PRIORITY 5: short "1"/"1A" -> "Item X" / friendly.
        if match(r"^\d+[A-Za-z]?$", normalized) !== nothing
            ik = "Item $(uppercase(normalized))"
            haskey(secs, ik) && return Documents.section_text(secs[ik])
            if haskey(_TENK_ITEM_TO_SECTION, ik)
                fn = _TENK_ITEM_TO_SECTION[ik]
                haskey(secs, fn) && return Documents.section_text(secs[fn])
            end
        end
    end
    # Cross Reference Index (GE/Henry Schein).
    xref = tk_cross_ref(tk)
    if xref !== nothing
        item_id = get(_TENK_CROSS_REF_ITEM_MAP, item_or_part, nothing)
        if item_id !== nothing
            idx = findfirst(e -> e.item_number == item_id, xref.entries)
            if idx !== nothing
                it = _extract_item_content(xref.html, xref.breaks, xref.entries[idx])
                it !== nothing && return _tk_clean_tail(it)
            end
        end
    end
    # ChunkedDocument fallback.
    cd = tk_chunked(tk)
    if cd !== nothing
        it = ChunkedDoc.getindex_item(cd, item_or_part)
        it !== nothing && return _tk_clean_tail(it)
    end
    return nothing
end

# Convenience accessors (faithful to TenK's properties).
business(tk::TenK) = tk_section(tk, "Item 1")
risk_factors(tk::TenK) = tk_section(tk, "Item 1A")
management_discussion(tk::TenK) = tk_section(tk, "Item 7")
directors_officers_and_governance(tk::TenK) = tk_section(tk, "Item 10")
