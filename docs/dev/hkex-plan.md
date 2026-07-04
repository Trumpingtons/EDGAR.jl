# Hong Kong (HKEX / HKEXnews) — the 8th FilingSystem — living plan

Status: **recon complete → HK0 pending**. Everything local on `main`; do **not** push until China *and*
Russia are done (HKEX slots before Russia).

## The headline: PDF-native like China, but English

Hong Kong is the second **PDF-native** jurisdiction, but it inverts China's hardest problem. Reports are in
**English** under **HKFRS** (substantially identical to IFRS), so classification reuses the shared
`ifrs-full` concepts through a light English label map — **no CJK vocab** (`vocab_cas` analogue) is needed.
HKEX mandates **no XBRL/iXBRL** for issuer financials (verified: every HKEXnews `FILE_TYPE = PDF`), so a HK
filing is a PDF whose facts come from the shared PDF extractor.

## Recon findings (verified 2026-07-04)

- **Portal — HKEXnews (`www1.hkexnews.hk`), keyless JSON, both endpoints verified:**
  - `prefix.do?name=<name|code>&type=A&market=SEHK&lang=EN` → JSONP `{stockId, code, name}`. Tencent →
    `stockId 7609, code "00700"`. Returns derivative/structured products too (N-series, `-R`) — pick the
    plain-code equity line.
  - `titleSearchServlet.do?stockId=…&title=Annual%20Report&searchType=1&market=SEHK&lang=E&…` →
    `{"result":"[…]"}` (JSON-in-JSON); each doc: `TITLE`, `LONG_TEXT` (`"‹Tier-1› - [‹Tier-2›]"`),
    `FILE_TYPE`, `DATE_TIME`, `STOCK_CODE`, `FILE_LINK` (relative PDF path → `https://www1.hkexnews.hk<link>`).
- **Artifact** — a single English PDF (Tencent AR2024 ≈ 4.75 MB, IFRS), under the "Financial Statements/ESG
  Information → [Annual Report]" category. Standard IFRS titles: "Consolidated Statement of Financial
  Position / Profit or Loss and Other Comprehensive Income / Cash Flows / Changes in Equity".
- **Entities** — Main Board (~2,300) + GEM (~300); by origin local / H-share / red-chip / P-chip / foreign
  (extraction-agnostic — all file one English IFRS report). Identity = 5-digit code + `stockId` →
  `EntityId(:hkex, "00700")`.
- **Existing reuse** — `extract_pdf` (Tier-1 pdf.js) already classifies English statements + scale; `vocab_ifrs.jl`
  and `document_profile.jl` exist; Docling (Tier-2) is the fallback. Yahoo covers `0700.HK` for HK4.

## Decisions locked (with the user)

1. **Extractor tier: Docling (revised after the HK2 spike).** The Tier-1 (`pdf.js`) spike on the Tencent AR
   was fast (~2 s, 84 facts, correct RMB values) but had systematic gaps — the BS **equity section** and
   **Revenue total** were missing, the **operating/investing cash-flow** net lines were missing (only
   financing captured), and note tables contaminated the statements. These are the same geometric-fragility
   issues that pushed China to Docling. So HK2 reuses China's **Docling** pipeline (`structured_document` →
   page-scoped table facts), with English being *easier* for Docling than CJK. Tier-1 stays available as a
   fast pre-scan (page location, fiscal year) exactly as in China.
2. **Label→concept: a light English-IFRS label map** — headline lines → `ifrs-full:` concepts (Total assets
   → `ifrs-full:Assets`, Revenue, Profit for the year → `ProfitLoss`, Total equity → `Equity`, net cash from
   operating → …`OperatingActivities`). Reuses `ifrs-full`, slots into the existing classify engine.

## Phases

- **HK0 — Seam.** `struct HKEX <: FilingSystem`; `system_tag(::HKEX)=:hkex`; `system_headers` (browser UA +
  HKEXnews `Referer`); `EntityId(:hkex, "00700")`. Loads clean, no behaviour yet.
- **HK1 — Discovery + fetch.** `hkex_stock(query) → (code, stockId)` via `prefix.do` (strip JSONP, pick the
  plain-code equity line). `HKEXFilings <: FilingSource`; `discover(::HKEXFilings; code|name, market=:sehk,
  years, …) → FilingHandle[]` via `titleSearchServlet.do` (annual reports; parse the JSON-in-JSON `result`).
  `fetch_filing(::HKEX, handle) → :pdf Filing` (download `www1.hkexnews.hk<FILE_LINK>` to cache).
- **HK2 — Facts.** Tier-1 spike on the saved Tencent AR (`extract_pdf`); if clean, keep it, else Docling. Add
  the English-IFRS label map; verify cross-foot (Assets = Liabilities + Equity) on Tencent + fresh filers.
- **HK3 — Manual.** Retrieval section (the Repositories / Entities / Forms sections are already written and
  committed); fill Taxonomy + Retrieval as implementation lands.
- **HK4 — External data benchmark.** Add `:hkex` to `YahooOracle` (`0700.HK`, `.HK` suffix); cross-check
  Assets/Revenue/NetIncome on fresh + stashed filers. Target Δ0.0% like China.

## Adjacent sources (scoping)

- **Mainland is complete with one source; HK is too.** HKEXnews carries the whole listed universe (Main Board
  + GEM); the exchange's own site re-hosts the same PDFs.
- **US-listed / secondary names → SEC, no new code.** Alibaba (`09988`/`BABA`), JD, NetEase etc. file Form
  20-F (tagged XBRL) — the better source. Rule: US-primary → SEC; HKEXnews PDF channel for HK-primary filers.
- **Non-listed HK companies: out of reach.** Companies Registry holds only the accounts-free NAR1 and charges
  per document (ICRIS/e-Search) — the SAMR/MCA21 analogue.
- **Later extensions:** interim / half-year report (same seam + extractor); annual/interim results
  announcements (condensed face statements); ESG reports (→ `narratives`); HK REITs/trusts/funds (net-asset
  shape, as in China).

## Hard rules honored

Persistent env `~/EDGAR-tools/edgar-dev/`; HTTP="1.10" never 2; ask before running the test suite; commit only
when told; check `~/EDGAR-Reports/` first & save new filers there; validate on fresh filers; never recompile
the manual unless told; don't push (HK before Russia).
