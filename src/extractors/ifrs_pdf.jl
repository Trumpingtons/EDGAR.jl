# English-language financial-statement PDF extractor (`ifrs-full` concepts) — the shared text/Docling path for
# every jurisdiction whose reports are English PDFs mapping to `ifrs-full`: Hong Kong (HKEX, HKFRS) and UK
# Companies House (FRS 101/102 — the net-assets format, GBP), and whatever English-PDF system comes next. It
# recovers the primary statements from the PDF and emits the SAME `Fact`s the XBRL path does. Like China's CAS
# path it goes through DOCLING (Tier-2): the Tier-1 pdf.js spike dropped the equity section, the revenue total
# and the operating/investing cash flows, so we reuse China's page-scoped Docling pipeline. Because the reports
# are English under an IFRS-converged framework, classification keys on the English label via `ifrs_label_concept`
# and the concepts are `ifrs-full:` (shared with ESEF/DART). Consolidated statements (the parent-company balance
# sheet, if any, lives in the notes). See docs/dev/hkex-plan.md (HK) and the Companies House plan (UK).

# English fiscal-year-end + column years. The column years are read from short header CELLS that START with the
# year — a bare "2024"/"2023", or the UK form "2025 £m"/"2025 £'000" where the unit rides in the same cell — of
# the statement tables; a whole-text scan would catch spurious years (bond maturities "2030", note references)
# that sit inside prose. The fiscal year-end month/day comes from a fiscal-period phrase ("Year ended 31
# December", "As at 31 March"). The whole set shares one year-end, so this is document-wide. Returns (month,
# day, years-desc) or nothing.
function _ifrs_period(sd)
    yrs = Int[]
    for t in sd.tables, c in t.cells
        s = strip(c.text)
        # A short header cell that STARTS with the year — bare "2024", or the UK form "2025 £m" / "2025 £'000"
        # where the currency/unit rides in the same cell. The length guard keeps it to header cells (a bond
        # maturity "2030" sits in prose, not a bare short cell).
        m = match(r"^(20\d{2})\b", s)
        (m === nothing || length(s) > 12) && continue
        push!(yrs, parse(Int, m.captures[1]))
    end
    isempty(yrs) && return nothing
    uy = sort!(unique(yrs); rev = true)
    # Year-end month/day from a fiscal-period phrase ("Year ended 31 December", "As at 31 March") — search
    # section headings too (a scanned filing carries the period line as a heading), and REQUIRE the fiscal
    # context so a bare date in prose (a pension-valuation "31 May", a signing date) can't set the year-end.
    MON = "January|February|March|April|May|June|July|August|September|October|November|December"
    text = join(vcat([s.title for s in sd.sections],
                     [something(t.caption, "") for t in sd.tables], [b.text for b in sd.text_blocks]), " ")
    m = match(Regex("(?i)(?:year|period)?\\s*(?:ended|ending|as at|as of)\\s+(\\d{1,2})\\s+($MON)"), text)
    m === nothing && (m = match(Regex("(?i)(\\d{1,2})\\s+($MON)"), text))
    mo = m === nothing ? 12 : monthabbr_to_num(m.captures[2])
    dy = m === nothing ? 31 : parse(Int, m.captures[1])
    return (mo, dy, uy)
end

const _IFRS_MONTHS = Dict("january"=>1,"february"=>2,"march"=>3,"april"=>4,"may"=>5,"june"=>6,"july"=>7,
                           "august"=>8,"september"=>9,"october"=>10,"november"=>11,"december"=>12)
monthabbr_to_num(s) = get(_IFRS_MONTHS, lowercase(String(s)), 12)

# The unit TOKEN → (scale, currency) from a pool of header/label strings, or `nothing` if none carries one.
# The unit lives in a header CELL ("RMB'Million", "HK$'000", "HK$ million", the UK form "2025 £m" / "£'000"),
# not a caption/block; the currency is read from the SAME token that carries the magnitude — a note elsewhere
# mentioning "RMB" must not override a statement stated in "HK$'000".
function _ifrs_unit(texts)
    _cur(s) = occursin(r"(?i)RMB|人民币|人民幣", s) ? "CNY" : occursin(r"(?i)US\$|USD|美元", s) ? "USD" : "HKD"
    _scl(mag) = (lowercase(mag) in ("million", "百萬", "百万")) ? 1e6 : 1e3
    # Sterling first: a £-denominated set never carries HK$. Within one pool, prefer £m over £'000 (a single
    # statement's header states one unit — the mixed case only arises document-wide, resolved per table).
    if any(occursin('£', s) for s in texts)
        gbp_m = any(occursin(r"(?i)£\s*'?\s*(m\b|million)", s) for s in texts)
        gbp_k = any(occursin(r"(?i)£\s*'?\s*(thousand|000)\b", s) for s in texts)
        (gbp_m || gbp_k) && return (gbp_m ? 1e6 : 1e3, "GBP")
    end
    conv = nothing                                             # a "#"-marked supplementary/convenience unit
    for s in texts
        m = match(r"(?i)(#\s*)?(HK\$|US\$|RMB|人民[币幣])\s*'?\s*(million|thousand|000|百萬|百万|千)", s)
        m === nothing && continue
        if m.captures[1] !== nothing                          # "#" = convenience column (e.g. CK Hutchison's
            conv === nothing && (conv = m)                     # US$ column beside its primary HK$ statements)
        else
            return (_scl(m.captures[3]), _cur(m.captures[2]))  # the PRIMARY currency
        end
    end
    conv === nothing || return (_scl(conv.captures[3]), _cur(conv.captures[2]))
    return nothing
end

# DOCUMENT-WIDE scale + currency default — used only for a table that carries no unit token of its own (see
# `_ifrs_table_unit`). Reads the unit token from anywhere in the set, else a bare magnitude + currency guess.
function _ifrs_scale_currency(sd)
    texts = vcat([something(t.caption, "") for t in sd.tables], [b.text for b in sd.text_blocks],
                 [c.text for t in sd.tables for c in t.cells])
    u = _ifrs_unit(texts)
    u === nothing || return u
    # fallback: magnitude alone, currency by presence (HK$ preferred — the HK default)
    text = join(texts, " ")
    scale = occursin(r"(?i)million", text) ? 1e6 : occursin(r"(?i)'?000\b|thousand", text) ? 1e3 : 1.0
    cur = occursin(r"(?i)US\$|\bUSD\b", text) ? "USD" :
          occursin(r"(?i)HK\$|\bHKD\b", text) ? "HKD" : occursin(r"(?i)\bRMB\b|人民[币幣]", text) ? "CNY" :
          occursin('£', text) ? "GBP" : "HKD"
    return (scale, cur)
end

# PER-STATEMENT scale + currency: read the unit from the TABLE's OWN header cells ("2025 £m", "RMB'Million").
# Each primary statement states its unit, and a note may differ (statements in £m, a note in £'000; a
# convenience US$ column beside HK$ statements) — so scale is per table, not per document. Falls back to the
# document-wide default when the table carries no unit token.
function _ifrs_table_unit(tbl, def_scale::Float64, def_cur::AbstractString)
    u = _ifrs_unit([strip(c.text) for c in tbl.cells])
    return u === nothing ? (def_scale, def_cur) : u
end

# A monetary VALUE cell (thousands comma or a parenthesised negative), en-locale.
_ifrs_ismoney(s) = (occursin(',', s) || occursin('(', s) || occursin(r"\d\.\d", s)) &&
                    (p = parse_amount(strip(String(s)); locale = :en); p !== nothing && !p.nil)

# A note-REFERENCE cell (dropped from labels): only digits, parens and lower-case sub-note letters —
# "6", "12(a)", "13(b)" — and containing a digit (so a real word label is never mistaken for a note).
_ifrs_isnoteref(s) = (t = strip(String(s)); occursin(r"\d", t) &&
                       isempty(strip(replace(t, r"[\d\(\)a-z\s\.,/–-]" => ""))))

# Facts from one classified Docling statement table. `stmt` is the statement ("BalanceSheet"/…); value columns
# (≥2 monetary cells) map left→right to the period ends (most-recent first, the HKFRS convention). The label is
# the leading text cells before the first value column, minus any note reference. Concepts come from
# `ifrs_label_concept(label, stmt)`; unrecognised rows are skipped (only the headline anchors are wanted).
function _ifrs_table_facts(tbl, stmt::AbstractString, instant::Bool, pends::Vector{Date},
                            scale::Float64, currency::AbstractString)
    nr, nc = tbl.n_rows, tbl.n_cols
    grid = Dict{Tuple{Int,Int},String}()
    for c in tbl.cells; grid[(c.row, c.col)] = strip(c.text); end
    valcols = Int[]
    for c in 1:nc-1
        count(r -> _ifrs_ismoney(get(grid, (r, c), "")), 0:nr-1) >= 2 && push!(valcols, c)
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
            (!isempty(s) && parse_amount(s; locale = :en) === nothing && !_ifrs_isnoteref(s)) && push!(lcells, s)
        end
        label = strip(join(lcells, " "))
        hasval = any(_ifrs_ismoney(get(grid, (r, c), "")) for c in valcols)
        if !hasval                                            # a section header / caption row — no fact
            isempty(label) || (last_header = label)
            continue
        end
        # HKFRS presents some totals on an UNLABELED row under a section header (Tencent's Revenue total sits
        # under a "Revenues" header, after the segment lines) — so an unlabeled value row inherits that header.
        # This EXTRACTS the reported figure (it does not compute it from other lines).
        elabel = isempty(label) ? last_header : label
        cc = isempty(elabel) ? nothing : ifrs_label_concept(elabel, stmt)
        cc === nothing && continue
        for (i, c) in enumerate(valcols)
            i <= length(pends) || break
            p = parse_amount(get(grid, (r, c), ""); locale = :en)
            (p === nothing || p.nil) && continue
            pend = pends[i]
            pst = instant ? nothing : (pend - Year(1) + Day(1))
            # store the line item's VALUE, not its presentation sign: a debit line (cost of sales) printed in
            # parentheses because it is subtracted carries the positive magnitude — the −1 belongs to the
            # calculation, per the ifrs-full XBRL convention. Credit / :none lines keep their reported sign
            # (a loss, a net cash outflow are genuinely negative).
            val = (cc.balance == :debit ? abs(p.val) : p.val) * scale
            push!(out, Fact(; concept = cc.concept, label = elabel, value = val, unit = currency,
                  period_start = pst, period_end = pend, is_instant = instant, statement = stmt,
                  context_ref = string(pend), unit_ref = currency,
                  source_selector = "{\"table\":$(repr(tbl.table_id)),\"row\":$r,\"col\":$c}"))
        end
    end
    return out
end

# Consolidated-statements page range, TOC-first (the AR outline's statement bookmarks), heading-scan fallback.
const _IFRS_STMT_TITLES = [r"(?i)consolidated (?:income )?statement of (?:financial position|profit or loss|comprehensive income|cash flows|changes in equity)",
                            r"(?i)consolidated income statement", r"(?i)consolidated balance sheet"]

function _ifrs_statement_pages(doc; window::Int = 14)
    npg = length(doc.pages)
    if haskey(doc, :outline) && doc.outline !== nothing && !isempty(doc.outline)
        sp = Int[]
        for e in doc.outline
            p = get(e, :page, nothing); p === nothing && continue
            t = String(get(e, :title, ""))
            any(occursin(rx, t) for rx in _IFRS_STMT_TITLES) && push!(sp, Int(p))
        end
        isempty(sp) || return (minimum(sp), min(maximum(sp) + 3, npg))
    end
    lo = nothing
    for pg in doc.pages
        any(occursin(rx, _cas_pagetext(pg)) for rx in _IFRS_STMT_TITLES) && (lo = Int(pg.page); break)
    end
    lo === nothing && return nothing
    return (lo, min(lo + window, npg))
end

"""
    extract_ifrs_pdf(path) -> Vector{FactRow}

Extract the primary statements (balance sheet, income statement, cash flow) from an English-language
financial-report PDF as classified [`facts`](@ref) on `ifrs-full` concepts. The shared text path for
IFRS-converged English PDFs — Hong Kong (HKFRS) and UK Companies House (FRS 101/102, the net-assets format).
The statement page range is located from the PDF outline (TOC-first, heading fallback), Docling parses just
those pages, and the headline lines are classified by [`ifrs_label_concept`](@ref). All figures are extracted
AS REPORTED — an unlabeled section total (e.g. Tencent's Revenue total under a "Revenues" header) is recovered
by carrying down the section header, not by computing it from other lines — so the balance-sheet cross-foot and
the benchmark check values the extractor did not itself derive. English analogue of [`extract_cas_pdf`](@ref).
"""
function extract_ifrs_pdf(path::AbstractString)
    doc = _pdf_words(path)
    rng = _ifrs_statement_pages(doc)
    rng === nothing && throw(ArgumentError("no consolidated statements found in $(repr(basename(path)))"))
    sd = structured_document(path; pages = rng, jurisdiction = "HK", language = "en")
    return _ifrs_facts_from_sd(sd; accession = basename(path), url = path)
end

# The SD → classified-facts core (shared by extract_ifrs_pdf and offline tests). Classifies each statement
# table and extracts the headline lines AS REPORTED — no identity-derived (computed) values, so the balance-
# sheet cross-foot and the external-data benchmark check figures the extractor did not itself compute.
# Returns the row table.
function _ifrs_facts_from_sd(sd; accession::AbstractString = "", url::AbstractString = "")
    per = _ifrs_period(sd)
    per === nothing && throw(ArgumentError("could not determine the fiscal period from $(repr(accession))"))
    mo, dy, yrs = per
    pends = [Date(y, mo, dy) for y in yrs]
    scale, currency = _ifrs_scale_currency(sd)
    sectitle = Dict(s.section_id => s.title for s in sd.sections)
    # Section headings grouped by page: a scanned UK statement is split into sibling headings on one page —
    # the statement NAME ("STATEMENT OF FINANCIAL POSITION"), then the period line ("AS AT 31 MARCH 2025")
    # which is what OWNS the table — so the table's own section title is the date, not the name.
    pagetitles = Dict{Int,Vector{String}}()
    for s in sd.sections
        p = hasproperty(s, :page_start) ? s.page_start : nothing
        p === nothing && continue
        push!(get!(pagetitles, Int(p), String[]), s.title)
    end

    facts = Fact[]
    for tbl in sd.tables
        # A statement table's own caption/section is often just the period line ("AS AT 31 MARCH 2025", "FOR
        # THE YEAR ENDED …"); the statement NAME lives in a sibling heading on the SAME PAGE. So classify on
        # the caption, then the table's section, then all section headings on the table's page (where
        # "STATEMENT OF FINANCIAL POSITION" / "INCOME STATEMENT" sits). classify_table_class is specific — a
        # note heading ("2. Revenue", "NOTES TO THE FINANCIAL STATEMENTS") returns nothing, so this is safe.
        cap = something(tbl.caption, "")
        sectit = get(sectitle, something(tbl.section_id, ""), "")
        pgtit = join(get(pagetitles, Int(tbl.page_start), String[]), " ")
        cls = classify_table_class(cap)
        cls === nothing && (cls = classify_table_class(sectit))
        cls === nothing && (cls = classify_table_class(pgtit))
        title = strip(string(cap, " ", sectit, " ", pgtit))
        stmt = cls == "balance_sheet" ? "BalanceSheet" : cls == "income_statement" ? "IncomeStatement" :
               cls == "cash_flow" ? "CashFlow" : nothing
        stmt === nothing && continue                          # skip equity-changes matrix + unrecognised
        # Skip the STANDALONE statement of comprehensive income (title says "comprehensive income" but is not
        # the income statement / profit-or-loss): its "Equity holders of the Company" line is comprehensive-
        # income-attributable-to-owners, which would otherwise collide with profit-attributable-to-owners.
        (stmt == "IncomeStatement" && occursin(r"(?i)comprehensive income", title) &&
         !occursin(r"(?i)income statement|profit or loss", title)) && continue
        tscale, tcur = _ifrs_table_unit(tbl, scale, currency)   # this statement's OWN unit (£m vs a note's £'000)
        append!(facts, _ifrs_table_facts(tbl, stmt, stmt == "BalanceSheet", pends, tscale, tcur))
    end

    sel = Selection(; cik = "", accession = accession, url = url, selector = "", kind = :filing, facts = facts)
    return EDGAR.facts(sel)
end
