# `reliance-fy2024.xml`

A **real** NSE Ind-AS financial-results XBRL instance — Reliance Industries Limited, **consolidated**,
financial year ending **31 March 2024** — used as the offline parse fixture for the India FilingSystem
(I1, see `docs/dev/india-plan.md`). It is a public regulatory disclosure, downloaded 2026-07 from NSE's
keyless corporate-filings archive:

    https://nsearchives.nseindia.com/corporate/xbrl/INDAS_104634_1106038_22042024074704.xml

Kept **whole** (83 KB, unmodified) rather than hand-trimmed: it is a classic XBRL instance whose facts
carry `contextRef`/`unitRef` into the instance's own contexts and units, so trimming risks dangling
references — the full real instance is a guaranteed-valid, representative regression anchor.

It exercises the India FilingSystem (the 6th) end-to-end with no network: `fetch_filing(India(), path)`
building an `:xbrl` filing, the shared classic-instance extractor (`_classic_facts`), and raw
`facts(f)`. Notable properties this fixture pins:

- **Taxonomy:** a single national namespace **`in-bse-fin`**
  (`http://www.bseindia.com/xbrl/fin/2020-03-31/in-bse-fin`, BSE's Financial Results taxonomy), with
  IFRS-identical local names (`in-bse-fin:Assets`, …) and **zero** bare `ifrs-full` tags — the driver
  for the dedicated `vocab_indas.jl` (I3).
- **Identity in the instance:** the context entity `<identifier>` scheme is
  `http://www.nseindia.com/NSESymbol` with value `RELIANCE` — the NSE ticker, **not** the ISIN (the ISIN
  `INE002A01018` comes from the discovery API record, I2).
- Linkbases are **not** bundled (standard-taxonomy-only, the Companies House shape).

# `nse-results-min.json`

A **trimmed** copy of the real NSE corporate-filings *financial-results* listing for Reliance Industries
(downloaded 2026-07 from `/api/corporates-financial-results?symbol=RELIANCE&period=Annual`), used for the
offline discovery test (I2). Reduced to **four records** covering the cases the handle parser must get
right: a consolidated+audited FY2024 filing, a standalone (non-consolidated)+audited FY2024 filing, an
older consolidated FY2023 filing, and one consolidated FY2024 record with an **empty `xbrl`** field (must
be skipped). Only the fields the parser reads are kept (`consolidated`, `audited`, `isin`, `seqNumber`,
`xbrl`, `toDate`, …). It exercises `_nse_result_handles` — the pure results→[`FilingHandle`] parser that
the live `discover(NSEFilings(); …)` wraps around one cookie-gated GET — with no network.

# `nbfc-bajaj-fy2024.xml`

A **real** NSE Ind-AS results instance — **Bajaj Finance Limited**, consolidated, FY ending 31 March 2024 —
in the **NBFC** format (NSE filename prefix `NBFC_INDAS_`; the fixture keeps an `nbfc-` prefix so the
format-aware linkbase selector routes it offline). Downloaded 2026-07 via
`discover(NSEFilings(); symbol="BAJFINANCE")`. It pins that the NBFC format classifies **fully** through its
own bundled presentation linkbase (`in-bse-fin-pre-nbfc-2020-03-31.xml`) — which shares the 2020-03-31
version tag with, but differs from, the general Ind-AS linkbase.
