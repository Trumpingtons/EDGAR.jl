# PDF table-specialist bake-off — results

Running log for the P0 competition (see [pdf-extractor-plan.md](pdf-extractor-plan.md) §2, P0). Harness:
`tools/pdf-bakeoff/` (`extract.mjs` = run one candidate → JSON; `match.mjs` = score one candidate's
extraction against an iXBRL-twin's headline figures). Run one candidate per process.

## Milestone 1 — single-twin end-to-end proof (2026-06)

**Purpose:** prove the full loop (twin fetch → iXBRL ground truth → run 3 candidates on the PDF → diff),
*not* yet rank the specialists. Floor metric = does the candidate's extracted output contain the twin's
headline figures (presence in text), not structured cell-level accuracy.

**Twin:** Tesco PLC FY2024 (period end 2024-02-24), fetched keyless from the FCA NSM —
- PDF: `NI-000096769.pdf` (240-page annual report, 6.9 MB)
- iXBRL `.zip`: `NI-000096767_…-2024-02-24.zip` (ESEF report package)

**Ground truth** (EDGAR's own extractor on the iXBRL twin, 752 facts), in the PDF's £m scale:
Revenue 68,187 · NetIncome 1,192 · Equity 11,671 · OperCashFlow 3,839.
(Total assets came back undimensioned-none — Tesco appears to tag it dimensioned; a truth gap to revisit.)

**Result (presence-in-output, n = 1 twin):**

| Candidate | Headline figures | Structure | Time |
|---|---|---|---|
| pdf.js-extract | **4/4** | 240 pp / 56,702 words+coords | 4.6 s |
| pdfreader | **4/4** | 86,510 items (x,y,text) | 4.8 s |
| pdfexcavator | **4/4** (text-only) | default table finder → 0 tables (borderless) | 2.5 s |

**Findings**
- The loop works end-to-end; all three can recover the headline numbers from the PDF text layer.
- **Process isolation is required:** the candidates bundle different pdf.js versions (pdf.js-extract 5.5.207,
  pdfexcavator's pdfjs-dist 4.10.38, pdfreader's pdf2json fork); running them in one Node process detaches
  the pdf.js buffer and crashes. One candidate per process (as the plan's "one CLI per candidate" mandates).
- **pdfexcavator (v0.1.2) rough edges:** its *default* `extractTables()` is ruling-line based → **0 tables**
  on Tesco's borderless statements; and interleaving `extractTables()` with `extractText()` crashes
  (detached ArrayBuffer). Borderless financial tables need its lower-level
  `extractTablesEnhanced(chars, lines, rects, …)` path. Text extraction works and is fastest.

**Caveats / not yet measured**
- n = 1, one jurisdiction (UK/IFRS), one form (full IFRS AFR). No German, no FRS-105/filleted, no scanned.
- **Floor metric only.** Presence-in-text does **not** distinguish the *table specialists* — that needs
  structured (line-item × period) cell matching, where pdfexcavator's borderless finder and pdfreader's
  column detection should separate from the build-our-own (pdf.js-extract + clustering) baseline. That is
  the real P0 comparison (P0.4–P0.6) and the next milestone.

## Next
- Scale to the stratified corpus (P0.1–P0.3): multi-jurisdiction (UK CH, NSM, **Germany**, US) × form type.
- Replace presence-in-text with **structured cell-level accuracy** vs the twin (the metric that ranks the
  specialists), plus the failure-mode classification (clean-fail vs confidently-wrong).
