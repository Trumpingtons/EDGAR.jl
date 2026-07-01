# Plan — `narratives()`: a cross-jurisdiction prose primitive

Status: **draft / awaiting approval**. Parallel to `facts()` (numeric) — `narratives()` is the
presentation/text layer that `Fact`'s docstring already anticipates ("non-numeric tags … belong to the
presentation/text layer").

## Goal

One primitive, `narratives(f)`, that harvests **narrative sections** from a filing regardless of source —
XBRL text-blocks, inline-XBRL text-blocks, an ingested PDF, or SEC HTML Item sections — into a single
Tables.jl row table of a new `Narrative` type. Downstream (search, export, LLM) is source-agnostic.

## Why now / what makes it testable

The EDINET CSV (`type=5`) lists every **text-block** fact as a clean `(concept, verbose-label, text)` row.
That is a **dual oracle**:
- vs `narratives()` from **iXBRL/classic XBRL** → **exact** text match (same document bytes).
- vs `narratives()` from the **PDF** → **fuzzy** character-similarity, aligning each PDF section to its
  text-block by title ↔ verbose label. This is a real, quantitative PDF-extraction benchmark.

We already hold, offline, all three renderings for Toyota (E02144), Fast Retailing (E03217), Nintendo
(E02367): submission XBRL, PDF, and CSV.

## The `Narrative` type (prose's `Fact`)

```
Narrative:
  cik, accession                        # provenance
  source        ::Symbol                # :xbrl | :ixbrl | :pdf | :html
  concept       ::String                # XBRL concept qname ("" for PDF/HTML)
  section       ::String                # classification ("MD&A","Risks",…) or ""
  title         ::String                # EDINET verbose label / SEC Item title / PDF heading
  text          ::String                # content, HTML-stripped to plain text
  lang          ::String                # "ja" | "en" | ""
  char_len      ::Int
  period_end    ::Union{Nothing,Date}   # XBRL context (nothing for PDF/HTML)
  dimensions    ::String                # JSON, XBRL only ("{}" otherwise)
  context_ref   ::String                # XBRL provenance ("" otherwise)
  page          ::Union{Nothing,Int}    # PDF provenance
  block_id      ::String                # PDF/HTML provenance ("" otherwise)
```
Plus `narrative_row(n)` + `const NarrativeRow` (mirrors `fact_row`/`FactRow`) so `narratives()` returns a
concretely-typed row table even when empty, and can flow to JSON/DuckDB later.

## Producers (all behind `narratives(f)`)

1. **`:ixbrl`/`:html` and `:xbrl`** — **generalize the existing `_dei_fact` extractor**
   (`filing_systems/sec/auditor.jl`), which already pulls `ix:nonNumeric` text from **both** inline *and*
   classic instances, entity-decoded, handling the `fixed-true/false` transforms — but for **one named
   concept at a time**. Widen it from "fetch one concept's text" to "harvest **all** text-block concepts,"
   reusing its proven regex + `_dei_clean` decoding. No text-block extraction is written from scratch.
2. **`:pdf`** — `StructuredDocument` → one `Narrative` per **section** (text-blocks concatenated in `ord`),
   carrying `title`, `lang`, `page`. (Docling/PythonCall; the tier-2 venv already exists.)
3. **SEC HTML** — wrap existing `sections(f; form)` → `Narrative` (source `:html`).

### Prior art in the codebase (checked)
- **No** general text-block/narrative harvester exists for XBRL/iXBRL — `facts()` and the picker both
  *deliberately skip* `ix:nonNumeric` (extract_xbrl.jl:161, picker.jl:226).
- **`_dei_fact` (auditor.jl)** is the one working precedent: single-concept `ix:nonNumeric`+classic text
  extractor, entity-decoded. N1 generalizes it.
- Text-block **type/label** metadata already exists (EDINET concept table, §sec:edinet-concepts); text-block
  **content** oracle already downloaded (EDINET CSV).

**Text-block predicate** (which concepts are narrative): `type == textBlockItemType` via the EDINET concept
table (§sec:edinet-concepts) for EDINET; `*TextBlock` local-name for SEC `us-gaap`. Per-system, general.

**Title source**: the **verbose** label — for EDINET, from the concept table (oracle-matched); for extension
concepts, from the filing's own bundled linkbase.

## Steps (checkpoint after each ▶)

- **N0 — Type & schema.** `Narrative`, `narrative_row`, `NarrativeRow`, `Base.show`; new file
  `src/core/narratives.jl`; include + export. ▶ loads clean.
- **N1 — XBRL/iXBRL producers.** Generalize `_dei_fact` (auditor.jl) into `_extract_narratives(f)` (mirrors
  `_extract_facts`) — harvest all `ix:nonNumeric`/classic text-block elements, reusing its regex +
  `_dei_clean` decoding + `_xbrl_contexts`. Text-block predicate + verbose title. ▶ rows on EDINET fixtures.
- **N2 — `narratives(f::Filing; classify, labels, lang)`** dispatch (`:pdf` → PDF producer; else XBRL/iXBRL).
  ▶ smoke on a real EDINET submission.
- **N3 — PDF producer.** `narratives(sd::StructuredDocument)` (+ `read_structured_document` path) → per-section
  rows; `narratives(f::Filing[:pdf])` builds the doc like `_pdf_filing_facts`. ▶ rows on a Toyota PDF.
- **N4 — SEC HTML producer.** wrap `sections(f; form)`. ▶ rows on a 10-K fixture.
- **N5 — Oracle harness (scratchpad, not shipped).**
  - Exact: `narratives(iXBRL/XBRL)` vs CSV text-blocks (concept→text, whitespace-normalised). Report match %.
  - Fuzzy: `narratives(PDF)` sections vs CSV text-blocks aligned by title; char-similarity score per section.
  - Run Toyota / Fast Retailing / Nintendo. ▶ report parity.
- **N6 — Tests + Manual.** Offline `narratives()` testset on a committed fixture; new Manual subsection
  (parallel to `facts`, the `Narrative` shape, producers, the CSV dual-oracle); recompile. ▶ green + builds.
- **Gate:** report parity; commit only when told.

## Risks / open

- Classic vs iXBRL text-block content: nested HTML + escaped entities; unescape before tag-strip.
- PDF↔CSV section alignment is heuristic (title similarity); report unmatched sections, never silently drop.
- PDF path needs Docling (tier-2 venv) and OCR for Japanese (`force_ocr` auto-on for JP) — slow; N3/N5-PDF
  run on demand, not in the offline test suite.
- `narratives()` default `labels=true` (a title is core to a narrative, unlike `facts` where `label` is opt-in).
