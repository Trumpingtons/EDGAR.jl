# EX-21 subsidiary-list extraction — a faithful port of edgartools' company_reports/subsidiaries.py
# (`parse_subsidiaries` and helpers) plus the EX-21 exhibit discovery from ten_k.py (`TenK.subsidiaries`).
# A 10-K's Exhibit 21 lists the registrant's subsidiaries (name / jurisdiction / ownership %) as an HTML
# table; this parses that table robustly across the layouts SEC filers use. 🔵 SEC-specific (exhibit fetch).

"""
    Subsidiary

A single subsidiary record parsed from a filing's Exhibit 21: the entity `name`, its `jurisdiction`
of organization, and `ownership` (percent, `nothing` when the exhibit does not state it).
"""
struct Subsidiary
    name::String
    jurisdiction::String
    ownership::Union{Float64,Nothing}
end
Subsidiary(name, jurisdiction) = Subsidiary(name, jurisdiction, nothing)

Base.show(io::IO, s::Subsidiary) =
    print(io, "Subsidiary(", repr(s.name), ", ", repr(s.jurisdiction),
          s.ownership === nothing ? "" : ", ownership=$(s.ownership)", ")")

# --- header / section / ownership detectors (subsidiaries.py, verbatim) --------------------------------

# Strong header patterns — safe to match against any single cell.
const _SUB_STRONG_HEADER = r"(name\s+of\s+(subsidiary|subsidiaries|company|entity|companies)|^subsidiary$|^subsidiaries$|company\s+name|entity\s+name|percent(age)?\s+(of\s+)?own|organized\s+under\s+the\s+laws|state\s+or\s+(other\s+)?jurisdiction)"i
# Weaker header keywords — require corroboration from multiple cells.
const _SUB_HEADER_KEYWORDS = ("jurisdiction", "ownership", "subsidiary", "subsidiaries",
                              "incorporation", "organization", "organized")
const _SUB_JURISDICTION_PHRASES = ("jurisdiction", "state or", "organized under", "place of", "country of")
const _SUB_SECTION_LABEL = r"^(u\.?\s*s\.?\s*(subsidiaries|companies)|international\s+(subsidiaries|companies)|domestic\s+(subsidiaries|companies)|foreign\s+(subsidiaries|companies)|subsidiaries\s+of|the\s+following|significant\s+subsidiaries|list\s+of\s+subsidiaries|exhibit\s+21|part\s+[ivx]+)"i
# Trailing footnote markers like (1), (2)(3), *, ** — anchored to end-of-string; 1–2 digits only (not years).
const _SUB_FOOTNOTE = r"(\s*[\(\[]\d{1,2}[\)\]])+\s*$|\s*\*+\s*$"

# Clean cell text: strip non-breaking spaces, collapse internal whitespace.
_sub_clean(text::AbstractString) =
    strip(replace(replace(text, '\ua0' => ' '), r"\s+" => " "))

# Clean a subsidiary name: drop trailing footnote markers / asterisks.
function _sub_clean_name(name::AbstractString)
    n = replace(name, _SUB_FOOTNOTE => "")
    return strip(rstrip(n, ['*', ' ']))
end

# Parse an ownership percentage from text like "100%", "80", "99.9%"; `nothing` if not a 0–100 number.
function _sub_ownership(text::AbstractString)
    t = strip(rstrip(strip(text), '%'))
    v = tryparse(Float64, t)
    return (v !== nothing && 0 <= v <= 100) ? v : nothing
end

# A row that looks like a table header (subsidiaries.py `_is_header_row`).
function _sub_is_header(cells::Vector{String})
    isempty(cells) && return false
    for c in cells
        t = strip(c)
        !isempty(t) && occursin(_SUB_STRONG_HEADER, t) && return true
    end
    # Weaker signals need corroboration across DIFFERENT cells.
    kw = [any(w -> occursin(w, lowercase(c)), _SUB_HEADER_KEYWORDS) for c in cells]
    ju = [any(w -> occursin(w, lowercase(c)), _SUB_JURISDICTION_PHRASES) for c in cells]
    kwi = findall(kw); jui = findall(ju)
    if !isempty(kwi) && !isempty(jui)
        length(union(Set(kwi), Set(jui))) >= 2 && return true
    end
    return count(kw) >= 2
end

# A row that is a section label like "U.S. Subsidiaries:" (subsidiaries.py `_is_section_label`).
function _sub_is_section_label(cells::Vector{String})
    nonempty = [c for c in cells if !isempty(strip(c))]
    length(nonempty) == 1 || return false
    text = rstrip(strip(nonempty[1]), ':')
    occursin(_SUB_SECTION_LABEL, text) && return true
    return length(text) < 60 && text == uppercase(text) && !any(isdigit, text)
end

# Does a column's values look like ownership percentages (>40% parse as 0–100)?
function _sub_is_ownership_col(values::Vector{String})
    numeric = 0; nonempty = 0
    for v in values
        s = strip(v); isempty(s) && continue
        nonempty += 1
        x = tryparse(Float64, strip(rstrip(s, '%')))
        (x !== nothing && 0 <= x <= 100) && (numeric += 1)
    end
    return nonempty > 0 && numeric / nonempty > 0.4
end

# Remove columns empty across all rows (spacer columns), padding ragged rows first.
function _sub_strip_empty_cols(rows::Vector{Vector{String}})
    isempty(rows) && return rows
    maxc = maximum(length, rows)
    padded = [vcat(r, fill("", maxc - length(r))) for r in rows]
    keep = [c for c in 1:maxc if any(!isempty(strip(row[c])) for row in padded)]
    return [[row[c] for c in keep] for row in padded]
end

# --- HTML table rows (EzXML/libxml2) — mirrors BeautifulSoup find_all('tr')/find_all(['td','th']).get_text() ---

# Top-level <table> elements (no <table> ancestor), in document order — BeautifulSoup's
# `find_parent('table') is None` filter, to avoid double-counting nested layout tables.
function _sub_toplevel_tables(html::AbstractString)
    s = String(html)
    startswith(s, "<?xml") && (s = replace(s, r"<\?xml[^>]*\?>" => ""; count = 1))
    tables = EzXML.Node[]
    walk(node, in_table) = begin
        intbl = in_table
        if lowercase(EzXML.nodename(node)) == "table"
            in_table || push!(tables, node)
            intbl = true
        end
        for c in EzXML.eachelement(node)
            walk(c, intbl)
        end
    end
    walk(EzXML.root(EzXML.parsehtml(s)), false)
    return tables
end

# All descendant elements with one of `tags`, document order.
function _sub_descendants(node, tags)
    out = EzXML.Node[]
    walk(n) = for c in EzXML.eachelement(n)
        lowercase(EzXML.nodename(c)) in tags && push!(out, c)
        walk(c)
    end
    walk(node)
    return out
end

# Concatenated descendant text — BeautifulSoup get_text() (default empty separator) == libxml2 nodecontent.
_sub_gettext(node) = EzXML.nodecontent(node)

function _sub_table_rows(table)
    rows = Vector{String}[]
    for tr in _sub_descendants(table, ("tr",))
        push!(rows, String[_sub_clean(_sub_gettext(c)) for c in _sub_descendants(tr, ("td", "th"))])
    end
    return rows
end

# --- parse_subsidiaries (subsidiaries.py, verbatim, 1-based) -------------------------------------------

_sub_at(row::Vector{String}, i::Int) = 1 <= i <= length(row) ? row[i] : ""

"""
    parse_subsidiaries(html) -> Vector{Subsidiary}

Parse the HTML of an EX-21 exhibit into [`Subsidiary`](@ref) records — a faithful port of edgartools'
`parse_subsidiaries`. Handles 2-column (name + jurisdiction) and 3+-column (with an ownership %) tables,
multiple/paginated tables, header rows, section labels, footnote markers, and empty spacer columns.
"""
function parse_subsidiaries(html::AbstractString)
    subs = Subsidiary[]
    for table in _sub_toplevel_tables(html)
        all_cells = _sub_table_rows(table)
        isempty(all_cells) && continue
        all_cells = _sub_strip_empty_cols(all_cells)
        # Keep rows with ≥2 non-empty cells that aren't headers / section labels.
        data_rows = Vector{String}[]
        for cells in all_cells
            count(!isempty ∘ strip, cells) < 2 && continue
            (_sub_is_header(cells) || _sub_is_section_label(cells)) && continue
            push!(data_rows, cells)
        end
        isempty(data_rows) && continue
        # Effective column count = most common non-empty-cell count (first wins on ties).
        counts = Dict{Int,Int}()
        for cells in data_rows
            n = count(!isempty ∘ strip, cells); counts[n] = get(counts, n, 0) + 1
        end
        effective = 0; best = -1
        for cells in data_rows
            n = count(!isempty ∘ strip, cells)
            counts[n] > best && (best = counts[n]; effective = n)
        end
        if effective == 2
            for cells in data_rows
                ne = [c for c in cells if !isempty(strip(c))]
                length(ne) < 2 && continue
                name = _sub_clean_name(ne[1]); jur = strip(ne[2])
                (!isempty(name) && !isempty(jur)) && push!(subs, Subsidiary(name, jur))
            end
        elseif effective >= 3
            num_cols = maximum(length, data_rows)
            own_col = nothing
            for c in 2:min(num_cols, 4)
                vals = String[_sub_at(row, c) for row in data_rows]
                _sub_is_ownership_col(vals) && (own_col = c; break)
            end
            if own_col !== nothing
                others = [i for i in 2:num_cols if i != own_col]
                jur_col = isempty(others) ? own_col + 1 : others[1]
                for cells in data_rows
                    name = _sub_clean_name(_sub_at(cells, 1))
                    own = _sub_ownership(_sub_at(cells, own_col))
                    jur = strip(_sub_at(cells, jur_col))
                    (!isempty(name) && !isempty(jur)) && push!(subs, Subsidiary(name, jur, own))
                end
            else
                for cells in data_rows
                    ne = [c for c in cells if !isempty(strip(c))]
                    length(ne) < 2 && continue
                    name = _sub_clean_name(ne[1]); jur = strip(ne[end])
                    (!isempty(name) && !isempty(jur)) && push!(subs, Subsidiary(name, jur))
                end
            end
        end
    end
    return subs
end

"""
    subsidiaries(f::Filing) -> Union{Nothing,Vector{Subsidiary}}

Extract the registrant's subsidiaries from a 10-K's Exhibit 21. Returns the parsed [`Subsidiary`](@ref)
list (possibly empty) when the filing carries an EX-21 exhibit, or `nothing` when it has none — a faithful
port of edgartools' `TenK.subsidiaries`, which locates the first `EX-21*` attachment and parses it.
"""
function subsidiaries(f::Filing)
    base = _filing_dir(f)
    for d in _filing_documents(f)
        startswith(d.type, "EX-21") || continue
        body = fetch_url("$base/$(d.filename)")
        body === nothing && continue
        return parse_subsidiaries(String(body))
    end
    return nothing
end
