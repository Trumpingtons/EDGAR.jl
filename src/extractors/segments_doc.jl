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
