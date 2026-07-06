# Plan — adding Russia (RFSD → RAS) as a FilingSystem, route 1

Status: **draft / living document** (expect iteration). Russia is the **9th `FilingSystem`**. Recon is
complete and written up in the manual (`\chapter{Russia: MOEX, CBR and e-Disclosure}`, `sys:russia`).
The recon outcome fixed **two routes**: **route 1 = RFSD → RAS facts** (this plan) and **route 2 = CBR bank
Forms 101/102** (a later, separate plan). Route 1 is chosen for the MVP because it reaches validated,
cross-footed facts with the least new code and the most reuse of the structured-fact model.

Governing principle (unchanged): **generalize the nouns, not the verbs.** Russia reuses the `FilingSystem`
seam, the `FilingSource`/`discover`/`fetch_filing` discovery seam, the credentials registry (N3, though
Russia needs no key), the `Filing`/`facts`/`FactRow` fact model, and the `classify_engine` statement-type
model. It adds exactly one genuinely new idea (below).

## The central finding — the "filing" is a dataset row, not a document

Every prior system fetches a **document per issuer** (an accession ZIP, an iXBRL file, an annual-report PDF)
and parses it. Russia route 1 does not: the facts arrive **already structured and pre-mapped** as the
**RFSD** — a firm-level Parquet collection of the whole non-financial universe's unconsolidated RAS
statements. So:

- **"Fetch a filing" becomes a dataset query.** A "filing" is one **`(inn, year)` row**; `fetch_filing`
  is a `SELECT` from the year-partitioned Parquet, not an HTTP document GET.
- **No PDF extraction, no XBRL parse, no label vocab.** The **187 numeric `line_XXXX` OKUD codes** *are*
  the taxonomy (fixed by regulation); classification is a static code→concept map, not label matching.
- **DuckDB is already a dependency** (`Project.toml`, `EDGARDuckDBExt`) — it reads Parquet natively with
  column projection + predicate pushdown, and can range-read remote HuggingFace files over `httpfs`. So the
  whole data backend needs **zero new deps**.
- **Identity via MOEX ISS** (open, keyless): name/ticker → `emitent_inn` → the RFSD row key. MOEX plays the
  role NSE played for India — it turns a name into the INN that keys the facts.

This is the first `FilingSystem` whose `Filing.kind` is a **structured row** (proposed `:ras`), joining
`:xbrl` / `:ixbrl` / `:html` / `:pdf` in the `facts(f)` dispatch (`extract_xbrl.jl:582`).

## What RFSD forces (new) vs. reuses

| | Reuse | New |
|---|---|---|
| Seam | `struct S <: FilingSystem`, `system_tag`, `system_headers` | `Russia` + `system_tag(::Russia)=:russia`; `system_headers` = browser UA (no key — MOEX & RFSD both open) |
| Discovery | `FilingSource` + `discover` + `FilingHandle` | `RFSDFilings` source, **two query modes**: *point* (name/ticker→INN via MOEX, or direct INN) **and** *population* (a cohort by sector/region/legal-form/ownership/age), both crossed with the `year` partition |
| Fetch | `fetch_filing(::Russia, h)` returns a `Filing` | fetch = **DuckDB query** of the `year=Y` partition `WHERE inn=…` → a `Filing(kind=:ras)` carrying the firm-year row(s) |
| Parse / facts | `facts(f)` dispatch on `f.kind`; `FactRow`; `classify_engine` | `_rfsd_facts(f)` — map the row's `line_XXXX` cells → `FactRow`s (the non-XBRL, non-PDF structured path) |
| Taxonomy / vocab | statement-type model | `vocab_ras` — a **numeric OKUD code map** (`line_1600`→total assets, `line_2110`→revenue), NOT a label vocab |
| Data backend | **DuckDB** (already a dep) | RFSD partition acquisition + a persistent local cache; DuckDB local query (remote `httpfs` as fallback) |
| Validation | fresh-filer rule; cross-foot | internal `line_1600 = line_1700` (+ the shipped `articulated` flag); RAS-parent spot-check (NOT Yahoo IFRS) |

## Data & access mechanics (verified 2026-07-05 from the dev env)

### RFSD (route-1 facts source)
- **`irlspbru/RFSD` on HuggingFace** (Zenodo DOI `10.5281/zenodo.14622208`), **CC-BY-4.0**. Apache Parquet,
  **year-partitioned** `year=2011 … year=2024` (`year` is the Hive partition key, not a row column).
- **Size:** ~7.4 GB total; **~550 MB per year** (2024 = 552 MB). Per-issuer lookup = column-projected,
  INN-filtered read of one partition — a tiny slice, not a scan.
- **Schema:** **213 columns** = id/meta + **187 `line_XXXX` float64** statement lines. Key id/meta columns:
  - `inn` (**join key**), `ogrn`, `okpo`, `okved` / `okved_section` (industry), `okopf` (legal form),
    `region`, `creation_date` / `dissolution_date`, `lon` / `lat`.
  - **Quality/eligibility flags (respect these):** `eligible`, `filed`, `imputed`, `simplified`,
    `articulated` (statements cross-foot), `totals_adjustment`, `outlier`, `financial`. → filter to
    `filed & eligible & !outlier`; prefer `articulated`; surface `imputed`/`simplified` as provenance.
- **Refresh:** annual, late July / early August; current **v2.0.3**. Descriptive dict shipped at
  `aux_data/descriptive_names_dict.csv` (`line_2110`→`B_revenue`-style names) — a naming aid; our map is
  code→our concept model.
- **Acquisition (decide in R1):** **(a)** download-once per year to a persistent cache
  (`~/EDGAR-Reports/rfsd/year=YYYY/part-0.parquet`) then DuckDB **local** query — deterministic, offline,
  recommended default; **(b)** DuckDB `httpfs` **remote** range-read of the HF URL for one-off lookups
  (needs `INSTALL httpfs; LOAD httpfs;` — confirm availability/CI).

### MOEX ISS (identity resolver — open, keyless)
- `GET https://iss.moex.com/iss/securities.json?q=<name|ticker>&limit=N` → `securities.data` rows with
  columns incl. `secid`, `isin`, `emitent_id`, **`emitent_inn`**, `emitent_title`, `is_traded`,
  `primary_boardid`. Take `emitent_inn` for the RFSD join. No key, no cookie.
- Caveat: MOEX resolves **listed** names only. Non-listed firms need a name→INN path (EGRUL/DaData) — out
  of MVP scope; the MVP also accepts a **direct INN**.

### Query axes — RFSD is queryable as a population, not just a firm (verified against the 26 dimension cols)

RFSD is a firm-level **panel** (~56.6M firm-year rows, 2011–2024; one row per `(inn, year)`), so `discover`
exposes **two modes**, both crossed with the `year` partition:

- **Point query** — one firm: `inn` (primary; the FNS/MOEX key), or `ogrn` / `okpo`, or a name/ticker
  resolved to INN via MOEX. Returns that firm's firm-year row(s) — the `FilingSystem` fetch path.
- **Population query** — a cohort by any of the **dimension** columns (the 187 `line_XXXX` cells are the
  *measures* read off the cohort). No prior document-fetch system can do this — it selects an *economy*.

| Axis | RFSD column(s) | Selects |
|---|---|---|
| Firm (point) | `inn`, `ogrn`, `okpo` | one firm's firm-year rows |
| Period | `year` (partition), `creation_date`, `dissolution_date`, `age` | reporting year; age cohorts |
| Industry | `okved`, `okved_section` | economic-activity class (OKVED = NACE Rev.2-compatible) |
| Legal form | `okopf` | LLC / JSC / PJSC … |
| Ownership | `okfc`, `okogu` | form of ownership (state/private/foreign/mixed); state-authority type |
| Geography | `region`, `region_taxcode`, `oktmo`, `lon`/`lat` | oblast, tax-region, municipality, or point |

**Quality flags are predicates, not axes:** default a sound population to `filed & eligible & !outlier`,
prefer `articulated`, surface `imputed` / `simplified` as provenance, use `financial` to confirm the sector's
absence. DuckDB expresses all of this as one `WHERE` over the partition (pushdown on the projected columns).

Documented in the manual at `sec:russia-axes` (Table `tab:russia-axes`).

### OKUD line-code map (the "taxonomy")
- `line_1xxx` = balance sheet (1100 non-current assets, 1200 current assets, **1600 total assets**, 1300
  equity, 1400 long-term liab, 1500 short-term liab, **1700 total liab+equity**).
- `line_2xxx` = income statement (**2110 revenue**, 2120 COGS, 2200 operating profit, 2300 pre-tax,
  **2400 net profit**). `line_3xxx` = equity changes; `line_4xxx` = cash flow; `line_6xxx` = targeted funds.
- Map is **static and numeric** — fixed by the OKUD 0710001/0710002 forms; no per-filing label resolution.

## Validation (oracle strategy)

1. **Internal cross-foot** — `line_1600 == line_1700` (balance) and revenue→net-profit articulation. RFSD's
   **`articulated` flag pre-marks** rows whose statements tie out; the testset asserts our extracted
   `FactRow`s reproduce it on fixtures.
2. **RAS-parent spot-check** — for a few **listed non-financial** names (resolve via MOEX), compare RFSD's
   `inn` figures to that legal entity's **published RAS annual report** (e-disclosure agency / company IR).
   **Do NOT benchmark against Yahoo/MOEX headline figures** — those are **consolidated IFRS** for the group,
   a different entity scope than RFSD's **unconsolidated RAS parent**. Document this prominently (the Russia
   analogue of the India "Yahoo caveats" §).
3. **Fresh-filer rule** — validate on new INNs each pass; never recycle one named example.

## Phases (stepped; 🚦 = hard-stop gate — pause, report, ask)

### R0 — Seam: `Russia` system + headers (no key) ✅ DONE
- ✅ R0.1 `struct Russia <: FilingSystem`; `system_tag(::Russia)=:russia` (`src/filing_systems/russia/russia.jl`).
- ✅ R0.2 `system_headers(::Russia)` → browser `User-Agent` + `Accept` + `Accept-Language` (MOEX/HF want a
  UA; **no API key**). Constants `_RUSSIA_UA`, `_MOEX_ISS_BASE`.
- ✅ R0.3 `include` (after HKEX, before Generic) + `export Russia` in `src/EDGAR.jl`. **🚦 GATE met:**
  `using EDGAR` precompiles clean (5.4 s); `Russia()` constructs, `system_tag`→`:russia`, headers keyless,
  `Russia <: FilingSystem`, exported unqualified. (`RFSDFilings` export lands in R2.)

### R1 — Offline parse: RFSD row → facts ✅ DONE
- ✅ R1.1 Live schema confirmed via DuckDB `httpfs` (range-read of the remote HF parquet — **works**, no
  full download): `inn`/`ogrn`/`okved` VARCHAR, `line_*` + flags DOUBLE. Values are in **thousands of
  rubles** (Gazprom FY2023 `line_1600` = 2.635e10 тыс = 26.3T RUB, matches reality).
- ✅ R1.2 **Payload shape decided:** `Filing(kind=:ras)`, `content` = JSON `{inn, year, okved, …, flags,
  lines:{line_XXXX=>value}}`. `_rfsd_facts` (in `russia.jl`) parses it → one `Fact` per non-null line,
  **×1000 → RUB** (`decimals=-3`), instant for `line_1xxx` / duration otherwise; `:ras` branch added to
  `facts()` dispatch (`extract_xbrl.jl`). No DuckDB/network at parse time (fetch is R2).
- ✅ R1.2b Fixtures: **4 real FY2023 rows** (Gazprom, Magnit, Lukoil, Tatneft) in `test/data/russia/`,
  authored via DuckDB `httpfs`; INNs resolved through MOEX ISS. Small JSON, not the 550 MB partition.
- ☐ R1.3 Acquisition (a) download-once vs (b) remote `httpfs`: **deferred to R2** (fetch concern). httpfs
  confirmed working; leaning download-once + persistent cache.
- ✅ R1.4 **🚦 GATE met:** `facts(f)` on all 4 fixtures **cross-foots** (`line_1600 ≈ line_1700` in RUB),
  period types correct (BS instant @31 Dec; P&L duration), magnitudes correct, all `articulated=1`. Offline
  `@testset "Russia: RFSD structured-row facts (R1, offline)"` added to `runtests.jl`; gate verified via the
  equivalent offline run (full suite not run — house rule).

### R2 — Discovery + fetch (`RFSDFilings` + MOEX) ✅ DONE (point query)
- ✅ R2.1 `RFSDFilings <: FilingSource` (`russia/discovery.jl`). `discover(::RFSDFilings; inn|name|ticker,
  year=RFSD_LATEST_YEAR)` — the **point** path: `name`/`ticker` → INN via the open MOEX ISS
  `securities.json` resolver (`_moex_resolve_inn`, exact-ticker-wins), or a direct `inn`; returns one
  `FilingHandle(EntityId(:inn,…), url=partition, period_end=Dec 31)`. The point path is HTTP-only (no DuckDB).
- ✅ R2.2 `fetch_filing(::Russia, h)` reads the `(inn, year)` row via DuckDB and wraps it as an `:ras`
  `Filing` (JSON content in the R1 shape). DuckDB is a **weakdep**: the query `EDGAR._rfsd_query(url, inn,
  year)` lives in `EDGARDuckDBExt` (installs/loads `httpfs`, so the remote HF parquet is range-read with
  **no download**); the core stub is a `_rfsd_query(args...)` catch-all (strictly less specific, so the ext
  *adds* rather than *overwrites* — the `to_duckdb` pattern; a same-signature stub broke precompilation).
- ✅ R2.3 **🚦 GATE met (live):** discover→fetch→`facts` on fresh non-financial filers — NLMK, PhosAgro,
  MTS, Aeroflot, Rosneft·Severstal·Surgut(empty, see below), + direct-INN Gazprom; all present ones
  cross-foot. `year=2024` also works. Live testset added to `runtests.jl` (RUN_NETWORK).

**Finding — the GIR BO sanctioned-firm coverage gap (verified 2026-07-06).** Some large issuers (Rosneft,
Surgutneftegas, Severstal) return **0 facts**: their RFSD row exists but `filed=0`, no `line_*`. Not a bug
(single row per INN; not a `LIMIT 1` artefact). The break is **exactly at 2018→2019** — the Rosstat→GIR BO
source switch: full RAS data ≤2018, nothing from 2019. Confirmed by the RFSD authors: strategic companies
(1,133 by end-2023) were authorised **not to disclose** from FY2018 and are *"retrospectively excluded from
the FNS API after 2018"* (Bondarkov, Ledenev & Skougarevskiy 2025; README cites Gazprom/Novatek examples).
So it is a **source-side** gap, faithfully reflected by RFSD, detectable via `filed=0`. Documented in the
manual (coverage-caveat paragraph + References, Econometrica style).

### R2b — Population discover (cohort by dimension axis) ✅ DONE
- ✅ R2b.1 `discover(::RFSDFilings; okved|okved_section|okopf|okfc|okogu|region|region_taxcode|oktmo, year,
  filed=true, eligible=true, outlier=false, limit=100)` — the **population** path. Unlike the point path
  it must scan the parquet to enumerate the cohort, so it needs DuckDB: the weakdep `_rfsd_discover(url,
  dims, preds, limit)` (ext) runs **one** `SELECT inn … WHERE <dim=code> AND <predicates> LIMIT n` and
  returns the matching INNs → `Vector{FilingHandle}`. Point identity and population axes are mutually
  exclusive (`ArgumentError`); hitting `limit` fires a `@warn` (no silent cap).
- ✅ R2b.2 Predicates default to a sound population (`filed & eligible & !outlier`) — which also **excludes
  the withheld strategic firms** (Rosneft `filed=0` is absent from its own crude-oil `okved=06.10` cohort,
  asserted live). Dimension keys come from a fixed allow-list (safe column identifiers); values are escaped.
- ✅ R2b.3 **🚦 GATE met (live):** `okved=46.71` → a 15-firm cohort; a member fetches and cross-foots; point
  path intact; guards fire. Live testset added (RUN_NETWORK). *Note: cohort listing is one scan; fetching
  all N members is N point queries — a batch-fetch / download-once cache is the future optimisation for
  large cohorts (still noted in R1.3).*

### R2c — Bulk: batch fetch + download-once / local partitions ✅ DONE
- ✅ R2c.1 **Batch fetch** `fetch_filing(::Russia, hs::Vector{FilingHandle})` — reads a whole cohort in
  **one** scan per year (weakdep `_rfsd_query_many`: `SELECT * WHERE inn IN (…)`), returning one `:ras`
  `Filing` per handle that has a row. A generic `fetch_filing(hs)` entry was added in core (default =
  per-handle; Russia overrides). Live: an 8-firm `okved=46.71` cohort → 8 filings, **8/8 cross-foot**, and
  **batch == point** (identical facts).
- ✅ R2c.2 **Local / cached partitions.** `_rfsd_partition(year)` resolves **local → cache → remote**, so
  point / population / batch reads all use a local parquet when present (DuckDB reads local paths with no
  httpfs). `set_rfsd_local(dir)` points at an existing dataset; `set_rfsd_cache_dir(dir)` sets the cache
  (default `~/EDGAR-Reports/rfsd/`); `rfsd_download(year)` COPYs a partition once (DuckDB `COPY` of the
  remote parquet → local, **no extra HTTP dep**). Handles keep the canonical remote URL as identity;
  fetch re-resolves to local at read time (so download-anytime works).
- Resolves the R1.3 acquisition fork: **both** (a) download-once and (b) remote httpfs are supported, with
  remote the zero-config default and local/cache the bulk fast path.

### R3 — Classification: `vocab_ras` (OKUD code map) ✅ DONE
- ✅ R3.1 `vocab_ras.jl` — `_ras_statement(code)` assigns a statement to **every** code by its OKUD leading
  digit (1xxx→BalanceSheet, 2xxx→IncomeStatement, 3xxx→Equity, 4xxx→CashFlow; 6xxx targeted-funds left
  unclassified), and `_RAS_LABELS` gives English labels for the headline lines (`ras_label`, exported).
  `_rfsd_facts` now fills `statement`/`statements` under `classify` and `label` under `labels`. No new
  architecture, no network — a static numeric map (the simplest of the national vocabs).
- ✅ R3.2 **🚦 GATE met (offline):** on the Gazprom fixture, `classify=true` gives line_1600→BalanceSheet,
  2110→IncomeStatement, 4300→CashFlow; `labels=true` gives "Total assets"/"Revenue"; `select_statement(…,
  "BalanceSheet")` returns 37 rows that **cross-foot**; only the 23 `line_6xxx` targeted-funds codes stay
  unclassified. Offline testset added (`Russia: vocab_ras classification (R3, offline)`).

### R4 — Validation + quality flags + benchmark caveats ✅ DONE (validation); benchmark caveat = R5/manual
- ✅ R4.1 **Cross-foot** validated across all fixtures (R1/R3) — `line_1600 = line_1700`, matching the
  `articulated` flag. **Magnitude anchor** (externally grounded, non-circular): Gazprom FY2023 RAS-parent
  revenue **5.62 T ₽** and net profit **695.57 bn ₽** match the figures Gazprom published under РСБУ in
  Mar-2024 (Reuters/Interfax) — confirming our ×1000→RUB scaling and sign handling.
- ✅ R4.2 **Author-flagged anomalies excluded by default** (user decision). The RFSD authors manually flag
  ~436 firms / 1,130 firm-years as anomalous (`outlier=1`, e.g. revenue 8–26× Gazprom) and recommend
  excluding them. `fetch_filing(::Russia, …)` now DROPS `outlier=1` rows by default — point → `error`,
  batch → skip + `@info` — overridable with `allow_outliers=true`; population `discover` already filters
  them in SQL. `rfsd_flags(f)` (exported) exposes `outlier`/`articulated`/`filed`/`eligible`/`imputed`/
  `simplified`/`financial`. Offline testset (flags + predicate) + live testset (end-to-end exclusion).
  Verified live: outlier INN 0277125521 → point errors, `allow_outliers` admits, batch drops.
- ☐ R4.3 The **RAS-unconsolidated vs IFRS-consolidated** benchmark caveat (why Yahoo/MOEX ≠ RFSD) is
  documentation — belongs in the manual (R5), not code. No market oracle is wired (unlike IFRS jurisdictions).

### R5 — Manual worked example + polish ☐
- ☐ R5.1 A runnable `julia>` example (name → MOEX INN → RFSD facts → cross-foot) in the Russia chapter.
- ☐ R5.2 Retrieving-filings section for Russia mirroring the HK/India `\section{Retrieving…}`.

## Open questions / risks

- **Name→INN for non-listed firms.** MOEX covers listed names only; the broad universe needs EGRUL/DaData.
  MVP: direct INN + listed-via-MOEX; note the gap.
- **Scope mismatch.** RFSD = unconsolidated RAS parent; market data = consolidated IFRS. Benchmark against
  published RAS, not Yahoo. (Biggest correctness trap.)
- **`financial` flag / eligibility.** Confirm financials are truly absent (RFSD excludes them by law); treat
  `financial==1` rows, if any, as out-of-scope.
- **DuckDB `httpfs`.** Remote range-read needs the extension; confirm it installs in the dev env + CI, else
  default to download-once (a).
- **HF reachability from CI.** HF reachable from the dev env (verified); confirm headless/CI runs (else ship
  the small fixture only and treat live RFSD pulls as opt-in, like DART's slow endpoints).
- **`year` is a Hive partition**, not a column — the reader must expose it (DuckDB `hive_partitioning=1`).
- **Route 2 (CBR banks)** is deliberately deferred to a separate plan; nothing here blocks it.
