# Faithful translation of edgartools' edgar/documents/strategies/table_processing.py.
# Converts an HTML <table> element into a TableNode: header/body/footer rows, cell colspan/rowspan, cell
# text (br→newline, entity cleanup, whitespace normalisation), multi-row-header detection, and table-type
# classification. Operates on EzXML elements via the lxml accessors in ezxml_dom.jl.

const _TP_ENTITY_REPLACEMENTS = [
    "&horbar;" => "-----", "&mdash;" => "-----", "&ndash;" => "---", "&minus;" => "-",
    "&hyphen;" => "-", "&dash;" => "-", "&nbsp;" => " ", "&amp;" => "&", "&lt;" => "<",
    "&gt;" => ">", "&quot;" => "\"", "&apos;" => "'", "&#8202;" => " ", "&#8203;" => "",
    "&#x2014;" => "-----", "&#x2013;" => "---", "&#x2212;" => "-",
]

const _TP_FINANCIAL_KEYWORDS = Set([
    "revenue", "income", "expense", "asset", "liability", "cash", "equity", "profit", "loss", "margin",
    "earnings", "cost", "sales", "operating", "net", "gross", "total", "balance", "statement", "consolidated",
    "provision", "tax", "taxes", "compensation", "stock", "share", "shares", "rsu", "option", "grant", "vest"])

const _TP_METRICS_KEYWORDS = Set([
    "ratio", "percentage", "percent", "%", "rate", "growth", "change", "increase", "decrease",
    "average", "median", "total", "count", "number"])

struct TableProcessor
    config::ParserConfig
end

function process(p::TableProcessor, element)::TableNode
    table_style = parse_style(_attr(element, "style", ""))
    table = TableNode(style = table_style)
    table_id = _attr(element, "id")
    table_class = split(_attr(element, "class", ""))
    table_id !== nothing && set_metadata!(table, "id", table_id)
    !isempty(table_class) && set_metadata!(table, "classes", table_class)
    caption_elem = _findfirst(element, ".//caption")
    caption_elem !== nothing && (table.caption = _extract_text(p, caption_elem))
    summary = _attr(element, "summary")
    summary !== nothing && (table.summary = summary)
    _process_table_structure!(p, element, table)
    p.config.detect_table_types && (table.table_type = _detect_table_type(p, table))
    p.config.extract_table_relationships && _extract_relationships!(p, table)
    return table
end

function _process_table_structure!(p::TableProcessor, element, table::TableNode)
    thead = _findfirst(element, ".//thead")
    if thead !== nothing
        for tr in _findall(thead, ".//tr")
            cells = _process_row(p, tr, true)
            isempty(cells) || push!(table.headers, cells)
        end
    end
    tbody = _findfirst(element, ".//tbody")
    rows_container = tbody !== nothing ? tbody : element
    headers_found = !isempty(table.headers)
    data_rows_started = false
    for tr in _findall(rows_container, ".//tr")
        (thead !== nothing && _getparent(tr) !== nothing && _same(_getparent(tr), thead)) && continue
        is_header_row = false
        if !data_rows_started
            is_header_row = _is_header_row(p, tr)
            if headers_found && !is_header_row
                row_text = strip(_text_content(tr))
                if occursin("(in millions)", row_text) || occursin("(in thousands)", row_text) || occursin("(in billions)", row_text)
                    is_header_row = true
                elseif !isempty(table.headers)
                    last_header_text = join((cell_text(c) for c in table.headers[end]), " ")
                    if occursin("year ended", lowercase(last_header_text)) || occursin("years ended", lowercase(last_header_text))
                        years_found = collect(eachmatch(r"\b(19\d{2}|20\d{2})\b", row_text))
                        isempty(years_found) || (is_header_row = true)
                    end
                end
            end
        end
        cells = _process_row(p, tr, is_header_row)
        if !isempty(cells)
            if is_header_row
                push!(table.headers, cells); headers_found = true
            else
                push!(table.rows, Row(cells = cells, is_header = false))
                has_content = any(c -> !isempty(strip(cell_text(c))), cells)
                if has_content
                    row_text = strip(join((strip(cell_text(c)) for c in cells), " "))
                    rl = lowercase(row_text)
                    is_header_related = (
                        occursin("(in millions)", rl) || occursin("(in thousands)", rl) || occursin("(in billions)", rl) ||
                        occursin("except per share", rl) || occursin("year ended", rl) || occursin("months ended", rl) ||
                        length(strip(row_text)) < 5 || match(r"\b(19\d{2}|20\d{2})\b", row_text) !== nothing)
                    is_header_related || (data_rows_started = true)
                end
            end
        end
    end
    tfoot = _findfirst(element, ".//tfoot")
    if tfoot !== nothing
        for tr in _findall(tfoot, ".//tr")
            cells = _process_row(p, tr, false)
            isempty(cells) || push!(table.footer, Row(cells = cells, is_header = false))
        end
    end
    return nothing
end

function _process_row(p::TableProcessor, tr, is_header::Bool)
    cells = Cell[]
    for cell_elem in vcat(_findall(tr, ".//td"), _findall(tr, ".//th"))
        push!(cells, _process_cell(p, cell_elem, is_header || _tag(cell_elem) == "th"))
    end
    return cells
end

function _process_cell(p::TableProcessor, elem, is_header::Bool)
    colspan_str = strip(_attr(elem, "colspan", "1"))
    rowspan_str = strip(_attr(elem, "rowspan", "1"))
    colspan = (!isempty(colspan_str) && _py_isdigit(colspan_str)) ? parse(Int, colspan_str) : 1
    rowspan = (!isempty(rowspan_str) && _py_isdigit(rowspan_str)) ? parse(Int, rowspan_str) : 1
    align = _attr(elem, "align")
    style = parse_style(_attr(elem, "style", ""))
    style.text_align !== nothing && (align = style.text_align)
    content = _extract_cell_content(p, elem)
    return Cell(content = content, colspan = colspan, rowspan = rowspan, is_header = is_header, align = align)
end

function _extract_cell_content(p::TableProcessor, elem)
    divs = _findall(elem, ".//div")
    if length(divs) > 1
        lines = String[]
        for div in divs
            t = _extract_text(p, div)
            isempty(t) || push!(lines, t)
        end
        return join(lines, "\n")
    end
    # br -> newline (Python mutates br.tail; we emit "\n" at each br position, same fragment order)
    return _finish_text(_itertext_br(elem))
end

# _extract_text — itertext fragments with whitespace-aware join, entity cleanup, whitespace normalisation.
_extract_text(p::TableProcessor, elem) = _finish_text(_itertext(elem))

function _finish_text(text_parts::Vector{String})
    isempty(text_parts) && return ""
    result = String[]
    for (i, part) in enumerate(text_parts)
        if i == 1
            push!(result, part)
        else
            prev_part = text_parts[i - 1]
            if !isempty(prev_part) && !isempty(part)
                if !isspace(last(prev_part)) && !isspace(first(part))
                    first(part) in (',', '.', ';', ':', '!', '?', '%', ')', ']') || push!(result, " ")
                end
            end
            push!(result, part)
        end
    end
    text = join(result, "")
    for (entity, replacement) in _TP_ENTITY_REPLACEMENTS
        text = replace(text, entity => replacement)
    end
    text = strip(text)
    cleaned_lines = [join(split(line), " ") for line in split(text, '\n')]
    return join(cleaned_lines, "\n")
end

# Comprehensive financial period-header regex (cached lru in Python).
const _PERIOD_HEADER_PATTERN = let
    periods = "(?:three|six|nine|twelve|[1-4]|first|second|third|fourth)"
    timeframes = "(?:month|quarter|year|week)"
    ended = "(?:ended|ending|end|period)"
    as_of = "(?:as\\s+of|at|as\\s+at)"
    months = "(?:january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)"
    day = "\\d{1,2}"; year = "(?:19|20)\\d{2}"
    date = "$months\\s*\\.?\\s*$day\\s*,?\\s*$year"
    pats = [
        "$periods\\s+$timeframes\\s+$ended(?:\\s+$date)?",
        "(?:fiscal\\s+)?$timeframes\\s+$ended",
        "$timeframes\\s+$ended(?:\\s+$date)?",
        "$as_of\\s+$date",
        "$date(?:\\s*(?:and|,)\\s*$date)*",
        "(?:$ended\\s+)?$date",
    ]
    Regex(join(("(?:$p)" for p in pats), "|"), "i")
end

function _is_header_row(p::TableProcessor, tr)
    _findfirst(tr, ".//th") !== nothing && return true
    cells = _findall(tr, ".//td")
    isempty(cells) && return false
    row_text = _text_content(tr)
    rl = lowercase(row_text)
    date_range = r"(?:january|february|march|april|may|june|july|august|september|october|november|december)\s+\d{1,2},\s*\d{4}\s*[—–-]\s*(?:january|february|march|april|may|june|july|august|september|october|november|december)\s+\d{1,2},\s*\d{4}"
    has_date_range = match(date_range, rl) !== nothing
    has_currency = match(r"\$[\s]*[\d,\.]+", row_text) !== nothing
    has_decimals = match(r"\b\d+\.\d+\b", row_text) !== nothing
    has_large_numbers = match(r"\b\d{1,3}(,\d{3})+\b", row_text) !== nothing
    (has_date_range && (has_currency || has_decimals || has_large_numbers)) && return false
    years_found = [m.captures[1] for m in eachmatch(r"\b(19\d{2}|20\d{2})\b", row_text)]
    if length(years_found) >= 2
        if length(unique(years_found)) == 1
            # same year repeated (date range) — not a multi-year header
        elseif !occursin("total", first(rl, 20))
            return true
        end
    end
    year_cells = 0; date_phrases = 0
    for cell in cells
        ct = strip(_text_content(cell))
        if !isempty(ct)
            if match(r"^\s*(19\d{2}|20\d{2})\s*$", ct) !== nothing
                year_cells += 1
            elseif occursin("june 30", lowercase(ct)) || occursin("december 31", lowercase(ct))
                date_phrases += 1
            end
        end
    end
    if year_cells >= 2 || (year_cells >= 1 && date_phrases >= 1)
        occursin("total", first(rl, 20)) || return true
    end
    if match(_PERIOD_HEADER_PATTERN, rl) !== nothing
        data_pattern = r"(?:\$\s*\d|\d+(?:,\d{3})+|\d+\s*[+\-*/]\s*\d+|\(\s*\d+(?:,\d{3})*\s*\))"
        match(data_pattern, row_text) === nothing && return true
    end
    match(r"\(in\s+(?:millions|thousands|billions)\)", rl) !== nothing && return true
    period_keywords = ("quarter", "q1", "q2", "q3", "q4", "month", "january", "february", "march", "april",
        "may", "june", "july", "august", "september", "october", "november", "december", "ended",
        "three months", "six months", "nine months")
    if occursin("fiscal", rl)
        has_currency_values = match(r"\$[\s]*[\d,]+", row_text) !== nothing
        has_large_nums = match(r"\b\d{1,3}(,\d{3})+\b", row_text) !== nothing
        (has_currency_values || has_large_nums) && return false
        match(r"^\s*fiscal\s+\d{4}\s*$", strip(rl)) !== nothing && return false
        (occursin("fiscal year", rl) && (occursin("ended", rl) || occursin("ending", rl))) && return true
    end
    if any(kw -> occursin(kw, rl), period_keywords)
        data_pattern = r"(?:\$\s*\d|\d+(?:,\d{3})+|\d+\.\d+|[(]\s*\d+(?:,\d{3})*\s*[)])"
        match(data_pattern, row_text) === nothing && return true
    end
    header_keywords = ("description", "item", "category", "type", "classification", "change", "percent",
        "increase", "decrease", "variance")
    if any(kw -> occursin(kw, rl), header_keywords)
        if !occursin("total", first(rl, 30))
            length(row_text) > 150 && return false
            data_pattern = r"(?:\$\s*\d|\d+(?:,\d{3})+|\d+\.\d+|[(]\s*\d+(?:,\d{3})*\s*[)])"
            match(data_pattern, row_text) !== nothing && return false
            return true
        end
    end
    bold_count = 0
    for cell in cells
        style = _attr(cell, "style", "")
        if occursin("font-weight", style) && occursin("bold", style)
            bold_count += 1
        elseif _findfirst(cell, ".//b") !== nothing || _findfirst(cell, ".//strong") !== nothing
            bold_count += 1
        end
    end
    (bold_count == length(cells) && bold_count > 0) && return true
    text_cells = 0; number_cells = 0
    for cell in cells
        ct = strip(_text_content(cell))
        if !isempty(ct)
            clean = replace(replace(replace(replace(replace(ct, "\$" => ""), "%" => ""), "," => ""), "(" => ""), ")" => "")
            clean2 = strip(replace(replace(clean, "." => ""), "-" => ""))
            _py_isdigit(clean2) ? (number_cells += 1) : (text_cells += 1)
        end
    end
    if text_cells > number_cells * 2 && text_cells >= 3
        data_row_indicators = ("impact of", "effect of", "adjustment", "provision for", "benefit", "expense",
            "income from", "loss on", "gain on", "charge", "credit", "earnings", "computed", "state taxes",
            "research", "excess tax")
        for ind in data_row_indicators
            (startswith(rl, ind) || occursin(ind, first(rl, 50))) && return false
        end
        startswith(rl, "total") || return true
    end
    return false
end

function _detect_table_type(p::TableProcessor, table::TableNode)
    text_parts = String[]
    table.caption !== nothing && push!(text_parts, lowercase(table.caption))
    for header_row in table.headers, cell in header_row
        push!(text_parts, lowercase(cell_text(cell)))
    end
    for row in table.rows[1:min(end, 3)], cell in row.cells
        push!(text_parts, lowercase(cell_text(cell)))
    end
    combined = join(text_parts, " ")
    financial_count = count(kw -> occursin(kw, combined), _TP_FINANCIAL_KEYWORDS)
    financial_count >= 2 && return FINANCIAL
    metrics_count = count(kw -> occursin(kw, combined), _TP_METRICS_KEYWORDS)
    numeric_cells = sum((count(cell_is_numeric, row.cells) for row in table.rows); init = 0)
    total_cells = sum((length(row.cells) for row in table.rows); init = 0)
    if total_cells > 0
        numeric_ratio = numeric_cells / total_cells
        (metrics_count >= 1 || numeric_ratio > 0.3) && return METRICS
    end
    if occursin("content", combined) || occursin("index", combined)
        has_page_numbers = any(row -> any(c -> match(r"\b\d{1,3}\b", cell_text(c)) !== nothing, row.cells), table.rows)
        has_page_numbers && return TT_TABLE_OF_CONTENTS
    end
    occursin("exhibit", combined) && return EXHIBIT_INDEX
    any(w -> occursin(w, combined), ("reference", "definition", "glossary", "citation")) && return REFERENCE
    return GENERAL
end

function _extract_relationships!(p::TableProcessor, table::TableNode)
    set_metadata!(table, "relationships_extracted", true)
    total_rows = Int[]
    for (i, row) in enumerate(table.rows)
        row_is_total(row) && push!(total_rows, i)
    end
    isempty(total_rows) || set_metadata!(table, "total_rows", total_rows)
    indentation_levels = Int[]
    for row in table.rows
        if !isempty(row.cells)
            fct = cell_text(row.cells[1])
            push!(indentation_levels, length(fct) - length(lstrip(fct)))
        end
    end
    if any(>(0), indentation_levels)
        set_metadata!(table, "has_hierarchy", true)
        set_metadata!(table, "indentation_levels", indentation_levels)
    end
    return nothing
end
