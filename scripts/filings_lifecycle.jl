#!/usr/bin/env julia
# =============================================================================
# EDGAR.jl — Filings life-cycle workflow
#
# Walks the full cycle on a real filing (Walmart, WMT — deliberately not Apple,
# and a filing whose Balance Sheet extracts less cleanly, to exercise the code):
#
#   1. find the company's CIK
#   2. fetch its latest Form 10-Q into memory
#   3. render the fetched filing in the browser
#   4. extract the Balance Sheet
#   5. save the full 10-Q to disk (with its images)
#   6. save the extracted Balance Sheet to disk
#   7. load the saved 10-Q from disk and show it in the browser
#   8. load the saved Balance Sheet from disk and show it in the browser
#
# Run:   julia --project scripts/filings_lifecycle.jl
# Set EDGAR_OPEN=0 to skip the three browser-opening steps (headless / CI).
# Needs a SEC User-Agent: set the SEC_USER_AGENT env var, or edit the call below.
# =============================================================================
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using EDGAR

const TICKER = "WMT"
const OPEN   = get(ENV, "EDGAR_OPEN", "1") == "1"

# A SEC User-Agent is mandatory. Prefer SEC_USER_AGENT from the environment;
# otherwise set one here (replace with your own name and contact email).
haskey(ENV, "SEC_USER_AGENT") || set_user_agent("Your Name you@example.com")

# Open a saved file in the browser via EDGAR's open_filing(path), honouring the
# EDGAR_OPEN switch so the script can also run headless.
show_in_browser(path) = OPEN ? open_filing(path) :
                        (println("   (EDGAR_OPEN=0 — not opening $path)"); path)

# 1 — Find the CIK from the ticker.
row = only(cik(TICKER; by = :ticker))
println("1. CIK for $TICKER ($(row.entity)) = $(row.cik)")

# 2 — Fetch the latest Form 10-Q into memory (no disk write yet).
filing_row = first(filings_by_cik(row.cik; forms = "10-Q"))
f = fetch_filing(row.cik, filing_row.accession)
println("2. Fetched 10-Q $(f.accession): $(f.document) [$(f.kind), $(length(f.content)) bytes]")

# 3 — Render the fetched filing in the browser (throwaway temp copy + its images).
if OPEN
    open_filing(f)
    println("3. Opened the fetched 10-Q in your browser")
else
    println("3. (EDGAR_OPEN=0 — not opening the fetched 10-Q)")
end

# 4 — Extract the Balance Sheet from the filing's HTML (f.content).
sections = extract_section(f.content, ["Balance Sheet"])
balance_sheet = get(sections, "Balance Sheet", "")
isempty(balance_sheet) && error("could not locate a Balance Sheet in $(f.accession)")
has_total_assets = occursin("total assets", lowercase(balance_sheet))
println("4. Extracted Balance Sheet: $(length(balance_sheet)) chars, ",
        has_total_assets ? "contains Total Assets" : "NO Total Assets (!)")

# 5 — Save the full 10-Q to disk; this also downloads the filing's images.
outdir = joinpath(pwd(), "filings_demo")
path_10q = save_filing(f; destdir = outdir)
println("5. Saved full 10-Q to $path_10q")

# 6 — Save the extracted Balance Sheet as a small standalone HTML page.
path_bs = joinpath(outdir, "balance_sheet.html")
write(path_bs,
      """<!doctype html>
      <html><head><meta charset="utf-8">
      <title>$(row.entity) — Balance Sheet ($(f.accession))</title></head>
      <body><h1>$(row.entity) — Balance Sheet</h1>
      <pre>$(balance_sheet)</pre></body></html>
      """)
println("6. Saved Balance Sheet to $path_bs")

# 7 — Load the saved 10-Q back from disk, then show it in the browser.
reloaded_10q = read(path_10q, String)
println("7. Loaded saved 10-Q from disk ($(length(reloaded_10q)) bytes)")
show_in_browser(path_10q)

# 8 — Load the saved Balance Sheet back from disk, then show it in the browser.
reloaded_bs = read(path_bs, String)
println("8. Loaded saved Balance Sheet from disk ($(length(reloaded_bs)) bytes)")
show_in_browser(path_bs)

println("\nDone — artifacts saved under $outdir")
