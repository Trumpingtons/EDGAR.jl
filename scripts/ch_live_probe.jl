# Live Companies House API probe (C2 step 3). Confirms the authenticated REST + Document API path
# end-to-end against the real service. Run with your key in the environment:
#
#   export COMPANIES_HOUSE_API_KEY="your-key"
#   julia --project=. scripts/ch_live_probe.jl [company_number]
#
# Defaults to a company number known to file iXBRL accounts; pass another to try it. The key is read
# from the env var by system_headers(::CompaniesHouse); this script never prints it.

using EDGAR

const NUM = length(ARGS) >= 1 ? ARGS[1] : "06150195"   # Jupiter Fund Management plc (override as needed)

haskey(ENV, "COMPANIES_HOUSE_API_KEY") || error("set COMPANIES_HOUSE_API_KEY in the environment first")

println("Discovering accounts filings for company $NUM …")
hs = discover(CompaniesHouseApi(); company_number = NUM)
println("  found $(length(hs)) accounts filing handle(s)")
isempty(hs) && (println("  (no accounts filings — try another company number)"); exit(0))

for (i, h) in enumerate(first(hs, min(3, length(hs))))
    println("  [$i] period_end=$(h.period_end)  ref=$(h.ref)")
end

h = first(hs)
println("\nFetching newest filing (ref=$(h.ref), period_end=$(h.period_end)) …")
f = fetch_filing(h)
println("  kind = $(f.kind)")

if f.kind === :pdf
    println("  → PDF/paper accounts (Companies House II territory); no iXBRL to parse.")
    exit(0)
end

rows = facts(f; classify = true)
println("  parsed $(length(rows)) classified fact(s)")
for r in first(rows, min(8, length(rows)))
    println("    ", r)
end
