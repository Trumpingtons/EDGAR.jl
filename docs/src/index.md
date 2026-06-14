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
without one are rejected with HTTP 403. Set yours once per session:

```julia
using EDGAR
set_config(user_agent = "Jane Doe jane@example.com")
```

## A first look

```julia
# Apple's Central Index Key is 320193 (zero-padded to 10 digits)
filings = list_recent_filings("0000320193"; count = 5)

# Net income over time, straight from XBRL
ni = company_concept("0000320193", "us-gaap", "NetIncomeLoss")

# Search the full text of 10-K filings
hits = full_text_search("climate risk"; forms = "10-K")
```

See [Examples](examples.md) for worked, end-to-end usage and the [API](api.md)
for the complete reference.
