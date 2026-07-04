# PDF extractor (CH II / P2.4) — the Format-axis sibling of extract_xbrl.jl. A born-digital PDF has no
# rows/columns, just positioned text; we recover the financial statements geometrically and emit the
# SAME `Fact`s the XBRL path does, so `facts`/`select_statement`/CSV/the oracles all work unchanged.
#
# Pipeline:  pdf.js (via the Node helper src/extractors/pdf/pdf_words.mjs) -> positioned words
#            -> rows (cluster by y) x period columns (numeric right-edge bands)
#            -> header row -> period dates + scale + statement kind
#            -> coordinate-anchored `Fact`s (bbox carried in `source_selector` for the Pollis back-link).
#
# This is the deterministic Tier-1 path (see docs/dev/pdf-extractor-plan.md). Column *meaning* is still
# financial-statement-tuned (period columns; single-line date headers); multi-row/spanning headers and
# the income-statement analysis-column semantics are the next increments.

const _PDF_WORDS_JS = joinpath(@__DIR__, "pdf", "pdf_words.mjs")

# Run the Node helper -> parsed pages of positioned words ({page,width,height,words:[{x,y,w,h,str}]}).
function _pdf_words(path::AbstractString; page::Union{Nothing,Integer}=nothing)
    isfile(path) || throw(ArgumentError("PDF not found: $(repr(path))"))
    cmd = page === nothing ? `node $_PDF_WORDS_JS $path` : `node $_PDF_WORDS_JS $path $page`
    out = try
        read(cmd, String)
    catch e
        error("PDF word extraction failed — is Node installed and the pinned pdfjs-dist present? " *
              "Run `npm install` in $(dirname(_PDF_WORDS_JS)). Underlying error: $e")
    end
    return JSON3.read(out)
end

# --- number semantics: parentheses = negative, strip £/commas, en-dash = nil, footnote markers ---
function _pdf_num(s)
    t = strip(String(s)); t = replace(t, r"[*†‡]+$" => "")
    (t in ("–", "-", "—", "")) && return (val = 0.0, nil = true)
    neg = startswith(t, "(") && endswith(t, ")"); t = strip(t, ['(', ')'])
    t = replace(replace(t, "," => ""), r"[£$€]" => "")
    v = tryparse(Float64, t); v === nothing && return nothing
    return (val = neg ? -v : v, nil = false)
end
_pdf_isnum(s) = _pdf_num(s) !== nothing

# words for one page as plain NamedTuples
_pdf_cells(pg) = [(x = Float64(w.x), y = Float64(w.y), w = Float64(w.w), h = Float64(w.h), str = String(w.str))
                  for w in pg.words]

# rows: cluster cells by y (≈ half a line height)
function _pdf_rows(cells; ytol = 3.5)
    cs = sort(cells; by = c -> (c.y, c.x))
    out = Vector{typeof(cs)}(); cur = similar(cs, 0); cy = nothing
    for c in cs
        if cy === nothing || abs(c.y - cy) <= ytol
            push!(cur, c); cy = cy === nothing ? c.y : cy
        else
            push!(out, sort(cur; by = t -> t.x)); cur = [c]; cy = c.y
        end
    end
    isempty(cur) || push!(out, sort(cur; by = t -> t.x))
    return out
end

# period columns: cluster right-edges of numeric tokens that sit right of the label/notes area
function _pdf_columns(cells; xmin = 400.0, gap = 12.0)
    edges = sort([c.x + c.w for c in cells if c.x >= xmin && _pdf_isnum(c.str) && !_pdf_num(c.str).nil])
    isempty(edges) && return Float64[]
    bands = [[edges[1]]]
    for e in edges[2:end]
        (e - bands[end][end]) <= gap ? push!(bands[end], e) : push!(bands, [e])
    end
    return [sum(b) / length(b) for b in filter(b -> length(b) >= 4, bands)]
end

# header -> period date per column (single-line date headers); returns Vector{Union{Date,Nothing}}
const _PDF_DATE = r"\d{1,2}\s+\p{L}+\s+\d{4}"
function _pdf_period(s)
    m = match(_PDF_DATE, s)
    if m !== nothing
        for fmt in (dateformat"d U yyyy", dateformat"d u yyyy")
            d = tryparse(Date, m.match, fmt); d === nothing || return d
        end
    end
    return nothing
end

# scale factor from a units/scale marker anywhere on the page
function _pdf_scale(alltext)
    occursin(r"£\s?m\b|£\s?million|in £m|€\s?m\b|\bmillion"i, alltext) && return (1e6, "millions")
    occursin(r"£\s?000|£\s?thousand|TEUR|in Tausend|\bthousand"i, alltext) && return (1e3, "thousands")
    return (1.0, "units")
end

# statement kind from the page's heading area -> (label, is_instant) or nothing
function _pdf_statement_kind(rows)
    head = lowercase(join((c.str for r in first(rows, min(8, length(rows))) for c in r), " "))
    occursin(r"balance sheet|statement of financial position", head) && return ("BalanceSheet", true)
    occursin(r"income statement|profit or loss|profit and loss|statement of comprehensive income", head) && return ("IncomeStatement", false)
    occursin(r"cash flow", head) && return ("CashFlow", false)
    return nothing
end

# extract coordinate-anchored Facts from ONE statement page (cells already known to have period columns)
function _pdf_page_facts(pg; currency = "GBP")
    cells = _pdf_cells(pg)
    cols = _pdf_columns(cells)
    length(cols) >= 1 || return Fact[]
    R = _pdf_rows(cells)
    kind = _pdf_statement_kind(R)
    kind === nothing && return Fact[]
    stmt, instant = kind
    scale, _ = _pdf_scale(join((c.str for c in cells), " "))

    # body starts at the first row with numbers aligned to the column bands (skips page-number margins)
    incol(c) = !isempty(cols) && minimum(abs.(cols .- (c.x + c.w))) <= 14
    isbody(r) = count(c -> _pdf_isnum(c.str) && incol(c), r) >= max(1, length(cols) - 1)
    fb = findfirst(isbody, R)
    fb === nothing && return Fact[]

    # map each column -> a period date from the header rows above the body
    center(c) = c.x + c.w / 2
    periods = Vector{Union{Date,Nothing}}(nothing, length(cols))
    for r in R[1:fb-1], c in r
        i = argmin(abs.(cols .- center(c))); abs(cols[i] - center(c)) > 40 && continue
        p = _pdf_period(c.str); p === nothing || (periods[i] === nothing && (periods[i] = p))
    end

    assign(c) = (e = c.x + c.w; i = argmin(abs.(cols .- e)); abs(cols[i] - e) <= 14 ? i : 0)
    facts = Fact[]
    pageno = Int(pg.page)
    for r in R[fb:end]
        label = strip(join([c.str for c in r if c.x < 360 && !_pdf_isnum(c.str)], " "))
        isempty(label) && continue
        for c in r
            _pdf_isnum(c.str) || continue
            i = assign(c); i == 0 && continue
            periods[i] === nothing && continue          # only period-resolved columns become facts
            p = _pdf_num(c.str); p.nil && continue
            bbox = "{\"page\":$pageno,\"x\":$(c.x),\"y\":$(c.y),\"w\":$(c.w),\"h\":$(c.h)}"
            push!(facts, Fact(; concept = label, label = label, value = p.val * scale,
                  unit = currency, period_end = periods[i], is_instant = instant,
                  statement = stmt, context_ref = string(periods[i]), unit_ref = currency,
                  source_selector = bbox))
        end
    end
    return facts
end

"""
    extract_pdf(path; page=nothing) -> Vector{FactRow}

Extract financial-statement facts from a born-digital PDF at `path`, as the same Tables.jl row table
[`facts`](@ref) returns for XBRL filings — each fact coordinate-anchored (its source `(page, bbox)` is
carried in `source_selector` for the Pollis workbench back-link).

With `page` it reconstructs that one statement page; without, it scans the document and emits facts from
every page that looks like a primary financial statement (heading + period columns). Deterministic
Tier-1 path (see `docs/dev/pdf-extractor-plan.md`); requires Node + the pinned pdfjs-dist (run
`npm install` in `src/extractors/pdf/`).

```julia
rows = extract_pdf("annual_report.pdf"; page = 133)   # one statement
select_statement(rows, "BalanceSheet")
```
"""
function extract_pdf(path::AbstractString; page::Union{Nothing,Integer} = nothing, currency = "GBP")
    doc = _pdf_words(path; page = page)
    facts = Fact[]
    for pg in doc.pages
        append!(facts, _pdf_page_facts(pg; currency = currency))
    end
    sel = Selection(; cik = "", accession = basename(path), url = path, selector = "",
                    kind = :filing, facts = facts)
    return EDGAR.facts(sel)
end

# `facts(f::Filing)` hook for `:pdf` filings. The PDF source must be reachable: `f.content` may hold a
# local path (or be empty). Byte-retention from the CH/NSM fetch path is a separate wiring step; until
# then, call `extract_pdf(path)` directly.
function _pdf_filing_facts(f::Filing; kwargs...)
    src = f.content
    (!isempty(src) && isfile(src)) ||
        throw(ArgumentError("facts(::Filing) for a :pdf filing needs the PDF source; this filing carries " *
              "none. Use `extract_pdf(path)` with the downloaded PDF for now."))
    # China filings are CAS PDFs — route to the CAS extractor (Chinese statement/label semantics).
    return f.system isa China ? extract_cas_pdf(src) : extract_pdf(src)
end
