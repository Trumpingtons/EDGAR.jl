# Plan — PDF as a first-class Filing ("CH II", the Format/extraction axis)

Status: **draft / living document** (expect iteration). This is the plan the Companies House plan
([companies-house-plan.md](companies-house-plan.md)) deferred as **"CH II"** — the second extractor on
the **Format / extraction** axis (FilingSystem × Taxonomy × **Format**). It follows the same governing
principle:

> **STATUS (2026-06-29) — the parser is no longer a risk; reframe to document-first.**
> **Parser settled:** Docling (no OCR) was validated across **EN** (Tesco) + **CN×3** (Moutai/Vanke/
> Wuliangye) + **KR** (Samsung) + **RU** (Lukoil) + **DE×2** (Fielmann IFRS, VW HGB) — it recovers text,
> section hierarchy, *and* statement tables that cross-foot. **OCR is only needed for Japan EDINET**
> (broken/CID text layer). The toolchain question is closed.
> **Reframe:** this is a **document** process. `FactRow` is at most **one later derivation**, not the lead
> deliverable (and possibly not the right lens at all). The questions to settle *first* are **(a)** which
> document **components** to separate & save, **(b)** whether the process is **general or
> jurisdiction-specific**, and **(c)** the **DuckDB schema + filesystem persistence** for text segments,
> tables and figures. These are worked in §1a below; the older FactRow-as-gate framing (Phase 1) is
> demoted accordingly.

> **Generalize the nouns, not the verbs.** The `Filing.kind == :pdf` outcome already exists as a typed,
> non-fatal result; this plan makes that outcome *parseable*. PDF is a new **extractor**, not a new
> system — it slots beside `extract_xbrl.jl`.

### Why this is the highest-leverage next feature

- It **unblocks work already built.** CH and the NSM source cover only the machine-readable minority of
  real filings: at CH the format is unpredictable and much of the registrar is PDF; on the NSM most AFRs
  are PDF/xHTML and `discover` currently returns *empty* for them. PDF is what makes the UK adapters
  cover the actual population.
- It is the **only path to entire jurisdictions.** **Germany** has no openly retrievable XBRL — German
  annual reports are PDF. No PDF extractor ⇒ no German firms. China/India are the same shape (no open
  XBRL, non-Latin) — the medium-term selling point.
- One extractor, **many consumers:** CH PDFs, NSM PDF + Untagged-xHTML, German filings, SEC PDF exhibits.

---

## 1. Goal & principle — one substrate, several derivations

**Goal.** A `:pdf` `Filing` produces *both* output families EDGAR.jl already has — `Fact`/`FactRow`
**and** the document family `Selection` / `SelectionTable` / `sections` — derived from one shared
**Structured Document**. The `FactRow` derivation goes first and is measured against the dual-format AFR
oracle.

**Principle.** One substrate, several derivations. **Don't overload `FactRow`.** Reuse the existing
document contracts; the only genuinely new type is `figure`.

### Output contract (the invariant that keeps everything downstream working)

The PDF extractor MUST emit the **same `FactRow` row table** (`core/types.jl`) that `facts()` returns for
XBRL. The Format axis changes *how facts are recovered from the bytes*, not the `Fact` model. So a `:pdf`
`Filing` becomes first-class: `facts(f)`, `select_statement`, `markdown`, CSV/DuckDB export, and the
validation oracles all work unchanged.

Consequence — **the concept problem.** XBRL facts carry a taxonomy concept (`us-gaap:Assets`); PDF facts
carry only a **line-item label** ("Total assets", "Bilanzsumme"). So `concept` is synthesized (a
normalized label key) and **`standard_concept` (the W4 standardizer) becomes the real cross-filing
bridge**; the classify engine keys off the label, not a prefix (confirm label-first in Phase 1.4).
**`source_selector` carries `(page, bbox)` for PDF** — the coordinate provenance that lets the Pollis
workbench back-link a fact to its source pixel.

---

## 1a. Document-first design — components, generality, persistence

> **The concrete schemas (StructuredDocument JSON + DuckDB DDL + filesystem layout) are drafted in
> [pdf-repository-schema.md](pdf-repository-schema.md) — review there.** This section is the rationale.

With the parser settled, the design to nail *before* writing extraction code is the **document** model,
not facts. Three questions:

**(a) Which components do we separate and save?** First-class objects (each with **page + bbox**
provenance and reading order):
- **document metadata** — source/jurisdiction, language, company, report type, fiscal year, currency,
  accounting framework (HGB/IFRS/…);
- **section/heading hierarchy** — the outline; the backbone that lets us locate "the balance sheet" / "the
  auditor's report" / "MD&A";
- **text segments (paragraphs)** — narrative prose under each section (feeds RAG, `find_paragraphs`,
  `extract_section`);
- **tables** — split into **statement** tables (BS/IS/CF/equity) vs **descriptive/note** tables; cells +
  caption;
- **figures** — image bytes + caption (the one genuinely new type);
- (captions/footnotes attach to their table/figure/section).
Facts are **not** a component — they are a *derived view* over statement tables, produced later if at all.

**(b) General or jurisdiction-specific?** **General decomposition + persistence; jurisdiction-specific
semantics.** Docling decomposes any report language-agnostically (proven over 6 languages). What varies is
the *interpretation*: statement identification + vocabulary (Bilanz / Balance sheet / 资产负债表), number
locale (decimal-comma, TEUR/Mio./千元), section taxonomy (Lagebericht ↔ MD&A ↔ 管理层讨论与分析),
unlabeled-total detection. Put those in a small **per-jurisdiction profile** keyed off the `FilingSystem`
(which already implies the language) — "generalize the nouns, not the verbs." The DuckDB schema stays
**jurisdiction-agnostic**; jurisdiction is a column that *drives* the profile.

**(c) Persistence — filesystem + DuckDB.** Filesystem under **`~/RegulatoryReports/`** (a fresh repository
built from scratch; the legacy `~/EDGAR-Reports/` test stash is kept untouched and is *not* the repository):
the original PDF at the root, and a per-document `derived/<doc_id>/` folder holding `structured.json` (the
canonical StructuredDocument = system of record), `document.md` (render for reading/RAG), `tables/<id>.csv`,
`figures/<id>.png`. One **repository `.duckdb`** indexes all documents relationally:
- `documents`, `sections` (self-referential tree), `text_blocks`, `tables` (+ `kind`/`statement_type`),
  `table_cells`, `figures` — the document family;
- `facts` — *one more, later* table (the FactRow derivation), not the foundation.
Reuse existing contracts: `sections`/text → `sections`/`Selection(:prose)`; tables → `SelectionTable`;
figures → new `figure` type; facts → `Fact`/`FactRow`.

**DECIDED (2026-06-29):** (a) save **all** of {sections, text, tables, figures}; (b) **general + profile**;
(c) **one repository `.duckdb`** with **normalized `table_cells`**.

**Build order (DECIDED 2026-06-29):**
1. **Document repository** — components persisted (sections/text/tables/figures). **SQL queries and
   full-text search come for free** here (it *is* a DuckDB DB; FTS over `text_blocks`) — an early win, not
   a later phase.
2. **Facts / numbers** — statement tables → `Fact`/`FactRow`, validated against the iXBRL twin oracle.
3. **Semantic RAG/Q&A** — embeddings → vector search → an LLM query agent over prose *and* tables (local
   LLM default, Claude opt-in). The heaviest/fuzziest piece; last.

This **reorders the older phases**: the document family moves *ahead* of facts (was Phase 3 → now first;
FactRow was Phase 1 → now second).

**(d) Language — store the ORIGINAL, translate later (DECIDED).** The canonical store is the **original
language** (Mandarin / Japanese / Russian / German), verbatim — `structured.json` + the DB are the source
of truth, never lossy. **Translation is a separate derived layer**, never done at ingestion. Two distinct
needs:
- **Accounting labels** — (i) *semantic normalization* to a canonical concept (`Bilanzsumme` / `资产总计`
  → concept) via the existing `standardize`/W4 + taxonomy vocabs, extended with multilingual label
  synonyms in the per-jurisdiction profile; (ii) *display translation* via a precomputed dictionary. Both
  **deterministic, no LLM, cheap.**
- **Free text (prose)** — needs an **LLM**, so **deferred**: store original now; add translations later as
  a pass defaulting to the **local LLM**, opt-in to a frontier model (**Claude**) for best quality.
- *Schema:* a `lang` column on `sections`/`text_blocks`, plus a generic
  `translations(object_type, object_id, target_lang, text, source[dict|local-llm|cloud-llm], model,
  created_at)` — so the original always remains and translations layer on top, on demand.

---

## 2. Tiering — resolves the install tension (roadmap goal 4)

PDF financial extraction = **table reconstruction + financial-number semantics**. The library is only
the easier half (positioned glyphs / cells); the **financial-semantics layer is the moat** and is
written in Julia regardless of the base tool. Two deployment targets bind the toolchain: EDGAR.jl must
run **standalone (a plain Julia package)** *and* **embedded in Pollis (a TypeScript/Electron VS Code
fork)**.

- **Tier-2 — the MAIN approach** (heavier install, opt-in). Docling/MinerU + a local LLM: full document +
  far better concept mapping. This is the primary path. Standalone-only (Python via
  `PythonCall`+`CondaPkg`); **absent in Pollis by design**.
- **Tier-1 — the FALLBACK** (light install, the graceful floor). The existing [../../src/extractors/pdf.jl](../../src/extractors/pdf.jl):
  Node + pdf.js, deterministic, **statements-only**. Always available; no Python, no GPU, no model
  downloads. When the document-AI stack is absent, this is what runs. (Empirical history in the Appendix.)

(The "Tier-1 / Tier-2" labels denote install weight, not priority — Tier-2 is the main approach, Tier-1
the fallback.)

**Both tiers emit to the same contracts, so downstream never knows which ran.** Tier-2 reuses Tier-1's
deterministic **number/sign/scale discipline** (`_pdf_num`: parentheses-negative, en-dash-nil, separator
and decimal-comma rules, scale footers) — that logic survives even though Tier-1's geometric *clustering*
is superseded by Docling/MinerU's table structure.

### Install philosophy (cross-cutting)

Tier-1 (light) always available; Tier-2 (heavy local stack) opt-in with **graceful degradation** to
Tier-1; a thin cloud mode stays possible later. The Structured-Document substrate (Phase 0) is the shared
foundation for **both** output families — *not* "optional RAG plumbing": locating statements in a
200-page report needs document structure first.

---

## 3. Tier-2 backend evaluation — Docling vs MinerU (test both, select later)

**Decision: keep BOTH for the Phase-1.3 bake-off; select one after measurement.** Both work well for our
purpose; the choice is empirical.

### Installed versions & environment (pinned)

Both are installed and importing, **pinned**: **`docling==2.107.0`**, **`mineru==3.4.0`** (Python 3.11).
The dev environment is a stable uv venv **outside the repo** at **`~/EDGAR-tools/tier2-venv`** (~1.3 GB),
reproducible from [`src/extractors/pdf/requirements-tier2.txt`](../../src/extractors/pdf/requirements-tier2.txt).
Per **Option A**, the venv is the **sole copy** of the bytes — installed with `--no-cache` and the uv cache
wiped, so the packages live in exactly one place outside `EDGAR.jl` (verified: the venv still imports after
a full cache clean). A reboot or cache wipe is a non-event (re-create from the pins). The eventual
standalone packaging path is `PythonCall`+`CondaPkg` against the same pins; **absent in Pollis by design**.

### Findings (the measurement the earlier draft only promised)

- **Docling works fine** out of the box for born-digital (UK / CH / ESEF / DART). **Only Japanese EDINET
  needed the OCR path** — its text layer is broken/CID-garbled, and Docling's default ("OCR only where
  text is *missing*") misjudges a *garbled-but-present* layer, so `--force-ocr` was required there.
- **MinerU works less well and needs the correct language set.** Its `pipeline` backend routes
  JP/TW/EN/Latin into the `ch` OCR model, so **non-`ch` scripts can silently drop** (Korean/Cyrillic
  vanished, no warning). Its newer `vlm` backend (a 1.2B VLM) is natively multilingual and removes the
  language hint — but needs a GPU.
- **Mitigation that makes both manageable for us specifically:** EDGAR.jl knows the `FilingSystem` of
  every filing → it largely knows the language (EDINET→ja, DART→ko, CH/NSM→en, ESEF→by country), so
  MinerU's `-l` is nearly free. And text-layer garble is **cheaply detectable** (extract the text layer,
  test mojibake / invalid-Unicode ratio; if bad → OCR), so Docling's flag can be chosen automatically.
  So it's not a blocker — it's a **robustness cost**: a small "which path / which language" pre-classifier
  plus a guard against the silent failure.

### Comparison

| Axis | **Docling** (IBM/DS4SD) | **MinerU** (OpenDataLab) |
|---|---|---|
| Architecture | Pipeline: layout + TableFormer; OCR only when invoked | Two backends: `pipeline` (DocLayout-YOLO + UniMERNet + table + PaddleOCR) **or** `vlm` (MinerU2.5, 1.2B VLM) |
| OCR | **Off by default** — text-layer first; OCR is a fallback | Always in the loop (PaddleOCR in `pipeline`; implicit in `vlm`) |
| Default OCR engine | **EasyOCR** (Python, no binary); RapidOCR (ONNX); Tesseract (**external binary**); OcrMac (macOS) | PaddleOCR (PP-OCRv6, ~109 langs), bundled; `vlm` OCRs natively |
| External OCR binary? | **No** on EasyOCR/RapidOCR; yes only if Tesseract chosen | **No** — built in |
| Language hint | Only when OCR fires | `pipeline`: **matters** (silent script-drop); `vlm`: **none needed** |
| GPU | **Not required** (CPU/PyTorch) | `pipeline`: CPU ok, ~4 GB VRAM accel; **`vlm`: GPU (Volta+)/Apple Silicon, ≥8 GB VRAM** |
| Footprint | **Lighter** (~1–2 GB incl. torch; *estimate*) | **Heavier** (docs: **≥20 GB disk**; VLM weights ~2.5 GB fp16) |

*Source pages: Docling installation + OCR-models docs; MinerU GitHub + MinerU2.5-2509-1.2B (HF) + PyPI.
The ~1–2 GB Docling figure is an estimate (its install page states no total); pin exact sizes from the
download manifests during Phase 1.3 if hard numbers are needed.*

**Net:** Docling is the light, CPU-friendly default; MinerU is the heavier, GPU-leaning option whose
`vlm` backend is the multilingual one. Carry both into Phase 1.3 and let cell fidelity + section recovery
decide.

---

## Phases (stepped; 🚦 = hard-stop gate — pause, report, ask)

Status icons: ☐ todo · ▶ doing · ✅ done · ⏸ blocked.

### Phase 0 — The Structured Document substrate (foundation)

Ingestion produces **one** Structured Document; every output family and every persistence target derives
from it (the "one substrate, several derivations" principle, §1):

```
                              PDF Document
                                   │
                    Document Parser: Docling / MinerU      (Tier-2; Tier-1 pdf.js as the fallback)
                                   │
                                   ▼
                          Structured Document
              ┌──────────────────────────────────────────┐
              │ headings hierarchy                         │
              │ paragraphs                                 │
              │ tables                                     │
              │ figures                                    │
              │ captions                                   │
              │ page numbers / reading order               │
              │ extracted document metadata                │
              └─────────────────────┬──────────────────────┘
                                 Persist
              ┌──────────────────────┴──────────────────────┐
              │                                              │
        Filesystem                              DuckDB Repository
   (PDF / JSON / Markdown / CSV)        (metadata · sections · tables ·
              │                            facts · relationships)
              └──────────────────────┬──────────────────────┘
                                     ▼
                       Derivations: FactRow  +  Selection / SelectionTable / sections / figure

  Extracted document metadata
      ├─ source            (FilingSystem / URL)
      ├─ language
      ├─ company
      ├─ report type
      ├─ fiscal year
      └─ additional document metadata
```

- ☐ **0.1 Define the `StructuredDocument` type.** An ordered tree of blocks with `kind ∈
  {heading(level), paragraph, table, figure, caption}`, each carrying **reading order + page + bbox
  provenance**, plus document metadata (source · language · company · report-type · fiscal-year). It's
  the PDF analogue of the rendered DOM the HTML path consumes.
- ☐ **0.2 Map it onto contracts that already exist** (so derivations are cheap):
  - `table` → `SelectionTable` (header+rows) + a `statement?` classification flag,
  - `heading`/`paragraph` → `sections` / `Selection(kind=:prose)`, feeding `extract_section`/`find_paragraphs`,
  - `figure` → **new type** (image bytes + caption + bbox) — the one new contract,
  - statement tables → the `Fact`→`FactRow` path.
- ✅ **0.3 The parser seam — DONE (PythonCall, not subprocess).** Docling is driven **in-process via
  PythonCall** in the `EDGARDoclingExt` package extension (PythonCall is an optional weakdep → core stays
  Python-free for Pollis; points at the existing `~/EDGAR-tools/tier2-venv`, no second env). `EDGAR.
  structured_document(pdf; …)` returns a `StructuredDocument`; `persist_document` writes
  `structured.json` + `document.md` + `tables/*.csv`. Verified on Tesco. (Tier-1 pdf.js remains the
  fallback when PythonCall/Docling absent.)
- ☐ **0.4 Reconcile with Tier-1.** `pdf.jl`'s geometric clustering is superseded by Docling/MinerU, but
  its **number/sign/scale rules** (`_pdf_num`, parentheses-negative, en-dash-nil, scale footers) are
  **reused** as the Tier-2 deterministic discipline layer.
- ☐ **0.5 Persistence design (the committed target).** The Structured Document is the system of record;
  it persists to **two** targets, both derived from it, so re-derivation never re-parses the PDF:
  - **Filesystem** — the human-/tool-facing artefacts: the original **PDF**, the Structured Document as
    **JSON**, **Markdown** (the document family rendered, reusing the existing `markdown` path), and
    **CSV** (the `FactRow` table). The document root is **`~/RegulatoryReports/`** (a fresh repository;
    the legacy `~/EDGAR-Reports/` validation-PDF stash is kept untouched and is *not* the repository);
    naming convention `<CC>-<Company>FR<year>.pdf` (e.g. `UK-TescoFR2024.pdf`, `JP-SonyFR.pdf`). The cache policy
    (`set_cache_policy`) still governs the derived artefacts.
  - **DuckDB Repository** — the queryable store, extending today's facts-only `to_duckdb`/`statement_view`
    into a small relational schema: **`documents`** (one row per filing: the metadata below + provenance),
    **`sections`** (headings/paragraphs, reading order), **`tables`** (descriptive `SelectionTable`s with
    a `statement?` flag), **`facts`** (the `FactRow`s, with `extractor`/`confidence` from Phase 2), and
    **`relationships`** (the foreign keys that tie a fact/section/table back to its `document` + `(page,
    bbox)`). One DB per corpus; this is what Track B (RAG/Q&A) and cross-filing analysis query.
  - **Document metadata** (carried on the Structured Document, stored on `documents`): `source`
    (FilingSystem / URL), `language`, `company`, `report type`, `fiscal year`, + additional fields.
- **Acceptance:** a `StructuredDocument` JSON schema; the parser subprocess producing it for a real
  annual report; confirmed mappings to `SelectionTable` / `sections` / `Fact`; and the DuckDB schema
  (`documents`/`sections`/`tables`/`facts`/`relationships`) defined, with one annual report round-tripped
  filesystem + repository.

### Phase 1 — FactRow derivation: prove local-first on the statements (THE GATE)

- ☐ **1.0 Thin vertical slice.** One filer, balance sheet, EN, born-digital, dual-format — the whole
  loop: parser → `StructuredDocument` → locate the statement table via headings → local-model
  concept-map → `Fact` → `FactRow` → oracle → accuracy %.
- ☐ **1.1 Dual-format gold set.** Filers with both a tagged instance and a PDF for one period — UK NSM /
  ESEF (EN), EDINET (JA), DART (KO); ~8–12 filings; XBRL `FactRow`s = ground truth, stored as fixtures.
- ☐ **1.2 Oracle harness** (`src/sources/pdf_oracle.jl`). Same DIY pattern as `arelle_local`/`yahoo`.
  **Value-anchored matching** (sidesteps "PDF label ≠ concept"): per ground-truth fact, did extraction
  recover that value in the right statement + period? → recall; of emitted rows, how many hit a real
  value? → precision. Reports per statement: value-match, sign, scale, period error rates.
- ☐ **1.3 Parser bake-off — Docling vs MinerU** (§3). Judged on **both** jobs the substrate serves:
  statement-table **cell fidelity** *and* **heading/section recovery** (locating statements depends on
  it). Test both, then select one (or keep both behind the seam if neither dominates).
- ☐ **1.4 Statement classifier + table→FactRow mapper.** On the structured doc: (a) classify which
  tables are BS/IS/CF/SCE vs descriptive (**descriptive tables stay `SelectionTable`s, never
  `FactRow`s**); (b) local model maps rows→concepts; (c) **deterministic rules fix sign/scale/period/
  statement** (Tier-1's logic reused). *Local proposes, rules discipline.* Confirm classify works
  **label-first**.
- ☐ **1.5 Measure local vs frontier ceiling** — accuracy table per statement × language ×
  born-digital/scanned.
- ☐ **1.6 🚦 Green-light gate** — is local-first usable now, and where does it fail? Gates Phase 2.
- **Acceptance:** a committed accuracy table + a written green-light decision with the failure map.

### Phase 2 — Productionize the FactRow track (lighter)

- ☐ Wrap behind the Phase-0 seam; subprocess-host management + Tier-1 fallback; add **extractor/
  confidence fields** (the `facts` table + exports gain these columns); **confidence-gated emission** ("a
  wrong number is worse than none"); populate the Phase-0.5 persistence targets (filesystem artefacts +
  the DuckDB repository) via the per-system cache policy; the oracle becomes a standing fixture test.

### Phase 3 — The second family: sections, descriptive tables, figures (sketch)

- ☐ Populate `Selection` / `SelectionTable` / `sections` for PDFs from the **same** `StructuredDocument`,
  so `find_paragraphs` / `extract_section` / Markdown export work on PDFs; add the `figure` type. The
  "annual report as a document" capability — narrative, descriptive tables, images become first-class,
  reusing the substrate Phase 0 built.

### Phase 4 — Track B + new jurisdictions (sketch)

- ☐ Track B (RAG/Q&A) builds on Phase 3's records: chunking → BGE-M3 → LanceDB → the query agent (local
  models via `llama.cpp`, Claude Code as the complex-case escape hatch). **China/India** ride the whole
  stack — the FactRow track for statements, the document family for narrative.

---

## Validation — the beachhead makes PDF uniquely testable *now*

PDF normally has no ground truth. The CH/NSM work created one: **dual-format AFRs** — the *same* annual
report as **both a PDF and an iXBRL package** (Tesco verified on the NSM; CH metadata offers both;
CH-PDF ↔ NSM-iXBRL cross-source pairs exist; ESEF via filings.xbrl.org; EDINET CSV).

1. **Twin oracle (primary):** parse the iXBRL twin → exact ground-truth facts → diff the PDF extractor's
   output (value-anchored, §1.2). The labeled test set that exists *because* of the NSM/CH work.
2. **Cross-footing (always-on):** Assets = Liabilities + Equity; subtotals foot; period columns
   internally consistent. Cheap arithmetic guard that also catches LLM hallucination.
3. **Totals oracle (no-twin, incl. Germany):** Yahoo / AlphaVantage headline totals.

---

## Open questions / risks

- **Label→concept bridge** — does classify work from labels alone across UK FRS, IFRS, German GAAP, JP/KR
  wording? Confirm in 1.4; may need a label-vocabulary akin to the taxonomy vocabs.
- **Tier-2 install weight & GPU** — MinerU's `vlm` needs a GPU; standalone-only. Graceful degradation to
  Tier-1 must be real, not theoretical.
- **Confidence-gated emission** — never silently accept; a wrong number is worse than none.
- **Twin-oracle quality varies by filer** (Diageo's came out implausible) — curate the gold set.

---

## Appendix — Tier-1 empirical history (pdf.js path, 2026-06)

Tier-1 is **built and proven**; this records the work so it isn't re-litigated.

**P0 bake-off — RESOLVED: `pdfjs-dist` directly (no wrapper).** On keyless NSM twins, direct pdf.js
(~15 lines: `getTextContent()` + a `dommatrix` polyfill + our own clustering) **tied the wrappers on
accuracy, ran faster, and removed a dependency**, with the best provenance (mozilla/pdf.js 53k★, our pin
**6.0.227**). Wrappers (`pdf.js-extract`, `pdfreader`, `pdfexcavator`) not adopted; kept only in
`tools/pdf-bakeoff/` for the multi-jurisdiction sweep. Ruled out: pdfplumber (Python+Conda), Poppler/
MuPDF/Ghostscript (GPL/AGPL), PDFIO.jl (stale), pdf-parse (native `@napi-rs/canvas`). Harness pinned
`pdfjs-dist ^6`; lockfile committed, `node_modules` gitignored.

**P1 prototype — DONE.** `tools/pdf-bakeoff/pdf_words.mjs` (pdfjs-dist → positioned words JSON, top-down
y) + `cluster.jl` (rows by y-bin; period columns by numeric right-edge bands; parentheses/en-dash
semantics; each cell coordinate-anchored). On Tesco's Group balance sheet it reconstructs the **whole
statement**, and `Equity attributable to owners` = **11,671 / 12,236** — an *exact* match to the iXBRL
twin. Graduated into `src/extractors/pdf.jl` (`extract_pdf`, coordinate provenance in `source_selector`).
**Finding:** geometry is robust but **column *meaning* is statement-specific** (the BS's columns are
periods; the income statement's are a before-exceptional/exceptional/total split) — the layout-fragility
that demotes geometric clustering to the Tier-1 floor and motivates Tier-2.

**Runtime facts.** Dev shell: nvm node v25 + npm 11.x; `package-lock.json` v3. npm is build-time only;
runtime is Electron's bundled Node (Pollis) or `NodeJS_jll` (standalone) — three contexts. All candidates
resolve to **pure-JS** deps (no native ABI) → portable across all three. `engines: node>=20`.
