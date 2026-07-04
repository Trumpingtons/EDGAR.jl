# Hong Kong HKFRS facts (HK2) — recover the consolidated financial statements from an HKEXnews annual-report
# PDF and emit the SAME `Fact`s the XBRL path does, on `ifrs-full` concepts. Like China, extraction goes
# through DOCLING (Tier-2): the Tier-1 pdf.js spike was fast but dropped the equity section, the revenue total
# and the operating/investing cash flows (see docs/dev/hkex-plan.md), so we reuse China's page-scoped Docling
# pipeline. Unlike China the reports are English under HKFRS (IFRS-converged), so classification keys on the
# English label via `hkfrs_concept` and the concepts are `ifrs-full:` (shared with ESEF/DART). Consolidated
# statements only (a parent-company balance sheet, if any, lives in the notes) — so no dual-column handling.

# English fiscal-year-end + column years. The column years are read from the STANDALONE year CELLS ("2024",
# "2023") of the statement tables — a whole-text scan would catch spurious years (bond maturities "2030", note
# references) that sit inside prose, not as bare cells. The fiscal year-end month/day comes from a header
# phrase ("Year ended 31 December", "As at 31 March"). The whole set shares one year-end, so this is
# document-wide. Returns (month, day, years-desc) or nothing.
function _hkfrs_period(sd)
    yrs = Int[]
    for t in sd.tables, c in t.cells
        m = match(r"^(20\d{2})$", strip(c.text)); m === nothing || push!(yrs, parse(Int, m.captures[1]))
    end
    isempty(yrs) && return nothing
    uy = sort!(unique(yrs); rev = true)
    text = join(vcat([something(t.caption, "") for t in sd.tables], [b.text for b in sd.text_blocks]), " ")
    m = match(r"(\d{1,2})\s+(January|February|March|April|May|June|July|August|September|October|November|December)"i, text)
    mo = m === nothing ? 12 : monthabbr_to_num(m.captures[2])
    dy = m === nothing ? 31 : parse(Int, m.captures[1])
    return (mo, dy, uy)
end

const _HKFRS_MONTHS = Dict("january"=>1,"february"=>2,"march"=>3,"april"=>4,"may"=>5,"june"=>6,"july"=>7,
                           "august"=>8,"september"=>9,"october"=>10,"november"=>11,"december"=>12)
monthabbr_to_num(s) = get(_HKFRS_MONTHS, lowercase(String(s)), 12)

# Reporting scale + currency from the statement headers ("RMB'Million", "HK$'000", "in thousands"). One unit
# for the whole set (HKFRS statements state it once). Returns (scale, currency).
function _hkfrs_scale_currency(sd)
    # include TABLE CELLS — the unit lives in a header cell ("RMB'Million", "HK$'000"), not a caption/block.
    text = join(vcat([something(t.caption, "") for t in sd.tables],
                     [b.text for b in sd.text_blocks],
                     [c.text for t in sd.tables for c in t.cells]), " ")
    scale = occursin(r"(?i)million"i, text) ? 1e6 :
            occursin(r"(?i)'?000\b|thousand"i, text) ? 1e3 : 1.0
    cur = occursin(r"(?i)\bRMB\b|人民币|CNY"i, text)   ? "CNY" :
          occursin(r"(?i)US\$|\bUSD\b"i, text)         ? "USD" :
          occursin(r"(?i)HK\$|\bHKD\b"i, text)         ? "HKD" : "HKD"
    return (scale, cur)
end

# A monetary VALUE cell (thousands comma or a parenthesised negative), en-locale.
_hkfrs_ismoney(s) = (occursin(',', s) || occursin('(', s) || occursin(r"\d\.\d", s)) &&
                    (p = parse_amount(strip(String(s)); locale = :en); p !== nothing && !p.nil)

# A note-REFERENCE cell (dropped from labels): only digits, parens and lower-case sub-note letters —
# "6", "12(a)", "13(b)" — and containing a digit (so a real word label is never mistaken for a note).
_hkfrs_isnoteref(s) = (t = strip(String(s)); occursin(r"\d", t) &&
                       isempty(strip(replace(t, r"[\d\(\)a-z\s\.,/–-]" => ""))))

# Facts from one classified Docling statement table. `stmt` is the statement ("BalanceSheet"/…); value columns
# (≥2 monetary cells) map left→right to the period ends (most-recent first, the HKFRS convention). The label is
# the leading text cells before the first value column, minus any note reference. Concepts come from
# `hkfrs_concept(label, stmt)`; unrecognised rows are skipped (only the headline anchors are wanted).
function _hkfrs_table_facts(tbl, stmt::AbstractString, instant::Bool, pends::Vector{Date},
                            scale::Float64, currency::AbstractString)
    nr, nc = tbl.n_rows, tbl.n_cols
    grid = Dict{Tuple{Int,Int},String}()
    for c in tbl.cells; grid[(c.row, c.col)] = strip(c.text); end
    valcols = Int[]
    for c in 1:nc-1
        count(r -> _hkfrs_ismoney(get(grid, (r, c), "")), 0:nr-1) >= 2 && push!(valcols, c)
    end
    sort!(valcols)
    isempty(valcols) && return Fact[]
    firstval = minimum(valcols)
    out = Fact[]
    last_header = ""                                           # most recent section header (label, no values)
    for r in 0:nr-1
        lcells = String[]
        for c in 0:firstval-1
            s = get(grid, (r, c), "")
            (!isempty(s) && parse_amount(s; locale = :en) === nothing && !_hkfrs_isnoteref(s)) && push!(lcells, s)
        end
        label = strip(join(lcells, " "))
        hasval = any(_hkfrs_ismoney(get(grid, (r, c), "")) for c in valcols)
        if !hasval                                            # a section header / caption row — no fact
            isempty(label) || (last_header = label)
            continue
        end
        # HKFRS presents some totals on an UNLABELED row under a section header (Tencent's Revenue total sits
        # under a "Revenues" header, after the segment lines) — so an unlabeled value row inherits that header.
        # This EXTRACTS the reported figure (it does not compute it from other lines).
        elabel = isempty(label) ? last_header : label
        cc = isempty(elabel) ? nothing : hkfrs_concept(elabel, stmt)
        cc === nothing && continue
        for (i, c) in enumerate(valcols)
            i <= length(pends) || break
            p = parse_amount(get(grid, (r, c), ""); locale = :en)
            (p === nothing || p.nil) && continue
            pend = pends[i]
            pst = instant ? nothing : (pend - Year(1) + Day(1))
            push!(out, Fact(; concept = cc.concept, label = elabel, value = p.val * scale, unit = currency,
                  period_start = pst, period_end = pend, is_instant = instant, statement = stmt,
                  context_ref = string(pend), unit_ref = currency,
                  source_selector = "{\"table\":$(repr(tbl.table_id)),\"row\":$r,\"col\":$c}"))
        end
    end
    return out
end

# Consolidated-statements page range, TOC-first (the AR outline's statement bookmarks), heading-scan fallback.
const _HKFRS_STMT_TITLES = [r"(?i)consolidated (?:income )?statement of (?:financial position|profit or loss|comprehensive income|cash flows|changes in equity)",
                            r"(?i)consolidated income statement", r"(?i)consolidated balance sheet"]

function _hkfrs_statement_pages(doc; window::Int = 14)
    npg = length(doc.pages)
    if haskey(doc, :outline) && doc.outline !== nothing && !isempty(doc.outline)
        sp = Int[]
        for e in doc.outline
            p = get(e, :page, nothing); p === nothing && continue
            t = String(get(e, :title, ""))
            any(occursin(rx, t) for rx in _HKFRS_STMT_TITLES) && push!(sp, Int(p))
        end
        isempty(sp) || return (minimum(sp), min(maximum(sp) + 3, npg))
    end
    lo = nothing
    for pg in doc.pages
        any(occursin(rx, _cas_pagetext(pg)) for rx in _HKFRS_STMT_TITLES) && (lo = Int(pg.page); break)
    end
    lo === nothing && return nothing
    return (lo, min(lo + window, npg))
end

"""
    extract_hkfrs_pdf(path) -> Vector{FactRow}

Extract the consolidated HKFRS statements (balance sheet, income statement, cash flow) from a Hong Kong
annual-report PDF as classified [`facts`](@ref) on `ifrs-full` concepts. The statement page range is located
from the PDF outline (TOC-first, heading fallback), Docling parses just those pages, and the headline lines
are classified by [`hkfrs_concept`](@ref). All figures are extracted AS REPORTED — an unlabeled section total
(e.g. Tencent's Revenue total under a "Revenues" header) is recovered by carrying down the section header, not
by computing it from other lines — so the balance-sheet cross-foot and the benchmark check values the
extractor did not itself derive. English/HKFRS analogue of [`extract_cas_pdf`](@ref); see docs/dev/hkex-plan.md.
"""
function extract_hkfrs_pdf(path::AbstractString)
    doc = _pdf_words(path)
    rng = _hkfrs_statement_pages(doc)
    rng === nothing && throw(ArgumentError("no consolidated statements found in $(repr(basename(path)))"))
    sd = structured_document(path; pages = rng, jurisdiction = "HK", language = "en")
    return _hkfrs_facts_from_sd(sd; accession = basename(path), url = path)
end

# The SD → classified-facts core (shared by extract_hkfrs_pdf and offline tests). Classifies each statement
# table and extracts the headline lines AS REPORTED — no identity-derived (computed) values, so the balance-
# sheet cross-foot and the external-data benchmark check figures the extractor did not itself compute.
# Returns the row table.
function _hkfrs_facts_from_sd(sd; accession::AbstractString = "", url::AbstractString = "")
    per = _hkfrs_period(sd)
    per === nothing && throw(ArgumentError("could not determine the fiscal period from $(repr(accession))"))
    mo, dy, yrs = per
    pends = [Date(y, mo, dy) for y in yrs]
    scale, currency = _hkfrs_scale_currency(sd)
    sectitle = Dict(s.section_id => s.title for s in sd.sections)

    facts = Fact[]
    for tbl in sd.tables
        title = something(tbl.caption, "")
        isempty(title) && (title = get(sectitle, something(tbl.section_id, ""), ""))
        cls = classify_table_class(title)
        stmt = cls == "balance_sheet" ? "BalanceSheet" : cls == "income_statement" ? "IncomeStatement" :
               cls == "cash_flow" ? "CashFlow" : nothing
        stmt === nothing && continue                          # skip equity-changes matrix + unrecognised
        # Skip the STANDALONE statement of comprehensive income (title says "comprehensive income" but is not
        # the income statement / profit-or-loss): its "Equity holders of the Company" line is comprehensive-
        # income-attributable-to-owners, which would otherwise collide with profit-attributable-to-owners.
        (stmt == "IncomeStatement" && occursin(r"(?i)comprehensive income", title) &&
         !occursin(r"(?i)income statement|profit or loss", title)) && continue
        append!(facts, _hkfrs_table_facts(tbl, stmt, stmt == "BalanceSheet", pends, scale, currency))
    end

    sel = Selection(; cik = "", accession = accession, url = url, selector = "", kind = :filing, facts = facts)
    return EDGAR.facts(sel)
end
