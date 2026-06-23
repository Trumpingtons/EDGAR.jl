# Changelog

Notable changes to EDGAR.jl. Format follows [Keep a Changelog](https://keepachangelog.com/);
versions follow [SemVer](https://semver.org/).

## [Unreleased]

### Added

- **`sections(f; form)` — form-agnostic item extraction.** Segments a filing's text into its items
  (`"Item 1"`, `"Item 1A"`, …) in document order — a faithful port of edgartools' `ChunkedDocument`:
  blocks are grouped into chunks (a new chunk at each `Item`/`Part`/heading; tables are their own chunk),
  each chunk's leading `Item N` line sets its item, the table of contents is dropped by item density, the
  item label is forward-filled, and the signature block truncates the tail. Header-vs-body is decided by
  word case and length, so the *same* logic serves 10-K, 10-Q, 20-F, 8-K and other item-structured forms
  with no per-form catalogue. Filings with no in-body `Item N` headers but a *FORM 10-K Cross-Reference
  Index* (GE, Henry Schein) are handled by a second strategy that maps items to page ranges. Validated at
  character-level parity with edgartools across a diverse set of 10-Ks. (Built on Gumbo for HTML parsing;
  complements the generic, name-at-a-time `extract_section`.)
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
