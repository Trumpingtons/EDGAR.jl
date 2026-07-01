# PDF extractor oracle — a do-it-yourself validation source (Phase 1.2).
#
# NOTE: like the other files in src/sources/, this is NOT part of the EDGAR module (not `include`d by
# src/EDGAR.jl). Load it on demand. It scores the PDF-derived facts in the DuckDB repository against the
# SAME filing's iXBRL twin (the dual-format AFR ground truth), the way arelle_*/yahoo oracles do for XBRL.
#
# VALUE-ANCHORED matching: PDF facts carry a line-item LABEL, not a concept, so we can't match on concept.
# Instead we match on (value, period) — sidestepping the label↔concept gap. Because the PDF stores the RAW
# printed number (e.g. £m: 64.9) while the twin is absolute (64,900,000), we match on the SIGNIFICAND at any
# power-of-10 scale; the consistent scale factor across matches is the document's inferred scale.
#
# Usage:
#   include(joinpath(pkgdir(EDGAR), "src", "sources", "pdf_oracle.jl"))
#   using .PdfOracle
#   PdfOracle.report("GB-GamesWorkshopFR2025",
#                    joinpath(expanduser("~/RegulatoryReports/goldset"), "GB-GamesWorkshopFR2025.twin.zip"))

module PdfOracle

using EDGAR, DuckDB, Printf, Dates
using DuckDB: DBInterface

const _DERIVABLE = ("balance_sheet", "income_statement", "cash_flow")

# |vt| == |vp| * 10^k for some integer k (ratio within ~0.7% of a power of ten)? Returns k, or nothing.
function scale_k(vp, vt)
    (vp == 0 || vt == 0) && return (vp == 0 && vt == 0) ? 0 : nothing
    lr = log10(abs(vt) / abs(vp))
    k = round(Int, lr)
    abs(lr - k) < 0.003 ? k : nothing
end

_pdf_facts(con, doc_id) = DuckDB.Tables.rowtable(DBInterface.execute(con,
    "SELECT label, value, statement_type AS st, period_end AS pe FROM facts " *
    "WHERE doc_id = ? AND statement_type IN ('balance_sheet','income_statement','cash_flow') " *
    "AND value IS NOT NULL", (doc_id,)))

function _twin_facts(twinpath)
    f = fetch_filing(EDGAR.ESEF(), twinpath)
    [r for r in EDGAR.facts(f) if r.value !== nothing]
end

# One comparison row: a PDF fact and its best twin match (or nothing).
function validate(doc_id, twinpath; db = joinpath(expanduser("~/RegulatoryReports"), "regulatory-reports.duckdb"))
    con = DBInterface.connect(DuckDB.DB, db)
    pdf = try _pdf_facts(con, doc_id) finally DBInterface.close!(con) end
    twin = _twin_facts(twinpath)
    byperiod = Dict{Any,Vector{Any}}()          # twin facts indexed by period_end
    for t in twin
        push!(get!(byperiod, t.period_end, Any[]), t)
    end
    rows = NamedTuple[]
    for p in pdf
        best = nothing
        for t in get(byperiod, p.pe, Any[])
            k = scale_k(p.value, t.value)
            k === nothing && continue
            best = (k = k, sign_ok = sign(p.value) == sign(t.value), concept = String(t.concept), tval = t.value)
            break
        end
        push!(rows, (label = String(p.label), pval = p.value, period = p.pe, stmt = String(p.st), m = best))
    end
    return rows
end

function report(doc_id, twinpath; kwargs...)
    rows = validate(doc_id, twinpath; kwargs...)
    matched = [r for r in rows if r.m !== nothing]
    n = length(rows); nm = length(matched)
    ks = [r.m.k for r in matched]
    scale = isempty(ks) ? nothing : argmax(c -> count(==(c), ks), unique(ks))   # modal scale factor
    at_scale = [r for r in matched if r.m.k == scale]
    signbad = [r for r in matched if !r.m.sign_ok]
    @printf("\n==== PDF oracle: %s ====\n", doc_id)
    @printf("PDF facts (BS/IS/CF): %d   matched a twin value: %d (%.0f%%)   [precision]\n", n, nm, 100nm/max(n,1))
    @printf("inferred scale: 10^%s  (%d/%d matches at the modal scale)\n", scale, length(at_scale), nm)
    @printf("sign mismatches among matches: %d (may be negatedLabel/presentation, not errors)\n", length(signbad))
    println("\n-- unmatched PDF facts (possible extraction errors, or twin-absent lines) --")
    for r in [r for r in rows if r.m === nothing][1:min(12, end)]
        @printf("  %-34s %-14s %s @%s\n", first(r.label, 34), string(r.pval), r.stmt, r.period)
    end
    return rows
end

end # module
