# Structure-based operating-segment table locator (S1 of docs/dev/segments-pdf-plan.md).
#
# `segments()`/`breakdown()` read segment members from XBRL dimensions; PDF-native and ESEF-block-tagged
# filings carry none, so the segment data sits in a *table* — a Docling `DocTable` (PDF: China/Germany/HK/
# Russia/Generic) or an HTML-document table (ESEF/UKSEF iXBRL). This file is the SOURCE-INDEPENDENT half:
# it finds the IFRS-8 / CAS operating-segment table among a document's tables by STRUCTURE, and rejects the
# co-located geography / product / management-view decoys. It works on a "grid" (rows of trimmed cell
# strings) so either table representation feeds it through a thin `_grid` adapter.
#
# The structural signature learned in S0 recon (ANTA, Techtronic, Continental, Gree — see the plan): the
# operating-segment table has (a) an EXTERNAL-REVENUE row whose values are revenue by segment, and usually
# (b) a TOTAL column and (c) a RECONCILIATION/elimination column. Orientation is segments-as-columns across
# every filer reconned, so the external-revenue ROW is the anchor.

# The revenue-row FAMILY (the anchor is a revenue row broken down by segment) and the EXTERNAL qualifier
# that distinguishes segment external revenue (which sums to consolidated) from inter-segment/total revenue.
# Learned across the S0 corpus: "External sales" (Continental/Techtronic), "对外交易收入" (Gree), "Revenue and
# other income from third parties" (Enel) — the label can also wrap onto the next grid row.
const _SEG_REVENUE  = r"(?i)\brevenues?\b|\bturnover\b|external sales|营业收入|对外交易收入|外部客户"
const _SEG_EXTERNAL = r"(?i)external|third[- ]part|对外|外部"
# TOTAL column/row label.
const _SEG_TOTAL  = r"(?i)\b(total|consolidated|group)\b|合计|总计"
# RECONCILIATION / elimination column (unallocated, inter-segment, holding, other).
const _SEG_RECON  = r"(?i)elimination|unallocated|reconcil|inter[- ]?segment|holding|corporate|分部间抵销|抵销|未分配"
# MANAGEMENT-view / disaggregation decoy signals (organic-growth review, like-for-like) → not the note.
const _SEG_MGMT   = r"(?i)\bRIG\b|\bOG\b|organic growth|proportion of total|like-for-like"

_seg_norm(s) = strip(replace(String(s), r"\s+" => " "))

# A numeric-looking cell: a grouped-thousands amount or a parenthesised negative (a bare "-" nil is NOT one).
_seg_isnum(s) = (t = strip(s); occursin(r"\d", t) && occursin(r"^\(?[-]?[\d.,\s]{2,}\)?%?$", t))

# Grid adapter for a Docling `DocTable` (cells carry 0-based `row`/`col`/`text`). The HTML adapter (S3)
# supplies its own `_grid` for the HTML-document table type; both yield `Vector{Vector{String}}`.
function _grid(t)::Vector{Vector{String}}
    isempty(t.cells) && return Vector{String}[]
    nr = maximum(c.row for c in t.cells) + 1
    nc = maximum(c.col for c in t.cells) + 1
    g = [fill("", nc) for _ in 1:nr]
    for c in t.cells
        (0 <= c.row < nr && 0 <= c.col < nc) && (g[c.row + 1][c.col + 1] = _seg_norm(c.text))
    end
    return g
end

# The effective label of a numeric row: its own first non-empty cell, plus the *following* non-numeric
# row's first cell when that carries the "external / third-party" qualifier the amount wrapped away from
# (HTML→grid splits a multi-line cell like "Revenue and other income / from third parties" across two rows).
function _row_label(g, i)
    lbl = get(filter(!isempty, g[i]), 1, "")
    if i < length(g) && count(_seg_isnum, g[i + 1]) == 0
        cont = get(filter(!isempty, g[i + 1]), 1, "")
        occursin(_SEG_EXTERNAL, cont) && (lbl = lbl * " " * cont)
    end
    return lbl
end

# Score a grid on "is this the operating-segment table". Returns `(score, revenue_row_1based)`; 0 = no.
# The anchor is a revenue row broken down by segment; the preferred row is EXTERNAL/third-party revenue
# (which reconciles to consolidated), then a plain revenue row, avoiding "total revenue" (incl. inter-segment).
function _segment_score(g::Vector{Vector{String}})
    (length(g) < 2 || maximum(length.(g); init = 0) < 3) && return (0.0, 0)
    joined = join((join(r, " ") for r in g), " ")
    occursin(_SEG_MGMT, joined) && return (0.0, 0)                     # management-view / organic-growth decoy
    hastotal = occursin(_SEG_TOTAL, joined)
    hasrecon = occursin(_SEG_RECON, joined)
    bestrow = 0; bestpref = -1
    for (i, r) in enumerate(g)
        count(_seg_isnum, r) >= 3 || continue                          # a data row with ≥3 numbers
        lbl = _row_label(g, i)
        occursin(_SEG_REVENUE, lbl) || continue                        # a revenue row
        pref = occursin(_SEG_EXTERNAL, lbl) ? 2 : (occursin(r"(?i)\btotal\b|合计|总计", lbl) ? 0 : 1)
        if pref > bestpref; bestpref = pref; bestrow = i; end
    end
    bestrow == 0 && return (0.0, 0)
    # A real operating-segment table carries either an explicit external/third-party revenue row, or the
    # total + reconciliation column structure — this is what separates it from a plain revenue disaggregation.
    (bestpref == 2 || (hastotal && hasrecon)) || return (0.0, 0)
    return (1.0 + bestpref + (hastotal ? 1.0 : 0.0) + (hasrecon ? 1.0 : 0.0), bestrow)
end

# Find the best operating-segment table among a set of grids. Returns `(grid, extrev_row)` or `nothing`.
function _find_segment_grid(grids)
    best = nothing; bestscore = 0.0; bestrow = 0
    for g in grids
        s, row = _segment_score(g)
        if s > bestscore
            bestscore = s; best = g; bestrow = row
        end
    end
    return best === nothing ? nothing : (best, bestrow)
end

# Convenience: locate the segment table among a Docling `StructuredDocument`'s tables.
_find_segment_table(sd) = _find_segment_grid(_grid(t) for t in sd.tables)

# ── HTML adapter (ESEF/UKSEF iXBRL) ──────────────────────────────────────────
# ESEF filings don't dimension segments and block-tag only a prose explanation; the numbers sit in a
# rendered HTML table in the iXBRL. Parse the HTML with the existing `Documents` machinery (`TableProcessor`
# → `TableNode`, then `TableMatrix` to flatten colspan/rowspan into a rectangular grid) and feed the same
# locator. Every `<table>` in the document is scored; the segment note wins on the external-revenue anchor.
function _grids_html(html::AbstractString)
    grids = Vector{Vector{String}}[]
    doc = try EzXML.parsehtml(String(html)) catch; return grids end
    tp = Documents.TableProcessor(Documents.ParserConfig())
    # `local-name()` matches `<table>` in any namespace — ESEF iXBRL is XHTML (default xmlns), so a bare
    # `//table` XPath matches nothing. (Div-positioned iXBRL has no <table> at all → needs the Docling adapter.)
    for el in EzXML.findall("//*[local-name()='table']", EzXML.root(doc))
        tn = try Documents.process(tp, el) catch; continue end
        m = Documents.TableMatrix()
        try Documents.build_from_rows!(m, tn.headers, tn.rows) catch; continue end
        g = [String[mc.original_cell === nothing ? "" : _seg_norm(Documents.cell_text(mc.original_cell))
                    for mc in mrow] for mrow in m.matrix]
        (isempty(g) || maximum(length.(g); init = 0) < 3) && continue
        push!(grids, g)
    end
    return grids
end

# Locate the operating-segment table in an iXBRL HTML document (the ESEF adapter's entry point).
_find_segment_html(html::AbstractString) = _find_segment_grid(_grids_html(html))

# ── S2: parse the located table into per-segment revenue ─────────────────────
# A monetary amount from a cell: parenthesised → negative; strip currency/percent; drop thousands
# separators (English/international format — German decimal-comma is a hardening item). Nil ("-"/"–") → nothing.
function _seg_amount(s::AbstractString)
    t = strip(s)
    (isempty(t) || t in ("-", "–", "—", "n/a", "N/A")) && return nothing
    neg = startswith(t, "(") && endswith(t, ")")
    t = strip(t, ['(', ')', '$', '€', '£', '%', '¥', ' ', '*'])
    t = replace(t, "," => "")
    v = tryparse(Float64, t)
    return v === nothing ? nothing : (neg ? -v : v)
end

# Header rows of a grid = the multi-cell, non-numeric rows above the revenue row (segment-name headers,
# possibly split across several lines); single-cell title rows ("Results for 2024") and numeric rows are excluded.
_seg_header_rows(g, revrow) = [i for i in 1:revrow-1 if count(_seg_isnum, g[i]) == 0 && count(!isempty, g[i]) >= 2]

# Strip a trailing unit token a header cell may carry ("Power Equipment US$'000" → "Power Equipment").
_seg_clean_name(s) = strip(replace(s, r"(?i)\s*(US\$'?0*|HK\$'?\w*|RMB'?\s?[Mm]illion|€\s?millions?|\$'?0*m?|£'?[m0]*|千元|百万元)\s*$" => ""))

"""
    _segment_revenue(g, revrow) -> (rows, total, recon, ok)

Parse the located segment grid at its revenue `revrow` into per-column results. `rows` is a vector of
`(name, value, kind)` — `kind ∈ (:segment, :total, :recon)` — one per numeric column, deduplicated against
colspan repeats. `total`/`recon` are the total-column and reconciliation/elimination values (or `nothing`).
`ok` is the reconciliation oracle: `Σ segment values (+ recon) ≈ total`, within 0.5%.
"""
function _segment_revenue(g::Vector{Vector{String}}, revrow::Int)
    hdrs = _seg_header_rows(g, revrow)
    ncol = maximum(length.(g); init = 0)
    colname(c) = _seg_clean_name(strip(join((get(g[i], c, "") for i in hdrs), " ")))
    rev = g[revrow]
    rows = NamedTuple[]; seen = Set{Tuple{String,Float64}}()
    for c in 1:ncol
        v = _seg_amount(get(rev, c, "")); v === nothing && continue
        name = colname(c); isempty(name) && continue
        (name, v) in seen && continue                                   # dedup colspan-expanded repeats
        push!(seen, (name, v))
        kind = occursin(_SEG_TOTAL, name) ? :total : occursin(_SEG_RECON, name) ? :recon : :segment
        push!(rows, (name = name, value = v, kind = kind))
    end
    total = findlast(r -> r.kind === :total, rows)
    recon = findlast(r -> r.kind === :recon, rows)
    tv = total === nothing ? nothing : rows[total].value
    rv = recon === nothing ? 0.0 : rows[recon].value
    segsum = sum((r.value for r in rows if r.kind === :segment); init = 0.0)
    ok = tv !== nothing && abs(segsum + rv - tv) <= 0.005 * max(abs(tv), 1)
    return (rows = rows, total = tv, recon = (recon === nothing ? nothing : rows[recon].value), ok = ok)
end

# ── S3: source entry points + breakdown()-shaped rows ────────────────────────
# The table states amounts in a scale (millions/thousands); XBRL-backed `breakdown` values are base units,
# so scale the segment values to match for a true drop-in. Detected from the header/unit tokens.
function _seg_scale(g)
    txt = join((join(r, " ") for r in first(g, min(length(g), 5))), " ")
    occursin(r"(?i)\bbillion", txt) && return 1.0e9
    occursin("亿", txt) && return 1.0e8
    occursin(r"(?i)\bmillions?\b|€\s*millions?|rmb'?\s?million|hk\$'?\s?m\b|百万", txt) && return 1.0e6
    occursin("万", txt) && return 1.0e4
    occursin(r"(?i)thousand|'000|千元|us\$'?0{2,}|hk\$'?0{2,}|\$'?0{3}", txt) && return 1.0e3
    return 1.0
end

# The reporting year: the first 4-digit 20xx in the header rows (the current/leftmost column year).
function _seg_year(g)
    for i in 1:min(length(g), 6), c in g[i]
        m = match(r"\b(20\d{2})\b", c)
        m !== nothing && return parse(Int, m.captures[1])
    end
    return nothing
end

# Fallback: the reporting year from the COVER page (a cheap single-page pdf.js pass). The cover states the
# reporting year prominently ("Annual Report 2024", "2024年年度报告") without the
# future-dated noise (subsequent events, certificate validities) that pollutes the note pages.
function _seg_cover_year(path)
    txt = ""
    try
        for pg in _pdf_words(path; page = 1).pages; txt *= _seg_pagetext(pg) * " "; end
    catch; return nothing end
    # Prefer the year bound to the report TITLE (excludes the publication date, which is often the next year).
    for pat in (r"(20\d{2})[年\s]{0,3}年度报告", r"annual\s+re(?:port|view)\s+(20\d{2})"i, r"(20\d{2})\s+annual\s+re(?:port|view)"i)
        m = match(pat, txt); m !== nothing && return parse(Int, m.captures[1])
    end
    yrs = filter(y -> 2000 <= y <= 2099, [parse(Int, m.captures[1]) for m in eachmatch(r"\b(20\d{2})\b", txt)])
    return isempty(yrs) ? nothing : maximum(yrs)
end

# Convert a located+parsed grid into `breakdown()`-shaped rows (one per segment). `axis = "segment"` is
# synthesised (there is no QName); `member`/`name` are the segment label; revenue is a duration → not instant.
# The fiscal year-end (`month`/`day`) defaults to 31 Dec (China + most ESEF); the PDF path passes the value
# `_ifrs_period` detected (e.g. 30 June for HK/Australian filers). Returns `(rows, reconciles)` so the PDF
# page-selector can prefer a page whose table reconciles.
function _seg_rows(g::Vector{Vector{String}}, revrow::Int;
                   year::Union{Int,Nothing} = nothing, month::Int = 12, day::Int = 31)
    p = _segment_revenue(g, revrow)
    scale = _seg_scale(g)
    yr = year === nothing ? _seg_year(g) : year        # PDF: from `_ifrs_period`; ESEF: from the grid header
    pe = yr === nothing ? nothing : Date(yr, month, day)
    ps = pe === nothing ? nothing : pe - Year(1) + Day(1)
    rows = NamedTuple[]
    for r in p.rows
        r.kind === :segment || continue
        push!(rows, (axis = "segment", member = r.name, name = r.name, value = r.value * scale,
                     period_start = ps, period_end = pe, is_instant = false, other_dims = ""))
    end
    return (rows, p.ok)
end

# Reading-order page text from the pdf.js word pass (rows grouped by y, then x) — for the text-scan fallback.
function _seg_pagetext(pg)
    ws = sort([(y = Float64(w.y), x = Float64(w.x), s = String(w.str)) for w in pg.words];
              by = t -> (round(t.y / 3.5), t.x))
    return join((t.s for t in ws), " ")
end

const _SEG_TOC_TITLE   = r"(?i)segment|分部|Segmentbericht"
const _SEG_PAGE_ANCHOR = r"(?i)external sales|revenue from external|外部客户|对外交易收入|revenue.{0,30}external customers|third[- ]part"

# Candidate segment-note pages for a PDF: TOC-titled entries first (cheap, precise), then a `_pdf_words`
# text scan for the external-revenue anchor when the TOC is coarse/absent.
function _segment_pdf_pages(path::AbstractString)
    cands = Int[]
    try
        for r in toc(path)
            r.page !== nothing && occursin(_SEG_TOC_TITLE, r.title) && push!(cands, r.page)
        end
    catch; end
    if isempty(cands)
        try
            for pg in _pdf_words(path).pages
                occursin(_SEG_PAGE_ANCHOR, _seg_pagetext(pg)) && push!(cands, Int(pg.page))
            end
        catch; end
    end
    return unique(cands)
end

# The PDF entry point: locate candidate pages, Docling a tight range around each, and return the segment
# rows from the first table that RECONCILES (Σ segments = total); fall back to the first non-empty parse.
function _segments_pdf(path::AbstractString)
    fallback = NamedTuple[]
    for pg in _segment_pdf_pages(path)
        sd = try structured_document(path; pages = (max(1, pg - 1), pg + 1)) catch; continue end
        res = _find_segment_grid(_grid(t) for t in sd.tables); res === nothing && continue
        md = try _ifrs_period(sd) catch; nothing end                # (month, day, years-desc) or nothing
        # Reporting year: `_ifrs_period` (needs the period phrase) → grid header → most-frequent year across
        # the segment-page tables. Fiscal year-end month/day from `_ifrs_period`, else 31 Dec.
        yr = (md !== nothing && !isempty(md[3])) ? md[3][1] : something(_seg_year(res[1]), _seg_cover_year(path), Some(nothing))
        rows, ok = _seg_rows(res[1], res[2]; year = yr,
                             month = md === nothing ? 12 : md[1], day = md === nothing ? 31 : md[2])
        isempty(rows) && continue
        ok && return rows
        isempty(fallback) && (fallback = rows)
    end
    return fallback
end

# The ESEF/iXBRL entry point: the segment note is a rendered HTML table in the in-memory iXBRL (no location).
function _segments_ixbrl(html::AbstractString)
    res = _find_segment_html(html); res === nothing && return NamedTuple[]
    return _seg_rows(res[1], res[2])[1]
end
