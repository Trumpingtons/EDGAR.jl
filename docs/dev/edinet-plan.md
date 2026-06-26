# Plan — adding EDINET (Japan) as a FilingSystem

Status: **draft / living document** (expect iteration). Follows the seam established by SEC, ESEF and
Companies House (see [filing-systems.md](filing-systems.md), [companies-house-plan.md](companies-house-plan.md)).
EDINET (JP) is the **4th `FilingSystem`**; DART (KR) is planned next and shares most of this shape.

Governing principle (unchanged): **generalize the nouns, not the verbs.** EDINET reuses almost the whole
stack — the `FilingSystem` seam, the `FilingSource`/`discover`/`fetch_filing` discovery seam, the
credentials registry (N3, built for CH), and the **ESEF report-package reader + XBRL extractor** (an
EDINET submission is a ZIP of inline-XBRL + bundled taxonomy, the same shape as a UKSEF/ESEF package). The
genuinely new work is small and well-scoped.

## What EDINET forces (the new nouns) vs. reuses

| | Reuse | New |
|---|---|---|
| Discovery | `FilingSource` + `discover` + `FilingHandle` | `EDINETApi` source over the EDINET REST API |
| Credentials (N3) | `set_credentials` / `get_credential` / `system_headers` registry | `system_headers(::EDINET)` = `Subscription-Key` header |
| Fetch / parse | ESEF **report-package** reader (`report_package.jl`) + the jurisdiction-agnostic XBRL extractor | EDINET ZIP entry layout (`XBRL/PublicDoc/…`) differs from ESEF's `reports/…` |
| Identity | `EntityId(scheme, value)` | scheme `:edinet` (EDINET code `E#####`) and/or `:jcn` (法人番号, 13-digit corporate number) |
| Taxonomy / vocab | `classify_engine` auto-merge; `ifrs-full` for IFRS adopters | **`vocab_jpgaap.jl`** — J-GAAP concepts (`jpcrp` / `jppfs`), keyed by prefix |
| Labels | `label_map` / `_concept_labels` | **N5 — language-aware labels** (`xml:lang` ja/en); `label_map(f; lang)` |

## Access mechanics (EDINET API v2 — verified 2026-06 against the FSA spec; confirm live with a key)

- **Base:** `https://api.edinet-fsa.go.jp/api/v2`. **Auth:** a free **`Subscription-Key`** (query param or
  header; register on the EDINET site). Rate limit ≈ one request / 3–5 s.
- **Document list:** `GET /documents.json?date=YYYY-MM-DD&type=2&Subscription-Key=…` → `{ metadata, results[] }`.
  Each result carries: **`docID`** (書類管理番号, the fetch key), **`edinetCode`** (`E#####`), **`secCode`**
  (5-digit securities code → ticker `nnnn.T` is the first 4), **`JCN`** (法人番号), `filerName`,
  **`docTypeCode`** (**120 = 有価証券報告書 / Annual Securities Report** — the annual report we want; 140 =
  quarterly, 160 = semi-annual), `formCode`, `ordinanceCode`, `periodStart`, `periodEnd`, `submitDateTime`,
  `docDescription`, and the flags **`xbrlFlag` / `csvFlag` / `pdfFlag`** (which formats exist).
- **Document fetch:** `GET /documents/{docID}?type=1&Subscription-Key=…` →
  - `type=1` → **the main ZIP (inline XBRL + taxonomy)** — our parse path.
  - `type=5` → **CSV** of the tagged facts — a pre-parsed **parser oracle** (see Validation).
  - `type=2` → PDF (out of scope here, like CH/NSM PDFs).
- EDINET code ≠ ticker: discovery is **date-based** (list a day's filings, filter by `edinetCode`/`docTypeCode`),
  not "by company id" like CH. An entity→`edinetCode` resolver (by name / ticker / JCN) is a later nicety.

## Validation

filings.xbrl.org does **not** carry JP, so **no Arelle oracle**. Instead:
- **EDINET CSV (`type=5`)** = the regulator's own parse of the same filing → a fact-level **parser oracle**
  (the JP analog of Arelle): our `facts(f)` must match the CSV's values. Strongest, free, same-document.
- **Yahoo** (Tokyo tickers `nnnn.T`, e.g. Toyota `7203.T`) for headline-total cross-checks (`yahoo_oracle`).
- AlphaVantage is US-strong / JP-weak → not relied on.

---

## Phases (stepped; 🚦 = hard-stop gate — pause, report, ask)

Status icons: ☐ todo · ▶ doing · ✅ done · ⏸ blocked.

### E0 — Seam: `EDINET` system + credentials + headers ✅ DONE
- ✅ E0.1 `struct EDINET <: FilingSystem` + `system_tag(::EDINET)=:edinet` (filing_systems/edinet/edinet.jl);
  identity scheme `:edinet`.
- ✅ E0.2 `system_headers(::EDINET)` → `Ocp-Apim-Subscription-Key` from the credentials registry
  (`set_credentials(EDINET(); api_key=…)`) or `EDINET_API_KEY` env (reuses the CH N3 pattern). Verified.
- ✅ E0.3 `include` + `export EDINET, EDINETApi` wired; package loads clean.

### E1 — Offline parse (mirrors CH C1 / ESEF B1) ✅ DONE (offline, no key)
- ✅ E1.1 `fetch_filing(::EDINET, src)` over a submission ZIP: `_edinet_primary_report` finds the instance
  under `XBRL/PublicDoc/`, reuses the report-package reader. Verified on the **real FSA sample** ZIP layout
  (IFRS instance → 1375 facts, BS/IS/CF classified).
- ✅ E1.2 `_fetch_linkbase(::EDINET, f, suffix)` from the bundled ZIP, like ESEF.
- ✅ E1.3 GATE met: committed a **minimal synthetic** fixture (`test/data/edinet/edinet-min.zip`, 830 B,
  J-GAAP, real `XBRL/PublicDoc/` layout — see the NOTICE) + a passing testset (runtests.jl
  "EDINET: offline submission-ZIP extraction (E1)", 12/12). ZIP entry layout confirmed against the FSA
  sample (not guessed).

### E2 — Discovery + authenticated fetch (`EDINETApi`)
- ▶ E2.1 `EDINETApi <: FilingSource`; `discover(::EDINETApi; date, edinet_code=nothing, doc_type="120")`
  → `/documents.json` → `FilingHandle`s (url = the `/documents/{docID}?type=1` ZIP; `xbrlFlag` filtered),
  `country="JP"`. **Implemented (grounded in the verified API); awaits live verification with a key.**
- ▶ E2.2 `fetch_filing(::EDINET, h)` downloads the ZIP and routes to the E1 parser. **Implemented.**
- ☐ E2.3 🚦 **GATE:** live probe with a free key (e.g. Toyota `E02144`); auth + list + fetch + `facts`.

### E3 — J-GAAP vocabulary (the new taxonomy) ✅ DONE (offline, no key)
- ✅ E3.1 `vocab_jpgaap.jl` — BS/IS/CF/Equity anchors under `jppfs_cor`, keyed by the standard EDINET
  prefix (stable, unlike CH → no canonicalization); registered in `_TAXONOMY_VOCABULARIES`. IFRS-adopting
  JP filers fall through to `ifrs-full`.
- ✅ E3.2 Concept local-names **verified against a real filing** (Kakaku.com FY2017, jppfs 2017-02-28) —
  `facts(f)` extracts 880 facts; the anchors classify BS/IS/CF.
- ✅ E3.3 GATE met: `jppfs_cor:Assets/NetAssets→BalanceSheet`, `NetSales/OperatingIncome/ProfitLoss→
  IncomeStatement`, `NetCashProvidedByUsedInOperatingActivities→CashFlow`; `select_statement` round-trips
  (BS 92 / IS 48 / CF 8). **EDINET extraction reuses the common XBRL extractor unchanged — thesis confirmed.**

> **Done WITHOUT the API key.** Verified across **4 real filers**: J-GAAP — Kakaku.com, Yahoo Japan, TIS
> (jppfs_cor); **IFRS** — the official FSA IFRS sample instance. Testing the IFRS filer surfaced a real
> gap and the vocab was **enriched** with it: EDINET IFRS filers tag with **`jpigp_cor:…IFRS`** concepts
> (`RevenueIFRS`/`AssetsIFRS`/`…OperatingActivitiesIFRS`), NOT bare `ifrs-full` — now classified (IFRS
> sample → BS 110 / IS 46 / CF 6). J-GAAP unchanged.
>
> The FSA sample instances (youseiushida/edinet mirror) also **confirm the ZIP layout for E1.3**:
> `S00XXXXX/XBRL/PublicDoc/jpcrp030000-asr-001_….xbrl` — `_edinet_primary_report` (matches `publicdoc/`)
> is correct. Remaining: build a committed ZIP fixture + `fetch_filing(::EDINET, zip)` test (E1.3); a
> **bank** filer (J-GAAP `OrdinaryIncome` top line — likely covered, unverified) needs a real filing; and
> E2.3 live discovery/fetch (needs the free key).

### E4 — N5 language-aware labels + validation
- ✅ E4.1 `label_map(f; lang="en"|"ja")` + a `lang`-aware `_concept_labels` (EDINET label linkbase carries
  both via `xml:lang`). DONE (offline): added `_lang_ok` (prefix match — `"en"` matches `"en-US"`; a label
  with no `xml:lang` always qualifies, so monolingual SEC/ESEF linkbases are unaffected), threaded `lang`
  through `label_map`/`facts`/`facts_json`. Default `lang=nothing` = no filter = **exact prior behaviour**
  (not defaulted to `en`, to avoid changing SEC/ESEF output). Testset "language-aware labels (E4.1, offline)"
  1/1; full suite (incl. live 31/31) green. Live ja/en selection on a real EDINET filing awaits the key.
- ☐ E4.2 **CSV oracle** (`type=5`): `facts(f)` == the EDINET CSV's values (the JP parser oracle).
- ☐ E4.3 Yahoo cross-check (`nnnn.T`); manual chapter (the EDINET placeholder already exists).
- ☐ E4.4 🚦 **GATE (run tests + commit):** report parity vs the CSV oracle; commit.

## Open questions / risks
- **ZIP entry layout** — EDINET inline-XBRL vs classic `.xbrl` under `XBRL/PublicDoc/`; the manifest may
  list several inline docs. Resolve with a real fixture (E1.3), don't guess.
- **N5 reach** — only EDINET (and DART) force multilingual labels; get the `lang` signature right once so
  DART reuses it.
- **Entity resolution** — discovery is date-based; a name/ticker/JCN → `edinetCode` index is a later nicety
  (the FSA publishes an EDINET-code list; a third-party `edinet-tools` resolves ~11k entities).
