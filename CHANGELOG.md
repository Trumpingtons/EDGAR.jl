# Changelog

Notable changes to EDGAR.jl. Format follows [Keep a Changelog](https://keepachangelog.com/);
versions follow [SemVer](https://semver.org/).

## [Unreleased]

### Added

- **Negated presentation labels.** `facts(f; classify=true)` now honours the XBRL
  `negatedLabel` / `negatedTerseLabel` / … preferred labels from a filing's presentation linkbase,
  flipping those facts' signs so a value matches the statement **as the company reports it** (treasury
  stock as a contra-equity; cash outflows, buybacks, dividends, debt repayments shown as subtractions;
  some filers even store operating cash flow negated). This is general — driven entirely by the
  filing's own labels — and affects roughly **99% of filers** (~20+ line items each).
  `classify=false` keeps the **raw** stored fact value (identical to the SEC `companyfacts` API);
  filers with no presentation linkbase (FilingSummary fallback) are unaffected.
- **Multi-statement membership.** Every fact carries the full set of statement sections its concept
  belongs to (a `statements` column), and `statement_view` is membership-aware. Multi-homed concepts
  (e.g. `StockholdersEquity` ∈ balance sheet *and* statement of equity) and *combined* statements
  (one role serving two, recognised via definitional key-anchor concepts) resolve through normal
  membership queries.
- **`reconstruct_from_notes(f, statement)`** — opt-in reconstruction of a statement a filer filed only
  as a note/detail (commonly the statement of changes in equity), each row clearly marked as
  reconstructed (`source_selector = "reconstructed:<role>"`).
- **`select_statement(rows, statement)`** — query-time resolver for combined statements
  (income ↔ comprehensive income, comprehensive income → equity), gated on essential content.
- Broader statement-classification vocabulary (audited for parity with edgartools): the fund/BDC
  statements `ScheduleOfInvestments` and `FinancialHighlights`, plus "Statement(s) of Earnings",
  "Comprehensive Earnings", bank "Statement of Condition", and IFRS naming.

### Fixed

- Classic-instance extraction is now at parity with the inline path: default-namespace instances
  (unprefixed `<context>`/`<unit>`), signs carried in the value text, and a regex match-limit on very
  large instances. `facts(::Filing)` loads the SEC's complete *extracted* instance, recovering
  foreign / 40-F / 20-F / multi-part filings whose primary document is only a cover.

### Validated

- Value-parity with edgartools across ~130 filers (foreign multi-GAAP, banks, insurers, REITs, MLPs,
  utilities, asset managers, BDCs, and micro-caps), the five face statements, and the
  10-K / 10-Q / 20-F / 40-F / 10-K-A forms.

## [0.8.0]

- Interactive picker, native bulk XBRL extraction, 4-layer export
  (iXBRL / Markdown / Facts JSON / DuckDB), the 3-table warehouse, concept standardization,
  statement classification, and calculation linkbases. See the manual for details.
