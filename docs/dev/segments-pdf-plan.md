# Revenue-by-segment for PDF-native jurisdictions — living plan

Status: **PLANNING** (2026-07-09). Extends `segments()`/`breakdown()` — today XBRL-dimension-only — to the
PDF-native filing systems (China, Germany, Hong Kong), by recovering the segment table from the
`StructuredDocument` rather than from XBRL contexts. Named target: Siemens' *Umsatz nach Konzernbereichen*
and VW's segment report, which the Germany arc deliberately skipped. Companion to the PDF fact extractors
(`extract_ifrs_pdf`/`extract_cas_pdf`/`extract_hgb_pdf`); see [[pdf-extractor-plan]], [[china-plan]],
[[india-plan]] (where revenue-by-segment was flagged as the next capability).

## The gap

`breakdown(f, concept)` and its convenience `segments(f, concept)` ([src/core/breakdown.jl](../../src/core/breakdown.jl))
read dimension members straight from the instance contexts (`_xbrl_contexts(f.content)`) and name them from
the label linkbase. A **PDF-native** filing has no XBRL layer — `f.content` is a report *path*, its facts are
derived by `extract_*_pdf` from `StructuredDocument.tables`, and they carry **no dimensions** — so
`segments(f, …)` returns empty for China/Germany/HK. The segment data is physically present as one of
`sd.tables` (Docling-parsed), but nothing reads it and there is no dimensional hook. This is a genuinely new
extraction path, not a tweak to the XBRL one.

## Design

### Public API — one signature, dispatched on filing kind
`segments(f, concept)` and `breakdown(f, concept; axis)` keep their **exact current signatures and row
shape**. Internally they dispatch on the filing's format:
- **XBRL-native** (SEC, ESEF, EDINET, DART, India) → the existing dimension path, unchanged.
- **PDF-native** (China, Germany, HK) → a new table-parsing path (below).

No `source=` kwarg, **no fallback** — a filing is one kind or the other, and the kind decides. (Decision:
the dial would have exactly one working setting per filing; a `source=`/same-document-segment-oracle can be
added non-breakingly later if a concrete need appears. Structure the code as two internal helpers —
`_segments_xbrl(f, …)` and `_segments_pdf(f, …)` — so that stays a five-minute addition.)

### The PDF segment path — `extract_segments_pdf`
A new extractor over the `StructuredDocument` (the substrate `extract_ifrs_pdf` already builds via Docling),
parallel to the fact extractors:
1. **Locate** the segment table in `sd.tables` by caption + enclosing section heading, multilingual
   ("Segment information", "Operating/Reportable segments", DE "Segmentberichterstattung" / "nach
   Konzernbereichen", CN "分部信息/分部报告"). A filing's segment note usually holds several tables (by segment,
   by region, reconciliation) — pick the by-segment revenue one.
2. **Detect orientation** — segments-as-rows (usual) vs -as-columns — and **identify the revenue column**
   via the framework label vocabulary (`ifrs_label_concept`/`cas_concept`); exclude the reconciliation /
   eliminations / "Group|Konzern|合计" total rows (capture the total separately for the S4 check).
3. **Reuse the ifrs_pdf machinery** for unit/scale/currency and the German decimal-comma locale
   (`_ifrs_scale_currency`, `_ifrs_table_unit`, the locale-aware value-cell parser) — already solved for the
   primary statements.
4. **Operate on a `StructuredDocument`**, not a re-parse: `extract_segments_pdf(sd, concept)` is the core;
   a `path` convenience builds the SD. `segments(f)` reuses the persisted SD from the document repository
   (`~/RegulatoryReports/regulatory-reports.duckdb`) when present, so segments does not re-run Docling that
   facts already ran.

### Output shape — a drop-in for `breakdown()`
Emit the **same rows** the XBRL path returns:
`(axis, member, name, value, period_start, period_end, is_instant, other_dims)` — with a synthesized
`axis = "segment"` (no QName exists), `member` = a stable slug, `name` = the segment label (native-script,
English-first per [[minimal-chinese-wordings]] where relevant), and `other_dims = ""`. Sorted newest-period,
largest-value first, as today. So a caller cannot tell (nor need to) whether a row came from XBRL or a PDF.

### Built-in reconciliation oracle
Self-validating, no external source: extracted segment revenues must **reconcile to the consolidated
revenue** that `extract_ifrs_pdf`/`extract_cas_pdf` already recovers — `Σ segments + eliminations = Group`.
This is the same-document cross-check the project favours (cf. Arelle/CSV oracles), and it doubles as the S4
gate.

## Phases

- **S0 — Recon (Germany first).** Dump the real segment `DocTable`s for the stashed DE panel (Siemens, VW,
  BASF, Deutsche Telekom-EN) via Docling. Catalogue per filer: the caption/heading text (and language),
  orientation, the metric columns, unit/scale, the total/eliminations rows, and segment-name language.
  Confirm Docling captures the table cleanly (multi-row headers, merged cells). **Gate:** for each DE filer
  the by-segment revenue table is present in `sd.tables` and its revenue column is human-identifiable.
- **S1 — Locate.** Heuristics to select the by-segment revenue table among the note's several tables,
  multilingual, robust to caption-on-section vs caption-on-table. **Gate:** the correct table is selected for
  every DE panel filer (and, once added, HK/CN).
- **S2 — Parse.** Orientation detection + revenue-column identification + per-segment value extraction,
  reusing the ifrs_pdf unit/locale machinery; exclude and separately capture the total/eliminations rows.
  **Gate:** a `segment → revenue` map (with period) is extracted for every DE filer.
- **S3 — API + shape.** Route `segments(f, concept)`/`breakdown` to `_segments_pdf` for PDF-native filings;
  emit `breakdown()`-shaped rows; reuse the persisted SD. **Gate:** `segments(f, "ifrs-full:Revenue")`
  returns rows for a German filer, XBRL filers are unchanged (no regression on the SEC/ESEF path).
- **S4 — Validate.** The reconciliation oracle: `Σ segments (+ eliminations) = consolidated revenue` within
  tolerance, across the DE panel, then HK, then CN. Add to the test suite. **Gate:** every panel filer
  reconciles; validated on FRESH filers per [[validate-on-new-filers]].
- **S5 — Manual + commit.** Document the capability — the `segments()` unification, the PDF path, the
  reconciliation oracle — in the manual (breakdown/segment section) and update the `breakdown.jl` docstrings.
  Commit. **Gate:** manual updated, changes committed.

Jurisdiction order: **Germany** (Siemens/VW, the named target; PDFs stashed; Latin-script names) → **Hong
Kong** (English IFRS PDFs, shares the ifrs_pdf path) → **China** (CAS PDFs; CJK segment names, the
[[minimal-chinese-wordings]] care applies).

## Deliverables
- `extract_segments_pdf(sd|path, concept)` + `_segments_pdf`, with `segments(f, concept)`/`breakdown`
  routing PDF-native filings to it — same signature, same row shape.
- Reconciliation test (segments-sum-to-consolidated) across the DE/HK/CN panels.
- Manual + docstring updates; changes committed.

## Risks / notes
- **Orientation & layout variance** — segments as rows vs columns; multi-row headers; the "Group/Konzern"
  total and the eliminations line to exclude (but keep for S4).
- **Docling fidelity** on large, dense segment tables (merged cells, footnote markers) — the S0 gate is
  precisely to surface this before building S2.
- **Metric ambiguity** — a segment table reports external vs total (incl. intersegment) revenue; pick
  external revenue for the consolidated reconciliation, and record which.
- **Multilingual segment names** — German is Latin-script (fine); China is CJK ([[minimal-chinese-wordings]]:
  English-first, native only where it is the data). HK is English.
- **SD reuse** — build on the persisted `StructuredDocument` (repository) so segments never re-runs Docling
  that facts already ran; see [[edgar-dev-env-and-reports]].

## Hard rules honored
- **HTTP = "1.10", never 2** — [[never-http-v2-reseau]].
- **Validate on NEW filers each run** — [[validate-on-new-filers]].
- **Persistent dev env `~/EDGAR-tools/edgar-dev/`; tier-2 Docling venv for `StructuredDocument`** —
  [[edgar-dev-env-and-reports]], [[pdf-extractor-plan]].
- **Ask before running tests; commit only when told; be decisive** — [[edgar-jl-working-style]].
- **Never recompile the manual unless told** — [[no-latex-recompile]].
