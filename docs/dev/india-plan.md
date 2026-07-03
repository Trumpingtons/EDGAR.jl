# Plan — adding India (NSE / BSE, Ind-AS) as a FilingSystem

Status: **draft / living document** (reconnaissance verified; **no code written yet**). Follows the seam
established by SEC, ESEF, Companies House, EDINET and DART (see [filing-systems.md](filing-systems.md),
[dart-plan.md](dart-plan.md)). India (IN) would be the **6th `FilingSystem`**.

**This supersedes the "India MCA21 🔭 — paid + per-country multi-channel" note in filing-systems.md.**
MCA21 (the registrar) *is* paid, but that is the wrong channel: the **stock exchanges publish the
quarterly/annual financial-results XBRL keyless and machine-readable.** NSE gives an EDINET-style
discovery→XBRL seam with **zero auth key** (only a cookie bootstrap). India is a **driver**, not a watch
system.

Governing principle (unchanged): **generalize the nouns, not the verbs.** India reuses the `FilingSystem`
seam, the `FilingSource`/`discover`/`fetch_filing` seam, the jurisdiction-agnostic XBRL extractor, and —
the thesis — the **`ifrs-full` vocabulary**, reached via a **namespace-canonicalization step** (the
Companies House pattern), because Ind-AS concepts carry IFRS-identical local names under a national
namespace.

## The central finding — taxonomy (verified live 2026-07-02, Reliance FY2023-24)

Downloaded a real Ind-AS instance (`INDAS_104634_1106038_22042024074704.xml`, 83 KB, Reliance
consolidated FY ending 31-Mar-2024). Namespace census of the concept tags:

- **365 `in-bse-fin:` concept tags, 326 `xbrli:`, 43 `xbrldi:` (dimensions), 0 `ifrs-full:`.**
- The one-and-only reporting namespace is **`in-bse-fin`** =
  `http://www.bseindia.com/xbrl/fin/2020-03-31/in-bse-fin` (BSE's "Financial Results" taxonomy,
  2020-03-31 version), with sibling `-ent` / `-roles` / `-types` namespaces.
- **Local names are IFRS-identical**: `in-bse-fin:Assets`, `in-bse-fin:AdjustmentsForDepreciationAnd­
  AmortisationExpense`, `in-bse-fin:AmountOfItemThatWillBeReclassifiedToProfitAndLoss`, … — these are
  verbatim `ifrs-full` element names, re-namespaced under `in-bse-fin`.

**Contrast with Korea (DART).** K-IFRS filed under **bare `ifrs-full`**, so DART needed *no* vocab and no
canonicalization. India files the *same IFRS concepts under a national namespace*. And the classify engine
matches **by namespace, not prefix** (see `vocab_ukgaap.jl` header, `_ch_canonicalize` in
companies_house.jl). So `in-bse-fin:Assets` will **not** hit `vocab_ifrs` as-is — the namespace differs.

### DECISIONS LOCKED (2026-07-02)
- **Vocab:** Strategy **C — dedicated `vocab_indas.jl`** (a full national vocabulary keyed on the
  `in-bse-fin` namespace, mirroring `vocab_jpgaap`/`vocab_ukgaap`), NOT the canonicalize-to-ifrs-full
  path. The most explicit route; supersedes the "Recommendation: A" note below.
- **Build cadence:** proceed **I0 scaffold only** (seam so `using EDGAR` loads clean), then STOP + report.

### Vocab strategy — the design fork (decide before coding D3-analog)

| Strategy | Mechanism | Pro | Con |
|---|---|---|---|
| **A — canonicalize to ifrs-full** (recommended) | `_india_canonicalize` (mirrors `_ch_canonicalize`): rewrite `in-bse-fin`-namespace concepts whose local name exists in `ifrs-full` → the `ifrs-full` namespace, then classify unchanged | Reuses all of `vocab_ifrs`; tiny surface; matches the CH precedent exactly | Needs a coverage check: which `in-bse-fin` local names are genuine India extensions absent from `ifrs-full` (e.g. `AdjustmentsForOtherBankBalances` looks India-specific) |
| **B — local-name fallback in classify** | teach the classify engine to match on local-name when the QName misses | fully general, no per-system code | collision risk across taxonomies; changes shared core — higher blast radius |
| **C — national `vocab_indas.jl`** | a full vocab keyed on the `in-bse-fin` namespace (mirrors jpgaap/ukgaap) | explicit, no reliance on name-identity | most work; duplicates ifrs-full for concepts that are already IFRS |

**Recommendation: A**, with a small `vocab_indas.jl` **only** for the residue of genuinely India-specific
`in-bse-fin` extensions that role-based placement doesn't already bucket (verify the residue empirically,
DART-style — we almost built dead KR vocab and "verify, don't assume" caught it). Linkbases are **not
bundled** (single instance `.xml`, standard-taxonomy-only — the Companies House shape), so classification
leans on the presentation-role placement + the canonicalized concept anchors, not on a bundled linkbase.

## Access mechanics — NSE (verified live 2026-07-02, keyless)

- **Discovery API (keyless, cookie-gated):** `GET https://www.nseindia.com/api/corporates-financial-results
  ?index=equities&symbol=<SYM>&period=Annual` → a JSON **array**, one object per result filing. Requires a
  **cookie bootstrap** first (`GET https://www.nseindia.com/` with a browser `User-Agent` to mint cookies;
  then send them + a `Referer`). No API key. Reliance returned 29.6 KB / full annual history.
- **Per-filing fields (the EDINET-style seam):** each record carries
  - **`xbrl`** → a direct keyless URL `https://nsearchives.nseindia.com/corporate/xbrl/INDAS_<...>.xml`
    (the instance — our parse target),
  - **`isin`** (e.g. `INE002A01018`) — clean identity scheme,
  - **`indAs`** (`"Ind-AS New"`), **`consolidated`** (`Consolidated`/`Standalone`),
    **`audited`** (`Audited`), **`financialYear`** (`01-Apr-2023 To 31-Mar-2024`), `fromDate`/`toDate`,
    `companyName`, `broadCastDate`/`filingDate`, `period` (`Annual`/`Quarterly`).
- **XBRL fetch:** `GET` the `xbrl` URL with the same cookies + `Referer` → the raw Ind-AS instance
  (single `.xml`, linkbases NOT bundled). Verified: 83 KB, parses as XBRL.
- **Identity:** **`:isin`** (INE… codes, present in every record) is the natural primary scheme; secondary
  **`:nse_symbol`** (RELIANCE) and BSE **`:scrip_code`** (6-digit, for the BSE channel). ISIN is cleaner
  than DART's corp_code — no separate resolver ZIP needed; the API is symbol-addressed and echoes ISIN.

### BSE — the second channel (probed keyless 200; not yet mapped)

BSE has a keyless JSON API (prior-session probe returned 200; the date window was just too wide). BSE is
the taxonomy *publisher* (`in-bse-fin` is theirs), so it is the authoritative second source and the natural
cross-channel for D-later. **Not yet mapped** — the annual-report/announcement endpoint + scrip_code
addressing is an open task. NSE alone is sufficient for the initial adapter.

## Validation (oracle strategy)

No filings.xbrl.org / Arelle oracle for IN (same as KR). Instead:
- **Cross-channel:** NSE `xbrl` instance vs BSE's copy of the same filing (both publish it) — a
  same-document parser cross-check once the BSE channel is mapped.
- **Yahoo** (`RELIANCE.NS` / `.BO`) for headline-total cross-checks (`yahoo_oracle`); wire
  `_edgar_rows(:india, …)` + `YahooOracle.validate(:india, …)`. NSE tickers are `.NS`, BSE `.BO`.
- **The instance is self-checking on the primary statements:** face concepts (`Assets`, `Equity`,
  `ProfitLoss`, `CashFlows…`) are IFRS-named → once canonicalized, `select_statement` round-trips are the
  same assertion we use for ESEF/DART.
- Reminder: oracle comparisons use RAW `facts()`, not classified (sign/negatedLabel).

---

## Phases (stepped; 🚦 = hard-stop gate — pause, report, ask)

Status icons: ☐ todo · ▶ doing · ✅ done · ⏸ blocked. **Nothing coded yet — all ☐.**

### I0 — Seam: `India` system + headers (no key) ☐
- ☐ I0.1 `struct India <: FilingSystem` + `system_tag(::India)=:india`
  (filing_systems/india/india.jl); identity schemes `:isin` / `:nse_symbol` / `:scrip_code`.
- ☐ I0.2 `system_headers(::India)` → browser `User-Agent` + `Accept`; **no API key** (N3 not needed).
  The NSE cookie bootstrap is the only auth — a `_nse_session` helper mints + caches cookies (they expire;
  refresh-on-miss like DART's index self-heal). Confirm the HTTP layer keeps a cookie jar (HTTP.jl
  `cookies=true`) — **pin HTTP 1.10, never 2** (Reseau TLS breaks cross-host redirects; see memory).
- ☐ I0.3 `include` + `export India, NSEFilings, ...`; `using EDGAR` precompiles + loads clean.

### I1 — Offline parse ✅ DONE
- ✅ I1.1 `fetch_filing(::India, src)` over a single Ind-AS `.xml` instance (standard-taxonomy-only path,
  NOT the report-package reader); classic `:xbrl` filing; `_india_normalize_periods` rewrites the unreliable
  NSE context dates from each context's `DateOf…ReportingPeriod` facts. `facts()` + `narratives()` both work.
- ✅ I1.2 GATE met: `test/data/india/reliance-fy2024.xml` fixture + offline testset (15/15). Committed.

### I2 — Discovery + keyless fetch (`NSEFilings`) ✅ DONE
- ✅ I2.1 `NSEFilings <: FilingSource`; `discover(::NSEFilings; symbol, period="Annual", consolidated=true,
  audited=true)` → the results API → `FilingHandle`s (ISIN identity, url = the `xbrl` field, `toDate`
  period, country="IN", newest-first) via the pure `_nse_result_handles`. **Cookie session** (`_nse_cookies`
  /`_nse_headers` in india.jl) bootstraps past Akamai with browser NAVIGATION headers — see [[nse-akamai-session]].
- ✅ I2.2 `fetch_filing(::India, h::FilingHandle)` downloads the instance with the cookie session; routes to I1.
- ✅ I2.3 GATE met (live): discover→fetch→`facts` end-to-end on **2 fresh filers** — TCS (rev ₹2,40,893 cr)
  and Maruti (₹1,41,858 cr), both real values, ISIN identity. Offline discovery testset (11/11) +
  `nse-results-min.json` fixture committed.

### I3 — Vocab: canonicalize `in-bse-fin` → `ifrs-full` (the design fork above) ☐
- ☐ I3.1 `_india_canonicalize`: rewrite `in-bse-fin`-namespace concepts with an `ifrs-full` local-name
  twin → `ifrs-full`. **Empirically measure the residue** (in-bse-fin local names absent from ifrs-full)
  on ≥2 filers before deciding whether a `vocab_indas.jl` is needed at all (DART lesson: it may not be).
- ☐ I3.2 🚦 **GATE:** BS/IS/CF classify + `select_statement` round-trips on 2 filers (consolidated +
  standalone). Report the canonicalized-vs-residue split with counts.

### I4 — Labels + validation ☐
- ☐ I4.1 Labels: Ind-AS instances don't bundle a label linkbase → use the standard BSE taxonomy labels
  (English only; India files in English — `Latin`, no lang-split needed, simpler than DART's ko/en).
  Confirm whether `_concept_labels` needs the remote BSE taxonomy or if IFRS labels suffice post-canon.
- ☐ I4.2 Oracle: wire `_edgar_rows(:india,…)` + Yahoo `.NS`/`.BO` cross-check; map the BSE second channel
  for the same-document cross-check.
- ☐ I4.3 🚦 **GATE (run tests + commit):** offline fixture test + commit.

## Open questions / risks
- **NSE bot-defense / cookies.** NSE is aggressive with bot detection; the cookie bootstrap worked
  first-try live but may need periodic refresh + a realistic UA. Cache the jar; refresh-on-401 (don't loop).
- **Vocab fork (I3).** Strategy A (canonicalize) vs a national vocab — decide from the measured residue,
  not assumption. Local-name identity is verified for the face concepts; the long tail is unmeasured.
- **Linkbases not bundled.** Standard-taxonomy-only (CH shape). Presentation-role placement + canonical
  anchors carry classification; a remote BSE-taxonomy fetch may be needed for labels/roles — measure.
- **BSE channel unmapped.** Keyless 200 confirmed; endpoint + scrip_code addressing still to reverse.
- **Standalone vs consolidated.** Every filer files both (the API flags `consolidated`); pick per request,
  default consolidated (matches DART's `fs_div=CFS`).
- **MCA21 is the wrong door.** The registrar channel is paid; the exchange channel is free — build the
  exchange channel. (Correct filing-systems.md line 85 accordingly.)
