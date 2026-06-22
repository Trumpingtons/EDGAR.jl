# Phase R2 — porting edgartools' resolver rules (STATUS, persistent)

> Tracks the port of the tuned, issue-driven rules in edgartools' `xbrl/statement_resolver.py`
> (`find_statement` + `_score_statement_quality` + the match cascade, lines 732–1306) into
> EDGAR.jl. The ~two-dozen gross score adjustments consolidate to the **~14 distinct rules** below.
> Each R2 rule is ported **fail→correct**: add/repoint a case in `test/data/classification_corpus.json`
> so the test goes red, then implement until green. **Update + commit this file after every rule** so
> progress survives a stop.
>
> Legend: ✅ done · 🔜 R2 to-do · 🅰 already covered by EDGAR.jl architecture · 🅓 already ported as
> R0 registry data · ⏭ deferred to R3 (query-time resolver).

## Already covered (R0 data / architecture)

| Rule | edgartools | What it does | Where | Status |
|---|---|---|---|---|
| D1 | #673 | IFRS P&L role names + `ifrs-full` concept anchors | `vocab_ifrs.jl` / engine role_substrings | 🅓 |
| D2 | #581/#584 | "operations" role pattern + singular/plural; combined operations+CI naming | engine role_substrings | 🅓 |
| D3 | 8ad8 | equity roll-forward concept + pattern | engine concept_patterns | 🅓 |
| D4 | — | `ifrs-full` equivalents for every statement | `vocab_ifrs.jl` | 🅓 |
| A1 | 8ad8 | penalize parentheticals | `_ROLE_EXCLUDE` (we drop them) | 🅰 |
| A2 | #518 | don't return a wrong type | score threshold → `""` + priority | 🅰 |
| A3 | #506 | deprioritize CI vs IS for a shared concept | `_STATEMENT_PRIORITY` (IS > CI) | 🅰 |

## R2 — to port into the scorer (this phase)

| Rule | edgartools | What it does | Status |
|---|---|---|---|
| T2 | #659 | essential-content validation: reject a role whose only concepts are abstract headers / note `TextBlock`s (a disclosure), even if its name matches a statement | ✅ **done** — line-item gate in `classify_engine.jl`; fixed 6 disclosure false-positives (ARCC/STT equity notes, MSFT/NVS/PNC comprehensive-income notes, SAP segment reconciliation) with zero regressions |
| T1 | #581 | penalize tax **disclosure** roles that carry income concepts | 🅰 covered — our IS role patterns require "statement"+"income" adjacency (a bare "incometax…" role doesn't match), plus `details` exclusion + the #659 gate. Re-open if a counterexample appears. |
| T3 | #503 | prefer a complete statement over a tiny **fragment** role of the same type | 🔜 no current evidence — the 2-concept "fragments" we saw were disclosures (fixed by T2). Needs a real same-type fragment filing to port responsibly. |
| T4 | #506/#584 | refine pure-ComprehensiveIncome vs combined-operations scoring | 🅰/⏭ — combined ops+CI → IncomeStatement via registry order + priority; the pure-CI-serves-as-income case (AZN) is the R3 resolver item Q1. |

## R3 — query-time resolver

| Rule | edgartools | What it does | Status |
|---|---|---|---|
| Q1 | #518/#608 | IncomeStatement → ComprehensiveIncome fallback, validating the CI role holds real P&L data | ✅ **done** — `select_statement` in `classify_engine.jl` |
| Q2 | #706 | ComprehensiveIncome → StatementOfEquity fallback (older filings embed CI in equity) | ✅ **done** — transitive fallback chain in `select_statement` |
| Q3 | — | the 5-strategy `find_statement` cascade (per-request best-role selection) | 🔜 next |

## Log

- **T2 (#659) DONE** — essential-content / line-item gate in `_classify_role`: a role whose only
  concepts are `…Abstract` headers or `…TextBlock` notes is rejected as a disclosure. The corpus
  surfaced **6** such false-positives (seeded from the pre-gate classifier); all now correctly `""`,
  full suite green. Generator updated to keep "name-looks-like-a-statement but classifies empty"
  cases as regression guards.
- After T2: of the remaining R2 rules, T1 and T4 are covered by our role-pattern specificity +
  exclusions + priority (see table); T3 has no current failing filing. The substantive remaining
  work is **R3** (the query-time resolver: AZN-style combined-statement aliasing #608, CI→Equity
  #706, and the find_statement cascade). Next: either broaden the corpus to hunt more failures, or
  start R3.
- **Q1 (#608) + Q2 (#706) DONE** — `select_statement(rows, statement)` in `classify_engine.jl`
  (exported). Query-time resolver: a requested face statement with no section of its own is aliased
  onto the section that *subsumes* it, **gated on essential content** so a pure-OCI section is never
  returned as the income statement. The fallback chains transitively — IncomeStatement →
  ComprehensiveIncome (#608, the AZN combined "Statement of Profit or Loss and Other Comprehensive
  Income") → Equity (#706, older filings embedding CI in the statement of changes in equity), each
  hop validated against the requested type's `key_concepts`. Operates on any `facts(...)` row table
  (reads only `.statement`/`.concept`). Offline testset "statement resolver (R3 …)" — direct-wins,
  #608 alias, pure-OCI no-alias, #706 CI→Equity, transitive IS→CI→Equity. Full suite green.
- **Remaining R3 = Q3** — the 5-strategy `find_statement` cascade (per-request best-role *selection*
  when multiple candidate roles classify to the same statement: complete-over-fragment #503,
  parenthetical penalty, recency/quality scoring). Distinct from Q1/Q2 (which alias *across* types);
  Q3 ranks *within* a type. Needs a multi-candidate corpus to port responsibly.
