# Phase 2R.A — the PDF-facts robustness SCORECARD (measurement harness).
#
# NOTE: like the other files in src/sources/, this is NOT part of the EDGAR module (not `include`d by
# src/EDGAR.jl). Load it on demand. It turns the vague "PDF facts are weak & inconsistent" complaint into a
# NUMBER, and guards the 2R.B/2R.C/2R.D fixes against regressions.
#
# It runs the born-digital IFRS-PDF extractor (`extract_ifrs_pdf`) one STAGE at a time over a fixture set of
# reports spanning languages, and records where each report falls off the conveyor:
#
#   parsed?  -> located?  -> tables?  -> facts?  -> reconciles?
#   (_pdf_words)  (_ifrs_statement_pages)  (structured_document)  (_ifrs_facts_from_sd)  (BS cross-foot)
#
# The three 2026-07 failure STAGES this harness was built to score (see docs/dev/pdf-extractor-plan.md §2R):
#   - Wesfarmers (EN)  -> located OK but 0 facts   (statement-name over-fit to "consolidated")
#   - Vale       (PT)  -> NOT located, throws       (anchors en/de-only; integrated report)
#   - Loblaw     (CA)  -> facts, balance sheet only  (IS/CF table->facts fragile)
#
# Requires the Tier-2 stack (Docling via PythonCall): `using PythonCall` before calling `score`.
#
# Usage:
#   using EDGAR, PythonCall
#   include(joinpath(pkgdir(EDGAR), "src", "sources", "pdf_scorecard.jl"))
#   using .PdfScorecard
#   PdfScorecard.report()                       # score the default fixture set, print the scorecard
#   PdfScorecard.report([PdfScorecard.FIXTURES[1]])   # a single fixture
#   rows = PdfScorecard.score()                 # the raw NamedTuples, for regression asserts

module PdfScorecard

using EDGAR, Printf, Dates

# Where the validation PDFs live (the untouched stash; see [[validate-on-new-filers]] / edgar-dev-and-reports).
const STASH = expanduser("~/EDGAR-Reports")

"""
A scorecard fixture: a born-digital financial-report PDF and what we expect the extractor to recover.

- `id`      — short label for the scorecard row.
- `file`    — basename under `STASH`.
- `lang`    — the presentation language (ISO-639-1), for reading the per-language columns.
- `expect`  — the primary-statement types that SHOULD be recovered, as a Set of `"BalanceSheet"`,
              `"IncomeStatement"`, `"CashFlow"`. Empty = unknown / not yet asserted (informational only).
- `located` — whether the report is EXPECTED to contain locatable primary statements. `false` marks a 2R.F
              case (an integrated/summary report with NO detailed statements, e.g. Vale) where "not located"
              is the CORRECT outcome, not a failure.
- `ticker`  — the Yahoo symbol, for the 2R.G aggregate-accuracy report (`accuracy`). Empty = skip in accuracy.
"""
Base.@kwdef struct Fixture
    id::String
    file::String
    lang::String
    expect::Set{String} = Set{String}()
    located::Bool = true
    ticker::String = ""
end

const _ALL3 = Set(["BalanceSheet", "IncomeStatement", "CashFlow"])

# The default fixture set: the three 2026-07 failure cases first (the reason this harness exists), then the
# Romance-language filers that DO carry statements (the real 2R.B targets), then known-good anchors so the
# score has a ceiling. EXTEND THIS as 2R.B/2R.D land new languages — the harness is only as honest as its
# fixtures (see [[validate-on-new-filers]]).
const FIXTURES = Fixture[
    # -- the 2026-07 failure cases (docs/dev/pdf-extractor-plan.md §2R) --
    Fixture(id = "Wesfarmers", file = "GEN-Wesfarmers-2024.pdf", lang = "en", expect = _ALL3, ticker = "WES.AX"),
    # Vale's "annual report" is an INTEGRATED report — it explicitly points elsewhere for the consolidated
    # statements (none in this PDF). "not located" is CORRECT here; the real fix is 2R.F (discovery-side).
    Fixture(id = "Vale",       file = "GEN-Vale-AR-2024.pdf",     lang = "pt", located = false),
    Fixture(id = "Loblaw",     file = "GEN-Loblaw-AR-2024.pdf",   lang = "en", expect = _ALL3, ticker = "L.TO"),
    # -- Romance-language filers WITH statements (2R.B location targets; labels are 2R.D, so facts may lag) --
    Fixture(id = "WEG",        file = "GEN-WEG-DF-2024.pdf",       lang = "pt", expect = _ALL3, ticker = "WEGE3.SA"),
    Fixture(id = "TotalEner.", file = "FR-TotalEnergiesFR2023.pdf", lang = "fr", expect = _ALL3, ticker = "TTE.PA"),
    Fixture(id = "Enel",       file = "IT-EnelFR2023.pdf",         lang = "it", expect = _ALL3, ticker = "ENEL.MI"),
    # -- Nordic/Benelux/Polish filers WITH statements (2R multilingual expansion; native-language reports) --
    Fixture(id = "H&M",        file = "SE-HM-arsredovisning-2023.pdf",   lang = "sv", expect = _ALL3, ticker = "HM-B.ST"),
    Fixture(id = "Coop",       file = "DK-Coop-aarsrapport-2023.pdf",    lang = "da", expect = _ALL3),   # Coop amba — unlisted (no ticker)
    Fixture(id = "Liander",    file = "NL-Liander-jaarbericht-2023.pdf", lang = "nl", expect = _ALL3),   # Alliander subsidiary — unlisted
    Fixture(id = "KGHM",       file = "PL-KGHM-skonsolidowane-2023.pdf", lang = "pl", expect = _ALL3, ticker = "KGH.WA"),
    Fixture(id = "Kesko",      file = "FI-Kesko-vuosiraportti-2023.pdf", lang = "fi", expect = _ALL3, ticker = "KESKOB.HE"),
    Fixture(id = "NorgesGr.",  file = "NO-NorgesGruppen-arsrapport-2023.pdf", lang = "no", expect = _ALL3),   # NorgesGruppen ASA — unlisted
    # -- known-good anchors (should already pass; regression guards for the fixes) --
    Fixture(id = "Fielmann",   file = "DE-FielmannFR2023.pdf",    lang = "de", expect = _ALL3, ticker = "FIE.DE"),
    Fixture(id = "Tencent",    file = "HK-Tencent-SEHK-AR2024.pdf", lang = "en", expect = _ALL3, ticker = "0700.HK"),
]

# ---- the reconciliation self-check (2R.A slice of 2R.C) -------------------------------------------------
# Balance-sheet cross-foot per period: Assets == EquityAndLiabilities (or Equity + Liabilities). Returns
# :ok / :off (present but doesn't foot) / :na (the totals aren't both present to check).
_val(facts, concept, pe) = begin
    hits = [r.value for r in facts if r.concept == concept && r.period_end == pe]
    isempty(hits) ? nothing : first(hits)
end

function _bs_crossfoot(facts)
    bs = [r for r in facts if r.statement == "BalanceSheet"]
    isempty(bs) && return :na                                  # no balance sheet extracted at all
    pe = maximum(r.period_end for r in bs)                       # check the latest reported period
    a  = _val(bs, "ifrs-full:Assets", pe)
    el = _val(bs, "ifrs-full:EquityAndLiabilities", pe)
    if el === nothing                                           # some filers split Equity + Liabilities
        eq = _val(bs, "ifrs-full:Equity", pe)
        li = _val(bs, "ifrs-full:Liabilities", pe)
        (eq !== nothing && li !== nothing) && (el = eq + li)
    end
    (a === nothing || el === nothing) && return :partial       # rows extracted but a headline total is MISSING
    abs(a - el) <= 0.01 * max(abs(a), 1.0) ? :ok : :off         # foots within 1% / doesn't foot
end

# ---- one fixture, scored stage by stage -----------------------------------------------------------------
"""
    score_one(fx::Fixture) -> NamedTuple

Run `fx` through the extractor stage by stage, catching a failure at each stage so downstream stages read
`missing`/`:na` rather than aborting the whole sweep. Fields: `id`, `lang`, `pages`, `located` (the page
range or `nothing`), `tables`, `facts`, `types` (the Set of statement types recovered), `missing_types`
(expected minus recovered), `reconcile` (`:ok`/`:off`/`:na`), and `error` (the stage that threw, or `""`).
"""
function score_one(fx::Fixture)
    path = joinpath(STASH, fx.file)
    base = (id = fx.id, lang = fx.lang, want_loc = fx.located, pages = missing, located = nothing,
            tables = missing, facts = missing, types = Set{String}(), missing_types = fx.expect,
            reconcile = :na, error = "")
    isfile(path) || return merge(base, (error = "missing file: $(fx.file)",))

    # stage 1 — parse the text layer.
    doc = try EDGAR._pdf_words(path) catch e; return merge(base, (error = "parse: $(_msg(e))",)) end
    base = merge(base, (pages = length(doc.pages),))

    # stage 2 — LOCATE the primary-statement page range (the 2R.B stage; Romance filers died here before).
    rng = try EDGAR._ifrs_statement_pages(doc) catch e; return merge(base, (error = "locate: $(_msg(e))",)) end
    base = merge(base, (located = rng,))
    # A 2R.F fixture (want_loc = false, e.g. an integrated report) is SUPPOSED to have no statements: not
    # located is the correct outcome. When it IS expected to locate, use the has-statements signal to tell a
    # thin report ("no detailed stmts") from a real locator gap ("unlocated, sig≥2 → statements are here").
    if rng === nothing
        sig = try EDGAR._ifrs_stmt_signal(doc) catch; 0 end
        return merge(base, (missing_types = Set{String}(),
            error = fx.located ? (sig >= 2 ? "unlocated (sig=$sig, gap)" : "no detailed stmts") : "",
            reconcile = :na))
    end

    # stage 3 — parse just those pages into tables (Docling).
    juris, lang = EDGAR._ifrs_doc_juris(doc)
    sd = try structured_document(path; pages = rng, jurisdiction = juris, language = lang)
         catch e; return merge(base, (error = "tables: $(_msg(e))",)) end
    base = merge(base, (tables = length(sd.tables),))

    # stage 4 — classify + extract FactRows (the 2R.C stage; Wesfarmers 0, Loblaw BS-only).
    facts = try extract_ifrs_pdf(sd; accession = fx.file, url = path)
            catch e; return merge(base, (error = "facts: $(_msg(e))",)) end
    types = Set(r.statement for r in facts if r.statement in _ALL3)
    base = merge(base, (facts = length(facts), types = types,
                        missing_types = setdiff(fx.expect, types)))

    # stage 5 — reconciliation self-check (BS cross-foot).
    return merge(base, (reconcile = _bs_crossfoot(facts),))
end

_msg(e) = e isa Exception ? sprint(showerror, e) : string(e)

"""
    score(fixtures = FIXTURES) -> Vector{NamedTuple}

Score every fixture (see [`score_one`](@ref)). Pure data — no printing; use for regression asserts.
"""
score(fixtures::AbstractVector{Fixture} = FIXTURES) = [score_one(fx) for fx in fixtures]

# ---- the printed scorecard ------------------------------------------------------------------------------
_rng(r) = r === nothing ? "—" : "$(r[1])–$(r[2])"
_types(s) = isempty(s) ? "—" : join(sort(replace.(collect(s), "BalanceSheet" => "BS",
                "IncomeStatement" => "IS", "CashFlow" => "CF")), "+")
_recon(s) = s == :ok ? "✓" : s == :off ? "✗off" : s == :partial ? "~part" : "—"

"""
    report(fixtures = FIXTURES) -> Vector{NamedTuple}

Score the fixtures and print the per-stage scorecard (returns the raw rows too). The conveyor reads left to
right; the first empty cell is where that report falls off.
"""
function report(fixtures::AbstractVector{Fixture} = FIXTURES)
    rows = score(fixtures)
    @printf("\n==== PDF-facts scorecard (2R.A) — %d fixtures ====\n", length(rows))
    @printf("%-11s %-4s %5s  %-8s %6s %6s  %-9s %-6s  %s\n",
            "fixture", "lang", "pages", "located", "tbls", "facts", "types", "recon", "note")
    println(repeat("-", 78))
    ok = 0
    for r in rows
        note = if !isempty(r.error)
            r.error
        elseif !r.want_loc
            r.located === nothing ? "2R.F: no stmts (ok)" : "2R.F: unexpected stmts"
        elseif !isempty(r.missing_types)
            "missing " * _types(r.missing_types)
        else
            ""
        end
        isempty(r.error) && isempty(r.missing_types) && r.reconcile in (:ok, :na) &&
            (r.want_loc || r.located === nothing) && (ok += 1)
        @printf("%-11s %-4s %5s  %-8s %6s %6s  %-9s %-6s  %s\n",
                first(r.id, 11), r.lang, r.pages === missing ? "—" : string(r.pages),
                _rng(r.located), r.tables === missing ? "—" : string(r.tables),
                r.facts === missing ? "—" : string(r.facts), _types(r.types), _recon(r.reconcile),
                first(note, 30))
    end
    println(repeat("-", 78))
    @printf("clean (all expected types + BS foots + no error): %d/%d\n\n", ok, length(rows))
    return rows
end

# ---- 2R.G — aggregate headline-total accuracy of the GENERIC PDF path vs an independent provider ---------
# The deterministic PDF fallback is judged STATISTICALLY over a sample, NOT tuned per filer (the plan's "no
# per-filer patches"): report how many of the five headline totals land within `tol` of the provider's figure
# across the fixtures, and treat misses as DATA. A filer that also files structured data (e.g. an ESEF filer
# with an iXBRL twin) should use its jurisdiction path for exact numbers — this gauges only how good the
# no-tuning generic fallback is in aggregate, for the long tail where no structured alternative exists.
"""
    accuracy(fixtures = FIXTURES; provider = :yahoo, tol = 0.01) -> NamedTuple

Run the generic PDF path over every fixture carrying a `ticker` and compare its five headline totals
(Assets, Equity, Revenue, NetIncome, OperCashFlow) to `provider` (Yahoo, via the shared fundamentals oracle).
Prints a per-fixture ✓/✗/– grid and the aggregate hit-rate. An HONEST aggregate gauge of the deterministic
fallback — misses are expected and are NOT per-filer bugs to hand-patch. Needs network + a User-Agent.
"""
function accuracy(fixtures::AbstractVector{Fixture} = FIXTURES; provider::Symbol = :yahoo, tol::Float64 = 0.01)
    metrics = ["Assets", "Equity", "Revenue", "NetIncome", "OperCashFlow"]
    @printf("\n==== 2R.G — generic-PDF headline accuracy vs %s (tol %g%%) ====\n", provider, 100tol)
    @printf("%-11s %-4s  %s\n", "fixture", "lang", join(rpad.(metrics, 11), " "))
    println(repeat("-", 78))
    hit = 0; cmp = 0
    for fx in fixtures
        isempty(fx.ticker) && continue
        rows = try EDGAR.validate(:germany, joinpath(STASH, fx.file), fx.ticker; provider = provider)
               catch e; @printf("%-11s %-4s  (error: %s)\n", first(fx.id, 11), fx.lang, first(sprint(showerror, e), 40)); continue end
        bym = Dict(String(r.metric) => r for r in rows)
        cells = String[]
        for m in metrics
            r = get(bym, m, nothing)
            if r === nothing || r.edgar === nothing || r.reference === nothing
                push!(cells, rpad("–", 11))                    # provider or EDGAR has no value → not counted
            else
                cmp += 1; okm = r.rel_diff <= tol; okm && (hit += 1)
                push!(cells, rpad(okm ? "✓" : @sprintf("✗%.1f%%", 100r.rel_diff), 11))
            end
        end
        @printf("%-11s %-4s  %s\n", first(fx.id, 11), fx.lang, join(cells, " "))
    end
    println(repeat("-", 78))
    @printf("headline totals within %g%%: %d/%d (%.0f%%)  — generic fallback, misses expected\n\n",
            100tol, hit, cmp, 100hit / max(cmp, 1))
    return (hit = hit, compared = cmp)
end

end # module
