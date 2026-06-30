# Facts derivation (document-first PDF repository): statement tables → Fact rows.
#
# This file holds the PURE, dependency-free core — locale-aware amount parsing and column-axis inference
# over a string grid. The DuckDB-backed `derive_facts!` (reads table_cells, writes the facts table) lives in
# the EDGARDuckDBExt extension, and calls into these helpers.
#
# Number locale is chosen from the document's jurisdiction. Only THREE separator classes exist worldwide:
#   :en       comma thousands, dot decimal   — US/GB/IE, and CN/JP/KR/IN (Western digits, comma-grouped;
#                                              India's irregular lakh/crore grouping parses fine once commas
#                                              are stripped)
#   :eu_space (non-breaking) space thousands, comma decimal — FR, RU
#   :eu_dot   dot thousands, comma decimal    — DE/IT/ES and most of continental Europe
# The CJK/India *scale* words (百万円 / 千元 / 백만원 / ₹ crore) are a SCALE concern (step 3), not a
# separator one. Japanese negative sign is △/▲ (handled below), and CJK may use full-width digits.

const _AMOUNT_LOCALE = Dict(
    "FR" => :eu_space, "RU" => :eu_space,
    "DE" => :eu_dot, "IT" => :eu_dot, "ES" => :eu_dot, "PT" => :eu_dot,
    "NL" => :eu_dot, "BE" => :eu_dot, "AT" => :eu_dot, "CH" => :eu_dot,
    "US" => :en, "GB" => :en, "UK" => :en, "IE" => :en,
    "CN" => :en, "JP" => :en, "KR" => :en, "IN" => :en)

"""
    amount_locale(jurisdiction) -> Symbol

Map an ISO jurisdiction code to a number-separator class: `:en` (comma/dot), `:eu_space` (space/comma,
e.g. France & Russia), or `:eu_dot` (dot/comma, e.g. Germany, Italy, Spain). Defaults to `:en`.
"""
amount_locale(j) = get(_AMOUNT_LOCALE, uppercase(strip(String(something(j, "")))), :en)

const _FULLWIDTH = Dict('０'=>'0','１'=>'1','２'=>'2','３'=>'3','４'=>'4','５'=>'5',
                        '６'=>'6','７'=>'7','８'=>'8','９'=>'9','，'=>',','．'=>'.','（'=>'(','）'=>')')
const _YEAR_ONLY = r"^\s*(19|20)\d\d\s*$"

"""
    parse_amount(s; locale=:en) -> (val, nil) | nothing

Parse a statement cell into a signed Float64 amount. Returns `(val, nil=true)` for an explicit zero/dash,
`nothing` when `s` is not a number (a label, a note reference, blank). Locale-aware (see [`amount_locale`](@ref)):
strips currency (`£ \$ € ¥ ₩ ₹`) and percent, normalises full-width digits, and treats parentheses, a
leading/trailing minus (incl. unicode variants) and the Japanese `△`/`▲` as negative.
"""
function parse_amount(s; locale::Symbol = :en)
    t = strip(String(s))
    t = map(c -> get(_FULLWIDTH, c, c), t)          # full-width (CJK) → ASCII
    t = replace(t, r"[*†‡]+$" => "")
    isempty(t) && return (val = 0.0, nil = true)
    (t in ("–", "—", "-", "n/a", "N/A", "NA", "nil", "—")) && return (val = 0.0, nil = true)
    neg = (startswith(t, "(") && endswith(t, ")")) ||
          occursin(r"^[△▲▽▼\-−﹣－]", t) || endswith(t, "-")
    t = strip(t, ['(', ')', '[', ']', ' ', '△', '▲', '▽', '▼', '-', '−', '﹣', '－', '+'])
    t = replace(t, r"[£$€¥₩₹%]" => "")
    t = replace(t, ' ' => ' ', ' ' => ' ', ' ' => ' ')   # nbsp / narrow / thin → space
    if locale === :en
        t = replace(t, "," => "")
    elseif locale === :eu_space
        t = replace(replace(t, " " => ""), "," => ".")
    else # :eu_dot
        t = replace(replace(t, "." => ""), "," => ".")
    end
    t = replace(t, " " => "")
    isempty(t) && return (val = 0.0, nil = true)
    v = tryparse(Float64, t)
    v === nothing && return nothing
    return (val = neg ? -v : v, nil = false)
end

_is_amount(s, loc) = !occursin(_YEAR_ONLY, strip(String(s))) &&
                     (p = parse_amount(s; locale = loc); p !== nothing && !p.nil)

"""
    data_start_row(grid, nrows, ncols; locale=:en) -> Int

First body row of a statement grid: the first row whose col-0 is a (non-numeric) label AND some value column
holds a real amount. Bare years in the header (`2023`) are excluded so they are not mistaken for amounts.
`grid` maps `(row,col)=>String`. Falls back to row 1 (or 0) when no such row is found.
"""
function data_start_row(grid, nr, nc; locale::Symbol = :en)
    for r in 0:nr-1
        lbl = strip(get(grid, (r, 0), ""))
        (!isempty(lbl) && parse_amount(lbl; locale) === nothing) || continue
        any(_is_amount(get(grid, (r, c), ""), locale) for c in 1:nc-1) && return r
    end
    return min(1, nr - 1)
end

const _NOTES_HDR = r"\bnotes?\b|\bnota\b|\banhang\b"i
const _OFWHICH   = r"\bdi cui\b|\bof which\b|\bdavon\b|\bdont\b"i
const _YEAR_HDR  = r"\b(19|20)\d\d\b"

"""
    infer_columns(grid, nrows, ncols; locale=:en) -> (data_start, columns)

Classify each value column (col ≥ 1) of a statement grid by its header text into a `kind`:
`:period` (key = year), `:entity` (key = name, e.g. a fund in a combined statement), `:notes`,
`:dimension` ("di cui"/"of which"/"davon" breakdown of an adjacent period), `:value` (numeric but
unlabelled), or `:skip` (no amounts). Header text is the rows above `data_start`. Returns a NamedTuple
`(data_start, columns)` where `columns` is a vector of `(col, kind, key)`.
"""
function infer_columns(grid, nr, nc; locale::Symbol = :en)
    ds = data_start_row(grid, nr, nc; locale)
    htxt(c) = strip(join((strip(get(grid, (r, c), "")) for r in 0:ds-1), " "))
    cols = NamedTuple{(:col, :kind, :key),Tuple{Int,Symbol,String}}[]
    for c in 1:nc-1
        n = count(r -> _is_amount(get(grid, (r, c), ""), locale), ds:nr-1)
        if n == 0
            push!(cols, (col = c, kind = :skip, key = ""))
            continue
        end
        h = htxt(c)
        m = match(_YEAR_HDR, h)
        kind, key =
            occursin(_NOTES_HDR, h) ? (:notes, "") :
            occursin(_OFWHICH, h)   ? (:dimension, h) :
            m !== nothing           ? (:period, String(m.match)) :
            occursin(r"\p{L}", h)   ? (:entity, h) :
                                      (:value, "")
        push!(cols, (col = c, kind = kind, key = key))
    end
    return (data_start = ds, columns = cols)
end
