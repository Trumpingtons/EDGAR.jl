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

# The external-revenue ROW label — the anchor (EN IFRS + CAS). Kept deliberately broad across languages.
const _SEG_EXTREV = r"(?i)revenue from external|external (sales|revenue|customers)|对外(交易)?收入|外部(客户)?收入|external segment revenue"
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

# Score a grid on "is this the operating-segment table". Returns `(score, extrev_row_1based)`; score 0 = no.
function _segment_score(g::Vector{Vector{String}})
    (length(g) < 2 || maximum(length.(g); init = 0) < 3) && return (0.0, 0)
    joined = join((join(r, " ") for r in g), " ")
    occursin(_SEG_MGMT, joined) && return (0.0, 0)                     # management-view / organic-growth decoy
    extrow = 0
    for (i, r) in enumerate(g)
        lbl = get(filter(!isempty, r), 1, "")                          # the row's label = first non-empty cell
        if occursin(_SEG_EXTREV, lbl) && count(_seg_isnum, r) >= 3     # anchor: external-revenue row, ≥3 numbers
            extrow = i; break
        end
    end
    extrow == 0 && return (0.0, 0)
    score = 3.0
    occursin(_SEG_TOTAL, joined) && (score += 1.0)                     # a total column/row
    occursin(_SEG_RECON, joined) && (score += 1.0)                     # a reconciliation/elimination column
    return (score, extrow)
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
