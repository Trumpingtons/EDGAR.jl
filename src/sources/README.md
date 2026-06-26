# `src/sources/` — do-it-yourself validation oracles

Self-contained helpers to **reassure yourself that EDGAR.jl's extraction is correct** by comparing it
against independent references. They are deliberately **not part of the EDGAR module** (not `include`d
by `src/EDGAR.jl`), so they add **no dependencies** to the package and don't touch the working code —
you load them on demand. Stray `.jl` files here are ignored by the package loader.

| File | Oracle | Kind | Coverage | Extra deps |
|---|---|---|---|---|
| `arelle_oracle.jl` | filings.xbrl.org **xBRL-JSON** (produced by **Arelle**, the reference XBRL processor) | *parser* check — same document, independent parser; fact-level parity | ESEF + UKSEF (EU, UK) | none (uses EDGAR's own HTTP+JSON) |
| `yahoo_oracle.jl` | **Yahoo Finance** (via `YFinance.jl`) | *data* check — independent pipeline; headline totals within 1% | global (100+ countries) | `YFinance` |
| `alphavantage_oracle.jl` | **AlphaVantage** (official REST API) | *data* check — independent pipeline; headline totals within 1% | US-strong (SEC filers) | none (uses EDGAR's own HTTP+JSON) |

The Arelle oracle confirms we *read the filing right*; the Yahoo and AlphaVantage oracles confirm the
*numbers match the outside world*. The Arelle approach mirrors
[`ESEF.jl`](https://github.com/trr266/ESEF.jl)'s `pluck_xbrl_json` (MIT, TRR 266) — credit there.

Why AlphaVantage needs no package (unlike Yahoo): AlphaVantage is an official, documented REST API
(one keyed GET → clean JSON), so the oracle uses EDGAR's own cached fetcher — adding no dependency and,
since the free key allows only ~25 calls/day, letting the response cache make re-runs free. Yahoo has
no official API (cookie/crumb-gated, undocumented endpoints), so `YFinance.jl` earns its dependency.

## Running

**Arelle** (needs only EDGAR — runs in the package's own environment):

```bash
julia --project=. src/sources/arelle_oracle.jl       # runs the built-in firm panel
```

```julia
include(joinpath(pkgdir(EDGAR), "src", "sources", "arelle_oracle.jl"))
using .ArelleOracle
rows = ArelleOracle.validate("549300P8N0P6KDGTJ206"; year = 2023)  # Citycon Oyj
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
