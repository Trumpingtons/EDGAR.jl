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
| T1 | #581 | penalize/exclude tax & similar **disclosure** roles that carry income concepts | 🔜 |
| T2 | #659 | essential-concept validation: a role labelled X must actually contain X's anchor concepts | 🔜 |
| T3 | #503 | prefer a complete statement over a tiny **fragment** role of the same type | 🔜 |
| T4 | #506/#584 | refine pure-ComprehensiveIncome vs combined-operations scoring | 🔜 (assess; may be 🅰) |

## R3 — query-time resolver (deferred)

| Rule | edgartools | What it does | Status |
|---|---|---|---|
| Q1 | #518/#608 | IncomeStatement → ComprehensiveIncome fallback, validating the CI role holds real P&L data | ⏭ R3 |
| Q2 | #706 | ComprehensiveIncome → StatementOfEquity fallback (older filings embed CI in equity) | ⏭ R3 |
| Q3 | — | the 5-strategy `find_statement` cascade (per-request best-role selection) | ⏭ R3 |

## Log

- (pending) — R2 started.
