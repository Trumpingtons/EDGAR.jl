# Plan — a PDF extractor for EDGAR.jl ("CH II", and the Format/extraction axis)

Status: **draft / living document** (expect iteration). This is the plan the Companies House plan
([companies-house-plan.md](companies-house-plan.md)) deferred as **"CH II"** — the second extractor on
the **Format / extraction** axis. It follows the same governing principle:

> **Generalize the nouns, not the verbs.** The `Filing.kind == :pdf` outcome already exists as a typed,
> non-fatal result; this plan makes that outcome *parseable*. PDF is a new **extractor**, not a new
> system — it slots beside `extract_xbrl.jl` on the third axis (FilingSystem × Taxonomy × **Format**).

### Why this is the highest-leverage next feature

- It **unblocks work already built.** CH and the NSM source are done but cover only the machine-readable
  minority of real filings: at CH the format is unpredictable and much of the registrar is PDF; on the
  NSM most AFRs are PDF/xHTML and `discover` currently returns *empty* for them. PDF is what makes the UK
  adapters cover the actual population.
- It is the **only path to entire jurisdictions.** **Germany** has no openly retrievable XBRL
  (absent from filings.xbrl.org; Bundesanzeiger OAM XBRL not open) — German annual reports are PDF. No
  PDF extractor ⇒ no German firms (beyond a few Yahoo/AlphaVantage totals).
- One extractor, **many consumers:** CH PDFs, NSM PDF + Untagged-xHTML, German filings, and SEC PDF
  exhibits all reuse it.

### Output contract (the invariant that keeps everything downstream working)

The PDF extractor MUST emit the **same `FactRow` row table** (`core/types.jl`) that `facts()` returns
for XBRL. The Format axis changes *how facts are recovered from the bytes*, not the `Fact` model. So a
`:pdf` `Filing` becomes a first-class citizen: `facts(f)`, `select_statement`, `markdown`, the CSV/
DuckDB export, and the validation oracles all work unchanged.

Consequence — **the concept problem.** XBRL facts carry a taxonomy concept (`us-gaap:Assets`); PDF facts
carry only a **line-item label** ("Total assets", "Bilanzsumme"). So:
- `concept` is synthesized (e.g. a normalized label key), and **`standard_concept` (the W4 standardizer)
  becomes the real cross-filing bridge** — classification/comparison key off the label, not a prefix.
- The classify engine already has label/role-name patterns; PDF leans on those rather than concept
  prefixes. This is the one place the extractor touches shared code — confirm the classify path works
  label-first before scaling.

---

## 1. Architecture — a tiered extractor, deterministic-first

PDF financial extraction = **table reconstruction + financial-number semantics**. The library is only
the easier half (positioned glyphs); the **financial-semantics layer is the moat** and is written in
Julia regardless of base library.

- **Tier 1 — deterministic core (the bulk).** Born-digital text-layer → words-with-bboxes → cluster into
  line-item rows × period columns → parse numbers. Handles modern annual-report PDFs. No ML, explainable,
  reproducible, offline.
- **Tier 2 — OCR fallback (scanned / older).** Rasterize + OCR, then the same reconstruction. Gated and
  flagged lower-confidence (a misread digit is a wrong number).
- **Tier 3 — optional LLM assist (opt-in, never the deterministic core).** For layouts Tier 1 can't
  reconstruct and for messy multilingual narrative. **Always routed through arithmetic validation** (see
  §4); off by default so the library stays deterministic, offline-capable and free-to-run.

### The moat: the financial-semantics layer (Julia)

Generic table extractors give cells, not financial meaning. This layer must handle:
- **Number locale** — parentheses = negative; thousands separators; **decimal-comma** and German
  thousands-dot (**reuse the existing decimal-comma logic** from the XBRL extractor); currency glyphs.
- **Scale footers** — "in £m", "in € thousands", **"in TEUR" / "in Tausend Euro" / "in Mio. EUR"** —
  multiply line items accordingly.
- **Structure** — multi-period columns (year headers), indented hierarchy/subtotals, wrapped row labels,
  footnote superscripts, mixed €/£/$.
- **Statement identification** — locate Balance sheet / Income statement / Cash flow (multi-language:
  Bilanz, Gewinn- und Verlustrechnung, Aktiva/Passiva, Kapitalflussrechnung) and tag `statement`.

## 2. Toolchain decision — base library

Two binding constraints: **non-GPL license**, and **minimal fragile dependency** — in particular **no
Python/Conda** (and no JVM).

**Decision: a single Node/TypeScript toolchain**, driven via a Node subprocess that emits JSON; Julia
reads the JSON and does all financial logic. Three layers:

1. **Parse + table reconstruction** — **one** pdf.js-based candidate, **chosen by the P0 bake-off** (see
   the candidates below). Whichever wins bundles pdf.js, so it *is* the parse layer — we do **not** wire a
   separate `pdfjs-dist`.
2. **OCR (Tier 2)** — **`tesseract.js`** (Apache-2.0), same Node runtime.
3. **LLM (Tier 3, optional)** — opt-in, arithmetic-validated assist for layouts the chosen tool can't
   reconstruct.

No Python, no Conda, no JVM, no GPL/AGPL anywhere.

**Tiers 2–3 are *mostly* independent — and the LLM interaction is deliberately kept OUT of the P0
decision unless it has to break a tie.** OCR (`tesseract.js`) is genuinely independent (preprocessing).
The LLM (Tier 3) is *mostly* independent, but the combined ranking is not only non-additive — **it is
LLM-dependent**: a specialist that is worse standalone (A < B) can win combined with one model
(A+LLM\_X > B+LLM\_X) yet lose with another (B+LLM\_Y > A+LLM\_Y). A fully-combined bake-off is therefore
combinatorial (specialists × LLMs) *and* unstable as models change.

**Decision policy:** compare the specialists **standalone** in P0; **if there is a clear winner, take
it** — the LLM never enters the choice. **Only if the standalone result is ambiguous** do we run a
combined specialist + LLM tiebreak, pinning the specific model and treating the outcome as an
LLM-specific heuristic (it may not generalise to other models). We still measure **failure mode**
(clean-fail vs confidently-wrong) standalone, because it is an **LLM-independent proxy** for how well a
specialist composes with *any* fallback — a clean-failing specialist is preferable without having to test
every LLM, since clean misses are recoverable by Tier 3 whereas confidently-wrong ones poison the data and
never trigger it.
So P0 measures failure *mode*, not just accuracy, and estimates **combined** performance for the
front-runners (P0.5, P0.7) — it does not pick the winner on standalone accuracy alone.

### The table-specialist candidates (P0 competition)

All three are pdf.js-based, MIT, pure Node — but their pdf.js *provenance* differs sharply, which matters
since "pdf.js is the most robust parser" only holds if it's the **full, current upstream** pdf.js
(verified from the npm tarballs, 2026-06; current upstream `pdfjs-dist` = **6.0.227**):

| Candidate | Role | pdf.js it ships | License · adoption | Strength / risk |
|---|---|---|---|---|
| **pdfexcavator** | Generic table finder ("JS pdfplumber"); **borderless** | **official `pdfjs-dist ^4.7.76`** — full, but the 4.x line (~2 majors behind) | MIT · v0.1.2 · ~620/wk | best table fit; but **immature package** (bus-factor risk à la PDFIO.jl) + lagging pdf.js |
| **pdfreader** (→ pdf2json 3.1.4) | Column detection + rule-based | **a modified *fork* of pdf.js** — divergent, version not cleanly exposed, **does not track upstream** | MIT · v3.0.8 · ~90k/wk | mature *package*, but **forked parser = weakest provenance** (no upstream fixes) |
| **pdf.js-extract** | Glyphs + x/y coords **only** | **full vendored pdf.js 5.5.207** — freshest (~1 major behind) | MIT · v1.0.1 · ~148k/wk | **best parser provenance + highest adoption**; but **not a table-finder** → represents the *build-our-own-clustering* baseline (most work for us) |

**Provenance takeaway:** on parser quality the order is **pdf.js-extract (fresh full) > pdfexcavator
(official full, lagging) > pdfreader (fork)**. So the *build-our-own-clustering* baseline rides the best
parser, and pdfreader's package-maturity is offset by its forked pdf.js. Net: it's really
**"adopt pdfexcavator's table finder" vs "build clustering on pdf.js-extract's fresher full parser"** —
which is exactly what P0 measures.

Ruled out (not in the bake-off): **pdfplumber** (Python + Conda; less robust parser than pdf.js);
**Poppler / MuPDF / Ghostscript-lattice** (GPL/AGPL); **PDFIO.jl** (pure-Julia but core untouched ~7
years); **pdf-parse** (huge adoption but pulls a native `@napi-rs/canvas` binary and its table support is
the least proven for our case) — keep as a distant backup only.

Rationale for the toolchain shape:
- **License:** MIT/Apache throughout; no GPL/AGPL.
- **Boundary:** subprocess + JSON is **more decoupled than in-process FFI**, and one runtime covers
  parse + table + OCR — no Python/Conda env to manage.
- **Host fit:** EDGAR.jl is being embedded in **Pollis** (a TypeScript-based VS Code fork), so a Node/TS
  toolchain is **native to the host**. (Stand-alone Julia use vendors it via `NodeJS_jll` + the pinned JS
  bundle.) Project precedent for shipping JS already exists (the browser picker, `PICKER_JS`).

**Whichever candidate wins, the financial-semantics layer (§1) is still ours** — a table finder gives
cells, not financial meaning. When the chosen tool struggles on a layout, escalation stays inside the
toolchain: improve our own clustering, or hand that filing to Tier 3 (LLM). We do **not** add a
Python/Conda parser as a fallback.

## 3. Where it plugs into the existing seam

- `fetch_filing` already returns `Filing(:pdf, …)` with the content/URL retained — **no discovery
  change.** This plan adds an extractor that consumes such a `Filing`.
- Mirror the XBRL forwarder: a generic `_extract_pdf(f::Filing)` (analogous to `extract_xbrl.jl`) that
  produces `Fact`s → the existing `facts()` assembly → `FactRow`. `facts(f)` dispatches on
  `f.kind` (`:ixbrl`/`:xbrl` → XBRL extractor; `:pdf` → PDF extractor).
- The Node helper lives under (proposed) `src/extractors/pdf/` with its pinned JS bundle; the Julia side
  is `src/extractors/pdf.jl` (subprocess driver + financial-semantics layer). Naming TBD in P1.

## 4. Validation — the beachhead makes PDF uniquely testable *now*

PDF normally has no ground truth. The recent CH/NSM work created one: **dual-format AFRs** — the *same*
annual report as **both a PDF and an iXBRL package** (verified for Tesco on the NSM; CH metadata offers
both; CH-PDF ↔ NSM-iXBRL cross-source pairs also exist). So:

1. **Twin oracle (primary):** parse the iXBRL twin → exact ground-truth facts → diff the PDF extractor's
   output against them. This is a labeled test set that exists *because* of the NSM/CH work — use it
   while fresh. Gates Tiers 1–3.
2. **Cross-footing (always-on):** Assets = Liabilities + Equity; subtotals foot; period columns
   internally consistent. Cheap arithmetic guard that also catches Tier-3 (LLM) hallucination.
3. **Totals oracle (no-twin case, incl. Germany):** Yahoo / AlphaVantage headline totals (the existing
   oracles) for filers with no XBRL twin.

## 5. Scope boundaries (CH II, v1)

- **In:** born-digital PDF **financial statements** (BS/IS/CF) → `FactRow`. Tier 1 + semantics + twin
  validation. UK first (dual-format), then German.
- **Later:** scanned PDFs (Tier 2 OCR); narrative/section text (MD&A-equivalent) → the prose/text layer,
  not facts; the optional LLM tier.
- **Out (separate concerns):** non-financial SEC PDF exhibits; image/figure extraction.

---

## Phases (stepped; 🚦 = hard-stop gate — pause, report, ask)

Status icons: ☐ todo · ▶ doing · ✅ done · ⏸ blocked.

### P0 — Table-specialist bake-off (the competition)  🚦 (dependency choice)

**Goal:** pick ONE Tier-1 specialist by measuring **pdfexcavator** (borderless table finder), **pdfreader**
(column detection), and **pdf.js-extract + our clustering** (build-our-own baseline) on a *large,
stratified, multi-jurisdiction, multi-form* PDF corpus against ground truth. OCR and LLM are out of scope
here (§2). The labelled corpus this phase builds is **reused by P3** (the end-to-end twin harness), so the
effort isn't throwaway.

- ☐ **P0.1 Define the corpus & strata.** Target **~200 born-digital PDFs**, stratified so the result
  generalises rather than overfitting one layout:
  - **Jurisdiction:** UK Companies House (~60), UK NSM PDF AFRs (~50), **Germany / Bundesanzeiger** (~50),
    US SEC PDF exhibits + misc (~20). (Germany is the highest-value unlock — no XBRL exists for it.)
  - **Form / layout type:** full IFRS statements; UK FRS-102 full; FRS-105 micro-entity & **filleted /
    balance-sheet-only**; dormant; multi-period (2–5 cols); **borderless vs ruled**; multi-currency;
    German HGB; English vs German language; 1-page vs long.
  - **Ground-truth tier per PDF:** **A** = dual-format twin (PDF + iXBRL ⇒ exact facts), **B** = no twin,
    hand-labelled, **C** = no twin, totals-only oracle (Yahoo/AlphaVantage, where the filer is listed).
  - **Flag scanned PDFs separately** — they belong to the OCR tier and are *excluded* from this comparison,
    but record the scanned fraction (it sizes Tier-2 priority later).
  - *Deliverable:* `test/data/pdf/manifest.csv` — one row per PDF: id, jurisdiction, form/layout type,
    source, language, born-digital|scanned, ground-truth tier, twin LEI/accession (if A).

- ☐ **P0.2 Assemble & store the corpus.** Fetch raw PDFs (CH Document API, NSM artefacts, Bundesanzeiger,
  SEC) into `test/data/pdf/raw/` (gitignored; note keyless vs keyed sources). For every **tier-A** PDF
  also fetch its iXBRL twin.

- ☐ **P0.3 Build the ground-truth store.** Tier A: run EDGAR's existing XBRL extractor on each twin →
  canonical expected facts (label/concept, period, value, sign, scale) for the three statements. Tier B:
  hand-label the 3 statements for the no-twin subset (start with headline lines, extend if cheap). Tier C:
  capture Yahoo/AlphaVantage headline totals. *Deliverable:* `test/data/pdf/truth/<id>.json` per PDF.

- ☐ **P0.4 Build the common harness.** One **Node CLI per candidate** (`pdf → JSON`) emitting that
  candidate's native output (pdfexcavator: tables; pdfreader: rows/columns; pdf.js-extract: words+bboxes).
  A **shared Julia adapter** normalises each into one *extracted-table* structure (rows × columns of cells
  with text+bbox); for pdf.js-extract this step includes *our own clustering* (that's the baseline's
  "finder"). Then a **single, shared, minimal financial-semantics pass** (number parse incl.
  parentheses/decimal-comma/scale, period-column mapping) turns the table into facts. **Hold the semantics
  layer identical across candidates** so the bake-off measures the *table the candidate produced*, not our
  parsing. Same pinned pdf.js per candidate; record the resolved version.

- ☐ **P0.5 Define metrics & scorecard shape.** Per candidate, aggregated over the corpus **and sliced by
  jurisdiction × form type**:
  - *Parse-success rate* (PDF opened, text layer present).
  - *Statement-table detection rate* (found the BS/IS/CF region at all).
  - *Cell/number accuracy vs ground truth* — precision/recall on (line-item × period) → value within
    tolerance; the headline metric. (Tier A exact; B manual; C totals-only.)
  - *Label-capture accuracy* and *structural correctness* (# periods/columns, row alignment).
  - *Borderless-vs-ruled* breakdown (decisive for financial statements, which are mostly borderless).
  - **Failure *mode* (first-class, not just rate)** — classify every miss as **clean-fail** (empty / flagged
    low-confidence ⇒ the LLM fallback can recover it) vs **confidently-wrong** (plausible-but-wrong table ⇒
    the fallback never fires and the data is poisoned). This is what makes the LLM tier *mostly* — not
    fully — independent (§2): a candidate that fails clean composes far better with Tier 3, so weight
    confidently-wrong heavily and track it per candidate.
  - *Robustness* — crash/empty rate; wall-time per page.
  - *Static axes* (not per-PDF): **pdf.js provenance** (pdf.js-extract full+fresh > pdfexcavator full+lagging
    > pdfreader fork), **package maturity/adoption**, license (all MIT — neutral).

- ☐ **P0.6 Run the bake-off.** Execute all three across the full corpus; emit the scorecard
  (candidate × metric, with the jurisdiction/form slices) as `docs/dev/pdf-bakeoff-results.md`.

- ☐ **P0.7 Decide — standalone first.** Rank the candidates on the **standalone, LLM-independent** metrics:
  accuracy on borderless financial tables × **failure-mode safety** (clean-fail ≫ confidently-wrong) ×
  pdf.js provenance × package maturity. Then:
  - **If a clear winner emerges → choose it.** The LLM does not enter the decision. Adopt a generic finder
    (pdfexcavator/pdfreader) over the build-our-own baseline only if it wins by a margin that justifies its
    dependency + provenance trade-off.
  - **Only if the result is ambiguous (no clear winner) → run a combined tiebreak:** for the front-runners,
    run the Tier-3 LLM over their residual misses and recompute combined accuracy — but **pin the specific
    LLM** and treat the outcome as an LLM-specific heuristic (the combined ranking can flip with a different
    model, §2), not a stable truth.
  - Catalogue what each handles/misses (German HGB, filleted balance sheets, 5-column tables) — that list
    seeds Tier-3 scope regardless of which specialist wins.

- ☐ **P0.8 🚦 GATE:** recommend the winner; **pin the resolved bundled pdf.js version** and confirm it is
  full + reasonably current (not a stale fork); lock the Node/Pollis runtime story (`NodeJS_jll` + pinned
  bundle). Report the scorecard + recommendation; commit the corpus manifest, harness, and results.

### P1 — Tier-1 scaffold: PDF → words → cells (one filing)
- ☐ P1.1 Node helper: PDF path → JSON (page → text items with x/y/w/h/font). Pin the JS bundle.
- ☐ P1.2 Julia subprocess driver + JSON ingest; `Filing(:pdf)` → positioned words.
- ☐ P1.3 Geometric reconstruction: cluster words → rows × columns for ONE clean dual-format UK BS.
- ☐ P1.4 🚦 **GATE:** show the reconstructed Balance-sheet grid for one filer; agree the row/column model.

### P2 — Financial-semantics layer (the moat)
- ☐ P2.1 Number parser: parentheses-negative, separators, **decimal-comma (reuse existing)**, currency.
- ☐ P2.2 Scale-footer detection (£m / €k / **TEUR / Tausend / Mio.**); period-column headers; hierarchy.
- ☐ P2.3 Statement identification (BS/IS/CF), multi-language headings; emit `Fact`s → `FactRow`.
- ☐ P2.4 Wire `facts(f)` dispatch on `f.kind == :pdf`; confirm classify works **label-first** (see §Output
  contract — the concept problem).
- ☐ P2.5 🚦 **GATE:** `facts(pdf)` for one UK filer round-trips into `select_statement`.

### P3 — Twin-validation harness  🚦 (checkpoint)
- ☐ P3.1 Promote the P0 ground-truth store into the end-to-end oracle: for a dual-format filer, diff the
  full PDF-extractor output vs the iXBRL twin's facts (within tolerance); plus always-on cross-footing.
- ☐ P3.2 Run across the P0 corpus (tier A); tune Tier 1 + the full semantics layer to the twin.
- ☐ P3.3 🚦 **GATE (run tests + commit):** report twin-parity numbers; commit Tier-1 + semantics + harness.

### P4 — German (no twin) + breadth
- ☐ P4.1 German Bundesanzeiger PDFs through Tier 1 + locale semantics; validate vs Yahoo/AlphaVantage
  totals (no XBRL twin).
- ☐ P4.2 Manual chapter: a German PDF workflow + a CH/NSM PDF workflow.
- ☐ P4.3 🚦 **GATE:** decide whether to start **Tier 2 (OCR, tesseract.js)** and/or the optional **Tier 3
  (LLM, arithmetic-validated)** — separate sub-plans.

---

## Open questions / risks
- **Tier-1 fidelity on messy layouts** — multi-column, merged cells, wrapped labels. The twin oracle
  bounds this empirically; P3 decides how far Tier 1 reaches before Tier 3 is needed.
- **Label→concept bridge** — does the classify engine classify reliably from labels alone across UK FRS,
  IFRS and German GAAP wording? Confirm in P2.4; may need a label-vocabulary akin to the taxonomy vocabs.
- **OCR numeric reliability** (Tier 2) — defer; flag confidence; never silently accept.
- **LLM determinism/cost** (Tier 3) — opt-in only, arithmetic-gated, never the default source.
