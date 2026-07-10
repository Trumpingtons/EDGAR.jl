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

## S0 findings (recon — 2026-07-10, six FRESH filers across HK/DE/CN)

Corpus (saved under `~/EDGAR-Reports/`, fetched fresh, not the Siemens/VW stash): HK — ANTA (02020),
Techtronic (00669); DE — Henkel, Continental (group); CN — Midea (000333), Gree (000651). Segment notes
Docling-extracted from each. Findings (they **revise the Design above**):

1. **Orientation is segments-as-COLUMNS, universally** in the sample (ANTA, Techtronic, Continental, Gree —
   all columns). The header row is the segment names ending in a total column; metric rows sit below. My
   earlier "segments-as-rows" (from Siemens *nach Konzernbereichen*) was wrong as a default. → **S2 default:
   segments-as-columns**, with segments-as-rows as the fallback orientation.
2. **The revenue anchor is the external-revenue row**, label per framework/language: `External sales` /
   `Revenue from external customers` (IFRS-EN), `对外交易收入` (CAS). Pick this row, not "total segment
   revenue" (which includes inter-segment).
3. **Total column**: `Consolidated` / `Continental Group` / `Total` / `合计`. **Reconciliation/elimination
   column**: `Other/Holding/Consolidation` / `Headquarters and unallocated items` / `分部间抵销` (+ `其他`).
4. **The data table is located by STRUCTURE, not by heading.** Heading and table can be far apart — Gree's
   分部报告 heading is p125, its table p207 (**82 pages**). And segment figures appear in *two* places: the
   management-report disaggregation (Midea p49, Henkel p28) and the formal notes table (Gree p207). → **S1
   must scan broadly and match on structure** (a segment-name header row + an external-revenue row),
   disambiguating from the co-located **geography** and **product** breakdown tables (Techtronic has all
   three).
5. **Reconciliation oracle confirmed real**: Σ external-revenue = total column — Gree 133.06+17.38+0.68+20.00
   = 171.12bn = 合计 ✓; Continental 19,405+13,768+6,308+238 = 39,719 = Group ✓.
6. **Docling captures CJK segment tables cleanly** (Gree p207 came through with correct Chinese headers and
   values) — CJK is *not* a blocker; page-range location was.
7. **Docling robustness risk**: Henkel's segment table was **not captured** on either the notes pages (p343)
   or the management-report page (p28) — two misses. Some presentations (infographic-style / very wide
   tables) defeat the parser. → S2/S3 must **fail gracefully and flag** "segment table not found", and S1
   may try a wider range / the alternate (mgmt-report vs notes) presentation before giving up.
8. **Plan correction**: the persisted repo `StructuredDocument`s are page-scoped to the **primary
   statements** and do **not** contain the segment note (Siemens p45–56 held EU-taxonomy tables, not
   segments). So `_segments_pdf` **cannot** reuse the persisted SD as-is; it needs the segment-note pages —
   either a wider persist range or on-demand extraction located by finding #4.

## S0-extended findings (Russia / Generic / ESEF — 2026-07-10)

Broadened the fresh corpus to Russia (Nornickel, Severstal), Generic (Nestlé) and ESEF (Airbus, Enel). Two
findings **reshape the architecture and the fetch layer**:

9. **Document selection is a first-class problem.** The segment note lives in the **consolidated financial
   statements**, which for many issuers is a \emph{separate} document from the annual report / review. The
   Russian IFRS annual reports (Nornickel, Severstal) and Nestlé's *Annual Review* carried **no** IFRS-8
   segment note — Nestlé's p42 "operating segment review" is a \emph{management-view category} sales table
   (a decoy, like Techtronic's product/geography tables). → S1 (or the fetch layer) must target the
   **financial-statements** document, not the flagship annual report; and the parser must reject
   management-view / product / geography tables in favour of the statutory segment note.
10. **ESEF is a table-parse over the iXBRL HTML — one parser, two source adapters.** Confirmed on Airbus:
    segments are **not dimensioned** (`segments(f, "ifrs-full:Revenue")` → 0 rows), the block-tagged
    `DisclosureOfEntitysReportableSegmentsExplanatory` is **prose** (1.7 kB, no `<table>`), yet the segment
    numbers sit in a **rendered HTML table** (segment names — Commercial Aircraft, Defence and Space,
    Helicopters — are all over the iXBRL). So the ESEF adapter parses the iXBRL **HTML into `DocTable`s**
    (the existing HTML document path, not Docling) and then runs the \emph{same} segment-table parser.

**Finalized architecture — one parser, two adapters.** The S1/S2 logic (locate the segment table by a
\emph{segment-name header row + an external-revenue row}; parse segments-as-columns; exclude/capture the
total + elimination columns; reject geography/product/management decoys) is **source-independent** and runs
on a `DocTable`. Two adapters feed it:
- **Docling adapter** — PDF (China/Germany/HK/Russia/Generic), page-scoped extraction located by structure.
- **HTML adapter** — ESEF/UKSEF iXBRL, tables from the HTML document builder; the block-tagged explanatory
  text is prose only, so it is ignored for the numbers.

**Scope (settled).** In: China, Germany, HK, Russia (IFRS-statements PDF), Generic (uncovered geographies),
and ESEF (HTML adapter). Out: UK Companies House (small PDF filers disclose no segments; large UK groups ride
the UKSEF/HTML adapter). EDINET/DART/India/SEC already work via XBRL dimensions.

## S1 findings (locator + adapters built — 2026-07-10)

Built `src/extractors/segments_doc.jl`: the source-independent locator (`_segment_score`/`_find_segment_grid`)
+ the Docling adapter (`_grid` over `DocTable`) + the HTML adapter (`_grids_html` via `Documents.TableProcessor`
→ `TableMatrix`). Verified on the corpus:

- **Locator generalises**: one scorer finds the segment table across Docling PDF (Continental/EN, Techtronic/EN,
  Gree/CJK) and HTML iXBRL (Enel), and rejects the geography/product/management-view decoys (Techtronic, Nestlé).
- **Anchor generalised beyond "external sales".** The revenue-row label varies more than S0 showed: Enel uses
  **"Revenue and other income from third parties"**, and the label **wraps across grid rows** (numbers on one,
  "from third parties" on the next). So the anchor is now a revenue FAMILY (`_SEG_REVENUE`) + an EXTERNAL
  qualifier (`_SEG_EXTERNAL`: external / third-party / 对外 / 外部), with a `_row_label` that stitches the wrapped
  continuation, preferring the external row over "total revenue" (which includes inter-segment).
- **ESEF iXBRL has TWO flavours** — the decisive S1 finding:
  - **Semantic-table** (Enel: 274 `<table>`) → the HTML adapter parses it directly (XPath must use
    `local-name()='table'` — iXBRL is XHTML with a default namespace, so bare `//table` matches nothing).
  - **Div/span-positioned** (Airbus: **0** `<table>`, 1706 `<div>`, absolutely-positioned spans from a
    PDF-to-iXBRL converter) → there is no HTML table to parse; it needs **Docling over the HTML** (visual
    reconstruction), i.e. the *Docling* adapter with an HTML input. **Remaining S1 task.**

So the "two adapters" are really **table-source strategies**: `Documents`-HTML for semantic-table iXBRL,
Docling for PDF *and* div-positioned iXBRL. The locator is unchanged across all of them.

**Table fragmentation (Wesfarmers, Generic ×2).** A filer with many segments (Wesfarmers: 8) has a *wide*
segment table that Docling **splits into two** by column-group — one fragment `BUNNINGS | KMART | WesCEF`
with the `Revenue from contracts with customers` row, the other `OFFICEWORKS | … | CONSOLIDATED`. Neither
half carries the full *segment-header + external-revenue + total* structure, so the single-table locator
misses it. This is the same class as Henkel's Docling-miss — the *table extractor* is the limiting factor,
not the locator. Two consequences for S2/hardening: (a) **re-join adjacent same-page table fragments** (same
row count, contiguous columns) before locating; (b) the revenue anchor must also accept the IFRS-15 label
`Revenue from contracts with customers` (no "external" qualifier — so it relies on the total+reconciliation
guard, which only appears once the fragments are joined). The geography (Australia/NZ) and management-view
`%` tables were correctly rejected.

## Phases

- **S0 — Recon. ✅ DONE** (see *S0 findings* above). Reconned six FRESH filers across HK/DE/CN (not the
  stash), Docling-extracting each segment note. Catalogued orientation, revenue anchor, total/elimination
  columns, table-location behaviour, CJK fidelity and Docling robustness. **Gate met:** the by-segment
  external-revenue table was located and its revenue row/column identified for HK (ANTA, Techtronic), DE
  (Continental) and CN (Gree); Henkel flagged as a Docling-miss robustness case; Midea's figures found in
  the management report.
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
