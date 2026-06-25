# Form 6-K cover page — a faithful port of edgartools' company_reports/sixk.py (`_parse_cover_page`).
# A 6-K (Report of Foreign Private Issuer) has no numbered item structure; its substance is in exhibits
# (see [`exhibits`](@ref) / [`press_releases`](@ref)) and a handful of cover-page metadata fields. This
# extracts those fields from the cover text. 🟢 jurisdiction-agnostic (operates on already-fetched text).

"""
    sixk_cover(f::Filing) -> @NamedTuple{commission_file_number, report_month, annual_report_form, content_description}

Parse a Form 6-K's cover page — a faithful port of edgartools' `_parse_cover_page`. Returns the SEC
`commission_file_number`, the `report_month` ("For the month of …"), which annual form the issuer files
(`annual_report_form`, `"20-F"` / `"40-F"` per the cover's check mark), and a `content_description` of the
material contained. Each field is a `String`, or `nothing` when the cover does not state it.
"""
# `clean_text` (not `html_to_text`) is used so HTML entities are decoded — the cover-page text edgartools
# reads via lxml's `text_content()` is entity-decoded, and the checkmark / `&nbsp;` separators that the
# field regexes straddle only match once decoded.
sixk_cover(f::Filing) = _parse_cover_page(clean_text(f.content))

function _parse_cover_page(text::AbstractString)
    cfn = nothing; month = nothing; form = nothing; desc = nothing
    if !isempty(text)
        m = match(r"Commission\s+File\s+Number[:\s]+([\d\-]+)"i, text)
        m !== nothing && (cfn = String(strip(m.captures[1])))
        m = match(r"For\s+the\s+month\s+of\s+([A-Za-z]+(?:\s+\d{4})?)"i, text)
        m !== nothing && (month = String(strip(m.captures[1])))
        if match(r"Form\s*20-?F\s+\[?\s*X\s*\]?"i, text) !== nothing
            form = "20-F"
        elseif match(r"Form\s*40-?F\s+\[?\s*X\s*\]?"i, text) !== nothing
            form = "40-F"
        end
        m = match(r"(?is)(?:Material\s+Contained\s+in\s+this\s+Report|Exhibit\s+Description)[:\s]*(.*?)(?=SIGNATURES|SIGNATURE\b)", text)
        if m !== nothing
            d = strip(replace(String(m.captures[1]), r"\s+" => " "))
            d = replace(d, r"[\s─\-]+$" => "")
            length(d) > 5 && (desc = String(d))
        end
    end
    return (commission_file_number = cfn, report_month = month,
            annual_report_form = form, content_description = desc)
end
