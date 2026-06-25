# Yahoo Finance oracle — a do-it-yourself validation source.
#
# NOTE: this file is NOT part of the EDGAR module (it is not `include`d by src/EDGAR.jl). It is a
# self-contained helper you load on demand. It needs `YFinance` (https://github.com/eohne/YFinance.jl),
# which you add to your own environment — keeping it out of the module means EDGAR.jl gains no
# dependency on YFinance.
#
# What it checks: do the headline numbers EDGAR.jl extracts for the three core statements agree with
# the same figures reported by **Yahoo Finance**? Balance sheet (Assets, Equity), income statement
# (Revenue, Net income) and cash-flow statement (Operating cash flow). This is an *approximate* oracle
# — Yahoo serves standardized fundamentals — so it compares unambiguous totals within a 1% tolerance,
# concept-mapped per taxonomy. Unlike the Arelle oracle (same document, fact-level), this is an
# INDEPENDENT-DATA check across jurisdictions (Yahoo covers 100+ countries).
#
# Usage:
#   using YFinance                                   # add it to your environment first
#   include(joinpath(pkgdir(EDGAR), "src", "sources", "yahoo_oracle.jl"))
#   using .YahooOracle
#   rows = YahooOracle.validate(:sec, "320193", "AAPL")   # Vector of comparison rows
#   YahooOracle.report()                                  # run the built-in firm panel

module YahooOracle

using EDGAR, YFinance, Dates, Printf

const Row = @NamedTuple{statement::Symbol, metric::String, period_end::Union{Date,Nothing},
                        edgar::Union{Float64,Nothing}, yahoo::Union{Float64,Nothing},
                        rel_diff::Float64, match::Bool}

isempty(strip(try EDGAR.get_user_agent() catch; "" end)) &&
    EDGAR.set_user_agent(get(ENV, "EDGAR_UA", "EDGAR.jl validation noreply@example.com"))

# A headline metric: the candidate XBRL concepts per taxonomy, the Yahoo line-item key(s), and which
# of the three statements it belongs to (:bs balance sheet, :is income statement, :cf cash flow).
struct Metric
    name::String
    usgaap::Vector{String}
    ifrs::Vector{String}
    yahoo::Vector{String}
    statement::Symbol
end

_instant(m::Metric) = m.statement === :bs    # balance-sheet items are point-in-time

const METRICS = [
    Metric("Assets",     ["us-gaap:Assets"], ["ifrs-full:Assets"], ["TotalAssets"], :bs),
    Metric("Equity",     ["us-gaap:StockholdersEquity", "us-gaap:StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"],
                         ["ifrs-full:EquityAttributableToOwnersOfParent", "ifrs-full:Equity"],
                         ["StockholdersEquity", "TotalEquityGrossMinorityInterest", "CommonStockEquity"], :bs),
    Metric("Revenue",    ["us-gaap:Revenues", "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax"],
                         ["ifrs-full:Revenue", "ifrs-full:RevenueFromContractsWithCustomers"],
                         ["TotalRevenue", "OperatingRevenue"], :is),
    Metric("NetIncome",  ["us-gaap:NetIncomeLoss"],
                         ["ifrs-full:ProfitLossAttributableToOwnersOfParent", "ifrs-full:ProfitLoss"],
                         ["NetIncome", "NetIncomeCommonStockholders"], :is),
    Metric("OperCashFlow", ["us-gaap:NetCashProvidedByUsedInOperatingActivities",
                            "us-gaap:NetCashProvidedByUsedInOperatingActivitiesContinuingOperations"],
                         ["ifrs-full:CashFlowsFromUsedInOperatingActivities"],
                         ["OperatingCashFlow", "CashFlowFromContinuingOperatingActivities"], :cf),
]

# EDGAR.jl's classified facts for a filer's latest annual filing (SEC 10-K or ESEF annual report).
function _edgar_rows(system::Symbol, locator::AbstractString)
    if system === :sec
        fs = EDGAR.filings_by_cik(locator; forms = "10-K")
        isempty(fs) && return nothing
        return EDGAR.facts(fetch_filing(locator, fs[1].accession); classify = true)
    elseif system === :esef
        hs = discover(FilingsXBRLOrg(); lei = locator)
        isempty(hs) && return nothing
        en = filter(x -> endswith(x.url, "-en.zip"), hs)
        return EDGAR.facts(fetch_filing(isempty(en) ? first(hs) : first(en)); classify = true)
    end
    return nothing                       # :edinet / :dart not implemented yet
end

# EDGAR.jl's (value, period_end) for a metric: consolidated (undimensioned), annual, most-recent.
# Candidates are tried in order, so the first listed concept wins when a filing tags several (e.g. IFRS
# net income prefers profit attributable to owners of parent — what Yahoo reports — over total profit).
function _edgar_metric(rows, m::Metric, sec::Bool)
    nodim(r) = r.dimensions == "{}" || isempty(r.dimensions)
    for c in (sec ? m.usgaap : m.ifrs)
        cand = [r for r in rows if r.concept == c && nodim(r) && r.is_instant == _instant(m)]
        _instant(m) || (cand = [r for r in cand if r.period_start !== nothing && (r.period_end - r.period_start) > Day(300)])
        isempty(cand) && continue
        r = cand[argmax([r.period_end for r in cand])]
        return (value = r.value, period_end = r.period_end)
    end
    return nothing
end

_yahoo_fund(ticker, kind) =
    try get_Fundamental(ticker, kind, "annual", today() - Year(4), today()) catch; nothing end

function _yahoo_metric(funds, m::Metric, pe::Date)
    d = m.statement === :bs ? funds.bs : m.statement === :is ? funds.is : funds.cf
    (d === nothing || !haskey(d, "timestamp")) && return nothing
    idx = findfirst(t -> Dates.year(t) == Dates.year(pe), d["timestamp"])
    idx === nothing && return nothing
    for k in m.yahoo
        haskey(d, k) && d[k][idx] !== nothing && d[k][idx] != 0 && return Float64(d[k][idx])
    end
    return nothing
end

const TOL = 0.01   # 1% (Yahoo rounds / standardizes)

"""
    validate(system::Symbol, locator, ticker) -> Vector{Row}

Validate EDGAR.jl's extraction against Yahoo Finance for one filer, across the three statements.
`system` is `:sec` or `:esef`, `locator` is the CIK (SEC) or LEI (ESEF), and `ticker` is the Yahoo
symbol (e.g. `"AAPL"`, `"CTY1S.HE"`) — needed because a filing knows only the CIK/LEI, not the
exchange symbol. Returns one [`Row`](@ref) per metric (tagged `:bs`/`:is`/`:cf`): EDGAR's value,
Yahoo's, the `rel_diff`, and whether they `match` within 1%.
"""
function validate(system::Symbol, locator::AbstractString, ticker::AbstractString)
    rows = Row[]
    edgar = _edgar_rows(system, locator)
    edgar === nothing && return rows
    funds = (bs = _yahoo_fund(ticker, "balance_sheet"),
             is = _yahoo_fund(ticker, "income_statement"),
             cf = _yahoo_fund(ticker, "cash_flow"))
    for m in METRICS
        e = _edgar_metric(edgar, m, system === :sec)
        if e === nothing
            push!(rows, (statement = m.statement, metric = m.name, period_end = nothing,
                         edgar = nothing, yahoo = nothing, rel_diff = Inf, match = false)); continue
        end
        y = _yahoo_metric(funds, m, e.period_end)
        rd = (y === nothing) ? Inf : abs(e.value - y) / max(abs(y), 1)
        push!(rows, (statement = m.statement, metric = m.name, period_end = e.period_end,
                     edgar = e.value, yahoo = y, rel_diff = rd, match = y !== nothing && rd <= TOL))
    end
    return rows
end

# Default panel (name, system, locator, ticker, jurisdiction).
const FIRMS = [
    ("Apple Inc.",      :sec,  "320193",               "AAPL",     "US"),
    ("Microsoft Corp.", :sec,  "789019",               "MSFT",     "US"),
    ("Citycon Oyj",     :esef, "549300P8N0P6KDGTJ206", "CTY1S.HE", "EU"),
    ("Nokia Oyj",       :esef, "549300A0JPRWG1KI7U06", "NOKIA.HE", "EU"),
]

const _STMT_LABEL = Dict(:bs => "BalanceSheet", :is => "IncomeStatement", :cf => "CashFlow")

"""
    report(firms = FIRMS) -> Bool

Run [`validate`](@ref) over a panel of filers, print each metric's EDGAR-vs-Yahoo comparison grouped
by statement, and return whether there were no mismatches (metrics Yahoo doesn't cover are reported
but not counted against the result).
"""
function report(firms = FIRMS)
    nfail = 0
    for (name, system, locator, ticker, jur) in firms
        println("\n", jur, "  ", name, "  [", system, "]")
        rows = try validate(system, locator, ticker) catch e; println("   ✗ ", e); nfail += 1; continue end
        isempty(rows) && (println("   ⏭  no EDGAR data"); continue)
        for r in rows
            tag = _STMT_LABEL[r.statement]
            if r.edgar === nothing
                @printf("   [%-15s] %-12s EDGAR: (none)\n", tag, r.metric)
            elseif r.yahoo === nothing
                @printf("   [%-15s] %-12s EDGAR %+.6g  @%s   Yahoo: (none)\n", tag, r.metric, r.edgar, r.period_end)
            else
                r.match || (nfail += 1)
                @printf("   [%-15s] %-12s EDGAR %+.6g   Yahoo %+.6g   Δ%.3f%%  %s\n",
                        tag, r.metric, r.edgar, r.yahoo, 100r.rel_diff, r.match ? "✓" : "✗ MISMATCH")
            end
        end
    end
    @printf("\nYahoo cross-check: %d mismatch(es)\n", nfail)
    return nfail == 0
end

end # module YahooOracle

if abspath(PROGRAM_FILE) == @__FILE__
    exit(YahooOracle.report() ? 0 : 1)
end
