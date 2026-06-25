# Faithful translation of edgartools' edgar/documents/utils/table_matrix.py.
# Converts a table with colspan/rowspan into a regular 2D grid so the renderer sees a rectangular matrix.
# Includes the Table-15 "special numeric colspan=2" placement quirk verbatim.

mutable struct MatrixCell
    original_cell::Union{Nothing,Cell}
    is_spanned::Bool
    row_origin::Int
    col_origin::Int
end
MatrixCell() = MatrixCell(nothing, false, 0, 0)

mutable struct TableMatrix
    matrix::Vector{Vector{MatrixCell}}
    row_count::Int
    col_count::Int
    header_row_count::Int
end
TableMatrix() = TableMatrix(Vector{MatrixCell}[], 0, 0, 0)

# build_from_rows — header rows (Vector{Cell}) + data rows (Row).
function build_from_rows!(m::TableMatrix, header_rows::Vector{Vector{Cell}}, data_rows::Vector{Row})
    m.header_row_count = length(header_rows)
    all_rows = Vector{Cell}[]
    for hr in header_rows
        push!(all_rows, hr)
    end
    for r in data_rows
        push!(all_rows, r.cells)
    end
    isempty(all_rows) && return m
    m.row_count = length(all_rows)
    _calculate_dimensions!(m, all_rows)
    m.matrix = [[MatrixCell() for _ in 1:m.col_count] for _ in 1:m.row_count]
    _place_cells!(m, all_rows)
    return m
end

# _calculate_dimensions — actual column count considering colspan (0-based col_pos kept as Python).
function _calculate_dimensions!(m::TableMatrix, rows::Vector{Vector{Cell}})
    max_cols = 0
    for (row_idx, row) in enumerate(rows)         # row_idx is 1-based here
        col_pos = 0                               # 0-based, as Python
        for cell in row
            while col_pos < max_cols && _is_occupied(m, row_idx, col_pos)
                col_pos += 1
            end
            col_end = col_pos + cell.colspan
            max_cols = max(max_cols, col_end)
            col_pos = col_end
        end
    end
    m.col_count = max_cols
    return nothing
end

# _is_occupied — is (row, col) covered by a rowspan from a previous row? `row`/`col` are 0-based positions
# but `row` indexes into the same 1-based row sequence; we mirror Python by treating prev rows < row.
function _is_occupied(m::TableMatrix, row::Int, col::Int)
    row == 1 && return false
    for prev_row in 1:(row - 1)
        if prev_row <= length(m.matrix) && (col + 1) <= length(m.matrix[prev_row])
            cell = m.matrix[prev_row][col + 1]
            if cell.original_cell !== nothing && cell.row_origin == prev_row
                if prev_row + cell.original_cell.rowspan > row
                    return true
                end
            end
        end
    end
    return false
end

# _place_cells — place cells handling colspan/rowspan (col positions 0-based, matrix indices +1).
function _place_cells!(m::TableMatrix, rows::Vector{Vector{Cell}})
    for (row_idx, row) in enumerate(rows)
        col_pos = 0
        for cell in row
            while col_pos < m.col_count && m.matrix[row_idx][col_pos + 1].original_cell !== nothing
                col_pos += 1
            end
            if col_pos >= m.col_count
                _expand_columns!(m, col_pos + cell.colspan)
            end
            cell_text_ = strip(cell_text(cell))
            has_comma = occursin(",", cell_text_)
            digit_ratio = isempty(cell_text_) ? 0.0 : count(isdigit, cell_text_) / length(cell_text_)
            is_special_numeric = (cell.colspan == 2 && has_comma && digit_ratio > 0.5 &&
                !startswith(cell_text_, "\$") &&
                !any(mn -> occursin(mn, lowercase(cell_text_)),
                     ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec")) &&
                row_idx > 2)   # Python row_idx>1 (0-based) → 1-based row_idx>2
            if is_special_numeric
                for r in 0:(cell.rowspan - 1)
                    if row_idx + r <= m.row_count && col_pos + 1 <= m.col_count
                        m.matrix[row_idx + r][col_pos + 1] = MatrixCell()
                    end
                    if row_idx + r <= m.row_count && col_pos + 2 <= m.col_count
                        m.matrix[row_idx + r][col_pos + 2] =
                            MatrixCell(cell, false, row_idx, col_pos + 1)
                    end
                    for c in 2:(cell.colspan - 1)
                        if row_idx + r <= m.row_count && col_pos + c + 1 <= m.col_count
                            m.matrix[row_idx + r][col_pos + c + 1] =
                                MatrixCell(cell, true, row_idx, col_pos + 1)
                        end
                    end
                end
            else
                for r in 0:(cell.rowspan - 1)
                    for c in 0:(cell.colspan - 1)
                        if row_idx + r <= m.row_count && col_pos + c + 1 <= m.col_count
                            m.matrix[row_idx + r][col_pos + c + 1] =
                                MatrixCell(cell, (r > 0 || c > 0), row_idx, col_pos)
                        end
                    end
                end
            end
            col_pos += cell.colspan
        end
    end
    return nothing
end

function _expand_columns!(m::TableMatrix, new_col_count::Int)
    new_col_count <= m.col_count && return nothing
    for row in m.matrix
        while length(row) < new_col_count
            push!(row, MatrixCell())
        end
    end
    m.col_count = new_col_count
    return nothing
end

# get_expanded_row — origin cells in place, `nothing` for spanned/empty positions.
function get_expanded_row(m::TableMatrix, row_idx::Int)
    row_idx > m.row_count && return Union{Nothing,Cell}[]
    expanded = Union{Nothing,Cell}[]
    for col_idx in 1:m.col_count
        mc = m.matrix[row_idx][col_idx]
        if mc.original_cell !== nothing
            push!(expanded, mc.is_spanned ? nothing : mc.original_cell)
        else
            push!(expanded, nothing)
        end
    end
    return expanded
end
