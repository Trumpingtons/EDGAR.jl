# User-facing PDF-extraction QUALITY layer — `coverage` and `accuracy`.
#
# These answer the two questions a user relying on the generic PDF fact path actually has:
#   coverage(x) — HOW FAR up the conveyor did each report get?  (parsed → located → tables → facts → foots)
#   accuracy(x) — do the recovered numbers MATCH an independent oracle?  (five headline totals vs Yahoo / an
#                 iXBRL twin of the same filer)
#
# Both are THIN: `coverage` runs the same pipeline the extractor does, stage by stage, and reports where it
# stops; `accuracy` reuses the fundamentals-oracle machinery (`ORACLE_METRICS`, the provider abstraction,
# `_edgar_metric`) — it adds no new metric taxonomy or provider. They operate on the USER's own `Filing`s,
# paths, or already-extracted `FactRow`s — not a fixed fixture panel (that panel is now a gated test).
# The tables/facts stages need the Tier-2 Docling stack (`using PythonCall`); `accuracy(; oracle=:yahoo)`
# needs the network.

_pdfq_msg(e) = e isa Exception ? sprint(showerror, e) : string(e)

# A born-digital PDF's on-disk path from a Filing (its `content`), or an error if it is not a readable path.
function _pdfq_path(f::Filing)
    p = expanduser(String(f.content))
    isfile(p) || throw(ArgumentError("coverage/accuracy need a PDF Filing whose `content` is a readable " *
                                     "path; got kind=$(repr(f.kind)) content=$(repr(first(String(f.content), 60)))"))
    return p
end

# The oracle "system" (which concept namespace `_edgar_metric` should pick) for a filing's FilingSystem —
# SEC → us-gaap, India → in-capmkt/in-bse-fin, China → cas, everything else (ESEF/HK/DE/Generic…) → ifrs-full.
_pdfq_sys(f::Filing) = f.system isa SEC ? :sec : f.system isa India ? :india :
                       f.system isa China ? :china : :esef

# ── reconciliation self-check (balance-sheet cross-foot) ─────────────────────────────────────────────────
# Assets == EquityAndLiabilities (or Equity + Liabilities) for the latest reported period. :ok / :off
# (present but doesn't foot) / :partial (a headline total missing) / :na (no balance sheet at all).
_pdfq_val(facts, concept, pe) =
    (hits = [r.value for r in facts if r.concept == concept && r.period_end == pe]; isempty(hits) ? nothing : first(hits))

function _bs_crossfoot(facts)
    bs = [r for r in facts if r.statement == "BalanceSheet"]
    isempty(bs) && return :na
    pe = maximum(r.period_end for r in bs)
    a  = _pdfq_val(bs, "ifrs-full:Assets", pe)
    el = _pdfq_val(bs, "ifrs-full:EquityAndLiabilities", pe)
    if el === nothing
        eq = _pdfq_val(bs, "ifrs-full:Equity", pe); li = _pdfq_val(bs, "ifrs-full:Liabilities", pe)
        (eq !== nothing && li !== nothing) && (el = eq + li)
    end
    (a === nothing || el === nothing) && return :partial
    abs(a - el) <= 0.01 * max(abs(a), 1.0) ? :ok : :off
end

const _PDFQ_STMTS = ("BalanceSheet", "IncomeStatement", "CashFlow")

# ── coverage ─────────────────────────────────────────────────────────────────────────────────────────────
"""
    coverage(x) -> NamedTuple   (or Vector{NamedTuple} for a Vector input)

The per-stage extraction funnel for a born-digital IFRS PDF: how far up the conveyor a report gets —
`parsed → located → tables → facts → reconciles` — and where it falls off. `x` is a [`Filing`](@ref), a PDF
path, or a `Vector` of them; a `Vector{FactRow}` scores only the facts-and-reconcile tail. Returns DATA (no
printing). Fields: `source`, `lang` (sniffed), `pages`, `located` (the page range or `nothing`), `tables`,
`facts` (count), `types` (statement types recovered), `reconcile` (`:ok`/`:off`/`:partial`/`:na`), and
`error` (the stage that stopped it, or `""`).

The `tables`/`facts` stages need the Tier-2 Docling stack — `using PythonCall` first. Network-free.

```julia
coverage(fetch_filing(Generic(), "report.pdf"))          # one report
coverage([f1, f2, f3])                                    # a corpus → one row each
```
"""
function coverage(path::AbstractString)
    src = basename(path)
    base = (source = src, lang = "", pages = missing, located = nothing, tables = missing,
            facts = missing, types = Set{String}(), reconcile = :na, error = "")
    isfile(path) || return merge(base, (error = "missing file",))
    doc = try _pdf_words(path) catch e; return merge(base, (error = "parse: $(_pdfq_msg(e))",)) end
    base = merge(base, (pages = length(doc.pages),))
    rng = try _ifrs_statement_pages(doc) catch e; return merge(base, (error = "locate: $(_pdfq_msg(e))",)) end
    base = merge(base, (located = rng,))
    if rng === nothing
        sig = try _ifrs_stmt_signal(doc) catch; 0 end
        return merge(base, (error = sig >= 2 ? "unlocated (sig=$sig, gap)" : "no detailed stmts",))
    end
    juris, lang = _ifrs_doc_juris(doc)
    base = merge(base, (lang = lang,))
    sd = try structured_document(path; pages = rng, jurisdiction = juris, language = lang)
         catch e; return merge(base, (error = "tables: $(_pdfq_msg(e))",)) end
    base = merge(base, (tables = length(sd.tables),))
    fx = try extract_ifrs_pdf(sd; accession = src, url = path)
         catch e; return merge(base, (error = "facts: $(_pdfq_msg(e))",)) end
    types = Set(r.statement for r in fx if r.statement in _PDFQ_STMTS)
    return merge(base, (facts = length(fx), types = types, reconcile = _bs_crossfoot(fx)))
end

coverage(f::Filing) = coverage(_pdfq_path(f))

function coverage(rows::AbstractVector{FactRow})
    types = Set(r.statement for r in rows if r.statement in _PDFQ_STMTS)
    return (source = "<facts>", lang = "", pages = missing, located = nothing, tables = missing,
            facts = length(rows), types = types, reconcile = _bs_crossfoot(rows), error = "")
end

coverage(xs::AbstractVector) = [coverage(x) for x in xs]

# ── accuracy ─────────────────────────────────────────────────────────────────────────────────────────────
"""
    accuracy(x; oracle = :yahoo, tol = 0.01, ticker = "", twin = nothing, system = :germany) -> NamedTuple

Compare the five headline totals recovered from `x` — **Assets, Equity, Revenue, NetIncome, OperCashFlow** —
to an independent oracle. `x` is a [`Filing`](@ref), a PDF path, or a `Vector{FactRow}`. `oracle`:

- `:yahoo` — an external fundamentals provider (needs `ticker`, e.g. `"KGH.WA"`; network + a User-Agent).
- `:xbrl_twin` — the SAME filer's own structured filing (`twin::Filing`, e.g. its ESEF iXBRL): the
  dual-format check that needs no third party.

Returns `(rows, hit, compared, rate)`, where each `row` is
`(metric, statement, extracted, reference, rel_diff, within_tol)` and `rate = hit / compared`. `tol` is the
match threshold (default 1%). `system` selects the concept namespace for the *extracted* side (`:germany`/
IFRS by default; a `Filing` input infers it — `:china` for a CAS PDF, etc.).

```julia
accuracy("KGHM.pdf"; oracle = :yahoo, ticker = "KGH.WA")
accuracy(pdf_filing; oracle = :xbrl_twin, twin = esef_filing)   # PDF vs the filer's own iXBRL
```
"""
function accuracy(facts::AbstractVector{FactRow}; oracle::Symbol = :yahoo, tol::Float64 = 0.01,
                  ticker::AbstractString = "", twin = nothing, system::Symbol = :germany)
    # oracle setup
    local p, funds, twinrows, twinsys
    if oracle === :yahoo
        isempty(ticker) && throw(ArgumentError("accuracy(; oracle = :yahoo) needs a `ticker` (e.g. \"KGH.WA\")"))
        _ensure_ua()
        p = _provider(:yahoo)
        funds = provider_fetch(p, ticker)
    elseif oracle === :xbrl_twin
        twin === nothing && throw(ArgumentError("accuracy(; oracle = :xbrl_twin) needs a `twin::Filing`"))
        twinrows = facts(twin; classify = true)
        twinsys = twin isa Filing ? _pdfq_sys(twin) : :esef
    else
        throw(ArgumentError("unknown oracle :$oracle (have :yahoo, :xbrl_twin)"))
    end

    rows = NamedTuple[]; hit = 0; cmp = 0
    for m in ORACLE_METRICS
        e  = _edgar_metric(facts, m, system)
        ev = e === nothing ? nothing : e.value
        pe = e === nothing ? nothing : e.period_end
        rv = if oracle === :yahoo
            pe === nothing ? nothing : begin
                payload = m.statement === :bs ? funds.bs : m.statement === :is ? funds.is : funds.cf
                provider_value(p, payload, provider_concepts(p, m.name), pe)
            end
        else
            t = _edgar_metric(twinrows, m, twinsys); t === nothing ? nothing : t.value
        end
        rd = (ev === nothing || rv === nothing) ? Inf : abs(ev - rv) / max(abs(rv), 1)
        wt = ev !== nothing && rv !== nothing && rd <= tol
        (ev !== nothing && rv !== nothing) && (cmp += 1; wt && (hit += 1))
        push!(rows, (metric = m.name, statement = m.statement, extracted = ev, reference = rv,
                     rel_diff = rd, within_tol = wt))
    end
    return (rows = rows, hit = hit, compared = cmp, rate = hit / max(cmp, 1))
end

accuracy(f::Filing; system::Symbol = _pdfq_sys(f), kwargs...) =
    accuracy(facts(f; classify = true); system = system, kwargs...)
accuracy(path::AbstractString; kwargs...) = accuracy(extract_ifrs_pdf(expanduser(path)); kwargs...)
