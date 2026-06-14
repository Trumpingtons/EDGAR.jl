# Examples

These examples assume you have set a User-Agent (see [Home](index.md)):

```julia
using EDGAR
set_config(user_agent = "Jane Doe jane@example.com")
```

## Filings: list, download, extract

```julia
# 1. List a company's recent filings by CIK (Apple = 320193)
filings = list_recent_filings("0000320193"; count = 5)
for f in filings
    println(f.date, "  ", f.form, "  ", f.accession)
end

# 2. Download the most recent filing's documents into a directory
latest = first(filings)
path = download_filing("0000320193", latest.accession; destdir = "filings")

# 3. Read the filing's HTML (the extraction functions operate on HTML)
html = parse_filing(path)

# 4. Pull out specific sections (heuristic, case-insensitive)
sections = extract_section(html, ["Item 7", "Management's Discussion"])
println(get(sections, "Item 7", "(not found)"))
```

## XBRL financial data

```julia
cik = cik_for_ticker("AAPL")                  # "0000320193"

# Every XBRL fact a company has reported, in one document
facts = company_facts(cik)

# One concept over time (net income, in USD)
ni = company_concept(cik, "us-gaap", "NetIncomeLoss")
println(ni.units.USD[end].val)

# The same concept across every filer for one period
assets = xbrl_frames("us-gaap", "Assets", "USD", "CY2022Q4I")
println(length(assets.data), " filers reported Assets")
```

## Full-text search

```julia
hits = full_text_search("climate risk"; forms = "10-K")
println(hits.hits.total.value, " matching filings")
```
