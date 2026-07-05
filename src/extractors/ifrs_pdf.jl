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
    # Year-end month/day. Search section headings, captions, blocks AND table cells — a bank states the
    # year-end date only in the balance-sheet column-header CELL ("31 December 2025"), not in a heading.
    # Priority: (1) a fiscal-period phrase ("Year ended 31 December", "As at 31 March"); (2) else a month-END
    # date (day 28–31 — a real year-end, never a "1 January" opening-balance line from the equity statement);
    # (3) else any date. Steps 1–2 keep a stray prose date (a pension "31 May", a "1 January" opening) out.
    MON = "January|February|March|April|May|June|July|August|September|October|November|December"
    text = join(vcat([s.title for s in sd.sections], [something(t.caption, "") for t in sd.tables],
                     [b.text for b in sd.text_blocks], [c.text for t in sd.tables for c in t.cells]), " ")
    # Accept BOTH orders — "31 December" (day-month, HK/UK) and "December 31" (month-day, US-style, e.g.
    # PetroChina). Priority: a fiscal-period phrase; then a month-END date (a real year-end, never a "1 January"
    # / "January 1" opening line); then any date. `a1` tells whether the month was captured first.
    fc = "(?:year|period)?\\s*(?:ended|ending|as at|as of)\\s+"
    m = nothing
    for rx in ["(?i)$fc(\\d{1,2})\\s+($MON)", "(?i)$fc($MON)\\s+(\\d{1,2})",
               "(?i)(28|29|30|31)\\s+($MON)", "(?i)($MON)\\s+(28|29|30|31)\\b",
               "(?i)(\\d{1,2})\\s+($MON)", "(?i)($MON)\\s+(\\d{1,2})\\b"]
        m = match(Regex(rx), text); m === nothing || break
    end
    a1 = m !== nothing && occursin(r"[A-Za-z]", String(m.captures[1]))    # month captured first (month-day order)?
    mo = m === nothing ? 12 : monthabbr_to_num(m.captures[a1 ? 1 : 2])
    dy = m === nothing ? 31 : parse(Int, m.captures[a1 ? 2 : 1])
    return (mo, dy, uy)
end

const _IFRS_MONTHS = Dict("january"=>1,"february"=>2,"march"=>3,"april"=>4,"may"=>5,"june"=>6,"july"=>7,
                           "august"=>8,"september"=>9,"october"=>10,"november"=>11,"december"=>12)
monthabbr_to_num(s) = get(_IFRS_MONTHS, lowercase(String(s)), 12)

# The unit TOKEN → (scale, currency) from a pool of header/label strings, or `nothing` if none carries one.
# The unit lives in a header CELL ("RMB'Million", "HK$'000", "HK$ million", "HK$'m", the UK form "2025 £m" /
# "£'000"), not a caption/block; the currency is read from the SAME token that carries the magnitude — a note
# elsewhere mentioning "RMB" must not override a statement stated in "HK$'000".
function _ifrs_unit(texts)
    _cur(s) = occursin(r"(?i)RMB|人民币|人民幣", s) ? "CNY" : occursin(r"(?i)US\$|USD|美元", s) ? "USD" : "HKD"
    _scl(mag) = (lowercase(mag) in ("million", "m", "百萬", "百万")) ? 1e6 : 1e3
    # Sterling first: a £-denominated set never carries HK$. Within one pool, prefer £m over £'000 (a single
    # statement's header states one unit — the mixed case only arises document-wide, resolved per table).
    if any(occursin('£', s) for s in texts)
        gbp_m = any(occursin(r"(?i)£\s*'?\s*(m\b|million)", s) for s in texts)
        gbp_k = any(occursin(r"(?i)£\s*'?\s*(thousand|000)\b", s) for s in texts)
        (gbp_m || gbp_k) && return (gbp_m ? 1e6 : 1e3, "GBP")
    end
    conv = nothing                                             # a "#"-marked supplementary/convenience unit
    for s in texts
        # magnitude is "million"/"thousand"/"000"/CJK, OR a bare "m" (HK banks abbreviate "HK$'m" = HK$ million)
        m = match(r"(?i)(#\s*)?(HK\$|US\$|RMB|人民[币幣])\s*['’]?\s*(million|thousand|000|百萬|百万|千|m)\b", s)
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

# Pick the most frequent element (deterministic on ties by string order).
_ifrs_mode(v) = (d = Dict{String,Int}(); for x in v; d[x] = get(d, x, 0) + 1; end;
                 first(sort(collect(keys(d)); by = k -> (-d[k], k))))

# Facts from one classified Docling statement table. COLUMN-AWARE, so it handles the awkward HK layouts as well
# as the plain ones:
#   • the LABEL is any word cell in the row (joined), so a LEADING convenience column — e.g. CK Hutchison's
#     "# US$ million" column that sits BEFORE the description — does not hide the line item;
#   • each VALUE column carries its own year + currency in the header ("2025 HK$ million"), so we keep only the
#     PRIMARY-currency columns (dropping the "#"-marked US$ convenience column) and map each to the period end
#     for ITS year — an opening-balance "1 January" column or a 3rd comparative year then lands correctly.
# The stored value is the line item's magnitude (a parenthesised debit is positive; its −1 is the calculation
# contribution, per the ifrs-full XBRL convention). Concepts come from `ifrs_label_concept`; other rows skipped.
function _ifrs_table_facts(tbl, stmt::AbstractString, instant::Bool, pends::Vector{Date},
                            scale::Float64, currency::AbstractString)
    nr, nc = tbl.n_rows, tbl.n_cols
    isempty(pends) && return Fact[]
    grid = Dict{Tuple{Int,Int},String}(); hdr = Dict{Tuple{Int,Int},String}()
    for c in tbl.cells
        grid[(c.row, c.col)] = strip(c.text)
        for cc in c.col:(c.col + max(c.colspan, 1) - 1)          # expand colspans for HEADER lookup: a spanning
            hdr[(c.row, cc)] = strip(c.text)                     # header ("Six months ended" over both year cols)
        end                                                     # must reach every column it covers
    end
    # value columns: ≥2 monetary body cells (a Note column of "13" / "32 (a)" is not monetary, so it is excluded)
    valcols = [c for c in 0:nc-1 if count(r -> _ifrs_ismoney(get(grid, (r, c), "")), 0:nr-1) >= 2]
    isempty(valcols) && return Fact[]
    firstbody = something(findfirst(r -> any(_ifrs_ismoney(get(grid, (r, c), "")) for c in valcols), 0:nr-1),
                          1) - 1                                # 0-based index of the first row carrying values

    # per value column: its header year, currency, and whether it is a "#" convenience or a "1 January" opening
    colyear = Dict{Int,Union{Int,Nothing}}(); colcur = Dict{Int,Union{String,Nothing}}()
    colconv = Dict{Int,Bool}(); colopen = Dict{Int,Bool}(); colcumul = Dict{Int,Bool}()
    for c in valcols
        h = join([get(hdr, (r, c), "") for r in 0:firstbody-1], " ")
        ym = match(r"(20\d{2})", h); colyear[c] = ym === nothing ? nothing : parse(Int, ym.captures[1])
        colcur[c] = occursin(r"(?i)HK\$", h) ? "HKD" : occursin(r"(?i)US\$|\bUSD\b", h) ? "USD" :
                    occursin(r"(?i)\bRMB\b|人民[币幣]", h) ? "CNY" : occursin('£', h) ? "GBP" : nothing
        colconv[c] = occursin('#', h)
        colopen[c] = occursin(r"(?i)1\s+january", h)
        colcumul[c] = occursin(r"(?i)(six|nine|twelve|half.?year|year.?to.?date) month|period ended|year ended", h)
    end
    stated = [colcur[c] for c in valcols if !colconv[c] && colcur[c] !== nothing]
    primary = isempty(stated) ? currency : _ifrs_mode(stated)   # the PRIMARY presentation currency (HK$, not US$)
    keep = [c for c in valcols if !colconv[c] && !colopen[c] && (colcur[c] === nothing || colcur[c] == primary)]
    isempty(keep) && (keep = valcols)                           # degenerate: no column matched — keep them all
    # An interim income statement shows BOTH a "three months" and a "six months" (year-to-date) column PER YEAR
    # — same year, so they can't be told apart by year. When a year appears in more than one kept column, prefer
    # the CUMULATIVE (year-to-date) one (a "six/nine months" / "period ended" / "year ended" header). Leaves the
    # annual case untouched: there each year appears once, so nothing is dropped.
    byyear = Dict{Int,Vector{Int}}()
    for c in keep; y = colyear[c]; y === nothing || push!(get!(byyear, y, Int[]), c); end
    for (_, cs) in byyear
        (length(cs) > 1 && any(colcumul[c] for c in cs)) || continue
        keep = filter(c -> !(c in cs) || colcumul[c], keep)     # drop this year's non-cumulative (quarter) columns
    end
    sort!(keep)
    mo, dy = month(pends[1]), day(pends[1])                     # the fiscal year-end; each column's year sets its end
    colend = Dict{Int,Date}(c => (colyear[c] === nothing ? pends[min(i, length(pends))] : Date(colyear[c], mo, dy))
                            for (i, c) in enumerate(keep))

    out = Fact[]
    last_header = ""                                            # most recent section header (label, no values)
    for r in 0:nr-1
        # the label is every word cell in the row (nonempty, not an amount, not a note reference) — position-free
        lcells = String[]
        for c in 0:nc-1
            s = get(grid, (r, c), "")
            (!isempty(s) && occursin(r"[A-Za-z]", s) && parse_amount(s; locale = :en) === nothing &&
             !_ifrs_isnoteref(s)) && push!(lcells, s)
        end
        label = strip(join(lcells, " "))
        # In a COMBINED profit-or-loss-and-OCI statement, stop at the OCI / total-comprehensive-income section:
        # everything below is other comprehensive income — including a second "attributable to owners" that is
        # comprehensive-income-attributable, not profit (China Mobile lists it under "Total comprehensive income
        # attributable to:" on a continuation page). The income statement we map ends at "profit for the year".
        (stmt == "IncomeStatement" && occursin(r"(?i)(?:other|total) comprehensive income", label)) && break
        hasval = any(_ifrs_ismoney(get(grid, (r, c), "")) for c in keep)
        if !hasval                                             # no monetary value on this row — no fact
            # A section header has its value columns EMPTY and carries down to a later unlabeled subtotal
            # (Tencent's "Revenues" / "Equity attributable to …" totals). A row whose value columns instead
            # hold a nil dash ("-") is a NIL line item with its own label (e.g. Tencent "Share capital  -  -")
            # — it must NOT overwrite the section header, or the subtotal inherits the wrong label and is lost.
            filled = any(!isempty(get(grid, (r, c), "")) for c in keep)
            (!filled && !isempty(label)) && (last_header = label)
            continue
        end
        # an UNLABELED value row inherits the section header (Tencent's Revenue total sits under a "Revenues"
        # header) — this EXTRACTS the reported figure, it does not compute it from other lines.
        elabel = isempty(label) ? last_header : label
        cc = isempty(elabel) ? nothing : ifrs_label_concept(elabel, stmt)
        cc === nothing && continue
        for c in keep
            p = parse_amount(get(grid, (r, c), ""); locale = :en)
            (p === nothing || p.nil) && continue
            pend = colend[c]
            pst = instant ? nothing : (pend - Year(1) + Day(1))
            val = (cc.balance == :debit ? abs(p.val) : p.val) * scale
            push!(out, Fact(; concept = cc.concept, label = elabel, value = val, unit = primary,
                  period_start = pst, period_end = pend, is_instant = instant, statement = stmt,
                  context_ref = string(pend), unit_ref = primary,
                  source_selector = "{\"table\":$(repr(tbl.table_id)),\"row\":$r,\"col\":$c}"))
        end
    end
    return out
end

# Consolidated-statements page range, TOC-first (the AR outline's statement bookmarks), heading-scan fallback.
const _IFRS_STMT_TITLES = [r"(?i)consolidated (?:income )?statement of (?:financial position|profit or loss|comprehensive income|cash flows|changes in equity)",
                            r"(?i)consolidated income statement", r"(?i)consolidated balance sheet"]
# The four primary-statement TYPES, each keyed by its consolidated heading — used by the heading-scan fallback
# to locate the statement CLUSTER (the window where the most distinct types co-occur), not a stray first mention.
const _IFRS_STMT_TYPES = [
    (:is, r"(?i)consolidated (?:income statement|statement of (?:profit or loss|comprehensive income))"),
    (:bs, r"(?i)consolidated (?:balance sheet|statement of financial position)"),
    (:cf, r"(?i)consolidated (?:cash flow statement|statement of cash flows)"),
    (:eq, r"(?i)consolidated statement of changes in equity")]

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
    # Heading-scan fallback. A long report (especially a DUAL-STANDARD CAS+IFRS filing like PetroChina, whose
    # outline is only two coarse Chinese section bookmarks) mentions statement titles many times — in the MD&A,
    # the parent-company statements, note headings — before the real consolidated set. So take the primary
    # CLUSTER: the `window` where the most DISTINCT consolidated statement types co-occur, not the first mention.
    pgtypes = Dict{Int,Set{Symbol}}()
    for pg in doc.pages
        s = Set{Symbol}(); txt = _cas_pagetext(pg)
        for (ty, rx) in _IFRS_STMT_TYPES; occursin(rx, txt) && push!(s, ty); end
        isempty(s) || (pgtypes[Int(pg.page)] = s)
    end
    isempty(pgtypes) && return nothing
    best_lo, best_n = minimum(keys(pgtypes)), 0
    for lo in sort!(collect(keys(pgtypes)))
        n = length(reduce(union, (get(pgtypes, p, Set{Symbol}()) for p in lo:min(lo + window, npg));
                          init = Set{Symbol}()))
        n > best_n && (best_n = n; best_lo = lo)      # strict >: on a tie the EARLIEST start wins
    end
    return (best_lo, min(best_lo + window, npg))
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

"""
    extract_ifrs_pdf(sd::StructuredDocument; accession="", url="") -> Vector{FactRow}

Classify and extract the primary statements from an ALREADY-parsed [`StructuredDocument`] — the same result as
`extract_ifrs_pdf(path)` but without re-running Docling, for when you have parsed the PDF once (with
`structured_document`) and want both its facts and, say, its `narratives` from the one parse.
"""
extract_ifrs_pdf(sd::StructuredDocument; accession::AbstractString = "", url::AbstractString = "") =
    _ifrs_facts_from_sd(sd; accession, url)

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

    # Is there a SEPARATE income statement — a "profit or loss" / "income statement" table that is NOT the
    # combined comprehensive-income one? If so, a standalone "statement of comprehensive income" is a DUPLICATE
    # and is skipped (its attributable line is comprehensive-income-attributable, not profit). If NOT, the filer
    # took the single-statement route (China Mobile, PetroChina): profit-or-loss lives INSIDE the "Statement of
    # Comprehensive Income", so it must be KEPT — `_ifrs_table_facts` then stops at the OCI section (below).
    _titleof(tbl) = strip(string(something(tbl.caption, ""), " ",
                                 get(sectitle, something(tbl.section_id, ""), ""), " ",
                                 join(get(pagetitles, Int(tbl.page_start), String[]), " ")))
    has_sep_is = any(t -> occursin(r"(?i)income statement|profit or loss", _titleof(t)) &&
                          !occursin(r"(?i)comprehensive income", _titleof(t)), sd.tables)

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
        # Skip a STANDALONE statement of comprehensive income (title says "comprehensive income", not "income
        # statement"/"profit or loss") — its "Equity holders of the Company" line is comprehensive-income-
        # attributable, which would collide with profit-attributable — but ONLY when a separate income statement
        # exists. A single-statement filer has none, so its comprehensive-income table IS the P&L and is kept.
        (stmt == "IncomeStatement" && occursin(r"(?i)comprehensive income", title) &&
         !occursin(r"(?i)income statement|profit or loss", title) && has_sep_is) && continue
        tscale, tcur = _ifrs_table_unit(tbl, scale, currency)   # this statement's OWN unit (£m vs a note's £'000)
        append!(facts, _ifrs_table_facts(tbl, stmt, stmt == "BalanceSheet", pends, tscale, tcur))
    end

    sel = Selection(; cik = "", accession = accession, url = url, selector = "", kind = :filing, facts = facts)
    return EDGAR.facts(sel)
end
