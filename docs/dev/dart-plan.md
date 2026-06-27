# Plan — adding DART / OpenDART (South Korea) as a FilingSystem

Status: **draft / living document** (expect iteration). Follows the seam established by SEC, ESEF,
Companies House and **EDINET** (see [filing-systems.md](filing-systems.md), [edinet-plan.md](edinet-plan.md)).
DART (KR) is the **5th `FilingSystem`** and shares almost the whole EDINET shape — it was explicitly
anticipated throughout the codebase (`:corp_code`/`:stock_code` schemes in filing_system.jl, the DART
row in filing-systems.md, the K-IFRS note in vocab_ifrs.jl, the `:dart` Yahoo stub, the manual chapter).

Governing principle (unchanged): **generalize the nouns, not the verbs.** DART reuses the `FilingSystem`
seam, the `FilingSource`/`discover`/`fetch_filing` discovery seam, the credentials registry (N3), the
**ESEF report-package reader + jurisdiction-agnostic XBRL extractor** (the OpenDART financial-statement
download is a ZIP of XBRL + linkbases, the same shape as an EDINET/ESEF package), and — the thesis — the
**`ifrs-full` vocabulary** (Korea adopted full IFRS as K-IFRS, so most concepts are bare `ifrs-full`).

## What DART forces (new) vs. reuses

| | Reuse | New |
|---|---|---|
| Discovery | `FilingSource` + `discover` + `FilingHandle` | `OpenDARTApi` source over the OpenDART REST API — **by-company OR by-date** (DART has a clean `corp_code` resolver, unlike EDINET's date-only listing) |
| Credentials (N3) | `set_credentials` / `get_credential` registry | **deviation:** OpenDART authenticates with `crtfc_key` as a **query parameter**, not a header → `system_headers(::DART)` is `[]`; a `_dart_url` helper appends the key |
| Fetch / parse | ESEF **report-package** reader (`report_package.jl`) + the XBRL extractor | DART ZIP entry layout (confirm against a real `fnlttXbrl` package — don't guess) |
| Identity | `EntityId(scheme, value)` | scheme `:corp_code` (8-digit DART code) and/or `:stock_code` (6-digit KRX) |
| Taxonomy / vocab | `classify_engine` auto-merge; **`ifrs-full`** for K-IFRS | a small KR-specific vocab only **if** real filings tag entity/dart-namespace top lines outside `ifrs-full` (verify first; likely minimal) |
| Labels | `label_map` / `_concept_labels` (N5, built for EDINET) | **reuse N5** — `xml:lang` ko/en; `label_map(f; lang="en"|"ko")` |

## Access mechanics (OpenDART — verified 2026-06 against the FSS spec + dart-fss; confirm live with a key)

- **Base:** `https://opendart.fss.or.kr/api`. **Auth:** a free **`crtfc_key`** (40 chars), passed as a
  **query parameter on every call** (register at opendart.fss.or.kr). Quota ≈ 10,000 calls/day. English
  guide mirror: engopendart.fss.or.kr.
- **Entity index (the resolver EDINET lacked):** `GET /corpCode.xml?crtfc_key=…` → a **ZIP** containing
  `CORPCODE.xml`, mapping **`corp_code`** (8-digit, the API key for a company) ↔ **`stock_code`** (6-digit
  KRX ticker, blank for unlisted) ↔ `corp_name` / `corp_eng_name` / `modify_date`. Cache it; it is the
  name/ticker → `corp_code` lookup.
- **Disclosure list:** `GET /list.json?crtfc_key=…&corp_code=…&bgn_de=YYYYMMDD&end_de=YYYYMMDD&pblntf_ty=A`
  → `{ status, message, list[] }`. Each item carries **`rcept_no`** (14-digit receipt number, the fetch
  key), `corp_code`, `stock_code`, `corp_name`, `report_nm`, `rcept_dt`, `flr_nm`. `pblntf_ty=A` =
  정기공시 (periodic disclosure — annual/half/quarter reports); filter `report_nm` for 사업보고서 (annual).
- **Financial-statement XBRL:** `GET /fnlttXbrl.xml?crtfc_key=…&rcept_no=…&reprt_code=11011` → a **ZIP of
  the financial-statement XBRL** (instance + linkbases) — our parse path. **`reprt_code`: 11011 = 사업보고서
  (annual), 11012 = half-year, 11013 = Q1, 11014 = Q3.** (Returns a zip; entry layout TBD via fixture.)
- **Full disclosure document:** `GET /document.xml?crtfc_key=…&rcept_no=…` → the whole 사업보고서 ZIP
  (dart-flavored XML/HTML). Out of scope for facts — we want the clean `fnlttXbrl` financials.
- **Structured statement API (the SEC-companyfacts analog):** `GET /fnlttSinglAcntAll.json?crtfc_key=…&
  corp_code=…&bsns_year=YYYY&reprt_code=11011&fs_div=CFS` → **pre-parsed account values** (account_nm,
  thstrm_amount, …). The DART parser **oracle** (see Validation), and an optional fast-path.

Note: the key lands in the URL (OpenDART offers no header auth), so it lands in the on-disk cache key.
Acceptable for a local cache; if it matters later, strip `crtfc_key` from `cache_path_for`'s key.

## Caching & renewal (N6 — per-system cache policy) ✅ DONE

OpenDART's document endpoints are **pathologically slow** (measured ~12 KB/s — a single `fnlttXbrl`
filing or the 100k-row `corpCode.xml` takes **minutes**; `corpCode.xml` clocked **293 s / 3.4 MB**). The
metadata `list.json` is fast (~1 s). This forced a new noun:

- **Per-system cache policy (N6).** A single global `cache_mode` is too coarse when DART is minutes-slow
  but SEC/ESEF are fast. Added `set_cache_policy(system; cache=:temporary|:persistent|:off)` (overrides
  the global per system, registry `SYSTEM_CACHE_MODE`), `effective_cache_mode(system)`, and threaded an
  optional `cache_mode` through `fetch_url` / `_get_json` / `cache_path_for` / `get_cache_dir(mode)`.
  Global default stays `:temporary`; `set_cache_policy(DART(); cache=:persistent)` makes **only** DART
  persist (slow downloads paid once, ever) while other systems stay ephemeral. DART's fetchers
  (`_dart_zip_bytes`, the DART `_get_json`) pass `effective_cache_mode(DART())`.
- **corp-code resolver — fast + cached.** Parse is a single linear `eachelement` pass (118,371 entities in
  **0.84 s**; the old per-row XPath was minutes). Parsed index persisted as a 3.57 MB TSV under DART's
  effective cache dir (in-process Ref + on-disk TSV), so it is downloaded+parsed once.
- **Renewal.** Global HTTP `cache_ttl` (24h) governs ordinary downloads. The **index** instead uses a
  jurisdiction-specific backstop TTL — default **30 days**, tunable via `dart_index_ttl!(days)` — because
  the mapping is stable (24h would re-pay the 5-min download daily). Plus a **miss-refresh**: a *ticker*
  lookup that misses re-downloads once and retries (self-heals for newly-listed firms); *name* misses
  don't (usually spelling variance). `dart_corp_code(q; refresh=true)` / `_dart_corp_index(; force=true)`
  bypass all cache layers. **Recommend `set_cache_policy(DART(); cache=:persistent)` for DART-heavy use.**

## Validation

filings.xbrl.org does **not** carry KR → **no Arelle oracle**. Instead:
- **OpenDART structured API (`fnlttSinglAcntAll`)** = the regulator's own parse of the same filing → a
  fact-level **parser oracle** (the KR analog of the EDINET CSV): our `facts(f)` must match its values.
  Strongest, free, same-document.
- **Yahoo** (KRX tickers — KOSPI `nnnnnn.KS`, KOSDAQ `.KQ`; e.g. Samsung Electronics `005930.KS`) for
  headline-total cross-checks (`yahoo_oracle`); wire `_edgar_rows(:dart, …)` + `YahooOracle.validate(:dart,…)`.
- Reminder: oracle comparisons use RAW `facts()`, not classified (sign/negatedLabel).

---

## Phases (stepped; 🚦 = hard-stop gate — pause, report, ask)

Status icons: ☐ todo · ▶ doing · ✅ done · ⏸ blocked.

### D0 — Seam: `DART` system + credentials + headers ✅ DONE (loads clean; uncommitted)
- ✅ D0.1 `struct DART <: FilingSystem` + `system_tag(::DART)=:dart` (filing_systems/dart/dart.jl);
  identity schemes `:corp_code` / `:stock_code`.
- ✅ D0.2 `system_headers(::DART)` → `[]` (DART has no auth header); the `crtfc_key` is appended to URLs by
  a `_dart_url`/`_dart_key` helper that reads the credentials registry (`set_credentials(DART(); api_key=…)`)
  or the `DART_API_KEY` / `OPENDART_API_KEY` env var, with a clear error if absent. Reuses the N3 pattern.
- ✅ D0.3 `include` + `export DART, OpenDARTApi, dart_corp_code` wired; `using EDGAR` precompiles + loads clean.

### D1 — Offline parse (mirrors EDINET E1 / CH C1)
- ▶ D1.1 `fetch_filing(::DART, src)` over a `fnlttXbrl` ZIP: `_dart_primary_report` finds the instance,
  reuses the report-package reader; `_fetch_linkbase(::DART, f, suffix)` from the bundled ZIP.
  **Implemented; unverified (awaits a real package — layout not guessed-and-locked).**
- ☐ D1.2 🚦 **GATE (fixture):** commit a minimal fixture (`test/data/dart/…`) with the **real**
  `fnlttXbrl` entry layout (confirm against an actual package — DON'T guess the layout) + a passing testset.

### D2 — Discovery + authenticated fetch (`OpenDARTApi`)
- ▶ D2.1 `OpenDARTApi <: FilingSource`; `discover(::OpenDARTApi; corp_code=nothing, stock_code=nothing,
  bgn_de/end_de, pblntf_ty="A", reprt_code="11011", annual_only=true)` → `/list.json` → `FilingHandle`s
  (url = the `fnlttXbrl` ZIP with `reprt_code`; `country="KR"`). `fetch_filing(::DART, h)` downloads +
  routes to D1. **Implemented (grounded in the verified API); awaits live verification with a key.**
- ▶ D2.2 `corp_code` resolver: `corpCode.xml` ZIP → CORPCODE.xml → name/ticker → `corp_code`, cached in
  `_DART_CORP_INDEX`; public entry `dart_corp_code(query)`. **Implemented; awaits live verification.**
- ✅ D2.3 GATE met: **live probe with a real key** — Samsung `005930` → `corp_code 00126380`, `corpCode.xml`
  resolver, `list.json` discovery (FY2023 annual, rcept 20240312000736), authenticated `fnlttXbrl` fetch +
  `facts` all verified live. Confirmed the real ZIP layout (flat, `entity<corp_code>_<date>.xbrl`, split
  `_lab-ko`/`_lab-en`). NOTE: the on-disk HTTP cache is keyed on the full URL, so the `crtfc_key` lands in
  the cache key (acceptable; noted under Access mechanics). Concurrent runs on the same URL contend on the
  cache file lock — run probes one at a time.

### D3 — K-IFRS vocabulary (mostly reuse) ✅ DONE (live; gate met)
- ✅ D3.1 Verified on **2 real filers** (Samsung FY2023 5,997 facts; SK Hynix FY2023 6,306 facts): **~80%
  of concepts are bare `ifrs-full`** (Samsung 4,735/5,997; SK Hynix 5,072/6,306); the rest are `entity…`
  extensions (~11%) and `dart`/`dart-gcd` (~10%). The K-IFRS thesis holds — **no KR vocab required**: the
  primary statements all classify through the shared `ifrs-full` vocabulary unchanged.
- ✅ D3.2 GATE met: BS/IS/CF classify and `select_statement` round-trips on **both** filers (Samsung BS
  1757 / IS 409 / CF 227; SK Hynix BS 2043 / IS 126 / CF 216; plus Equity + ComprehensiveIncome buckets).
- ✅ **Operating-income enrichment investigated → NOT needed (verified live on Samsung).** Hypothesised
  that `dart:`-namespace operating income (영업이익) would be unclassified and need a `vocab_krgaap.jl`.
  The live probe disproved it: `dart:OperatingIncomeLoss` already classifies to **IncomeStatement**, and
  many other `dart`/`entity` lines bucket correctly too — because the classify engine uses the
  **presentation-linkbase statement roles**, not concept anchors alone, so national extensions are placed
  by *where* they sit in the statement role. No KR vocab is needed at all. (We almost built dead code;
  "verify, don't assume" caught it.) Stronger result than EDINET, which did need the `jpigp` vocab add.

### D4 — N5 language-aware labels (ko/en) + validation
- ✅ D4.1 DONE (live-verified). DART splits the label linkbase per language (`…_lab-ko.xml` / `…_lab-en.xml`,
  each single-language) — unlike EDINET's one bilingual file — so `label_map(f;"lab")` grabbing the FIRST
  file then filtering by `xml:lang` returned EMPTY (the bug seen live). Fix: threaded an optional `lang`
  kwarg through `_fetch_linkbase` (forwarder + all 5 system methods; only DART acts on it, the other 4
  accept-and-ignore → byte-identical behaviour). DART's method picks `…_lab-<lang>.xml` for `suffix=="lab"`.
  Verified on Samsung: `label_map(f; lang="en")` = 1742 EN labels, `lang="ko"` = 1742 KO labels (was 0);
  `dart:OperatingIncomeLoss` → "Operating income(loss)" / "영업이익(손실)"; sanity en=non-Hangul, ko=Hangul.
  Remaining for the test suite: add `_lab-ko`/`_lab-en` to `dart-min.zip` + an offline label testset.
- ✅ D4.2 DONE (live-verified). **`src/sources/dart_oracle.jl`** — the `fnlttSinglAcntAll` structured-API
  parser oracle (standalone module, no new deps, mirrors arelle_esef_oracle). Maps `account_id`
  (`ifrs-full_Assets`→`ifrs-full:Assets`) to EDGAR's RAW fact, asserts agreement. Key subtlety: DART tags
  the consolidated FACE on `ConsolidatedAndSeparateFinancialStatementsAxis` (`ConsolidatedMember`/`SeparateMember`),
  NOT undimensioned — so a face fact = undimensioned OR single consolidation-member (no other axis/comma).
  **Samsung FY2023: 116/116 face accounts matched 100%** (BS 51, IS 18, CIS 13, CF 34). SCE 18/49 =
  informational (movements-by-component table; `fnlttSinglAcntAll` doesn't expose the column, so its
  dimensional rows map to no single face fact — an oracle-source limit, not an extraction bug). Also wired
  `_edgar_rows(:dart,…)` in yahoo_oracle.jl (normalizes ConsolidatedMember face → undimensioned for the
  shared metric picker) for the weaker Yahoo `.KS` cross-check (needs YFinance dep + live run to confirm).
- ☐ D4.3 🚦 **GATE (run tests + commit):** offline label-fixture test + commit.

## Open questions / risks
- **ZIP entry layout** — confirm the `fnlttXbrl` package's instance + linkbase naming against a real
  download before locking `_dart_primary_report` (D1.2). Don't guess.
- **Key in URL** — OpenDART has no header auth; the key lands in the cache key (note above).
- **K-IFRS vs entity extensions** — how much classifies via bare `ifrs-full` vs needs a KR vocab is an
  empirical question (D3.1); the thesis (manual) is "mostly `ifrs-full`".
- **Annual selection** — `list.json` returns all periodic disclosures; pick the 사업보고서 by `report_nm`,
  then fetch with `reprt_code=11011`.
