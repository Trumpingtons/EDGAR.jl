# China CAS facts (C3) — recover the CONSOLIDATED financial statements from a CNINFO annual-report PDF and
# emit the same `Fact`s the XBRL path does, so facts/select_statement/the oracles work unchanged.
#
# Engine = DOCLING (Tier-2), not hand-rolled geometry. Table-structure recovery is Docling's job; here we add
# only the CAS *semantics* on top of its clean cells. The extraction is a HYBRID:
#   1. a cheap pdf.js pre-scan (`_pdf_words`) locates the consolidated-statements page range (first 合并资产
#      负债表 heading … the 财务报表附注 notes boundary) and reads the fiscal year off the cover — so
#   2. Docling runs on only those ~15 pages (not the whole 100+-page report), then
#   3. facts are derived from Docling's `DocTable` cells: statement kind from the table's caption/section
#      title (the CJK patterns already in `TABLE_CLASSES`) with a row-label content fallback for mis-titled
#      tables; consolidated kept, parent-company (母公司) skipped; each row's label classified through
#      `vocab_cas` (`cas_concept`); amounts parsed by the shared locale-aware `parse_amount`.
# CAS statements carry two period columns (current, prior) in that order and no relative-column dates on
# continuation pages, so periods come from the fiscal year (current = FY, prior = FY-1). The equity-changes
# statement is a component matrix, not a two-period statement, and is left to a later increment.
# See docs/dev/china-plan.md (C3) and the manual PDF chapter (Docling was selected over MinerU).

# --- fiscal year + statement-page location (cheap pdf.js pre-scan) --------------------------------

# Page text in reading order (pdf.js word order is unreliable), so multi-token headings read contiguously.
function _cas_pagetext(pg)
    ts = sort([(y = Float64(w.y), x = Float64(w.x), s = String(w.str)) for w in pg.words];
              by = t -> (round(t.y / 3.5), t.x))
    return join((t.s for t in ts), "")
end

# Fiscal year: the latest "YYYY年12月31日" balance-sheet date ON THE STATEMENT PAGES (`rng`) — the
# authoritative current period end (its two column headers are the current + prior year-ends). This beats
# the report title, which a 可视化年报 (visual report) fills with prior-year comparatives that mislead a
# title-mode vote (Yingtai). Falls back to the most frequent "YYYY年[年]度报告" across the whole document.
function _cas_fiscal_year(doc, rng=nothing)
    lo, hi = rng === nothing ? (1, length(doc.pages)) : rng
    dates = Int[]
    for pg in doc.pages
        (lo <= Int(pg.page) <= hi) || continue
        for m in eachmatch(r"(20\d{2})年12月31日", _cas_pagetext(pg)); push!(dates, parse(Int, m.captures[1])); end
    end
    isempty(dates) || return maximum(dates)
    counts = Dict{Int,Int}()
    for pg in doc.pages, m in eachmatch(r"(20\d{2})\s*年年?度报告", _cas_pagetext(pg))
        y = parse(Int, m.captures[1]); counts[y] = get(counts, y, 0) + 1
    end
    return isempty(counts) ? nothing : argmax(counts)
end

# The primary-statements page range: from the first page bearing a statement heading (合并资产负债表 …) to
# the last (+ a small buffer). Bounding by the statement HEADINGS — not by a 财务报表附注 mention — is
# deliberate: filers print "财务报表附注" as a running header on EVERY financial page (BYD), so a notes-text
# boundary collapses the range. The consolidated statements plus their 母公司 (parent) copies form one
# compact block ending just before the notes; the notes' own tables sit past the last statement heading.
const _CAS_STMT_HEADINGS = ("合并资产负债表", "合并利润表", "合并现金流量表", "合并所有者权益变动表",
                            "母公司资产负债表", "母公司利润表", "母公司现金流量表", "母公司所有者权益变动表")
# TOC-FIRST statement location from the PDF bookmarks (`doc.outline`, emitted by pdf_words.mjs). Bookmarks
# point at ABSOLUTE pages, so they are far more robust than searching page text (headings recur in the TOC,
# notes and running headers). Prefers per-statement bookmarks (合并资产负债表 …); else bounds by the
# financial-report SECTION start (第X节 财务报告 / 财务报表) up to the first notes bookmark (会计政策 / 报表
# 附注 / 公司基本情况). Returns (lo,hi) or nothing (no usable bookmarks → caller falls back to heading search).
function _cas_toc_range(doc)
    haskey(doc, :outline) || return nothing
    entries = doc.outline
    (entries === nothing || isempty(entries)) && return nothing
    npg = length(doc.pages)
    _pg(e)    = (p = get(e, :page, nothing); p === nothing ? nothing : Int(p))
    _title(e) = (t = get(e, :title, nothing); t === nothing ? "" : _cas_norm(String(t)))
    _lvl(e) = Int(get(e, :level, 9))
    sp = Int[]                                            # per-statement bookmarks (consolidated only)
    for e in entries
        p = _pg(e); p === nothing && continue
        t = _title(e)
        (occursin("附注", t) || occursin("项目", t) || occursin("范围", t)) && continue   # notes, not the statement
        occursin(r"合并(?:及(?:母)?公司)?(?:资产负债表|利润表|现金流量表)", t) && push!(sp, p)
    end
    isempty(sp) || return (minimum(sp), min(maximum(sp) + 3, npg))
    lo = nothing; hi = nothing                            # section-level: 财务报告/报表 start … notes start
    for e in entries
        p = _pg(e); p === nothing && continue
        t = _title(e); lvl = _lvl(e)
        if lo === nothing && lvl <= 1 && length(t) <= 12 && occursin(r"财务报[告表]", t) &&
           !occursin("附注", t) && !occursin("分析", t)   # a SHORT section title "第X章 财务报告" — not prose
            lo = p                                        # ("3.2 财务报表分析" in the MD&A, "…财务报告中…" etc.)
        elseif lo !== nothing && p > lo && hi === nothing && lvl <= 2 &&
               (occursin("会计政策", t) || occursin("报表附注", t) || occursin("基本情况", t))  # notes start (银行/公司)
            hi = p
        end
    end
    lo === nothing && return nothing
    return (lo, hi === nothing ? min(lo + 22, npg) : hi)
end

# Statement page range: TOC-first (bookmarks), falling back to a heading-anchored fixed window over the page
# text (the primary-statements block — BS/IS/CF/EC plus 母公司 copies — fits in ~20 pages; a WINDOW not
# first…last heading, since headings recur in the TOC/notes).
function _cas_statement_pages(doc; window::Int=22)
    toc = _cas_toc_range(doc)
    toc === nothing || return toc
    lo = nothing
    for pg in doc.pages                                   # also matches combined "合并及(母)公司资产负债表" (Midea)
        t = _cas_pagetext(pg)
        # the AUDIT REPORT enumerates every statement on one page ("…合并资产负债表、合并利润表、合并现金流量表…"),
        # which would anchor `lo` too early; a real balance-sheet page carries the BS heading but NOT a
        # cash-flow one, so require the BS heading in the ABSENCE of 现金流量表 to skip the audit enumeration.
        occursin(r"合并(?:及(?:母)?公司)?资产负债表", t) && !occursin("现金流量表", t) && (lo = Int(pg.page); break)
    end
    if lo === nothing
        for pg in doc.pages
            any(h -> occursin(h, _cas_pagetext(pg)), _CAS_STMT_HEADINGS) && (lo = Int(pg.page); break)
        end
    end
    lo === nothing && return nothing
    return (lo, min(lo + window, length(doc.pages)))
end

# Reporting-unit scale from a 单位…（万元|千元|元) marker in the parsed captions / text blocks / cells (万元 =
# 1e4, 千元 = 1e3, else 元 = 1). CAS statements state one unit for the whole set. The `[^万千元]{0,6}` tolerates
# text between 单位 and the unit (e.g. "单位为：千元", "单位：人民币千元").
# Reporting-unit scale is a property of the individual STATEMENT, not the document: a report may present its
# primary statements in 千元 while a governance/notes table on another page is in 万元. So map the 单位…
# declaration (in captions / text blocks) to the PAGE it appears on, and give each statement table its own
# page's unit — never a document-wide vote, which a differently-scaled non-statement table would corrupt.
function _cas_page_units(sd)
    _u(s) = (m = match(r"单位[^百万千元]{0,6}(百万元|万元|千元|元)", String(s));   # 百万元 = millions (banks)
             m === nothing ? nothing :
             m.captures[1] == "百万元" ? 1e6 : m.captures[1] == "万元" ? 1e4 : m.captures[1] == "千元" ? 1e3 : 1.0)
    units = Dict{Int,Float64}()
    for b in sd.text_blocks
        u = _u(b.text); u === nothing || (units[b.page] = u)
    end
    for t in sd.tables
        u = _u(something(t.caption, "")); u === nothing || get!(units, t.page_start, u)
    end
    return units
end

# Scale for a table starting on `page`: its own page's 单位 declaration, else the NEAREST declaring page in
# either direction (a "金额单位均为…" note may sit on a later statement page than the balance sheet — Ping An
# declares 百万元 on the cash-flow pages, after the BS), else 元 (1.0 — the CAS default when unstated).
function _cas_scale_at(units::Dict{Int,Float64}, page::Int)
    haskey(units, page) && return units[page]
    isempty(units) && return 1.0
    best = first(keys(units)); bd = abs(best - page)
    for p in keys(units)
        d = abs(p - page); d < bd && (best = p; bd = d)
    end
    return units[best]
end

# --- statement classification of a Docling table --------------------------------------------------

# A monetary VALUE cell: an amount carrying a thousands comma or a decimal point (so note-reference integers
# and bare years are excluded). Locale is :en for China (comma thousands, dot decimal).
_cas_ismoney(s) = (occursin(',', s) || occursin('.', s) || occursin('，', s) || occursin('．', s)) &&
                  (p = parse_amount(s; locale = :en); p !== nothing && !p.nil)

# The LAST monetary value in a cell — Docling sometimes MERGES a subtotal row and the following net-flow row
# into one cell (Midea CF: "(205,837,639) (87,901,802)" = 投资活动现金流出小计 + 投资活动使用的现金流量净额).
# The values stay in row order, so the net flow (what we want) is the last number. For a single number this
# just returns it; returns nothing when the cell has no monetary token.
function _cas_num_last(s)
    p = parse_amount(s; locale = :en)          # a genuine single number (cleans internal spaces) — common case
    (p !== nothing && !p.nil) && return p
    last = nothing                             # empty/nil OR a merged multi-number cell → scan numeric tokens
    for m in eachmatch(r"[（(]?[-−﹣－]?[\d,]+\.?\d*[）)]?", String(s))
        _cas_ismoney(m.match) && (last = m.match)
    end
    last === nothing ? nothing : parse_amount(last; locale = :en)
end

# A note-REFERENCE cell (dropped from labels): consists ONLY of note markers, Chinese/Arabic numerals and
# punctuation — "1", "注释 61", "附注七", "五、(四十一)". A real line-item label always carries content
# characters beyond these, so anything left after stripping this class marks it as a genuine label.
_cas_isnoteref(s) = isempty(strip(replace(String(s),
    r"[注释附一二三四五六七八九十百千零两\d a-zA-Z、，,\.．（）()\s　:：\-'‘’\"−﹣－]" => "")))

# Classify by the row labels when the caption/section title fails (Docling sometimes mis-titles a statement,
# e.g. the consolidated cash flow captioned with a running header). Scans col-0 labels for anchor terms.
function _cas_class_by_labels(labels)
    # a long financial-institution cash-flow statement splits across pages → Docling emits a SEPARATE table
    # per activity section, so accept any of the three (经营/投资/筹资)活动…现金流量 anchors, not just 经营.
    any(l -> occursin(r"(经营|投资|筹资)活动.{0,4}现金流量", l), labels) && return "cash_flow"
    any(l -> occursin("营业总收入", l) || occursin("营业利润", l) || occursin("营业收入", l), labels) && return "income_statement"
    # balance sheet: the totals OR either asset subtotal — the latter is essential because a multi-page BS
    # can split so a continuation page holds ONLY current assets (…流动资产合计) with the totals on the next
    # page. "负债合计" as a substring also catches 流动/非流动负债合计.
    any(l -> occursin("资产总计", l) || occursin("资产合计", l) || occursin("负债合计", l) ||
             occursin("流动资产合计", l) || occursin("非流动资产合计", l) ||
             occursin("股东权益合计", l) || occursin("所有者权益合计", l), labels) && return "balance_sheet"
    return nothing
end

# (statement, is_instant, is_parent) for a Docling table, or nothing (skip: equity matrix / descriptive).
function _cas_table_kind(tbl, title::AbstractString)
    t = _cas_norm(title)
    # pure 母公司 (corporate parent) or 个别 (a REIT/fund's standalone accounts) = the non-consolidated copy →
    # skip; 合并 / 合并及公司 kept. A REIT files 合并 AND 个别 statements, the latter being the fund-only view.
    isparent = (occursin("母公司", t) || occursin("个别", t)) && !occursin("合并", t)
    cls = classify_table_class(title)
    if cls === nothing
        cls = _cas_class_by_labels([_cas_norm(c.text) for c in tbl.cells if c.col == 0])
    end
    cls == "balance_sheet"    && return ("BalanceSheet", true, isparent)
    cls == "income_statement" && return ("IncomeStatement", false, isparent)
    cls == "cash_flow"        && return ("CashFlow", false, isparent)
    return nothing               # equity_changes (matrix) and unrecognised tables are skipped
end

# --- fact derivation from one table ---------------------------------------------------------------

# `combined`: a 合并及公司 table presents CONSOLIDATED and PARENT side by side (value columns
# [合并cur, 合并prior, 公司cur, 公司prior]). Docling's per-row column alignment for these wide tables is
# inconsistent (the note cell is present on some rows, absent on others → column shifts), so a GLOBAL
# value-column list mis-maps. For combined tables we instead take, per row, the FIRST TWO monetary cells as
# the consolidated (current, prior) pair — the consolidated columns always sit left of the parent pair.
function _cas_table_facts(tbl, stmt::AbstractString, instant::Bool, fy::Int, scale::Float64,
                          currency::AbstractString)
    nr, nc = tbl.n_rows, tbl.n_cols
    grid = Dict{Tuple{Int,Int},String}()
    for c in tbl.cells
        grid[(c.row, c.col)] = strip(c.text)
    end
    # value columns: those (col ≥ 1) holding several monetary cells (excludes the note-reference column).
    valcols = Int[]
    for c in 1:nc-1
        count(r -> _cas_ismoney(get(grid, (r, c), "")), 0:nr-1) >= 2 && push!(valcols, c)
    end
    sort!(valcols)
    isempty(valcols) && return Fact[]
    # A normal statement table has 2 value columns (current, prior); a 合并及公司 combined table has 4
    # (合并×2, 公司×2). Detect combined by the column count and switch to per-row consolidated extraction.
    combined = length(valcols) >= 3
    firstval = minimum(valcols)
    # For a 合并及公司 combined table the CONSOLIDATED columns are those LEFT of the first value column whose
    # header (top rows) says 公司/母公司 — the parent block. Restricting to that region (not just "the first
    # two monetary cells") is what makes Midea's 资产总计 come out MISSING rather than wrongly picking up the
    # parent value, when Docling drops its consolidated cells. `nc` = boundary not found (whole row).
    parent_col = nc
    if combined
        for r in 0:min(2, nr-1), c in 1:nc-1
            occursin("公司", get(grid, (r, c), "")) && (parent_col = min(parent_col, c))
        end
    end

    out = Fact[]
    for r in 0:nr-1
        # value cells for this row → (period_index, col). Normal: the global value columns. Combined: the
        # first two monetary cells WITHIN the consolidated column region (= consolidated current, prior).
        if combined
            mons = Int[c for c in 1:parent_col-1 if _cas_num_last(get(grid, (r, c), "")) !== nothing]
            isempty(mons) && continue
            usecols = [(i, mons[i]) for i in 1:min(2, length(mons))]
            fm = mons[1]
        else
            usecols = [(i, c) for (i, c) in enumerate(valcols) if _cas_ismoney(get(grid, (r, c), ""))]
            fm = firstval
        end
        # label = the leading TEXT columns before the values, excluding numeric cells and note references
        # ("注释 61", "附注七", "五、(四十一)"). Handles BS (label in col-0) and IS/CF (enumerator in col-0,
        # label in col-1, e.g. BYD), so the label can span several leading columns.
        lcells = String[]
        for c in 0:fm-1
            s = get(grid, (r, c), "")
            (!isempty(s) && parse_amount(s; locale = :en) === nothing && !_cas_isnoteref(s)) && push!(lcells, s)
        end
        label = join(lcells, "")
        isempty(label) && continue
        cc = cas_concept(label)
        for (i, c) in usecols
            p = combined ? _cas_num_last(get(grid, (r, c), "")) : parse_amount(get(grid, (r, c), ""); locale = :en)
            (p === nothing || p.nil) && continue
            pend = Date(fy - (i - 1), 12, 31)
            push!(out, Fact(; concept = cc === nothing ? _cas_labelkey(label) : cc.concept,
                  label = _cas_norm(label), value = p.val * scale, unit = currency,
                  period_start = instant ? nothing : Date(fy - (i - 1), 1, 1), period_end = pend,
                  is_instant = instant, statement = stmt, context_ref = string(pend), unit_ref = currency,
                  source_selector = "{\"table\":$(repr(tbl.table_id)),\"row\":$r,\"col\":$c}"))
        end
    end
    return out
end

# --- entry ----------------------------------------------------------------------------------------

"""
    extract_cas_pdf(path; currency="CNY") -> Vector{FactRow}

Extract the **consolidated** CAS financial statements (balance sheet, income statement, cash flow) from a
Chinese annual-report PDF at `path`, via Docling, as the same Tables.jl row table [`facts`](@ref) returns for
XBRL filings. A cheap pdf.js pre-scan locates the statements' page range and the fiscal year; Docling parses
just those pages; each table is classified (`TABLE_CLASSES` CJK captions + a row-label fallback), the
parent-company (母公司) copies dropped, and each row's Chinese label mapped through [`cas_concept`](@ref).
Periods come from the fiscal year (current column = FY, prior = FY−1). **Requires the Docling Tier-2 stack**
(`using PythonCall`); the equity-changes matrix is not yet derived.

```julia
rows = extract_cas_pdf(expanduser("~/EDGAR-Reports/CN-MotaiFR2023.pdf"))
select_statement(rows, "BalanceSheet")
```
"""
function extract_cas_pdf(path::AbstractString; currency::AbstractString = "CNY")
    doc = _pdf_words(path)
    rng = _cas_statement_pages(doc)
    rng === nothing && throw(ArgumentError("no consolidated balance sheet (合并资产负债表) found in $(repr(basename(path)))"))
    fy = _cas_fiscal_year(doc, rng)
    fy === nothing && throw(ArgumentError("could not determine the fiscal year from $(repr(basename(path)))"))

    sd = structured_document(path; pages = rng, jurisdiction = "CN", language = "zh")
    units = _cas_page_units(sd)                        # per-page 单位 scale (千元/万元/元)
    sectitle = Dict(s.section_id => s.title for s in sd.sections)

    # Parent-company (母公司) statement pages. Docling's per-table caption often drops the 母公司 heading (a
    # broker's parent statements caption as a bare unit note), so the in-title check in _cas_table_kind misses
    # them and the parent cash flow would then compete with the consolidated one via `max`. Mark a page parent
    # when its heading carries a 母公司…表 title without the 合并 counterpart, and skip tables starting there.
    parent_pages = Set{Int}()
    for pg in doc.pages
        t = _cas_pagetext(pg)
        (occursin(r"(?:母公司|个别)(?:资产负债表|利润表|现金流量表)", t) &&
         !occursin(r"合并(?:及(?:母)?公司)?(?:资产负债表|利润表|现金流量表)", t)) && push!(parent_pages, Int(pg.page))
    end

    facts = Fact[]
    for tbl in sd.tables
        # A table's own caption may be a bare "单位：人民币元"; the 合并/个别 designation then lives only in the
        # numbered section heading (11.1.2 个别资产负债表), so classify on caption + section title together.
        cap = something(tbl.caption, "")
        sectit = get(sectitle, something(tbl.section_id, ""), "")
        title = strip(string(cap, " ", sectit))
        k = _cas_table_kind(tbl, title)
        # page-based parent exclusion is a fallback for tables whose title carries NO 合并/个别/母公司 designation
        # (CITIC's parent cash flow captions as a bare unit note). When the title DOES say 合并/个别/母公司, trust
        # it — a REIT interleaves a consolidated statement's tail and its 个别 head on one page, so a page-level
        # skip would wrongly drop the consolidated rows sharing that page.
        ct = _cas_norm(title)
        titled = occursin("合并", ct) || occursin("个别", ct) || occursin("母公司", ct)
        isparent_page = !titled && (tbl.page_start in parent_pages)
        (k === nothing || k[3] || isparent_page) && continue   # skip unrecognised + parent-company statements
        scale = _cas_scale_at(units, tbl.page_start)  # each statement uses its OWN page's unit
        append!(facts, _cas_table_facts(tbl, k[1], k[2], fy, scale, currency))
    end

    # Recover a dropped 资产总计: in a CAS balance sheet 资产总计 ≡ 负债和所有者权益总计 (the balancing total),
    # but Docling sometimes drops the consolidated cells of one of them on a wide combined layout (Midea). If
    # total assets is missing for a period but the liabilities-and-equity total is present, fill it in.
    for pe in unique(f.period_end for f in facts if f.is_instant)
        any(f -> f.concept == "cas:Assets" && f.period_end == pe, facts) && continue
        i = findfirst(f -> f.concept == "cas:LiabilitiesAndEquity" && f.period_end == pe, facts)
        i === nothing && continue
        src = facts[i]
        push!(facts, Fact(; concept = "cas:Assets", label = "资产总计", value = src.value, unit = src.unit,
              period_start = nothing, period_end = pe, is_instant = true, statement = "BalanceSheet",
              context_ref = string(pe), unit_ref = src.unit, source_selector = src.source_selector))
    end

    # Recover a dropped 归属于母公司股东的净利润: in a CAS consolidated income statement it ≡ 净利润 −
    # 少数股东损益. Docling sometimes wraps the long parent-NI label across two rows (CITIC: "归属于母公司股东
    # 的净" | "利润" + value), stranding the value on a "利润"-only row that matches no concept. If parent net
    # income is missing for a period but net profit and minority-interest income are present, fill it in.
    for pe in unique(f.period_end for f in facts if f.statement == "IncomeStatement" && !f.is_instant)
        any(f -> f.concept == "cas:ProfitAttributableToParent" && f.period_end == pe, facts) && continue
        ip = findfirst(f -> f.concept == "cas:ProfitLoss" && f.period_end == pe, facts)
        im = findfirst(f -> f.concept == "cas:MinorityInterestIncome" && f.period_end == pe, facts)
        (ip === nothing || im === nothing) && continue
        p, m = facts[ip], facts[im]
        push!(facts, Fact(; concept = "cas:ProfitAttributableToParent", label = "归属于母公司股东的净利润",
              value = p.value - m.value, unit = p.unit, period_start = p.period_start, period_end = pe,
              is_instant = false, statement = "IncomeStatement", context_ref = string(pe), unit_ref = p.unit,
              source_selector = p.source_selector))
    end

    # Recover a dropped 现金及现金等价物净增加额: it equals 期末余额 − 期初余额 (Docling sometimes drops its
    # cells, e.g. Moutai's consolidated CF). Fill from the ending/beginning cash balances when both are present.
    for pe in unique(f.period_end for f in facts if f.statement == "CashFlow")
        any(f -> f.concept == "cas:NetIncreaseInCash" && f.period_end == pe, facts) && continue
        ie = findfirst(f -> f.concept == "cas:CashAtEndOfPeriod" && f.period_end == pe, facts)
        ib = findfirst(f -> f.concept == "cas:CashAtBeginningOfPeriod" && f.period_end == pe, facts)
        (ie === nothing || ib === nothing) && continue
        e, b = facts[ie], facts[ib]
        push!(facts, Fact(; concept = "cas:NetIncreaseInCash", label = "现金及现金等价物净增加额",
              value = e.value - b.value, unit = e.unit, period_start = e.period_start, period_end = pe,
              is_instant = false, statement = "CashFlow", context_ref = string(pe), unit_ref = e.unit,
              source_selector = e.source_selector))
    end

    sel = Selection(; cik = "", accession = basename(path), url = path, selector = "", kind = :filing, facts = facts)
    return EDGAR.facts(sel)
end
