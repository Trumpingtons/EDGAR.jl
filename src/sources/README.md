# `src/sources/` — do-it-yourself validation oracles

Self-contained helpers to **reassure yourself that EDGAR.jl's extraction is correct** by comparing it
against independent references. They are deliberately **not part of the EDGAR module** (not `include`d
by `src/EDGAR.jl`), so they add **no dependencies** to the package and don't touch the working code —
you load them on demand. Stray `.jl` files here are ignored by the package loader.

| File | Oracle | Kind | Coverage | Extra deps |
|---|---|---|---|---|
| `arelle_esef_oracle.jl` | filings.xbrl.org **xBRL-JSON** (produced by **Arelle**, the reference XBRL processor) | *parser* check — same document, independent parser; fact-level parity | ESEF + UKSEF (EU, UK) | none (uses EDGAR's own HTTP+JSON) |
| `arelle_local_oracle.jl` | **Arelle run locally** (the reference XBRL processor, as a subprocess) | *parser* check — same document, fact-level **including dimensions** (covers the statement of changes in equity) | **any** XBRL filing — SEC (US), ESEF/UKSEF (EU/UK), KR/DART, JP/EDINET | **Arelle CLI** (external tool) |
| `yahoo_oracle.jl` | **Yahoo Finance** (via `YFinance.jl`) | *data* check — independent pipeline; headline totals within 1% | global (100+ countries) | `YFinance` |
| `alphavantage_oracle.jl` | **AlphaVantage** (official REST API) | *data* check — independent pipeline; headline totals within 1% | US-strong (SEC filers) | none (uses EDGAR's own HTTP+JSON) |

The Arelle oracle confirms we *read the filing right*; the Yahoo and AlphaVantage oracles confirm the
*numbers match the outside world*. The Arelle approach mirrors
[`ESEF.jl`](https://github.com/trr266/ESEF.jl)'s `pluck_xbrl_json` (MIT, TRR 266) — credit there.

**`arelle_esef_oracle.jl` vs `arelle_local_oracle.jl`.** Both pit EDGAR.jl against **Arelle**, the reference
XBRL processor, but differ in *who runs Arelle* and *what they can reach*. `arelle_esef_oracle.jl` fetches
Arelle's **already-published** xBRL-JSON from filings.xbrl.org, so it adds no dependency but is limited to
what that aggregator hosts (ESEF + UKSEF) and to consolidated/undimensioned facts. `arelle_local_oracle.jl`
runs **Arelle itself** (`arelleCmdLine`) on a locally downloaded package, so it needs the Arelle CLI
installed but then validates **any** XBRL filing — including jurisdictions the aggregator does **not** host
(**Korea/DART**, Japan/EDINET) *and* the ESEF/UKSEF filings `arelle_esef_oracle` covers — comparing **every**
fact *including dimensional ones*, which is what lets it validate the **statement of changes in equity**
(the per-equity-component movements table that Yahoo and OpenDART's `fnlttSinglAcntAll` cannot). It is thus
a superset of `arelle_esef_oracle`; the latter stays for the **zero-dependency** case (no Arelle install). It
handles both package shapes: a **loose** package (DART `fnlttXbrl`) is extracted and Arelle is pointed at
the instance; a formal **report package** (ESEF/UKSEF, with `META-INF/taxonomyPackage.xml`) is handed to
Arelle as a package so its catalog remaps the standard taxonomy (else the standard concepts have no schema
and values come back empty). Both oracles compare values **raw** (as-stored), never the
classified/as-presented values — which differ in sign for `negatedLabel` and cash-outflow concepts.
It handles all three filing shapes: a **loose package** (DART), a **report package** (ESEF/UKSEF), and a
**bare inline-XBRL instance** (SEC — `f.url` is the inline `.htm`, not a ZIP, so Arelle is pointed at it
directly and fetches the DTS from the Archives). Verified across jurisdictions — the five financial
statements (BS/IS/CIS/CF and the SCE) match Arelle **100%** on **SEC** (Apple 10-K), **ESEF** (Citycon,
312/312), **UKSEF** (Kainos) and **DART** (Samsung, 5997/5997); the only unconfirmed facts are a handful of
note-level *non-financial* disclosures (counts, percentages) with key-representation quirks. (EDINET needs
a complete submission package — instance + bundled taxonomy; the trimmed test fixtures lack the DTS Arelle
requires.)

Why AlphaVantage needs no package (unlike Yahoo): AlphaVantage is an official, documented REST API
(one keyed GET → clean JSON), so the oracle uses EDGAR's own cached fetcher — adding no dependency and,
since the free key allows only ~25 calls/day, letting the response cache make re-runs free. Yahoo has
no official API (cookie/crumb-gated, undocumented endpoints), so `YFinance.jl` earns its dependency.

## Running

**Arelle** (needs only EDGAR — runs in the package's own environment):

```bash
julia --project=. src/sources/arelle_esef_oracle.jl       # runs the built-in firm panel
```

```julia
include(joinpath(pkgdir(EDGAR), "src", "sources", "arelle_esef_oracle.jl"))
using .ArelleEsefOracle
rows = ArelleEsefOracle.validate("549300P8N0P6KDGTJ206"; year = 2023)  # Citycon Oyj
filter(r -> !r.match, rows)                                        # any discrepancies
```

**Local Arelle** (needs the Arelle CLI installed; found via `ARELLE_CMD`, `PATH`, or the macOS app —
covers KR/DART and the dimensional statement of changes in equity):

```julia
set_credentials(DART(); api_key = ENV["DART_API_KEY"])             # for DART discovery
include(joinpath(pkgdir(EDGAR), "src", "sources", "arelle_local_oracle.jl"))
using .ArelleLocalOracle
ArelleLocalOracle.report_dart("005930"; year = 2023)              # Samsung — per-statement, incl. SCE
f, rows = ArelleLocalOracle.validate_dart("005930"; year = 2023)  # any other XBRL filing: validate(f)
filter(r -> !r.match, rows)                                        # any discrepancies
```

**Yahoo** (needs `YFinance` in the active environment):

```bash
# one-shot in a throwaway environment:
julia -e 'using Pkg; Pkg.activate(; temp=true); Pkg.develop(path="."); Pkg.add("YFinance");
          include("src/sources/yahoo_oracle.jl"); exit(Main.YahooOracle.report() ? 0 : 1)'
```

```julia
using YFinance
include(joinpath(pkgdir(EDGAR), "src", "sources", "yahoo_oracle.jl"))
using .YahooOracle
YahooOracle.validate(:sec, "320193", "AAPL")          # CIK + Yahoo ticker
YahooOracle.report()                                  # the built-in panel
```

**AlphaVantage** (needs only EDGAR — runs in the package's own environment; set your free key first):

```bash
export ALPHA_VANTAGE_API_KEY="your-key"               # https://www.alphavantage.co/support/#api-key
julia --project=. src/sources/alphavantage_oracle.jl  # runs the built-in US panel
```

```julia
include(joinpath(pkgdir(EDGAR), "src", "sources", "alphavantage_oracle.jl"))
using .AlphaVantageOracle
AlphaVantageOracle.validate(:sec, "320193", "AAPL")   # CIK + AlphaVantage symbol
AlphaVantageOracle.report()                           # the built-in panel
```

Both default panels return/print near-exact agreement (Arelle 100% fact parity; Yahoo 0 mismatches on
the headline totals it covers). The AlphaVantage panel matches the headline totals it returns (balance
sheet verified to 0.000%); on the free key a fresh run is paced under the ~5/minute limit (a minute or
two) and then served from cache. Set a contact `User-Agent` first if you haven't:
`export EDGAR_UA="you@example.com"` (or call `set_user_agent`).
