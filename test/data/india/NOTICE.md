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
