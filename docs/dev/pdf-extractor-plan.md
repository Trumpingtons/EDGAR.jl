# Plan — PDF extractor ("CH II", the Format/extraction axis)

Status: **living reference** (rewritten 2026-06-30 as the consolidated, status-tracking plan; supersedes
the earlier draft, whose durable decisions are condensed into the Appendix). This is the second extractor
on the **Format / extraction** axis (FilingSystem × Taxonomy × **Format**) — the "CH II" deferred by
[companies-house-plan.md](companies-house-plan.md). A `:pdf` Filing is parsed into one shared
**StructuredDocument**, from which every output family derives.

> **Generalize the nouns, not the verbs.** PDF is a new **extractor**, not a new FilingSystem — it slots
> beside `extract_xbrl.jl`. One substrate, several derivations; don't overload `FactRow`.

### Why this is the highest-leverage feature
- **Unblocks work already built** — CH (format unpredictable, mostly PDF) and the NSM source (most AFRs are
  PDF/xHTML; `discover` returns empty for them today).
- **The only path to whole jurisdictions** — Germany has no openly retrievable XBRL (reports are PDF);
  China/India are the same shape (no open XBRL, non-Latin) = the medium-term selling point.

---

## Two axes (read this first)

The plan is decomposed two ways; both are valid and they are **not** the same numbering:

- **Phase axis (0–4)** — the *design* decomposition. Phase 0 substrate · Phase 1 FactRow (THE GATE) ·
  Phase 2 productionize · Phase 3 second family · Phase 4 Track B.
- **Build-order axis (1–3)** — the *execution* reorder (decided 2026-06-29): **(1) document repository →
  (2) facts → (3) RAG/Q&A**. This deliberately moves the document family *ahead* of facts (Phase 0 +
  document side first; Phase 1 FactRow second).

There is **no third "Step" level** — only **Phase N** and **sub-step N.M**. "Step 1/2/3" refers to the
build-order axis only.

**Where we are now: build-order step 2 / Phase 1.4** (table→FactRow mapper built; oracle not yet).

Legend: **✅ implemented** · **▶ in progress** · **⏸ deferred** (in scope, consciously pushed to a later
step) · **☐ to-do** · **⚠️ deviation from the original plan**.

---

## Phase 0 — StructuredDocument substrate  *(build-order step 1)*

One ingestion → one StructuredDocument (ordered block tree: heading/paragraph/table/figure + reading-order
+ page/bbox + metadata) → persisted to **two** targets (filesystem + DuckDB repo).

| # | Item | Status | Notes |
|---|------|--------|-------|
| 0.1 | Define `StructuredDocument` type | ✅ | `src/extractors/structured_document.jl` — BBox/DocSection/TextBlock/TableCell/DocTable/DocFigure/DocMeta |
| 0.2 | Map onto existing contracts (table→SelectionTable+`statement?`; heading/para→sections; **figure=new type**) | ✅ types + persistence; ⏸ live derivation | DocFigure + `figures` table + image bytes done. **Live `Selection`/`SelectionTable`/`find_paragraphs` derivation from the repo deferred to Phase 3.** |
| 0.3 | Parser seam — Docling via **PythonCall** weakdep ext | ✅ | `ext/EDGARDoclingExt.jl`; `structured_document(pdf)` / `persist_document`; verified on Tesco. Core stays Python-free for Pollis. |
| 0.4 | Reconcile with Tier-1 (`pdf.jl`) number/sign/scale rules | ⚠️ superseded | Wrote a **new** locale-aware `parse_amount` (`facts_derive.jl`) instead of reusing `_pdf_num`. Sign ✅. ⏸ **scale footers (TEUR/Mio/百万) not ported.** |
| 0.5 | Persistence: filesystem (PDF/JSON/MD/CSV) + DuckDB repo + referencing views | ✅ schema + loader; ⏸ CSV | `to_repository`; schema `documents`/`sections`/`text_blocks`/`tables`/`table_cells`/`figures`/`translations`/`facts`; views `v_cell_context`/`v_section_path`/`v_fact_provenance`. ⚠️ `relationships` realized as **FK + views**, not a table. ⏸ **FactRow CSV artefact not written yet.** Repo DB: `~/RegulatoryReports/regulatory-reports.duckdb`. |

**Acceptance (met):** StructuredDocument JSON schema; parser produces it for a real annual report;
mappings confirmed; DuckDB schema defined; Tesco round-tripped filesystem + repository.

---

## Phase 1 — FactRow derivation: prove local-first on the statements (THE GATE)  *(build-order step 2 — current)*

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1.0 | Thin vertical slice (one filer, BS, EN, full loop → accuracy %) | ☐ | Never run as a formal end-to-end slice (pieces exist). |
| 1.1 | Dual-format gold set (tagged instance + PDF; NSM/ESEF EN, EDINET JA, DART KO; ~8–12 fixtures) | ☐ | **Not started.** Feeds 1.2. |
| 1.2 | **Oracle harness `src/sources/pdf_oracle.jl`** — value-anchored recall/precision vs iXBRL twin | ☐ | **Not started. The current blocker** — 1.4c has no measuring stick without it. |
| 1.3 | Parser bake-off Docling vs MinerU (cell fidelity + heading recovery) | ⏸ partial | Docling validated EN/CN×3/KR/RU/DE×2; **MinerU head-to-head deferred**; Docling chosen provisionally. |
| 1.4a | Classify tables BS/IS/CF/SCE vs descriptive | ✅ | `classify_tables!` + `TABLE_CLASSES` (`document_profile.jl`). Descriptive tables stay SelectionTables. |
| 1.4b | Local model maps **rows → concepts** (`standard_concept` bridge, label-first) | ⏸ | **Deferred.** Labels stored verbatim; concept/standardize not wired; translation is a later derived layer. |
| 1.4c | Deterministic rules fix **sign / scale / period / statement** | ✅ built & validated (EN/FR/DE/IT/CN/JP/KR/IN/RU) | `parse_amount` + `infer_columns` + `parse_period_end`/`period_dates` (`facts_derive.jl`) + `derive_facts!` (`EDGARDuckDBExt.jl`). Sign ✅, statement ✅. **Period ✅, honest model** — dates parsed from the column header (multilingual D/M/Y locale-aware, **CJK 年月日 / 년월일**, Russian months); a range gives both ends via **min/max** (OCR-scramble-proof); **colspan-expanded** headers recover dates hidden by a spanning cell (Tesco BS); same-year propagation within a doc; **NO fabrication** — year-only columns keep `fiscal_year` + `period_precision='year'` with `period_end` NULL (new cols). A **column-level pass** reassigns dates to columns by monotonic display order when a header cell is mangled, and **warns on a genuine date reversal** — this caught notes columns (`附注`/`주석`/`Примечание`) misclassified as periods (now excluded; removed ~111 spurious note-number facts). The warn is **panel-aware**: a tiling of a repeated monotonic block (account-form/two-sided BS `…,2025,2024,…,2025,2024`) is accepted, not flagged. `force_ocr` (Japan auto) in the Docling ext. ⏸ **scale still deferred.** ⏸ KR `당기/전기` relative-period labels (date stated once, not per-column) deferred. |
| 1.5 | Measure local vs frontier ceiling (accuracy per statement × language × digital/scanned) | ☐ | Not started. |
| 1.6 | 🚦 Green-light gate — is local-first usable? failure map. Gates Phase 2. | ☐ | Not started. |

**Acceptance:** a committed accuracy table + a written green-light decision with the failure map.

---

## Phase 2 — Productionize the FactRow track  *(lighter)*
☐ All to-do. Subprocess-host mgmt + Tier-1 fallback; populate `extractor`/`confidence` (columns exist);
policy "a wrong number is worse than none" (clean-fail over confidently-wrong); write the Phase-0.5
filesystem artefacts (incl. the deferred FactRow CSV).

## Phase 2R — Robustness hardening: "PDF facts weak & inconsistent"  *(evidence-driven; the core soft spot)*

Motivating evidence (2026-07, Generic "ABC" runs — the unmodified path on **born-digital** English/Portuguese
IFRS annual reports). Same code, three different failure stages:

| Filer | Lang | Result | Broke at |
|---|---|---|---|
| Wesfarmers (AU) | en | **0 facts** | **Location** — `_IFRS_STMT_TITLES`/anchors require `"consolidated"` (en/de); bare *"Income statement"/"Balance sheet"* match nothing |
| Vale (BR) | pt | **error "no consolidated statements found"** | **Location** — anchors are en/de only; Portuguese matches none (also: an *integrated* report may lack detailed statements) |
| Loblaw (CA) | en | **16, balance sheet only** | **Table→facts** — located OK, but IS/CF tables did not map |

Root causes, ranked by leverage: **(1) statement location over-fit** to `"consolidated"` + en/de wording
(gates *everything*); (2) **table→facts fragile per layout**; (3) **line-item classification
en-`ifrs-full`-label-only**; (4) **document scope** (integrated vs statements).

| # | Item | Status | Notes |
|---|------|--------|-------|
| 2R.A | **Measurement harness** — fixtures of born-digital IFRS PDFs across languages (the 3 above + more per lang); a per-stage diagnostic (located? tables? rows classified? facts? Σ reconciles to stated total?) → a scorecard | ✅ | `src/sources/pdf_scorecard.jl` (load-on-demand, mirrors `pdf_oracle.jl`). Stages: parsed→located→tables→facts→BS cross-foot. Baseline captured `2/5` clean; guards 2R.B–D regressions. Run: `using EDGAR, PythonCall` then `PdfScorecard.report()` |
| 2R.B | **Generalize statement location** — drop the hard `"consolidated"`; match statement TYPE structurally + multilingually (the five statement names per **detected language** via `_detect_lang`, + structure cues: year-pair header + money column + a known total row like `Total assets`/`Total equity`); prefer toc titles with **fuzzy type match** ("Income statement"→`:is`) | ✅ | Done in `ifrs_pdf.jl`: one multilingual source of truth `_STMT_LANGS` (en/pt/fr/it/es + de via `_dekonz`) drives `_IFRS_STMT_TYPES`/`_IFRS_STMT_TITLES`/`_IFRS_TOC_TYPES`; en keeps `"consolidated"` required (ambiguous bare names), Romance makes it optional (Enel/WEG don't repeat it → cluster+TOC disambiguates). `_ifrs_doc_juris` now sniffs the language → number LOCALE (`+BR`→`:eu_dot`; fr→`:eu_space`) — mis-locale silently corrupts values. **Result:** WEG(pt 13–27)/TotalEnergies(fr 421–427)/Enel(it 64–73) now locate + parse tables (were erroring); Fielmann/Tencent unchanged. **Vale ≠ 2R.B:** its "AR" is an integrated report with NO statements (points elsewhere) → a **2R.F** case, scorecard marks `want_loc=false` |
| 2R.C | **Harden table→facts** — diagnose Loblaw IS/CF miss; add layout tolerance + a **reconciliation self-check** (flags PARTIAL); Portuguese period detection | ✅ | Three fixes in `ifrs_pdf.jl`/`document_profile.jl`: **(1)** the Loblaw/Wesfarmers miss was LOCATION — NA filers pluralize ("Statements of Earnings", "Balance Sheets") and AU/UK title the primary set BARE (no "consolidated"). Made `statement`→`statements?` and "consolidated" OPTIONAL for English + added "statement(s) of earnings/income" everywhere → **Wesfarmers 0→28 facts (BS+CF+IS, foots)**, **Loblaw BS→BS+IS**. **(2)** bookmark strategy now gap-CLUSTERS matched pages + keeps the densest run (a stray "Off-Balance Sheet Arrangements" bookmark no longer balloons the range). **(3)** `_ifrs_period` reads numeric "31/12/24" & long "31 de dezembro de 2024" headers + multilingual month names → **WEG unblocked** (was throwing). Reconciliation self-check = the scorecard's BS cross-foot, now with a **`:partial`** state (rows extracted but a headline total missing). Anchors (Fielmann/Tencent) unchanged. **clean 2/5→4/8** |
| 2R.D | **Multilingual line-item classification** — a per-language IFRS label map (pt/de/fr/es/… → `ifrs-full`), selected by the detected label language; same pattern as `vocab_hgb` (DE) / `vocab_dcca` (DK). Portuguese first | ✅ | Added **fr/it/pt** headline branches to `ifrs_label_concept` (BS/IS/CF) from the REAL labels dumped off Enel/TotalEnergies/WEG; broadened English CF ("Cash flows from … activities" / "Decrease in cash", Loblaw) and pt/it BS heading classes in `TABLE_CLASSES`. Two structural fixes surfaced by the validation: **(1)** `_ifrs_ismoney` was `:eu_space`-blind — French space-thousands "184 125" carries no comma/dot, so TotalEnergies' all-positive **assets** column was never detected (0 assets facts → no cross-foot); now recognizes NBSP/space grouping. **(2)** classify from short page PARAGRAPHS + a pt/it account-form marker (Ativo/Passivo/Attività) for filers whose statement name isn't a Docling heading. **Result: Enel/TotalEnergies/Loblaw all → CLEAN; scorecard 4/8→7/8.** RESIDUAL: **WEG(pt)** gets BS only (3 facts) — Docling exposes none of its IS/CF headings (only the running header "DEMONSTRAÇÕES FINANCEIRAS 2025"), so IS/CF can't be keyed → a **2R.E** candidate (structural path can't crack it) |
| 2R.E | **Local vision-LLM fallback (Tier-3)** — when Tier-2 (Docling tables + classification) returns nothing or fails the 2R.C reconciliation, render the **located** statement page(s) to image and read them with a **LOCAL** vision-LLM → structured `FactRow`s. Gated by 2R.C, so it fires only on hard cases | ☐ | **LOCAL-ONLY** (privacy/cost/reproducibility); cloud vision opt-in at most, never default — mirrors Phase 4's "local default, Claude opt-in". Amends the earlier "no vision-LLM" decision (local fallback now allowed) |
| 2R.F | **Document scope** — distinguish "extractor failed" from "report has no detailed statements" (Vale integrated); prefer the statements doc when discovery finds both; label the thin case honestly | ✅ | **Extractor side:** `_ifrs_stmt_signal(doc)` = distinct statement types the doc shows; `extract_ifrs_pdf` now returns **no facts + an `@info`** for a THIN report (signal <2, e.g. Vale — points to its website/CVM for the accounts) and throws a clear "present but not located — coverage gap" only when 2+ types ARE there. Callers (`pdf.jl` dispatch, `fundamentals_oracle`) get an honest empty instead of an exception. Scorecard's not-located branch now reads the signal ("no detailed stmts" vs "unlocated, sig≥2 → gap"). **Discovery side (the "separate layer"):** `FilingHandle` gains a `doc_type` scope facet (`:statements` / `:annual` / `:integrated` / `:summary` / default `:report`) and `discovery.jl` gains a reusable **`prefer_statements(handles)`** pass — groups by `(entity, period_end)` and keeps the best-scoped document (a `:statements` doc beats all; an `:integrated`/`:summary` report loses to any sibling; unclassified sources pass through untouched). `CNINFOFilings` is wired to it: it now tags the report **summary** (摘要) `:summary` and the full 年度报告 `:annual`, so `prefer_statements` drops the thin summary in favour of the statements-bearing report (and still surfaces a summary-only filer, honestly thin, instead of silently returning nothing). Ready to consume a verified separate-statements category the moment a source produces one |
| 2R.G | **Oracle / acceptance gate** — validate PDF facts against the SAME filer's XBRL where both exist (an ESEF filer that also ships a PDF AR) + Yahoo. **Gate:** N born-digital PDFs × ≥4 languages each recover the 5 headline totals within tolerance | ◑ | **Oracle DONE & exported** (2026-07): `coverage`/`accuracy` (`src/extractors/pdf_quality.jl`); `accuracy(pdf; oracle=:xbrl_twin, twin=esef)` verified on **Inditex** PDF vs its ESEF iXBRL → **5/5 exact (0.0%)**. **GATE FAILS: 8/41 within 1% across 9 langs** (`accuracy(:yahoo)` over the ticker panel). The failures were **absolute-magnitude bugs the internal cross-foot MASKS** (Assets & EqL wrong by the same factor still foot): the "in millions" SCALE detection was English/German-only (H&M-sv/Kesko-fi/KGHM-pl defaulted to thousands, 1000× small), and a full-units statement (Enel's BS in full euros) inherited a doc-wide 1e6 → 7e16. **FIXED** (`b6bedea`): extend the magnitude words to all languages + a median full-units guard; **added `calibrate_scale`** (`1b14160`) — per-statement scale from a one-value Yahoo anchor (scale is NOT a document property). **Re-run gate: deterministic 8→17/41, calibrated 26/41 across 9 langs.** RESIDUAL is now mostly NON-scale: **Enel is a wrong-fixture, not a bug** — `IT-EnelFR2023.pdf` is the *Bilancio di esercizio di Enel SpA* (parent-only; the sole total-assets figure in all 181 pages is the parent's €71bn), so comparing it to Yahoo's consolidated ~€200bn is apples-to-oranges; the extractor correctly returned the only balance sheet present (a full report with BOTH consolidated + separate would need a prefer-consolidated pass, but Enel does not exercise it). Also **Yahoo standardisation** gaps (Inditex/Fielmann revenue/NI), missing metrics; and **`calibrate_scale` can BACKFIRE** when its anchor is itself mis-extracted (Kesko NetIncome x999900 — snaps the whole IS to a bad Revenue anchor) → needs a plausibility guard. Gate MUCH improved, not fully met; oracle + calibration are the acceptance tools |

**Sequence:** A → B → C → D → E → F/G. B is the single highest-leverage change; E (local vision-LLM) is the
last-resort floor for layouts the structural path can't crack. **Guardrails:** no per-filer patches; keep the
Tier-1 `toc`/`pdf.js` floor; one `StructuredDocument`→`FactRow`; vision-LLM fallback **local-only**.

## Phase 3 — The second family: sections, descriptive tables, figures
☐ To-do. The deferred half of 0.2 — live `Selection`/`SelectionTable`/figure derivations from the repo,
feeding `extract_section`/`find_paragraphs`. Reuses the substrate Phase 0 built.

## Phase 4 — Track B (RAG/Q&A) + new jurisdictions  *(build-order step 3)*
☐ To-do. Chunking → BGE-M3 → LanceDB → query agent (local default, Claude opt-in); China/India.

---

## Consolidated *deferred* list (in scope, pushed later)

1. **Scale & currency detection** (百万円 / TEUR / Mio. / 千元 footers; £/€/¥/₩/₹). Storage is ready — `tables.scale` + `tables.currency` columns exist (table-invariant; facts inherit, per-fact `unit`/`scale` only for exceptions like per-share/%); the *detection* of these from headers/footers is deferred.
2. **Row→concept mapping** (1.4b, `standard_concept`) — labels stored raw.
3. **Translation layer** — original verbatim now; translate as a later derived layer.
4. **Entity/dimension column header storage** — no schema column; provenance-recoverable only.
5. **MinerU head-to-head** (1.3) — Docling chosen provisionally.
6. **Account-form (two-sided) balance sheets** — Assets | Liab+Equity side by side. Dates resolve correctly and the monotonic warn tolerates the repeated panel, but right-side facts currently take the **left-side label column** (the middle label column is ignored). Needs per-panel label association; deferred until an ingested filing exhibits it.
7. **FactRow CSV filesystem artefact** + live `Selection`/`SelectionTable` derivation (Phase 3).
8. **`relationships` as an explicit table** — realized as views (design decision, not a gap).

## Next to implement, in order

1. **1.2 — `pdf_oracle.jl`** (value-anchored oracle). *The real blocker.*
2. **1.1 — dual-format gold-set fixtures** (feeds 1.2).
3. **Run `derive_facts!`** against the gold set → first 1.5 numbers + cross-foot check.
4. Then the deferred 1.4 refinements the oracle shows matter (period, scale), **1.5**, **1.6 🚦 gate**.

> Sequencing note: 1.4c (the mapper) was built before 1.2 (the oracle), so we currently have a deriver
> with no measuring stick. The plan's intended order is 1.1 → 1.2 → 1.4.

---

## Appendix — durable decisions & rationale (condensed from the prior draft)

**Output contract.** The PDF extractor emits the **same `FactRow` row table** as XBRL (`core/types.jl`),
so `facts(f)`, `select_statement`, `markdown`, CSV/DuckDB export and the oracles work unchanged. *Concept
problem:* PDF facts carry a line-item **label** ("Total assets", "Bilanzsumme"), not a taxonomy concept →
`concept` is a normalized label key and **`standard_concept` (W4) is the cross-filing bridge**; classify
keys off the label (confirm label-first in 1.4). **`source_selector` carries `(page, bbox)`** for the
Pollis back-link.

**Tiering (install weight, NOT priority).** **Tier-2 = Docling/MinerU + local LLM is the MAIN approach**
(heavier, opt-in, standalone-only, full document); **Tier-1 = `pdf.jl` (Node + pdf.js) is the graceful
FALLBACK** when the AI stack is absent. Both emit the same contracts. **A LOCAL vision-LLM is admitted only
as a gated last-resort FALLBACK** (Tier-3, 2R.E) — for statements the structural path can't crack; local-only
(privacy/cost/reproducibility), cloud vision stays out. (Earlier "vision-LLM-*primary*" framing is dead; a
local vision-LLM as *fallback* is now in scope — amended 2026-07.)

**Parser — settled, no longer a risk (2026-06-29).** Docling (no OCR) validated across EN (Tesco) + CN×3
(Moutai/Vanke/Wuliangye) + KR (Samsung) + RU (Lukoil) + DE×2 (Fielmann IFRS, VW HGB): recovers text,
section hierarchy, and statement tables that cross-foot. **OCR only needed for Japan EDINET** (broken/CID
text layer). Docling = lighter (CPU, ~1–2 GB); MinerU = heavier (~20 GB, GPU-leaning, `vlm` backend best,
natively multilingual). Both **pinned** in a uv venv outside the repo: `docling==2.107.0`,
`mineru==3.4.0`, Python 3.11, at `~/EDGAR-tools/tier2-venv`; reproducible from
`src/extractors/pdf/requirements-tier2.txt`. Model weights → `~/.cache/huggingface`.

**Number locale (the `parse_amount` core).** Three separator classes worldwide: `:en` (comma/dot —
US/GB/IE + CN/JP/KR/IN Western-digit comma-grouped), `:eu_space` (space/comma — **FR, RU**), `:eu_dot`
(dot/comma — DE/IT/ES + continental EU), keyed off **jurisdiction not language** (Lukoil: English text,
Russian number format). Also: parentheses- and `△`/`▲`-negatives, full-width CJK digits, currency/percent
stripping. CJK/India **scale words** (百万/千元/crore) are a separate *scale* concern (deferred).

**Per-jurisdiction findings for the mapper (1.4 refinements).** (1) Chinese/German BS **splits across
multiple tables** (assets / liab+equity) → mapper must stitch. (2) **Label synonyms** (负债及股东权益 vs
负债和所有者权益; 股东 vs 所有者) → label→concept must handle. (3) German **total rows are often
UNLABELED** → detect totals structurally, and locate statements by **heading/section** not bare label
("Summe Aktiva" also appears in IFRS-9 notes). (4) Header rows are messy everywhere (Docling over-flags
`is_header`) → use **data-start-row detection** (first row with a col-0 label + an amount), not header
flags.

**Persistence (committed).** StructuredDocument is the system of record; persists to (1) **filesystem**
(`~/RegulatoryReports/derived/<doc_id>/`: `structured.json` + `document.md` + `tables/*.csv` +
`figures/*.png`) and (2) **one DuckDB repo** (`regulatory-reports.duckdb`). Language: store the **original
verbatim**, translate **later** as a derived layer (`translations` table). `doc_id` = filename stem;
loader namespaces local ids as `<doc_id>:<localid>`. Every number traces to its exact cell
`(table_id,row,col)` + `section_id` via the FK chain + views. **Two dirs:** the repository root is
`~/RegulatoryReports/` (fresh); the legacy `~/EDGAR-Reports/` is the untouched validation-PDF stash (11
reports: UK-Tesco, CN-Moutai/Vanke/Wuliangye, JP-Sony/Toyota, KR-Samsung, RU-Lukoil, IN-Infosys,
DE-Fielmann/VolkswagenAG), convention `<CC>-<Company>FR<year>.pdf`.

**Product vision (Pollis).** A provenance-linked, validated Regulatory-Report workbench: render report +
extracted facts side-by-side, **click a number → highlight its source cell** (and back), oracle/cross-foot
status inline. This is *why* `(page, bbox)` provenance is a hard requirement and pdf.js does triple duty
(render + extract + coordinates) in the host (a TypeScript VS Code fork). GUI-first; China/India the
medium-term play.

**Validation beachhead.** Dual-format AFRs (same report as PDF *and* iXBRL on CH/NSM) are a ground-truth
oracle: diff PDF facts vs the iXBRL twin + always-on cross-footing (Assets = Liab + Equity, subtotals
foot). German (no twin) → validate vs Yahoo/AlphaVantage totals.

**Tier-1 history (pdf.js path).** P0 bake-off resolved to **`pdfjs-dist` directly** (no wrapper) +
~15-line row/column clustering; harness in `tools/pdf-bakeoff/`. The deterministic-only extractor scored
low recall on messy layouts (Tesco ~44%, Vodafone ~16%) — which is *why* the document-AI Tier-2 is the
main approach and Tier-1 is the fallback. No Python/Conda/JVM/GPL in the Tier-1 stack.
</content>
</invoke>
