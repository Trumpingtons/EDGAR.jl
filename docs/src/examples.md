# Examples

These examples assume you have set a User-Agent (see [Home](index.md)):

```julia
using EDGAR
set_config(user_agent = "Jane Doe jane@example.com")
```

## Filings: list, download, extract

```julia
# 1. List a company's filings by CIK (Apple = 320193) as a row table
rows = filings_by_cik("0000320193"; forms = "8-K")
for f in rows[1:min(5, end)]
    println(f.filed, "  ", f.form, "  ", f.accession, "  isXBRL=", f.isXBRL)
end
profile("0000320193").entityType   # filer-level data: "operating", SIC, tickers, …

# 2. Download the most recent filing's documents into a directory
path = download_filing("0000320193", rows[1].accession; destdir = "filings")

# 3. Read the filing's HTML (the extraction functions operate on HTML)
html = parse_filing(path)

# 4. Pull out specific sections (heuristic, case-insensitive)
sections = extract_section(html, ["Item 7", "Management's Discussion"])
println(get(sections, "Item 7", "(not found)"))
```

## XBRL financial data

```julia
id = only(cik("AAPL"; by = :ticker)).cik      # "0000320193"

# Every XBRL fact a company has reported, in one document
facts = company_facts(id)

# One concept over time (net income, in USD)
ni = company_concept(id, "us-gaap", "NetIncomeLoss")
println(ni.units.USD[end].val)

# The same concept across every filer for one period
assets = xbrl_frames("us-gaap", "Assets", "USD", "CY2022Q4I")
println(length(assets.data), " filers reported Assets")
```

## Full-text search

```julia
rows = full_text_search("climate risk"; forms = "10-K")
for f in rows[1:min(5, end)]
    println(f.filed, "  ", f.form, "  ", f.entity)
end
```
