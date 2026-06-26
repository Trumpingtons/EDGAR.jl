# Vision — the Pollis Regulatory-Report workbench

Status: **product/UX vision** (not a build plan). Records *why* the PDF extractor
([pdf-extractor-plan.md](pdf-extractor-plan.md)) is built the way it is, and the one requirement that
flows back into the extractor core. EDGAR.jl is being embedded in **Pollis** (a TypeScript-based VS Code
fork); this is how a Pollis user works with regulatory reports.

## The market read: build the vertical, not another viewer

The VS Code marketplace's pdf.js extensions are all **horizontal viewers** ("render a PDF in a tab") with
low installs — because developers rarely open PDFs in an editor and a viewer has no lock-in. That space is
empty *because it is the wrong space*. Nobody has built the **vertical**: *turn a regulatory filing into
trustworthy structured data and work with it*. That is EDGAR.jl's lane. An empty adjacent space full of
weak horizontal tools is opportunity, not competition.

So we explicitly do **not** build a generic "PDF Extractor Plus" (generic text/table extraction is
commoditised — that is what the low installs reflect).

## The differentiator: provenance + validation, not extraction

Extraction is table stakes; **trust** is the product. The workbench interaction:

> Fetch a filing → see the **rendered report and the extracted facts side-by-side** → **click a number in
> the table and its source cell highlights in the report** (and vice-versa) → with each figure's **oracle /
> cross-foot status shown inline** (ties to the iXBRL twin · foots correctly · unverified) → one-click
> **export to CSV / DataFrame / Julia**.

"Click a fact ↔ highlight its source pixel, with a trust badge" is what the Arelle iXBRL viewer does for
*tagged* filings and what **nobody does for PDF filings** — exactly where private / German / Chinese filers
live. "Every extracted number traceable to its source location and validated" is a finance-grade,
defensible value proposition. Generic extractors cannot offer it: they have no discovery, no validation
oracles, and no coordinate-anchored facts. EDGAR.jl has all three.

## Why pdf.js-in-Pollis is the enabling substrate

In Pollis (Electron/web) the **same pdf.js does triple duty** — it *renders* the PDF in a webview, it
*extracts* the facts, and it *yields the coordinates* that link them. One library, in-process with the
host, closes the loop: render + extract + back-link are the same engine. A viewer extension can't link (it
doesn't own the extraction); a Python extractor can't render in the editor. This is why the
**`pdfjs-dist`-direct** decision compounds beyond the bake-off — it is also the rendering and
provenance-linking layer of the workbench.

## Continuous with what already exists

EDGAR.jl already has the **picker → `Selection` → `facts`** paradigm (`PICKER_JS`): select a region of a
rendered filing, get facts with provenance. The workbench is the *same* paradigm on the PDF rendering path
— pick a region of a rendered report, get facts, with a source back-link. Not a new product; the existing
`Selection` model extended to PDF.

## The requirement this pushes back into the extractor (act on it in P1)

For the back-link to exist, **every PDF-extracted `Fact` must carry its source `(page, bbox)` provenance**,
not just the value — the PDF analogue of `FactRow.source_selector` (today an HTML/CSS selector). pdf.js
already hands us the bounding box per text item, so this is cheap **if designed in from the start** and
painful to retrofit. → captured as **P1.5** in the PDF plan.

## Caveats

- **GUI-first, code-optional.** Regulatory-report users are not traditional VS Code users; the workbench
  (picker, side-by-side view, highlight, export buttons) must work without writing Julia, with Julia as the
  power-user escape hatch. Whether that audience lives in Pollis is Pollis's thesis; the UX must lower the
  barrier to meet them.
- **Sequence it.** Finish the Julia extraction core (P1–P3) producing **coordinate-anchored, validated
  facts** first — that is the substrate. The Pollis extension UX (side-by-side, highlighting) is a separate,
  later track. Do not let the UI pull effort before the core is solid.

## The longer arc

The provenance-linked, validated workbench is the medium-term selling point precisely for markets with **no
open XBRL and non-Latin scripts** — **China** (CSRC/SSE/SZSE) and **India** (BSE/NSE/MCA), largely PDF.
There, born-digital pdf.js alone won't suffice (scanned, CJK, dense layouts → Tier-2 OCR + Tier-3 LLM), but
the *workbench contract* — traceable, validated facts from a rendered report — is the same. The
multi-jurisdiction sweep ([pdf-extractor-plan.md](pdf-extractor-plan.md) P0 reframe) is the dress rehearsal.
