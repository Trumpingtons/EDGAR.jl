# EDGAR.jl Manual

Fetch company filings and financial data from the U.S. SEC
[EDGAR](https://www.sec.gov/search-filings/edgar-application-programming-interfaces)
system, and pull out the parts you care about: a filer's submissions, filings
downloaded and turned into text, named sections such as *Item 7 — Management's
Discussion*, XBRL financial facts, and full-text search across filing contents.

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/Trumpingtons/EDGAR.jl.git")
```

This installs the package and its dependencies, including `HTTP` and `JSON3` for
talking to the SEC endpoints, and the `Gumbo` and `Cascadia` packages for robust
HTML parsing. EDGAR.jl requires **Julia 1.12 or later**.

## Set a User-Agent first

The SEC requires a descriptive `User-Agent` with contact information — requests
without one are rejected with HTTP 403. Set yours once per session with your name
and a contact email:

```julia
using EDGAR
set_user_agent("Jane Doe jane@example.com")
```

If you forget, EDGAR.jl stops with a clear error before ever contacting the SEC.

**Per session.** `set_user_agent` (and `set_config`) set the User-Agent only for the
current Julia process; a new REPL or notebook kernel starts without one. To avoid
setting it every session, define the `SEC_USER_AGENT` environment variable — EDGAR.jl
reads it automatically. Put it in `~/.julia/config/startup.jl`
(`ENV["SEC_USER_AGENT"] = "Jane Doe jane@example.com"`) so every Julia session has it.

## A first look

```julia
# Apple's Central Index Key is 320193 (zero-padded to 10 digits)
filings = list_recent_filings("0000320193"; count = 5)

# Net income over time, straight from XBRL
ni = company_concept("0000320193", "us-gaap", "NetIncomeLoss")

# Search the full text of 10-K filings
hits = full_text_search("climate risk"; forms = "10-K")
```

## A quick glossary

SEC filings and their structured (XBRL) data come with their own vocabulary. The
terms that matter here:

- **CIK** — *Central Index Key*, the SEC's unique ID for a filer, zero-padded to
  10 digits (Apple → `0000320193`). Functions accept it as an integer or a string,
  with or without leading zeros (`320193` ≡ `"0000320193"`). Look one up from a
  ticker or company name with `cik`.
- **Filing** — a document submitted to the SEC, identified by an **accession
  number** and a **form type** (`10-K` annual report, `10-Q` quarterly, `8-K`
  current report, …). List a filer's filings with `list_recent_filings`.
- **XBRL** — *eXtensible Business Reporting Language*, the machine-readable format
  companies tag their financial statements in; it is what makes the numbers
  queryable rather than locked inside a document.
- **iXBRL** — *Inline XBRL*: those same tags embedded directly inside the filing's
  human-readable HTML, so one document is both readable and machine-parseable. The
  SEC has required it for financial statements since around 2019.
- **Fact** — a single reported number: one *concept*, for one *period*, in one
  *unit* (e.g. "net income for FY2023 was 96,995,000,000 USD"). `company_facts`
  returns every fact a company has reported.
- **Concept** — the *name* of a reported line item, drawn from a taxonomy (e.g.
  `NetIncomeLoss`, `Assets`, `Revenues`) — the "what is being measured".
  `company_concept` returns one concept over time for one filer.
- **Taxonomy** — a dictionary that defines concepts. The big one is **`us-gaap`**
  (US accounting standards); **`dei`** (*Document and Entity Information*) holds
  metadata about the filing itself — entity name, fiscal year-end, document type,
  shares outstanding. Others you may meet: **`srt`** (shared, common elements),
  **`ifrs-full`** (filers reporting under IFRS), and each company's own
  **extension** namespace (e.g. `aapl` for Apple-specific concepts).
- **Frame** — a cross-section: one concept, one unit, one period, across *every*
  filer that reported it (e.g. Assets in USD at the end of Q4 2022, for all
  companies). `xbrl_frames` returns a frame.
- **Unit** — the unit of measure of a fact: `USD`, `shares`, `USD/shares`
  (per-share), `pure` (a ratio), …
- **Period** — the time a fact covers, and how it is written. **Frames** use
  *calendar* periods: `CY` + year, as in `CY2022` (a full calendar year),
  `CY2022Q4` (a quarter), or `CY2022Q4I` (a single instant — note the trailing
  `I`). An **instant** is a point in time (balance-sheet items such as Assets, at
  quarter-end); a **duration** is a span (income-statement items such as Revenue).
  By contrast, **`FY`** in a company's own facts is its *fiscal* year, which need
  not match the calendar (Apple's `FY2023` ended in September 2023).

!!! note "Two things that trip people up"
    **Concept vs Fact** — a concept is the *label* (`Assets`); a fact is a concrete
    *value* of that concept for a given period and unit. **The `I` suffix** — in
    Frames a trailing `I` means an *instant*, which is why
    `xbrl_frames("us-gaap", "Assets", "USD", "CY2022Q4I")` needs it: a balance is
    measured at a moment, whereas a flow like revenue uses a plain duration code.

See [Examples](examples.md) for worked, end-to-end usage and the [API](api.md)
for the complete reference.
