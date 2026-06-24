# Faithful translation of edgartools' edgar/documents/renderers/fast_table.py.
# The production table renderer (`fast_table_rendering=True`). `TableNode.text()` uses the `simple()` style.
# Only the parts on the default render path are translated (the unused `_combine_headers`/`_looks_like_date`
# header-combining helpers, which `render_table_data` does not call, are omitted).

@enum Alignment ALIGN_LEFT ALIGN_RIGHT ALIGN_CENTER

Base.@kwdef struct TableStyle
    border_char::String = "|"
    header_separator::String = "-"
    corner_char::String = "+"
    padding::Int = 1
    min_col_width::Int = 8
    max_col_width::Int = 50
end

# TableStyle.simple — matches Rich's box.SIMPLE (no borders, unicode header rule, generous padding).
table_style_simple() = TableStyle(border_char = "", header_separator = "─", corner_char = "",
                                  padding = 2, min_col_width = 6, max_col_width = 500)
table_style_pipe() = TableStyle()
table_style_minimal() = TableStyle(border_char = "", header_separator = "", corner_char = "",
                                   padding = 2, min_col_width = 6, max_col_width = 40)

struct FastTableRenderer
    style::TableStyle
end
FastTableRenderer() = FastTableRenderer(table_style_pipe())

# Python str helpers.
_py_isalnum(s::AbstractString) = !isempty(s) && all(c -> isletter(c) || isdigit(c), s)
_py_isdigit(s::AbstractString) = !isempty(s) && all(isdigit, s)
function _py_center(s::AbstractString, w::Int)
    n = length(s)
    n >= w && return s
    total = w - n; left = total ÷ 2; right = total - left
    return " "^left * s * " "^right
end
_py_ljust(s::AbstractString, w::Int) = length(s) >= w ? String(s) : s * " "^(w - length(s))
_py_rjust(s::AbstractString, w::Int) = length(s) >= w ? String(s) : " "^(w - length(s)) * s

# TableNode._fast_text_rendering — render via the simple style.
function _fast_text_rendering(t::TableNode)
    return render_table_node(FastTableRenderer(table_style_simple()), t)
end

# render_table_node — build the colspan/rowspan matrix, expand each row to strings, render.
function render_table_node(r::FastTableRenderer, t::TableNode)
    m = TableMatrix()
    build_from_rows!(m, t.headers, t.rows)
    headers = Vector{String}[]
    if !isempty(t.headers)
        for row_idx in 1:length(t.headers)
            er = get_expanded_row(m, row_idx)
            push!(headers, String[c === nothing ? "" : strip(cell_text(c)) for c in er])
        end
    end
    rows = Vector{String}[]
    start_row = isempty(t.headers) ? 1 : length(t.headers) + 1
    for row_idx in start_row:m.row_count
        er = get_expanded_row(m, row_idx)
        push!(rows, String[c === nothing ? "" : strip(cell_text(c)) for c in er])
    end
    table_text = render_table_data(r, headers, rows)
    if t.caption !== nothing && !isempty(t.caption)
        return "$(t.caption)\n$table_text"
    end
    return table_text
end

function render_table_data(r::FastTableRenderer, headers::Vector{Vector{String}}, rows::Vector{Vector{String}})
    (isempty(headers) && isempty(rows)) && return ""
    all_rows = isempty(headers) ? rows : vcat(headers, rows)
    isempty(all_rows) && return ""
    max_cols = maximum(length, all_rows; init = 0)
    max_cols == 0 && return ""
    meaningful = _identify_meaningful_columns(r, all_rows, max_cols)
    isempty(meaningful) && return ""
    filtered_headers = isempty(headers) ? Vector{String}[] : [_filter_row_to_columns(row, meaningful) for row in headers]
    filtered_rows = [_filter_row_to_columns(row, meaningful) for row in rows]
    all_filtered = isempty(filtered_headers) ? filtered_rows : vcat(filtered_headers, filtered_rows)
    if !isempty(all_filtered)
        _, all_merged = _merge_related_columns(r, all_filtered[1], all_filtered)
        if !isempty(filtered_headers)
            nh = length(filtered_headers)
            filtered_headers = all_merged[1:nh]
            filtered_rows = all_merged[nh + 1:end]
        else
            filtered_rows = all_merged
        end
    end
    filtered_all_rows = isempty(filtered_headers) ? filtered_rows : vcat(filtered_headers, filtered_rows)
    filtered_max_cols = maximum(length, filtered_all_rows; init = 0)
    col_widths = _calculate_column_widths(r, filtered_all_rows, filtered_max_cols)
    alignments = _detect_alignments(r, filtered_all_rows, filtered_max_cols)
    return _build_table(r, filtered_headers, filtered_rows, col_widths, alignments)
end

function _identify_meaningful_columns(r::FastTableRenderer, all_rows::Vector{Vector{String}}, max_cols::Int)
    scores = Tuple{Int,Float64,Int}[]   # (col_idx 1-based, avg, total)
    for col_idx in 1:max_cols
        content_score = 0; total_rows = 0
        for row in all_rows
            if col_idx <= length(row)
                total_rows += 1
                cell = strip(row[col_idx])
                if !isempty(cell)
                    if length(cell) >= 3
                        content_score += 3
                    elseif length(cell) == 2 && _py_isalnum(cell)
                        content_score += 2
                    elseif length(cell) == 1 && (_py_isalnum(cell) || cell == "\$")
                        content_score += 1
                    end
                end
            end
        end
        avg = content_score / max(total_rows, 1)
        push!(scores, (col_idx, avg, content_score))
    end
    order = sortperm(scores; by = x -> x[2], rev = true)   # stable: ties keep original order
    meaningful = Int[]
    for k in order
        col_idx, avg, total = scores[k]
        if avg >= 0.5 || total >= 5
            push!(meaningful, col_idx)
        end
        length(meaningful) >= 8 && break
    end
    sort!(meaningful)
    return meaningful
end

function _filter_row_to_columns(row::Vector{String}, column_indices::Vector{Int})
    isempty(row) && return String[]
    return String[ci <= length(row) ? row[ci] : "" for ci in column_indices]
end

function _merge_related_columns(r::FastTableRenderer, headers::Vector{String}, rows::Vector{Vector{String}})
    (isempty(rows) || !any(!isempty, rows)) && return headers, rows
    max_cols = maximum(length, vcat([headers], rows); init = 0)
    merge_pairs = Tuple{Int,Int}[]
    for col_idx in 1:(max_cols - 1)
        _should_merge_columns(r, headers, rows, col_idx, col_idx + 1) && push!(merge_pairs, (col_idx, col_idx + 1))
    end
    merged_headers = copy(headers)
    merged_rows = [copy(row) for row in rows]
    for (left, right) in reverse(merge_pairs)
        if !isempty(merged_headers) && left <= length(merged_headers) && right <= length(merged_headers)
            lh = strip(merged_headers[left]); rh = strip(merged_headers[right])
            merged_headers[left] = strip("$lh $rh")
            deleteat!(merged_headers, right)
        end
        for row in merged_rows
            if left <= length(row) && right <= length(row)
                lc = strip(row[left]); rc = strip(row[right])
                if lc == "\$" && !isempty(rc)
                    row[left] = "\$$rc"
                elseif !isempty(lc) && !isempty(rc)
                    row[left] = "$lc $rc"
                else
                    row[left] = isempty(lc) ? rc : lc
                end
                right <= length(row) && deleteat!(row, right)
            end
        end
    end
    return merged_headers, merged_rows
end

function _should_merge_columns(r::FastTableRenderer, headers::Vector{String}, rows::Vector{Vector{String}}, left::Int, right::Int)
    currency_count = 0; total_count = 0
    for row in rows
        if left <= length(row) && right <= length(row)
            total_count += 1
            lc = strip(row[left]); rc = strip(row[right])
            if lc == "\$" && !isempty(rc) && _py_isdigit(replace(replace(rc, "," => ""), "." => ""))
                currency_count += 1
            end
        end
    end
    total_count > 0 && currency_count / total_count >= 0.5 && return true
    empty_left = 0
    for row in rows
        if left <= length(row) && right <= length(row)
            lc = strip(row[left]); rc = strip(row[right])
            (isempty(lc) && !isempty(rc)) && (empty_left += 1)
        end
    end
    return total_count > 0 && empty_left / total_count >= 0.7
end

function _calculate_column_widths(r::FastTableRenderer, all_rows::Vector{Vector{String}}, max_cols::Int)
    col_widths = fill(r.style.min_col_width, max_cols)
    for row in all_rows
        for col_idx in 1:min(length(row), max_cols)
            content = row[col_idx]
            max_line = maximum((length(line) for line in split(content, '\n')); init = 0)
            cw = min(max_line + r.style.padding * 2, r.style.max_col_width)
            col_widths[col_idx] = max(col_widths[col_idx], cw)
        end
    end
    return col_widths
end

function _detect_alignments(r::FastTableRenderer, all_rows::Vector{Vector{String}}, max_cols::Int)
    alignments = fill(ALIGN_LEFT, max_cols)
    for col_idx in 1:max_cols
        data_rows = length(all_rows) > 1 ? all_rows[2:end] : all_rows
        numeric = 0; total = 0
        for row in data_rows
            if col_idx <= length(row) && !isempty(strip(row[col_idx]))
                total += 1
                _looks_numeric(r, strip(row[col_idx])) && (numeric += 1)
            end
        end
        total > 0 && numeric / total >= 0.7 && (alignments[col_idx] = ALIGN_RIGHT)
    end
    return alignments
end

function _looks_numeric(r::FastTableRenderer, text_::AbstractString)
    isempty(text_) && return false
    clean = strip(replace(replace(replace(replace(replace(text_, "," => ""), "\$" => ""), "%" => ""), "(" => ""), ")" => ""))
    st = strip(text_)
    if startswith(st, "(") && endswith(st, ")")
        clean = strip(replace(replace(chop(st; head = 1, tail = 1), "," => ""), "\$" => ""))
    end
    return tryparse(Float64, clean) !== nothing
end

function _build_table(r::FastTableRenderer, headers::Vector{Vector{String}}, rows::Vector{Vector{String}},
                      col_widths::Vector{Int}, alignments::Vector{Alignment})
    lines = String[]
    if !isempty(headers)
        for header_row in headers
            if any(!isempty ∘ strip, header_row)
                append!(lines, _format_multiline_row(r, header_row, col_widths, alignments))
            end
        end
        if !isempty(r.style.header_separator)
            push!(lines, _create_separator_line(r, col_widths))
        end
    end
    for row in rows
        if any(!isempty ∘ strip, row)
            push!(lines, _format_row(r, row, col_widths, alignments))
        end
    end
    return join(lines, "\n")
end

function _format_row(r::FastTableRenderer, row::Vector{String}, col_widths::Vector{Int}, alignments::Vector{Alignment})
    cells = String[]
    border = r.style.border_char
    for (col_idx, width) in enumerate(col_widths)
        content = col_idx <= length(row) ? row[col_idx] : ""
        occursin('\n', content) && (content = first(split(content, '\n')))
        content = strip(content)
        available = width - r.style.padding * 2
        if length(content) > available
            content = first(content, available - 3) * "..."
        end
        align = col_idx <= length(alignments) ? alignments[col_idx] : ALIGN_LEFT
        aligned = align == ALIGN_RIGHT ? _py_rjust(content, available) :
                  align == ALIGN_CENTER ? _py_center(content, available) : _py_ljust(content, available)
        push!(cells, " "^r.style.padding * aligned * " "^r.style.padding)
    end
    if !isempty(border)
        return border * join(cells, border) * border
    else
        return join(cells, "  ")
    end
end

function _format_multiline_row(r::FastTableRenderer, row::Vector{String}, col_widths::Vector{Int}, alignments::Vector{Alignment})
    cell_lines = Vector{SubString{String}}[]
    max_lines = 1
    for content in row
        ls = isempty(content) ? SubString{String}[SubString("")] : split(content, '\n')
        push!(cell_lines, ls)
        max_lines = max(max_lines, length(ls))
    end
    out = String[]
    for line_idx in 1:max_lines
        current = String[]
        for col_idx in 1:length(row)
            push!(current, line_idx <= length(cell_lines[col_idx]) ? String(cell_lines[col_idx][line_idx]) : "")
        end
        push!(out, _format_row(r, current, col_widths, alignments))
    end
    return out
end

function _create_separator_line(r::FastTableRenderer, col_widths::Vector{Int})
    sep = r.style.header_separator
    border = r.style.border_char
    isempty(sep) && return ""
    if !isempty(border)
        return border * join((sep^w for w in col_widths), border) * border
    else
        total_width = sum(col_widths) + (length(col_widths) - 1) * 2
        return " " * sep^total_width
    end
end
