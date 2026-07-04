# China (CSRC / CNINFO) — the 7th FilingSystem — living plan

Status: **C0–C4 DONE** (seven CAS formats cross-foot; fund §8 portfolios; Yahoo oracle 0 mismatches).
Everything local on `main`; do **not** push until China *and* Russia are done.

## The headline: China is the first PDF-native jurisdiction

Unlike the six prior systems (SEC, ESEF, Companies House, EDINET, DART, India) — all of which hand us an
XBRL/iXBRL package as the keyless primary channel — China's only complete, keyless, machine-accessible
channel yields **PDF annual reports under CAS**. There is no practical keyless XBRL feed for the general
filer universe. So China is the **flagship consumer of the PDF extractor** (`extractors/pdf.jl`,
`structured_document.jl`, `facts_derive.jl`, already 🟢 and wired) — and its first non-Latin/CJK consumer.

## Reconnaissance (live-verified 2026-07-04)

| Repository | What it is | Access — verified | Format |
|---|---|---|---|
| **CNINFO (巨潮资讯网)** | Designated national disclosure portal (SZSE subsidiary). All Shanghai+Shenzhen+Beijing listed companies' periodic reports. The real EDGAR-equivalent. | ✅ **Keyless** JSON: `topSearch/query` (orgId resolver) → `hisAnnouncement/query` (discovery) → `static.cninfo.com.cn/<adjunctUrl>` (PDF). Browser UA + Referer only. | **PDF only** |
| SSE data service (`listxbrl.sse.com.cn`) | SSE's XBRL-derived company-performance viewer; numbers normalized ("converted to base numbers"). Page itself says "refer to the PDF for actual disclosed numbers." | HTML/JSONP display layer (`query.sse.com.cn/commonQuery.do`). | Normalized, display-only |
| SZSE XBRL platform | Instance-document service (2009), `xbrl.cninfo.com.cn`. | Legacy; no documented live keyless API. | XBRL (legacy/uncertain) |
| CSRC | The regulator, not a repository — delegates disclosure to CNINFO + exchanges. | Not a fetch target. | — |
| MOF / CAS taxonomy | National-GAAP vocabulary (`xbrl.mof.gov.cn`). | ❌ Host **geo-blocked** from outside China. | — (irrelevant; we're PDF, not XBRL) |

**Accounting standard:** CAS / ASBE (企业会计准则), substantially IFRS-converged but its own taxonomy —
Chinese-labeled line items (`资产总计` Total assets, `营业收入` Revenue, `净利润` Net income), **not**
IFRS-namespaced. Classification is therefore **by Chinese label**, not concept namespace.

### Verified CNINFO chain (all three hops, keyless)

1. **orgId resolver** — `POST http://www.cninfo.com.cn/new/information/topSearch/query` with `keyWord=000001&maxNum=10`
   → `[{"code":"000001","orgId":"gssz0000001","zwjc":"平安银行",...}]`. This is China's `corp_code`↔`stock_code`
   resolver (like DART's `corpCode.xml`), but **live per-query** — no bulk index download needed.
2. **discovery** — `POST http://www.cninfo.com.cn/new/hisAnnouncement/query` with
   `stock=000001,gssz0000001` (code,orgId), `column=szse|sse|bj`, `category=category_ndbg_szsh` (annual report),
   `seDate=2024-01-01~2025-12-31`, `tabName=fulltext` → records with `announcementTitle` (年度报告 vs 摘要),
   `adjunctUrl`, `announcementTime`.
3. **PDF** — `GET http://static.cninfo.com.cn/<adjunctUrl>` (Referer required) → the annual-report PDF.
   Ping An Bank FY2024 = 1.9 MB, PDF 1.7, 296 pp, **born-digital text layer**; Tier-1 pdf.js extracts CJK
   with coordinates cleanly (no OCR). Stash: `~/EDGAR-Reports/CN-PingAnBankFR2024.pdf` (+ existing
   CN-Motai/Vanke/Wuliangye FR2023).

## Design decisions (agreed 2026-07-04)

- **Identity: new `:cninfo` scheme.** `EntityId(:cninfo, "000001,gssz0000001")` packing code+orgId,
  distinct from DART's `:stock_code` namespace to avoid cross-jurisdiction collisions. (`topSearch` resolves
  a bare 6-digit code or a name → the `code,orgId` pair.)
- **Coverage: all three boards** (SZSE + SSE + BSE/Beijing) — same endpoint, only the `column` param differs
  (`szse`/`sse`/`bj`).
- **Milestone order: C0–C2 first** (a shippable keyless slice: seam + discovery + fetch + narratives), then
  **C3** (CAS facts via the PDF extractor) as a separate gated phase, since C3 is the first CJK consumer of
  the extractor.

## Phases

- **C0 — Seam.** `China <: FilingSystem`, `system_tag(::China)=:china`, `system_headers` = browser UA/Referer.
  Register includes + exports. Loads clean, no behaviour yet.
- **C1 — Discovery (CNINFO, keyless).** `discovery.jl`: `CNINFOFilings <: FilingSource`; a `cninfo_org(query)`
  resolver over `topSearch`; `discover(CNINFOFilings(); stock_code=…, board=:auto, from=, to=)` →
  `FilingHandle[]` (filter `category_ndbg_szsh`; separate 年度报告 from 摘要; carry the `static.cninfo`
  PDF URL). Live-verified shapes above.
- **C2 — Fetch → PDF `Filing`.** ✅ `fetch_filing(::China, url|handle)` downloads the PDF to a cache path and
  builds `Filing(…, :pdf, path)` — the first system to fully wire fetch→:pdf-Filing. Verified: discover→fetch→
  `facts(f)` dispatches to `extract_pdf`, `narratives(f)` to `structured_document`. Bonus: `pdf_words.mjs` now
  passes `cMapUrl`+`cMapPacked` so CID-keyed **CJK fonts decode** (non-breaking for Latin). Open for C3: CJK
  extracts char-by-char (cluster into labels); `_pdf_page_facts` is Latin-tuned (needs CAS labels + CJK/full-width
  digit parsing + `currency=CNY`); `narratives` needs the Docling Tier-2 venv.
- **C3 — CAS facts + labels.** ✅ **Done via Docling** (Tier-2), not geometry. `extract_cas_pdf` is a hybrid:
  a pdf.js pre-scan locates the statement page range (by statement headings) + fiscal year, Docling parses just
  those pages, and facts are derived from its `DocTable` cells — statement kind from `TABLE_CLASSES` CJK captions
  (+ a row-label fallback for mis-titled tables), parent-company (母公司) copies dropped, labels classified
  through `vocab_cas` (`cas_concept` + `_cas_labelkey` prefix/divider stripping), amounts via the shared
  `parse_amount`, scale (千元/万元) from a `单位…` marker, periods from the fiscal year. **7/7 anchors + BS
  cross-foot verified on Moutai (元) and BYD (千元) via the real `fetch_filing→facts(f)` path.** Equity-changes
  matrix deferred. Original design (now historical):
- **C3 (original plan) — CAS facts + labels (gated).** `facts(f)` routes through the PDF extractor; `vocab_cas.jl` maps
  Chinese CAS labels → canonical statement roles (label-driven, the analog of `vocab_indas` but keyed on 中文).
- **C4 — Oracle/validation. ✅ DONE.** `YahooOracle` gained a `:china` branch (`src/sources/yahoo_oracle.jl`):
  `cas:` concepts → Yahoo fundamentals (`.SS`/`.SZ`), Revenue prefers `cas:TotalRevenue` (= Yahoo TotalRevenue
  = 营业总收入; banks fall back to 营业收入合计), NetIncome prefers `cas:ProfitAttributableToParent`.
  `_edgar_rows(:china,·)` takes a CNINFO code OR a local PDF path. Panel result: **Ping An Bank (000001.SZ),
  Moutai (600519.SS), Midea (000333.SZ) — all five metrics (Assets/Equity/Revenue/NetIncome/OperCashFlow)
  match Yahoo to Δ0.0%, 0 mismatches.**

## Adjacent sources (scoping, decided 2026-07-04)

- **Mainland is complete with one source.** SSE/SZSE/BSE are all surfaced through CNINFO (the designated
  portal); the individual exchange sites just re-host the same PDFs. No extra mainland adapter needed.
- **US-listed Chinese ADRs → SEC, today, no new code.** Alibaba/PDD/JD/Baidu/NetEase etc. file Form 20-F with
  the SEC as tagged XBRL — the better source for those names. Documented in the manual (§ US-listed issuers,
  `sec:china-adr`). Rule: US-listed → SEC; CNINFO PDF channel is for A-share-only filers.
- **HKEX (Hong Kong) → its own FilingSystem, on the roadmap BEFORE Russia.** NOT a China source: SFC regulator,
  HKFRS≈IFRS (reuse `ifrs-full`, no CJK label vocab), English-primary PDFs on HKEXnews. Keyless JSON verified
  (prefix.do code→stockId, titleSearchServlet.do → docs). Dual A+H firms file twice (CAS on CNINFO, HKFRS on HK).
- **Non-listed mainland companies: effectively out of reach.** SAMR registry `gsxt.gov.cn` holds statutory
  annual filings but discloses little financial detail and has no keyless API (CAPTCHA-gated); commercial
  aggregators (Qichacha/Tianyancha) are paid — the MCA21 analog. The one exception: non-listed **bond issuers**
  (large SOEs / financing vehicles) must publish audited statements via bond-market disclosure (interbank
  NAFMII/ChinaMoney; exchange bonds via CNINFO) — a possible later extension, not current equity scope.

## Post-China workstream (parked 2026-07-04)

- **Fund portfolios for JP / KR / IN.** China gained a §8 portfolio extractor (`extract_fund_portfolio`,
  holdings + 8.1/8.2 summaries) because CNINFO serves fund annual reports with one standardized PDF section.
  The other three are each a *separate* sub-project (new source + holdings extractor), NOT a reuse:
  - **Japan (most tractable)** — investment trusts (投資信託) file 有価証券報告書 / 運用報告書 via the existing
    **EDINET** seam; holdings live in 組入資産明細. New document type + table extractor, but discovery is seamed.
  - **Korea** — DART is corporate; ETF/fund holdings are on **KRX** (ETF PDF/CSV composition) and **KOFIA**
    (fund disclosure); some 자산운용보고서 in DART. New adapter.
  - **India (most fragmented)** — mutual-fund portfolios are monthly per-AMC disclosures (SEBI/AMFI), Excel/PDF
    on each AMC site; no single keyless portal. New adapter.
  Recon first (as with China), one jurisdiction at a time; sequence JP → KR → IN.

## Hard rules honored

Persistent env `~/EDGAR-tools/edgar-dev/` (never scratchpad); HTTP="1.10" never 2; ask before running the test
suite; commit only when told; check `~/EDGAR-Reports/` first & save new filers there; validate on fresh filers;
never recompile the manual (edit `.tex` and stop).
