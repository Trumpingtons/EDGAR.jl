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
    if isempty(yrs)
        # Locales that head statement columns with a DATE, not a bare year: Brazilian "31/12/24", European
        # "31.12.2024", or the long "31 de dezembro de 2024" (pt/es) / "31 décembre 2024" (fr) forms.
        pool = join(vcat([s.title for s in sd.sections], [c.text for t in sd.tables for c in t.cells]), " ")
        for mm in eachmatch(r"\b\d{1,2}[./]\d{1,2}[./](\d{2})(\d{2})?\b", pool)
            y = mm.captures[2] === nothing ? 2000 + parse(Int, mm.captures[1]) : parse(Int, mm.captures[1] * mm.captures[2])
            (2000 <= y <= 2099) && push!(yrs, y)
        end
        for mm in eachmatch(Regex("(?i)(?:$_MON)\\s+(?:de\\s+|del\\s+)?(20\\d{2})"), pool)
            push!(yrs, parse(Int, mm.captures[1]))
        end
    end
    isempty(yrs) && return nothing
    uy = sort!(unique(yrs); rev = true)
    # Year-end month/day. Search section headings, captions, blocks AND table cells — a bank states the
    # year-end date only in the balance-sheet column-header CELL ("31 December 2025"), not in a heading.
    # Priority: (1) a fiscal-period phrase ("Year ended 31 December", "As at 31 March"); (2) else a month-END
    # date (day 28–31 — a real year-end, never a "1 January" opening-balance line from the equity statement);
    # (3) else any date. Steps 1–2 keep a stray prose date (a pension "31 May", a "1 January" opening) out.
    # English full names + German full names and abbreviations ("30. Sep. 2023", "31. Dezember 2024") — the
    # German editions state the year-end with an abbreviated month and a dot after the day.
    MON = _MON
    text = join(vcat([s.title for s in sd.sections], [something(t.caption, "") for t in sd.tables],
                     [b.text for b in sd.text_blocks], [c.text for t in sd.tables for c in t.cells]), " ")
    # Accept BOTH orders — "31 December" (day-month, HK/UK) and "December 31" (month-day, US-style, e.g.
    # PetroChina) — plus the pt/es "31 de dezembro" long form (optional "de") and the Brazilian/European
    # NUMERIC "31/12/24" / "31.12.2024" year-end header. Priority: a fiscal-period phrase; then a month-END
    # date (a real year-end, never a "1 January" / "January 1" opening); then any date. The name tiers come
    # before the numeric one so an English/German month NAME wins; numerics catch the locales that print none.
    fc = "(?:year|period)?\\s*(?:ended|ending|as at|as of)\\s+"
    m = nothing
    for rx in ["(?i)$fc(\\d{1,2})\\.?\\s+(?:de\\s+)?($MON)", "(?i)$fc($MON)\\s+(\\d{1,2})",
               "(?i)(28|29|30|31)\\.?\\s+(?:de\\s+)?($MON)", "(?i)($MON)\\s+(28|29|30|31)\\b",
               "(28|29|30|31)[./](0?[1-9]|1[0-2])[./]\\d{2,4}",
               "(?i)(\\d{1,2})\\.?\\s+(?:de\\s+)?($MON)", "(?i)($MON)\\s+(\\d{1,2})\\b"]
        m = match(Regex(rx), text); m === nothing || break
    end
    if m === nothing
        mo, dy = 12, 31
    elseif occursin(r"^\d+$", String(m.captures[1])) && occursin(r"^\d+$", String(m.captures[2]))
        dy, mo = parse(Int, m.captures[1]), parse(Int, m.captures[2])   # numeric "31/12" → day, month
    else
        a1 = occursin(r"[A-Za-z]", String(m.captures[1]))               # month captured first (month-day order)?
        mo = monthabbr_to_num(m.captures[a1 ? 1 : 2])
        dy = parse(Int, m.captures[a1 ? 2 : 1])
    end
    return (mo, dy, uy)
end

# Month names are RE-HOMED to the language registry (src/core/languages.jl), per language; this is a VIEW that
# merges them (shared names like "mai"/"marzo"/"agosto" carry the same value in every profile, so the merge is
# lossless). Add a language's months there, on its `LanguageProfile`, not here.
const _IFRS_MONTHS = Dict(language_month_pairs())
monthabbr_to_num(s) = get(_IFRS_MONTHS, lowercase(String(s)), 12)
# Month-name alternation for the date regexes, built from the dict (longest first so "december" beats "dec").
const _MON = join(sort(collect(keys(_IFRS_MONTHS)); by = length, rev = true), "|")

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
    # Euro next: a €/EUR-denominated set (German IFRS) never carries HK$/£. Match a genuine unit expression in
    # EITHER order — the English edition writes "millions of €" (magnitude first, symbol after), the German one
    # "Mio. €" / "Millionen"; thousands are "TEUR" / "T€" / "thousands of €". A stray prose "EUR"/"USD" is not a
    # unit expression, so it can't trigger a false EUR. Prefer millions over thousands within one pool.
    # magnitude-first + symbol-after in several languages: en "millions of €", de "Mio. €"/"Millionen", es
    # "millones de euros", pt "milhões de euros", it "milioni di euro", fr "millions d'euros".
    eur_m = any(occursin(r"(?i)(EUR|€)\s*'?\s*(m\b|million)|million[s]?\s+(of\s+)?(EUR|€|euro)|\bMio\.?\s*€|\bMillionen\b|mill(?:ón|ones)\s+de\s+euros?|milh(?:ão|ões)\s+de\s+euros?|milioni\s+di\s+euro", s) for s in texts)
    eur_k = any(occursin(r"(?i)\bTEUR\b|T€|(EUR|€)\s*'?\s*(thousand|000)\b|thousand[s]?\s+(of\s+)?(EUR|€|euro)|\bTsd\.?\s*€|mil(?:es|hares)\s+de\s+euros?", s) for s in texts)
    (eur_m || eur_k) && return (eur_m ? 1e6 : 1e3, "EUR")
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
    # fallback: magnitude alone, currency by presence (HK$ preferred — the HK default). The magnitude word is
    # matched across the supported languages (sv miljoner/MSEK, fi miljoonaa, da/no millioner, nl miljoen, it
    # milioni, es millones, pt milhões, pl milionów) — the English-only regex silently defaulted a Swedish
    # "MSEK" report to thousands (values 1000x too small).
    text = join(texts, " ")
    scale = occursin(r"(?i)million|\bMio\.?\b|\bMilj\.|\bMillionen\b|miljoner|miljoona|millioner|miljoen|milioni|mill[oó]n|milhõe?s?|milh[ãa]o|\bmilion\w*|\bmln\b|\bM(?:SEK|EUR|NOK|DKK)\b|\bMkr\b", text) ? 1e6 :
            occursin(r"(?i)'?000\b|thousand|\bTEUR\b|T€|tusen|tuhat|tusind|duizend|tysi[ąa]c|migliaia|\bmiles\b|milhares|\bTSEK\b|\bTkr\b", text) ? 1e3 : 1.0
    cur = occursin(r"(?i)\bMSEK\b|\bTSEK\b|\bSEK\b|svenska kronor|\bMkr\b", text) ? "SEK" :
          occursin(r"(?i)\bNOK\b|norske kroner", text) ? "NOK" :
          occursin(r"(?i)\bDKK\b|danske kroner", text) ? "DKK" :
          occursin(r"(?i)\bPLN\b|złot", text) ? "PLN" :
          occursin(r"(?i)canadian dollar|\bCAD\b|\bC\$", text) ? "CAD" :
          occursin(r"(?i)australian dollar|\bAUD\b|\bA\$", text) ? "AUD" :
          occursin(r"(?i)singapore dollar|\bSGD\b|\bS\$", text) ? "SGD" :
          occursin(r"(?i)US\$|\bUSD\b|\bU\.S\. dollar|united states dollar", text) ? "USD" :
          occursin(r"(?i)HK\$|\bHKD\b|hong kong dollar", text) ? "HKD" :
          occursin(r"(?i)\bRMB\b|人民[币幣]|renminbi|\byuan\b", text) ? "CNY" :
          occursin(r"(?i)japanese yen|\bJPY\b|\byen\b|円", text) ? "JPY" :
          occursin(r"(?i)swiss franc|\bCHF\b", text) ? "CHF" :
          occursin(r"(?i)£|pound sterling|\bGBP\b", text) ? "GBP" :
          (occursin('€', text) || occursin(r"(?i)\bEUR\b|\bTEUR\b|\beuro\b", text)) ? "EUR" : "XXX"
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

# Full-units guard. A report can state DIFFERENT scales per statement — Enel's income statement is "in milioni
# di euro" but its balance sheet prints FULL euros ("71.244.987.342"). A balance-sheet table that carries no
# unit token of its OWN then inherits the document-wide "millions" scale and is multiplied by 1e6 into nonsense
# (7e16). No real company total exceeds ~1e13, so if the table's own largest value already blows past that ceiling
# once scaled, its values are already in full units → drop the scale to 1. Only kicks in for `scale > 1`.
const _IFRS_TOTAL_CEILING = 1e13
function _ifrs_sane_scale(tbl, scale::Float64, loc::Symbol)
    scale <= 1 && return scale
    vals = Float64[]
    for c in tbl.cells
        p = parse_amount(c.text; locale = loc)
        (p === nothing || p.nil || p.val == 0) || push!(vals, abs(p.val))
    end
    isempty(vals) && return scale
    # Use the MEDIAN, not the max: a full-units statement (Enel's BS) has MOST values already large, whereas a
    # millions statement with one mis-parsed outlier cell does not — so a stray big cell can't strip the scale.
    med = sort!(vals)[cld(length(vals), 2)]
    return med * scale > _IFRS_TOTAL_CEILING ? 1.0 : scale
end

# A monetary VALUE cell (a grouped-thousands separator or a parenthesised negative). Locale-aware: the German
# (`:eu_dot`) reports write "47.996" (dot thousands) / "8,50" (comma decimal), so the number parse must use the
# document's locale — parsing "47.996" as en would read it as 47.996, not 47 996.
_ifrs_ismoney(s, loc::Symbol = :en) = (t = strip(String(s));
                    (occursin(',', t) || occursin('(', t) || occursin(r"\d\.\d", t) ||
                     (loc == :eu_space && occursin(r"\d[\s\x{a0}\x{202f}]\d", t))) &&   # FR/RU space-thousands "184 125" (incl. NBSP/narrow-NBSP) carries no comma/dot
                    (p = parse_amount(t; locale = loc); p !== nothing && !p.nil))

# A VALUE cell in an ALREADY-CONFIRMED value column: a plain number is enough, no thousands separator needed —
# BASF's small 2023 net income ("379", "225") carries none. Looser than `_ifrs_ismoney` (which gates column
# DETECTION, where a separator guards against mistaking a note column for a value column); a bare year is
# excluded so a header row is not read as data.
_ifrs_isval(s, loc::Symbol = :en) = (t = strip(String(s)); !occursin(_YEAR_ONLY, t) &&
                    (p = parse_amount(t; locale = loc); p !== nothing && !p.nil))

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
                            scale::Float64, currency::AbstractString, loc::Symbol = :en)
    nr, nc = tbl.n_rows, tbl.n_cols
    isempty(pends) && return Fact[]
    grid = Dict{Tuple{Int,Int},String}(); hdr = Dict{Tuple{Int,Int},String}()
    for c in tbl.cells
        grid[(c.row, c.col)] = strip(c.text)
        for cc in c.col:(c.col + max(c.colspan, 1) - 1)          # expand colspans for HEADER lookup: a spanning
            hdr[(c.row, cc)] = strip(c.text)                     # header ("Six months ended" over both year cols)
        end                                                     # must reach every column it covers
    end
    # value columns: ≥2 monetary body cells (a bare-number Note column of "13" / "32 (a)" is not monetary, so it
    # is excluded). Two German-layout traps are dropped explicitly:
    #   • a PERCENTAGE column — a "Veränderung zum Vorjahr" %-change column (Fielmann "11,9%") parses as numbers;
    #   • a NOTE-reference column whose refs are PARENTHESISED ("(30)", Fielmann) and so read as negative amounts
    #     — excluded by its header ("Textziffer im Anhang" / "Ziffer" / "Anhang"), since the values can't tell it
    #     apart from a real column.
    _ispctcol(c) = count(r -> occursin('%', get(grid, (r, c), "")), 0:nr-1) >= 2
    _isnotecol(c) = occursin(r"(?i)textziffer|\bziffer\b|\banhang\b|anmerkung|\bnotes?\b|\bnotas?\b", join([get(grid, (r, c), "") for r in 0:min(2, nr-1)], " "))
    valcols = [c for c in 0:nc-1 if !_ispctcol(c) && !_isnotecol(c) &&
                                    count(r -> _ifrs_ismoney(get(grid, (r, c), ""), loc), 0:nr-1) >= 2]
    isempty(valcols) && return Fact[]
    firstbody = something(findfirst(r -> any(_ifrs_ismoney(get(grid, (r, c), ""), loc) for c in valcols), 0:nr-1),
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
            (!isempty(s) && occursin(r"[A-Za-zÄÖÜäöüß]", s) && parse_amount(s; locale = loc) === nothing &&
             !_ifrs_isnoteref(s)) && push!(lcells, s)
        end
        label = strip(join(lcells, " "))
        # In a COMBINED profit-or-loss-and-OCI statement, stop at the OCI / total-comprehensive-income section:
        # everything below is other comprehensive income — including a second "attributable to owners" that is
        # comprehensive-income-attributable, not profit (China Mobile lists it under "Total comprehensive income
        # attributable to:" on a continuation page). The income statement we map ends at "profit for the year".
        (stmt == "IncomeStatement" && occursin(r"(?i)(?:other|total) comprehensive income", label)) && break
        # Stop at the earnings-per-share block: a German income statement REPEATS the "Gewinn nach Steuern" label
        # as a per-share EPS line, which would otherwise re-map to profit with the (tiny) EPS value. Match the EPS
        # SECTION header ("(Un)verwässertes Ergebnis je Aktie" / "…earnings per share"), NOT the unit caption
        # "(in Mio. €, Ergebnis je Aktie in €)" which merely names the EPS unit.
        (stmt == "IncomeStatement" && occursin(r"(?i)verwässertes ergebnis je aktie|earnings per share", label)) && break
        hasval = any(_ifrs_isval(get(grid, (r, c), ""), loc) for c in keep)   # keep cols are value cols: a bare number counts
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
            raw = get(grid, (r, c), "")
            # Drop a Docling ROW-MERGE artifact: two stacked lines glued into one cell leave two number groups
            # separated by a space ("1,507 5,767"). In a comma/dot locale (no space-grouped thousands) that is
            # two values, not one — skip it rather than let parse_amount concatenate them into a giant number.
            (loc in (:en, :eu_dot) && occursin(r"\d[\d.,]*\s+[\d(]", strip(raw))) && continue
            p = parse_amount(raw; locale = loc)
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

    # Account-form (Kontoform) grand total. A two-sided German balance sheet prints the total (Bilanzsumme) on
    # an UNLABELED foot row — no "Summe Aktiva"/"Summe Passiva" line — so the label pass above misses it. When
    # the table is a single side ("Aktiva" alone, or "Passiva" alone; a combined table already carries labelled
    # totals) and that side's total was not otherwise found, take the LAST row whose every kept column holds a
    # value — the balance total, whether printed on an UNLABELED foot row (Fielmann) or a LABELED "Bilanzsumme"
    # one (Volkswagen): on the assets side it is Assets, on the equity+liabilities side EquityAndLiabilities.
    if stmt == "BalanceSheet"
        top = join([get(grid, (r, c), "") for r in 0:min(2, nr - 1) for c in 0:nc-1], " ")
        has_ak = occursin(r"(?i)\baktiva\b", top); has_pa = occursin(r"(?i)\bpassiva\b", top)
        side = (has_ak && !has_pa) ? "ifrs-full:Assets" : (has_pa && !has_ak) ? "ifrs-full:EquityAndLiabilities" : nothing
        if side !== nothing && !any(f -> f.concept == side, out)
            for r in (nr-1):-1:0
                all(_ifrs_ismoney(get(grid, (r, c), ""), loc) for c in keep) || continue
                for c in keep
                    p = parse_amount(get(grid, (r, c), ""); locale = loc); (p === nothing || p.nil) && continue
                    push!(out, Fact(; concept = side, label = "Bilanzsumme", value = p.val * scale, unit = primary,
                          period_start = nothing, period_end = colend[c], is_instant = true, statement = stmt,
                          context_ref = string(colend[c]), unit_ref = primary,
                          source_selector = "{\"table\":$(repr(tbl.table_id)),\"row\":$r,\"col\":$c}"))
                end
                break
            end
        end
    end
    return out
end

# Consolidated-statements page range, TOC-first (the AR outline's statement bookmarks), heading-scan fallback.
# `_dekonz` (the German Konzern prefix/suffix/Gruppe shape) is defined in core/languages.jl, alongside the
# re-homed per-language statement patterns; the uses below resolve to it.
# --- Multilingual primary-statement HEADINGS (2R.B) ---------------------------------------------------
# The statement-location scan and the presentation-language sniff share ONE source of truth: the primary-
# statement heading names per language, keyed by type (:is P&L / comprehensive income, :bs balance sheet,
# :cf cash flow, :eq changes in equity). English keeps "consolidated" REQUIRED (the bare names — "balance
# sheet", "income statement" — echo in the parent-company set, MD&A and note headings). The Romance
# languages (pt/fr/it/es) make it OPTIONAL: Enel/WEG statement headings don't repeat "consolidado/consolidato",
# so the primary-CLUSTER + TOC validation in `_ifrs_statement_pages` disambiguates the echoes instead of the
# keyword — the plan's "match the statement TYPE structurally + multilingually, drop the hard 'consolidated'".
# Short ambiguous names (fr "bilan", es "balance") stay PINNED to their consolidé/situación qualifier so they
# can't match prose. German is structurally different (Konzern prefix/suffix/Gruppe) and stays on `_dekonz`
# below. Line-item LABEL translation (pt/fr/… → ifrs-full) is a SEPARATE concern (2R.D). See §2R.B.
# The per-language statement patterns (+ default jurisdiction) are RE-HOMED to the language registry
# (core/languages.jl); this is a VIEW over it — one entry per language with non-empty `stmt_patterns` (en, pt,
# es, fr, de, it). German is a normal entry there (its bodies pre-expanded through `_dekonz`), so there is no
# separate `_DE_STEMS` any more. Add a language's statement patterns there, on its `LanguageProfile`.
const _STMT_LANGS = [(p.code, p.jurisdiction, p.stmt_patterns) for p in SUPPORTED_LANGS if !isempty(p.stmt_patterns)]
# The union heading-body for one statement type across ALL languages, from the registry bodies (already
# includes German's Konzern shapes and the "Entwicklung des Konzern-Eigenkapitals" :eq form). Alternation order
# is immaterial for the `occursin`/`eachmatch` uses in the locator.
_stmt_body(ty::Symbol) = join([d[ty] for (_, _, d) in _STMT_LANGS], "|")
const _IFRS_STMT_ORDER = (:is, :bs, :cf, :eq)
# The four primary-statement TYPES, each a union regex across languages — used by the heading-scan fallback
# to locate the statement CLUSTER (the window where the most distinct types co-occur), not a stray mention.
const _IFRS_STMT_TYPES = [(ty, Regex("(?i)" * _stmt_body(ty))) for ty in _IFRS_STMT_ORDER]
# The PDF-outline bookmark titles that mark a primary statement — the same multilingual bodies.
const _IFRS_STMT_TITLES = [r for (_, r) in _IFRS_STMT_TYPES]

# Reading-order text of a page with words SPACE-joined (unlike `_cas_pagetext`, which joins tight for CJK) —
# needed to read a table-of-contents line "64 Konzernbilanz …" where the page number and title are separate
# tokens, and to read the printed page number that leads a page.
function _ifrs_spacedtext(pg)
    ts = sort([(y = Float64(w.y), x = Float64(w.x), s = String(w.str)) for w in pg.words];
              by = t -> (round(t.y / 3.5), t.x))
    return join((t.s for t in ts), " ")
end

# A page's PRINTED page number — the standalone integer that leads the running header/footer (PDF page 66 of a
# Fielmann report prints "64"). Read from the first few reading-order tokens. `nothing` if none.
function _ifrs_printed_pageno(pg)
    ts = sort([(y = Float64(w.y), x = Float64(w.x), s = strip(String(w.str))) for w in pg.words];
              by = t -> (round(t.y / 3.5), t.x))
    for t in first(ts, min(8, length(ts)))
        occursin(r"^\d{1,4}$", t.s) && return parse(Int, t.s)
    end
    return nothing
end

# The printed-TOC title bodies per statement type (multilingual) — used by `_ifrs_toc_range` to read a
# "<printed-page> <title>" / "<title> <printed-page>" line off an Inhalt/Contents/Índice/Sommaire page.
const _IFRS_TOC_TYPES = [(ty, _stmt_body(ty)) for ty in (:bs, :is, :cf, :eq)]

# Locate the primary consolidated statements via the printed TABLE OF CONTENTS. A large German report reprints
# the statements several times (a segment breakdown, a condensed set in the management report, the AUDITED
# Konzernabschluss, the HGB parent) — the outline/heading-scan can latch onto the wrong copy. The Inhalt page
# lists the audited set with its PRINTED page numbers ("64 Konzernbilanz …"); mapping those to PDF pages (each
# page leads with its printed number) pins the audited cluster. Returns a PDF page range, or `nothing` when
# there is no parseable TOC (English reports, section-relative numbering) — the caller then falls back.
function _ifrs_toc_range(doc; margin::Int = 8)
    npg = length(doc.pages)
    p2pdf = Dict{Int,Int}()                                   # printed page number → PDF page (first wins)
    for pg in doc.pages
        n = _ifrs_printed_pageno(pg); n === nothing || get!(p2pdf, n, Int(pg.page))
    end
    isempty(p2pdf) && return nothing
    # The TOC page is the one listing the most DISTINCT statement types, each as "<printed-page> <title>".
    best_prs = Int[]; best_types = 0
    for pg in doc.pages
        txt = _ifrs_spacedtext(pg); prs = Int[]; tys = Set{Symbol}()
        for (ty, body) in _IFRS_TOC_TYPES
            de = body
            # A TOC lists the page number BEFORE the title ("64 Konzernbilanz", Fielmann) or AFTER it
            # ("Bilanz 270", Volkswagen's two-column TOC). Capture both; keep only plausible page numbers
            # (≤ page count) so a year in the title ("… 2023") is not mistaken for a page.
            for m in eachmatch(Regex("(?i)(\\d{1,4})\\s+(?:$de)"), txt)
                n = parse(Int, m.captures[1]); (1 <= n <= npg) && (push!(prs, n); push!(tys, ty))
            end
            for m in eachmatch(Regex("(?i)(?:$de)\\s+(\\d{1,4})\\b"), txt)
                n = parse(Int, m.captures[1]); (1 <= n <= npg) && (push!(prs, n); push!(tys, ty))
            end
        end
        length(tys) > best_types && (best_types = length(tys); best_prs = prs)
    end
    # A page listing 2+ statement types each with an adjacent page number IS a TOC (on a real statement page the
    # header number is far from the heading, so it never matches). The mapped range is then VALIDATED by the
    # caller against the actual headings, so a rare false TOC is caught there — 2 is a safe detection floor.
    best_types < 2 && return nothing
    pdfs = Int[p for p in (get(p2pdf, pr, nothing) for pr in best_prs) if p !== nothing]
    length(pdfs) < 2 && return nothing                        # printed pages didn't map (section-relative etc.)
    lo, hi = minimum(pdfs), maximum(pdfs)
    (hi - lo > 30) && return nothing                          # a real primary-statement cluster is tight
    return (lo, min(hi + margin, npg))
end

# Per-page primary-statement types from the spaced-text scan, EXCLUDING contents/index pages: a German "Inhalt"
# (or a filing index) lists every statement name on ONE page (3+ distinct types), whereas a real primary
# statement page shows one statement (a P&L + its comprehensive-income sibling still count as one type). Shared
# by the locator, the TOC validation, and the has-statements signal (2R.F).
function _ifrs_pgtypes(doc)
    pgtypes = Dict{Int,Set{Symbol}}()
    for pg in doc.pages
        s = Set{Symbol}(); txt = _ifrs_spacedtext(pg)          # SPACED (not tight): the suffix/Gruppe forms
        for (ty, rx) in _IFRS_STMT_TYPES; occursin(rx, txt) && push!(s, ty); end   # need whitespace to match
        (isempty(s) || length(s) >= 3) || (pgtypes[Int(pg.page)] = s)
    end
    return pgtypes
end

# How many DISTINCT primary-statement types the document shows on its statement pages — the discriminator (2R.F)
# between a THIN report (an integrated/summary report that carries none of the detailed statements — Vale points
# to its website/CVM for them → ~0) and a real statement set (BS/IS/CF co-occur → ≥3). Lets a caller tell "this
# document has no detailed statements" from "the statements are here but the locator missed them".
_ifrs_stmt_signal(doc) = length(reduce(union, values(_ifrs_pgtypes(doc)); init = Set{Symbol}()))

function _ifrs_statement_pages(doc; window::Int = 14)
    npg = length(doc.pages)
    pgtypes = _ifrs_pgtypes(doc)
    _ntypes(lo, hi) = length(reduce(union, (get(pgtypes, p, Set{Symbol}()) for p in lo:hi); init = Set{Symbol}()))
    # Strategy 1 — the printed TOC, VALIDATED: trust its range only when the mapped pages really hold the
    # statements (≥3 types). This is the reliable path for multi-section reports whose outline points at a
    # reprint (Volkswagen), and it self-rejects when the TOC uses section-relative numbering (Siemens).
    toc = _ifrs_toc_range(doc)
    toc !== nothing && _ntypes(toc[1], toc[2]) >= 3 && return toc
    # Strategy 2 — the PDF outline's statement bookmarks. The primary set is CONTIGUOUS, so cluster the matched
    # bookmark pages by gaps and keep the densest run — a stray MD&A bookmark that trips a bare name ("Off-
    # Balance Sheet Arrangements" → :bs) sits far from the real cluster and would otherwise balloon the range.
    if haskey(doc, :outline) && doc.outline !== nothing && !isempty(doc.outline)
        sp = Int[]
        for e in doc.outline
            p = get(e, :page, nothing); p === nothing && continue
            t = String(get(e, :title, ""))
            any(occursin(rx, t) for rx in _IFRS_STMT_TITLES) && push!(sp, Int(p))
        end
        if !isempty(sp)
            sort!(unique!(sp))
            runs = [[sp[1]]]                                   # split where consecutive pages gap by > 8
            for p in sp[2:end]; (p - runs[end][end] <= 8) ? push!(runs[end], p) : push!(runs, [p]); end
            best = argmax(length, runs)
            return (minimum(best), min(maximum(best) + 3, npg))
        end
    end
    # Strategy 3 — heading-scan: the `window` where the most DISTINCT consolidated statement types co-occur (a
    # long report mentions statement titles many times — MD&A, parent-company statements, note headings — so a
    # cluster beats a stray first mention).
    isempty(pgtypes) && return nothing
    best_lo, best_n = minimum(keys(pgtypes)), 0
    for lo in sort!(collect(keys(pgtypes)))
        n = _ntypes(lo, min(lo + window, npg))
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
# Per-language sniff regex (all four statement types unioned) → the doc's presentation language. Built from the
# same registry statement patterns (German included — its bodies are pre-expanded through `_dekonz`). Drives the
# number LOCALE: a Brazilian/French/Italian report is decimal-comma (not the en dot-decimal default), and a
# mis-locale silently corrupts every extracted value. English is excluded (it is the default fallback).
const _LANG_SNIFF =
    [(lang, juris, Regex("(?i)" * join(collect(values(d)), "|"))) for (lang, juris, d) in _STMT_LANGS if lang != "en"]

# Sniff the presentation language from the primary-statement headings so the number locale is right (a German
# report carries "Konzern-Bilanz"; a Brazilian one "Balanço Patrimonial"; a French one "Bilan consolidé").
# Picks the language whose statement names appear on the most pages; defaults to the English/HK path (`:en`
# locale) when none do. Returns `(jurisdiction, language)`.
function _ifrs_doc_juris(doc)
    texts = [_ifrs_spacedtext(pg) for pg in doc.pages]
    best = ("HK", "en"); bestn = 0
    for (lang, juris, rx) in _LANG_SNIFF
        n = count(t -> occursin(rx, t), texts)
        n > bestn && (bestn = n; best = (juris, lang))
    end
    return best
end

function extract_ifrs_pdf(path::AbstractString)
    doc = _pdf_words(path)
    juris, lang = _ifrs_doc_juris(doc)
    # A mainland (SIMPLIFIED-Chinese, CAS) report is not IFRS — sniff it here and hand off to the CAS extractor
    # (its own statement locator + `cas:` label map). Lets the GENERIC PDF path handle a mainland filing NOT
    # discovered via CNINFO (a `China()` filing already routes to `extract_cas_pdf` upstream). Only Simplified
    # matches `_SP_ZH`, so a Traditional-Chinese Hong Kong report (HKFRS ≈ IFRS) is NOT delegated — it correctly
    # stays on this IFRS path.
    lang == "zh" && return extract_cas_pdf(path)
    rng = _ifrs_statement_pages(doc)
    if rng === nothing
        # 2R.F — tell "this document has no detailed statements" from "the statements are here but I missed
        # them". A THIN report (integrated/summary, e.g. Vale — which points to its website/CVM for the
        # accounts) shows almost no statement-type headings; return no facts, honestly. When 2+ statement
        # types ARE present, the locator genuinely failed → surface it as a coverage gap, not a silent empty.
        if _ifrs_stmt_signal(doc) >= 2
            throw(ArgumentError("primary statements appear present but could not be located in " *
                                "$(repr(basename(path))) — likely an extractor coverage gap"))
        end
        @info "extract_ifrs_pdf: no detailed primary statements in $(repr(basename(path))) " *
              "(looks like a summary/integrated report) — returning no facts"
        return FactRow[]
    end
    sd = structured_document(path; pages = rng, jurisdiction = juris, language = lang)
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
    loc = amount_locale(sd.document.jurisdiction)               # number-separator class (DE → :eu_dot, else :en)
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
    # Short text PARAGRAPHS by page — some filers (WEG) render the statement NAME ("Balanço Patrimonial …")
    # as a bold paragraph, not a Docling section heading, so it never reaches `pagetitles`. Keep only heading-
    # length blocks (≤ 80 chars) so a note sentence mentioning "balance sheet" can't misclassify a table.
    pageblocks = Dict{Int,Vector{String}}()
    for b in sd.text_blocks
        (b.kind == "paragraph" && length(b.text) <= 80) || continue
        push!(get!(pageblocks, Int(b.page), String[]), b.text)
    end

    # Is there a SEPARATE income statement — a "profit or loss" / "income statement" table that is NOT the
    # combined comprehensive-income one? If so, a standalone "statement of comprehensive income" is a DUPLICATE
    # and is skipped (its attributable line is comprehensive-income-attributable, not profit). If NOT, the filer
    # took the single-statement route (China Mobile, PetroChina): profit-or-loss lives INSIDE the "Statement of
    # Comprehensive Income", so it must be KEPT — `_ifrs_table_facts` then stops at the OCI section (below).
    _titleof(tbl) = strip(string(something(tbl.caption, ""), " ",
                                 get(sectitle, something(tbl.section_id, ""), ""), " ",
                                 join(get(pagetitles, Int(tbl.page_start), String[]), " ")))
    # The table's OWN name (caption + its section), WITHOUT the shared page headings — a German report puts the
    # P&L ("… Gewinn- und Verlustrechnung") and the comprehensive-income statement ("… Gesamtergebnisrechnung")
    # on ONE page, so their common page-title can't tell them apart; the section title can.
    _owntitle(tbl) = strip(string(something(tbl.caption, ""), " ", get(sectitle, something(tbl.section_id, ""), "")))
    _is_pl(t) = occursin(r"(?i)income statement|profit or loss|gewinn-?\s*und\s*verlustrechnung", t)
    _is_ci(t) = occursin(r"(?i)comprehensive income|gesamtergebnisrechnung", t)
    has_sep_is = any(t -> (_is_pl(_owntitle(t)) && !_is_ci(_owntitle(t))) ||
                          (_is_pl(_titleof(t)) && !_is_ci(_titleof(t))), sd.tables)

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
        pgblk = join(get(pageblocks, Int(tbl.page_start), String[]), " | ")
        cls = classify_table_class(cap)
        cls === nothing && (cls = classify_table_class(sectit))
        cls === nothing && (cls = classify_table_class(pgtit))
        cls === nothing && (cls = classify_table_class(pgblk))   # statement name as a paragraph (WEG)
        # An account-form balance sheet often carries no statement title — only a leading "Aktiva"/"Passiva"
        # (DE) or "Ativo"/"Passivo" (PT) / "Attività"/"Passività" (IT) heading cell (BASF's Passiva page heading
        # is just the running header; Volkswagen prints "Passiva" below the unit/year header; WEG's "Ativo"/
        # "Passivo" sit a few rows in, under the Controladora/Consolidado column headers) — so classify from that
        # marker when nothing else matched. Require the marker to START a cell (not appear mid-prose).
        cls === nothing && any(occursin(r"(?i)^\s*(aktiva|passiva|ativo|passivo|attivit[àa]|passivit[àa])\b", strip(c.text))
                               for c in tbl.cells if c.row <= 3) && (cls = "balance_sheet")
        title = strip(string(cap, " ", sectit, " ", pgtit))
        stmt = cls == "balance_sheet" ? "BalanceSheet" : cls == "income_statement" ? "IncomeStatement" :
               cls == "cash_flow" ? "CashFlow" : nothing
        stmt === nothing && continue                          # skip equity-changes matrix + unrecognised
        # Skip a STANDALONE statement of comprehensive income (title says "comprehensive income", not "income
        # statement"/"profit or loss") — its "Equity holders of the Company" line is comprehensive-income-
        # attributable, which would collide with profit-attributable — but ONLY when a separate income statement
        # exists. A single-statement filer has none, so its comprehensive-income table IS the P&L and is kept.
        # Prefer the table's OWN name for the CI-vs-P&L test (falls back to the full page title when the section
        # carries no statement name); a same-page German P&L + comprehensive-income pair is told apart this way.
        own = _owntitle(tbl)
        ci_title = (_is_pl(own) || _is_ci(own)) ? own : title
        (stmt == "IncomeStatement" && _is_ci(ci_title) && !_is_pl(ci_title) && has_sep_is) && continue
        tscale, tcur = _ifrs_table_unit(tbl, scale, currency)   # this statement's OWN unit (£m vs a note's £'000)
        tscale = _ifrs_sane_scale(tbl, tscale, loc)             # …unless its values are already full units (Enel BS)
        append!(facts, _ifrs_table_facts(tbl, stmt, stmt == "BalanceSheet", pends, tscale, tcur, loc))
    end

    sel = Selection(; cik = "", accession = accession, url = url, selector = "", kind = :filing, facts = facts)
    return EDGAR.facts(sel)
end
