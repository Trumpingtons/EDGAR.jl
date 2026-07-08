# HGB single-entity Jahresabschluss extractor (German-GAAP concepts) — the German-language analogue of
# `extract_cas_pdf`, for a *Jahresabschluss* whose Bilanz (§266) and GuV (§275) carry HGB labels. It recovers
# the primary statements from the PDF and emits `hgb:` Facts (via `hgb_concept`). Unlike the consolidated IFRS
# path (`extract_ifrs_pdf`) it is single-entity German-GAAP and handles the classic ACCOUNT-FORM (Kontoform)
# Bilanz whose numbers sit in a two-level column layout: per year a DETAIL column (line items) and a SUBTOTAL
# column (section totals). The last subtotal within a §266 section is that section's total; the last subtotal
# overall is the Bilanzsumme (which both sides equal). See docs/dev/germany-plan.md (G2).

# A §266/§275 SECTION header row ("A. Anlagevermögen", "C. Rückstellungen") — a leading capital-letter
# enumerator + a capitalised German noun, carrying no value of its own. Resets the current section.
_hgb_is_section(label) = occursin(r"^[A-E]\.\s+[A-ZÄÖÜ]", strip(String(label)))

# The German fiscal year-end + the comparative years, from the Bilanz column headers ("31.12.2019 31.12.2018")
# or a "zum 31. Dezember 2019" phrase. Returns (month, day, years-desc) or nothing.
function _hgb_period(sd)
    text = join(vcat([s.title for s in sd.sections], [something(t.caption, "") for t in sd.tables],
                     [c.text for t in sd.tables for c in t.cells]), " ")
    yrs = Int[]
    for m in eachmatch(r"\b(\d{1,2})\.(\d{1,2})\.(20\d{2})\b", text)          # 31.12.2019
        push!(yrs, parse(Int, m.captures[3]))
    end
    md = nothing
    for m in eachmatch(r"\b(\d{1,2})\.(\d{1,2})\.(20\d{2})\b", text)
        md = (parse(Int, m.captures[2]), parse(Int, m.captures[1])); break
    end
    if md === nothing                                                         # "zum 31. Dezember 2019"
        m = match(r"(?i)zum\s+(\d{1,2})\.\s*(januar|februar|märz|april|mai|juni|juli|august|september|oktober|november|dezember)\s+(20\d{2})", text)
        m === nothing && return nothing
        md = (monthabbr_to_num(m.captures[2]), parse(Int, m.captures[1])); push!(yrs, parse(Int, m.captures[3]))
    end
    isempty(yrs) && return nothing
    return (md[1], md[2], sort!(unique(yrs); rev = true))
end

# Money in an HGB cell — full-euro amounts, decimal-comma (":eu_dot"). Same guard as the IFRS path.
_hgb_ismoney(s) = (occursin(',', s) || occursin(r"\d\.\d", s)) &&
                  (p = parse_amount(strip(String(s)); locale = :eu_dot); p !== nothing && !p.nil)

# Per-year (detail, subtotal) column pairs from a Bilanz/GuV table. Value columns carry ≥2 money cells; a column
# whose header holds a year (or "31.12.YYYY") is a DETAIL anchor, and the next value column WITHOUT its own year
# is that year's SUBTOTAL column. Returns Vector of (year, detail_col, subtotal_col|nothing).
function _hgb_columns(grid, nr, nc)
    valcols = [c for c in 0:nc-1 if count(r -> _hgb_ismoney(get(grid, (r, c), "")), 0:nr-1) >= 2]
    hdr(c) = join([get(grid, (r, c), "") for r in 0:min(2, nr-1)], " ")
    yearof(c) = (m = match(r"(20\d{2})", hdr(c)); m === nothing ? nothing : parse(Int, m.captures[1]))
    pairs = Tuple{Int,Int,Union{Int,Nothing}}[]
    i = 1
    while i <= length(valcols)
        c = valcols[i]; y = yearof(c)
        if y === nothing
            i += 1; continue
        end
        sub = (i < length(valcols) && yearof(valcols[i+1]) === nothing) ? valcols[i+1] : nothing
        push!(pairs, (y, c, sub)); i += (sub === nothing ? 1 : 2)
    end
    return pairs
end

# The label of a row — its word cells joined (a number-only or blank cell is not a label).
function _hgb_label(grid, r, nc)
    lc = String[]
    for c in 0:nc-1
        s = get(grid, (r, c), "")
        (!isempty(s) && occursin(r"[A-Za-zÄÖÜäöüß]", s) && parse_amount(s; locale = :eu_dot) === nothing) && push!(lc, s)
    end
    return strip(join(lc, " "))
end

# Facts from one classified HGB statement table. The BALANCE SHEET is account-form: the last SUBTOTAL-column
# value within each §266 section is that section's total, and the last subtotal overall is the Bilanzsumme. The
# GuV is single-level: each mapped line's DETAIL (or subtotal) value is taken directly.
function _hgb_table_facts(tbl, stmt::AbstractString, pends::Vector{Date})
    nr, nc = tbl.n_rows, tbl.n_cols
    grid = Dict{Tuple{Int,Int},String}(); for c in tbl.cells; grid[(c.row, c.col)] = strip(c.text); end
    cols = _hgb_columns(grid, nr, nc)
    isempty(cols) && return Fact[]
    yr_end = Dict(year(pe) => pe for pe in pends)
    instant = stmt == "BalanceSheet"
    out = Fact[]
    _emit(concept, y, v, r, c) = push!(out, Fact(; concept, label = "", value = v, unit = "EUR",
        period_start = instant ? nothing : (yr_end[y] - Year(1) + Day(1)), period_end = yr_end[y],
        is_instant = instant, statement = stmt, context_ref = string(yr_end[y]), unit_ref = "EUR",
        source_selector = "{\"table\":$(repr(tbl.table_id)),\"row\":$r,\"col\":$c}"))

    if stmt == "BalanceSheet"
        section = nothing                                        # current §266 section concept (or nothing)
        sect_last = Dict{Tuple{String,Int},Tuple{Float64,Int,Int}}()   # (concept,year) → (value,row,col), last wins
        grand = Dict{Int,Tuple{Float64,Int,Int}}()               # year → last subtotal overall = Bilanzsumme
        for r in 0:nr-1
            lbl = _hgb_label(grid, r, nc)
            if _hgb_is_section(lbl)
                hc = hgb_concept(lbl); section = hc === nothing ? nothing : hc.concept
            end
            for (y, dc, sc) in cols
                haskey(yr_end, y) || continue
                sc === nothing && continue
                p = parse_amount(get(grid, (r, sc), ""); locale = :eu_dot)
                (p === nothing || p.nil) && continue
                grand[y] = (p.val, r, sc)                        # overwrite → the last subtotal per year
                lc = hgb_concept(lbl)                            # an explicit "Summe X"/mapped total on this row
                key = lc !== nothing && startswith(_hgb_norm(lbl), "summe ") ? lc.concept : section
                key === nothing || (sect_last[(key, y)] = (p.val, r, sc))
            end
        end
        for ((concept, y), (v, r, c)) in sect_last
            (haskey(grand, y) && grand[y][2] == r) && continue   # the Bilanzsumme row is emitted below, not as a section
            _emit(concept, y, v, r, c)
        end
        for (y, (v, r, c)) in grand
            _emit("hgb:Bilanzsumme", y, v, r, c)
        end
    else                                                         # GuV — take each mapped line's own value
        for r in 0:nr-1
            lbl = _hgb_label(grid, r, nc); isempty(lbl) && continue
            cc = hgb_concept(lbl); cc === nothing && continue
            for (y, dc, sc) in cols
                haskey(yr_end, y) || continue
                p = nothing
                for c in (dc, sc)
                    c === nothing && continue
                    q = parse_amount(get(grid, (r, c), ""); locale = :eu_dot)
                    (q === nothing || q.nil) || (p = (q, c); break)
                end
                p === nothing || _emit(cc.concept, y, p[1].val, r, p[2])
            end
        end
    end
    return out
end

# The single-entity Jahresabschluss statement page range. The primary Bilanz ("Bilanz zum <date>") and GuV
# ("Gewinn- und Verlustrechnung für die Zeit …") — NOT the §6b-EnWG activity-specific accounts ("… für die
# Tätigkeit Elektrizitätsverteilung"), which are unbundling schedules, and NOT a consolidated set.
function _hgb_statement_pages(doc)
    npg = length(doc.pages); hits = Int[]
    for pg in doc.pages
        t = _ifrs_spacedtext(pg)
        occursin(r"(?i)für die tätigkeit|konzern", t) && continue          # skip §6b-EnWG activity accounts
        (occursin(r"(?i)\bbilanz\s+zum\b", t) || occursin(r"(?i)gewinn-?\s*und\s*verlustrechnung\s+für\s+die\s+zeit", t)) &&
            push!(hits, Int(pg.page))
    end
    isempty(hits) && return nothing
    # The primary Bilanz + GuV are one FRONT cluster; later "Bilanz zum" mentions are the Anhang prose. Take the
    # first run of headings (gap ≤ 2 pages) and add a small margin for the value-only continuation page.
    hi = hits[1]
    for p in hits; p - hi <= 2 ? (hi = p) : break; end
    return (hits[1], min(hi + 2, npg))
end

"""
    extract_hgb_pdf(path) -> Vector{FactRow}

Extract the primary statements (account-form Bilanz, GuV) from a single-entity German **HGB** *Jahresabschluss*
PDF as classified [`facts`](@ref) on `hgb:` concepts (EUR). The German-GAAP analogue of [`extract_cas_pdf`];
the Bilanz's §266 section totals and the two-sided Bilanzsumme are recovered from the account-form subtotal
column. See [`hgb_concept`](@ref) and `docs/dev/germany-plan.md` (G2).
"""
function extract_hgb_pdf(path::AbstractString)
    doc = _pdf_words(path)
    rng = _hgb_statement_pages(doc)
    rng === nothing && throw(ArgumentError("no HGB Bilanz/GuV found in $(repr(basename(path)))"))
    sd = structured_document(path; pages = rng, jurisdiction = "DE", language = "de")
    return _hgb_facts_from_sd(sd; accession = basename(path), url = path)
end

extract_hgb_pdf(sd::StructuredDocument; accession::AbstractString = "", url::AbstractString = "") =
    _hgb_facts_from_sd(sd; accession, url)

function _hgb_facts_from_sd(sd; accession::AbstractString = "", url::AbstractString = "")
    per = _hgb_period(sd)
    per === nothing && throw(ArgumentError("could not determine the fiscal period from $(repr(accession))"))
    mo, dy, yrs = per
    pends = [Date(y, mo, dy) for y in yrs]
    sectitle = Dict(s.section_id => s.title for s in sd.sections)
    facts = Fact[]
    for tbl in sd.tables
        cls = classify_table_class(something(tbl.caption, ""))
        cls === nothing && (cls = classify_table_class(get(sectitle, something(tbl.section_id, ""), "")))
        stmt = cls == "balance_sheet" ? "BalanceSheet" : cls == "income_statement" ? "IncomeStatement" : nothing
        # The account-form Bilanz is split into two tables; the PASSIVA side (and sometimes the Aktiva side) is
        # headed only "Aktiva"/"Passiva", which the generic classifier does not recognise — treat it as the BS.
        if stmt === nothing
            sec = get(sectitle, something(tbl.section_id, ""), "")
            occursin(r"(?i)\b(aktiva|passiva)\b", sec) && (stmt = "BalanceSheet")
        end
        stmt === nothing && continue
        append!(facts, _hgb_table_facts(tbl, stmt, pends))
    end
    sel = Selection(; cik = "", accession = accession, url = url, selector = "", kind = :filing, facts = facts)
    return EDGAR.facts(sel)
end
