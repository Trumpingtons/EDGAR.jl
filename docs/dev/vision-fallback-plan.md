# 2R.E — Local vision-LLM fallback (Tier-3)

**Status:** PLAN only — deferred by design. Do **not** start until the two preconditions below are met.
**Purpose:** the last-resort floor for statement pages the *structural* path (Tier-2 Docling) cannot read —
render the **already-located** statement page(s) to an image and have a **local** vision-LLM read them into
structured `FactRow`s. It is a **fallback**, gated so it fires only on hard cases; Tier-1/Tier-2 stay the
default. It also closes **WEG** (pt): Docling exposes none of its IS/CF headings, so the structural path gets
BS-only — the canonical case Tier-3 exists for.

## 0. Preconditions (why it stays deferred)

Do not build this until:
1. **The deterministic path is unified** — one coherent Tier-1/Tier-2 pipeline with scale, locale, and
   `calibrate_scale` settled (mostly done: locate 16 / labels 15 / CJK+Latin scale). No point adding a Tier-3
   floor while the floor below it is still moving.
2. **It is measured** — a stable coverage/accuracy baseline exists (the gate: `coverage`/`accuracy`), so we
   know *which* statements actually fail Tier-2 and can quantify what Tier-3 must recover and at what
   false-positive cost. Tier-3 is only justifiable against a measured gap.

Rationale: Tier-3 is expensive (a multi-GB local model, GPU/CPU inference) and non-deterministic. It earns its
place only as a *narrow* patch over a *measured* residual, never as a general extractor.

## 1. When it fires — the gate (per statement, not per document)

Reuse the existing funnel (`coverage`: parsed → located → tables → facts → reconcile). After the deterministic
pass, escalate an individual **located** statement to Tier-3 only when:
- it **located** (we know the page range — locate is 16 languages) **but** produced **no facts** (Docling
  surfaced no headings — WEG's IS/CF), **or**
- its balance-sheet **cross-foot fails** (`reconcile ∈ {:off, :partial}` — a headline total missing/wrong).

So Tier-3 re-does **only the failing statement's pages**, never the whole report, and never a statement Tier-2
already got clean. A document where Tier-2 succeeds never invokes a model.

## 2. Architecture

```
extract_ifrs_pdf (Tier-2)  ──►  per-statement gate (§1)
                                     │ fails
                                     ▼
                 render located page(s) → image  (reuse Docling with_images)
                                     ▼
                 VisionExtractor.read(image, statement_type, language)  →  [(label, value, period), …]
                                     ▼
                 reuse ifrs_label_concept (label→concept) + parse_amount (value, via detected locale)
                                     ▼
                 RECONCILIATION GATE (_bs_crossfoot / range/scale sanity) → accept or REJECT
                                     ▼
                 merge accepted FactRows back (replacing the thin/failed statement)
```

Key design choices:

- **Render:** the pipeline already locates the page range and Docling can emit page images
  (`structured_document(...; with_images = true)`). Reuse those — no new PDF-render path. Target ~150–200 DPI
  so digits are legible.
- **The VLM reads, the existing map classifies.** The model does ONLY the hard part — reading `(label, value,
  period)` off a page whose layout Docling couldn't parse. Concept assignment stays deterministic: feed the
  model's labels through the **existing `ifrs_label_concept`** (15 languages) and values through
  `parse_amount` (with the document's detected locale). This keeps Tier-3 output consistent with Tier-2 and
  avoids trusting the model for taxonomy. The model never emits `ifrs-full` concepts directly.
- **Provider abstraction** (mirror `FundamentalsProvider`): a `VisionExtractor` singleton with one plug point
  `read(image, stmt, lang) -> rows`. Default = **local** (an Ollama-hosted vision model — `llama3.2-vision` /
  `qwen2.5-vl` / `minicpm-v`, model configurable; called over Ollama's local HTTP + JSON structured output).
  A **cloud** (`:claude`) provider is **opt-in only**, never default — exactly Phase 4's "local default,
  Claude opt-in" and the 2R plan's "vision-LLM fallback LOCAL-only".
- **Structured output:** prompt with the image + statement type + language; require JSON rows
  `{label, value_current, value_prior}` (Ollama `format`/JSON-schema). Deterministic settings: `temperature =
  0`, fixed seed where the backend allows.
- **Reconciliation gate on the model output (ESSENTIAL).** VLMs hallucinate numbers, so Tier-3 output is
  accepted ONLY if it passes the same checks the deterministic path uses — the BS cross-foot (`_bs_crossfoot`),
  a plausible-magnitude/scale sanity, and (when a ticker is available) `calibrate_scale` / a one-value
  `accuracy` order-of-magnitude check. Output that doesn't reconcile is **rejected**, not merged — a rejected
  Tier-3 is no worse than the thin Tier-2 it was trying to replace.
- **Determinism / reproducibility:** cache `(pdf-hash, page-range, model) → rows` so a re-run is stable and
  the model runs once. Local-only keeps it reproducible (a cloud API drifts over time).

## 3. Integration point

Opt-in, gated — never on by default:
```julia
extract_ifrs_pdf(path; vision_fallback = false)     # default: deterministic only
extract_ifrs_pdf(path; vision_fallback = true)       # Tier-3 fires on the per-statement gate (§1)
extract_ifrs_pdf(path; vision_fallback = :claude)    # opt-in cloud provider
```
The flag threads through `facts`/`coverage`. With it off, behaviour is exactly today's.

## 4. Infrastructure (the heavy lift)

- A **local VLM runtime** — the real cost. Default: **Ollama** (clean local server, model-swappable, JSON
  structured output), pulled model ~7–11B (multi-GB). Alternative: a Python VLM in the existing tier2 venv
  (`transformers`), heavier to manage.
- Packaged as an **optional package extension** (like `EDGARDoclingExt` on `PythonCall`) or behind a runtime
  check — loaded only when `vision_fallback` is requested, so `using EDGAR` and the deterministic path never
  pull it in. No new hard dependency.

## 5. Sub-steps (build order, once un-deferred)

| # | Step | Deliverable |
|---|---|---|
| E1 | **Render + abstraction** | page-image from the located range (reuse Docling images); `VisionExtractor` interface + a stub provider; the per-statement gate (§1) wired but calling the stub |
| E2 | **Local provider** | Ollama-backed `read(...)` — prompt, JSON schema, temp 0; returns `(label,value,period)` rows |
| E3 | **Classify + reconcile** | map rows via `ifrs_label_concept`/`parse_amount`; the reconciliation ACCEPT/REJECT gate; merge accepted facts |
| E4 | **WEG acceptance** | WEG(pt) BS-only → all three statements; measure recover-rate + false-positive (rejected) rate on the gated fixtures |
| E5 | **Cloud opt-in** | `:claude` provider behind the same interface (never default) |
| E6 | **Docs + gated test** | manual section (Tier-3 as the floor); a gated regression test on the WEG-class fixtures |

## 6. Acceptance

- **WEG:** BS-only (3 facts) → BS+IS+CF, cross-footing, values within tolerance of the report.
- **No regression:** a document Tier-2 already extracts clean never invokes the model (the gate is negative for
  it), so nothing that works today changes.
- **Honest floor:** rejected Tier-3 output (fails reconcile) leaves the statement as its thin Tier-2 result +
  an honest note — Tier-3 can only *improve or abstain*, never silently corrupt.

## 7. Risks & guardrails

- **Hallucination** → the reconciliation ACCEPT/REJECT gate is mandatory; no per-filer prompt tuning.
- **Cost / latency** → local, gated, per-statement only; a clean Tier-2 doc pays nothing.
- **Non-determinism** → temp 0 + cache; local-only for reproducibility.
- **Heavy dep** → optional extension, opt-in flag; never in the default load.
- **Scope creep** → Tier-3 is a *fallback*, not a second extractor. It reads pages Tier-2 can't; it does not
  replace the deterministic label map, scale detection, or locator.

## 8. Non-goals

- Not the default path; not a cloud-first design; not a replacement for Tier-1/Tier-2.
- Not a general OCR/table engine — it fires only on the located, Tier-2-failed statement pages.
- Not trusted for taxonomy — concepts still come from `ifrs_label_concept`, values from `parse_amount`.
