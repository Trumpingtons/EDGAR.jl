# Validation surface — consolidation plan

**Status:** ✅ implemented (2026-07-13). `coverage`/`accuracy`/`validate`/`report` exported
(`src/extractors/pdf_quality.jl`); `PdfScorecard` module deleted, its panel now a gated test
(`EDGAR_PDF_SCORECARD=true`); `ArelleLocalOracle.validate_dart`/`report_dart` removed; manual
`sec:pdf-accuracy` rewritten. The DIY oracle source modules were left untouched.
**Trigger:** adding a user-facing "did the PDF path get it right?" layer (`coverage`/`accuracy`) surfaced how
tangled the validation surface is. This doc inventories what exists and proposes ONE exported user-facing API
— `coverage`, `accuracy`, `validate`, `report` — with migration notes, before any implementation.

## 1. Inventory (verified 2026-07-12)

| Entry point | File | In `EDGAR`? | Exported? | Purpose |
|---|---|---|---|---|
| `validate(system, locator, ticker; provider, scheme)` | `sources/fundamentals_oracle.jl` | **yes** (top-level) | **no** | cross-check EDGAR facts vs an external provider (Yahoo/AlphaVantage) |
| `report(firms; provider, scheme)` | `sources/fundamentals_oracle.jl` | **yes** (top-level) | **no** | the multi-firm oracle panel |
| `PdfScorecard.score_one/score/report/accuracy` | `sources/pdf_scorecard.jl` | no (load-on-demand `module`) | n/a | per-stage PDF funnel + headline accuracy over a fixed `FIXTURES` panel (regression harness) |
| `PdfOracle.validate/report` | `sources/pdf_oracle.jl` | no (`module`) | n/a | DIY: PDF vs a DuckDB "twin" |
| `ArelleEsefOracle.validate/report` | `sources/arelle_esef_oracle.jl` | no (`module`) | n/a | DIY: vs Arelle xBRL-JSON (ESEF) |
| `ArelleLocalOracle.validate/validate_dart/report/report_dart` | `sources/arelle_local_oracle.jl` | no (`module`) | n/a | DIY: run Arelle yourself |
| `CsvOracle.validate/report` | `sources/csv_oracle.jl` | no (`module`) | n/a | DIY: EDINET same-document CSV |

## 2. What stays untouched

The DIY oracle **submodules** — `PdfOracle`, `ArelleEsefOracle`, `ArelleLocalOracle`, `CsvOracle` — are the
right pattern for what they are: self-contained, load-on-demand validation *sources* with heavy external deps
(a local Arelle, a DuckDB stash), each in its own `module` so there is no name collision. **Leave them.**

One small wart to fix while we're here (not core to this plan): `ArelleLocalOracle.validate_dart` /
`report_dart` are **DART-only convenience sugar** — `validate_dart` just discovers+fetches a Korean filing
then calls the generic `validate(f)`. No other system has an equivalent; it is a leftover from DART bring-up.
**Recommend deleting both** (callers do `validate(fetch_filing(…))` explicitly, as for every other system).

## 3. The problem (two things, both user-facing)

1. **The primary oracle is invisible.** `validate`/`report` are the real "is my extraction right?" API —
   global, provider-pluggable, documented in the manual — yet **not exported**. Documented-but-unexported.
2. **`PdfScorecard` is test code wearing a module costume.** Strip it down and it is exactly: a `FIXTURES`
   list (12 test filers + expected results), a `Fixture` struct, and runners that apply the pipeline over them
   and print. Every justification for it being a `src/` module has fallen:
   - "heavy optional deps" — false; `PythonCall` is a lazy weakdep (the Docling extension loads on demand
     regardless of where the code lives).
   - "namespacing" — moot once `coverage`/`accuracy` are exported functions.
   - "it's a DIY oracle like the Arelle ones" — no; those are genuine separate *sources*, this is a
     regression harness over a fixed panel.

   So its two genuinely useful operations — *coverage* ("how far up the conveyor did each filing get?") and
   *accuracy* ("do the numbers match an oracle?") — should be **exported functions that take the user's own
   filings**, and the fixed-panel harness should be **a test**, not a shipped module.

## 4. The consolidated API — exactly four exported functions

```
# EXISTING — export the cross-provider oracle (no behaviour change):
validate(system, locator, ticker; provider = :yahoo, scheme) -> Vector{OracleRow}
report(firms; provider, scheme)                              -> printed panel + rows

# NEW — user-facing PDF quality, operate on the user's Filings/paths/facts, return DATA:
coverage(x)  -> NamedTuple           # x :: Filing | path | Vector{FactRow} | Vector thereof
             # per-stage funnel: parsed? located? tables? facts? types? reconcile (BS cross-foot)
accuracy(x; oracle = :yahoo | :xbrl_twin, tol = 0.01, ticker = …, twin = …) -> (rows, hit_rate)
             # 5 headline totals vs the oracle; per-metric (extracted, reference, rel_diff, within_tol)
```

- **No new machinery.** `coverage` = the pipeline (`_pdf_words` → `_ifrs_statement_pages` →
  `structured_document` → `extract_ifrs_pdf`) + a BS cross-foot, with the `Fixture`/`STASH`/`expect` coupling
  removed. `accuracy` reuses `ORACLE_METRICS` for the five headline concepts and delegates: `:yahoo` →
  `validate`; `:xbrl_twin` → compares the PDF facts' headline totals to the twin filing's own iXBRL facts
  (the "dual-format AFR oracle" of plan item **2R.G**).
- `coverage` is **network-free** → offline-testable. `accuracy` needs the oracle (network for `:yahoo`).
- Both accept **already-extracted facts** (`Vector{FactRow}`) so a user who called `facts(f)` doesn't
  re-extract.

**Export policy:** export all four (`coverage, accuracy, validate, report`) — the decision is to make these
THE validation API. `report`/`accuracy` are generic names; that is accepted.

**Decided defaults** (were open questions; resolved so implementation isn't blocked):
- `accuracy` is **single-filer-first** (`accuracy(f; oracle, ticker/twin, tol)`) with a `Vector` convenience
  that maps over it — simpler, composes.
- File placement: **`src/extractors/pdf_quality.jl`** (exported package code, included by `src/EDGAR.jl`).
- `coverage`/`accuracy` accept `Filing`, a path `String`, or `Vector{FactRow}`.

## 5. Eliminate `PdfScorecard`

- **Delete `src/sources/pdf_scorecard.jl`** (the module).
- Its `FIXTURES` panel + expected results → a **gated regression test** in `test/` that calls
  `coverage`/`accuracy` on the stashed PDFs and asserts. It is inherently local/network-gated (the fixture
  PDFs live in `~/EDGAR-Reports`, not the repo), so it slots in beside the existing `RUN_NETWORK` tests as an
  opt-in block that skips cleanly when the stash/network is absent.
- `Fixture`, `score_one`, and the pretty-printers are absorbed: the per-stage funnel becomes `coverage`'s
  return value; the "expected types / expected totals" become test assertions; the printing becomes the
  test's failure messages (or a tiny local helper).

## 6. Migration / deprecation

- **Additive for the survivors:** `validate`/`report` signatures unchanged, now exported.
- **Removed:** the `PdfScorecard` module (→ test) and `ArelleLocalOracle.validate_dart`/`report_dart` (→ inline
  the discovery). No other `validate`/`report` touched.
- **New exports:** `validate, report, coverage, accuracy`.
- **Docs:** the manual's `sec:pdf-accuracy` currently teaches `PdfScorecard.accuracy()`/`report()`. Rewrite it
  to teach `accuracy(f; oracle=…)` / `coverage(f)` on the user's own filing; the fixed panel becomes an
  internal test, no longer a documented user entry point. `language-support.md` is unaffected.

## 7. Non-goals

- Not touching the DIY oracle sources (`PdfOracle`, `ArelleEsefOracle`, `ArelleLocalOracle`, `CsvOracle`)
  beyond removing the `_dart` sugar.
- Not changing `validate`/`report` behaviour or the provider abstraction.
- Not building new providers or a new benchmark source.

## 8. Implementation order (once approved)

1. `src/extractors/pdf_quality.jl`: `coverage` (offline) + `accuracy` (`:yahoo` via `validate`, `:xbrl_twin`
   via twin facts); include + export the four names in `src/EDGAR.jl`.
2. Port the `FIXTURES` panel to a gated `test/` block asserting on `coverage`/`accuracy`.
3. Delete `src/sources/pdf_scorecard.jl`; delete `ArelleLocalOracle.validate_dart`/`report_dart`.
4. Rewrite manual `sec:pdf-accuracy` around the exported functions.
