# AlphaVantage oracle — a do-it-yourself validation source.
#
# NOTE: this file is NOT part of the EDGAR module (it is not `include`d by src/EDGAR.jl). It is a
# self-contained helper you load on demand to reassure yourself that EDGAR.jl's extraction matches an
# independent reference.
#
# What it checks: do the headline numbers EDGAR.jl extracts for the three core statements agree with
# the standardized fundamentals **AlphaVantage** reports? Balance sheet (Assets, Equity), income
# statement (Revenue, Net income) and cash flow (Operating cash flow). Like the Yahoo oracle this is
# an INDEPENDENT-DATA check (a different pipeline, not the same document), so it compares unambiguous
# totals within a 1% tolerance, concept-mapped per taxonomy.
#
# Why no dependency on the AlphaVantage.jl package: AlphaVantage is an *official, documented REST API*
# — one GET with an `apikey` query parameter returns clean JSON (`annualReports[]`). The package is a
# thin wrapper around exactly that call, so we use EDGAR's own cached fetcher instead (mirrors the
# Arelle oracle). This adds NO dependency and — crucially for the free tier's 25-calls/day limit —
# the on-disk response cache means re-running the panel costs no further calls (run `EDGAR.clean_cache()`
# to force fresh data). Contrast the Yahoo oracle, which earns its YFinance dependency because Yahoo
# has no official API (undocumented, cookie/crumb-gated endpoints worth encapsulating).
#
# Coverage: AlphaVantage is US-strong (SEC filers); fundamentals for non-US issuers are sparser, so the
# default panel is US. The free key is rate-limited (25/day, ~5/min) — set it once:
#   export ALPHA_VANTAGE_API_KEY="your-key"      # https://www.alphavantage.co/support/#api-key
#
# Usage:
#   include(joinpath(pkgdir(EDGAR), "src", "sources", "alphavantage_oracle.jl"))
#   using .AlphaVantageOracle
#   rows = AlphaVantageOracle.validate(:sec, "320193", "AAPL")   # CIK + AlphaVantage symbol
#   AlphaVantageOracle.report()                                  # run the built-in firm panel

module AlphaVantageOracle

using EDGAR, Dates, Printf
const JSON3 = EDGAR.JSON3            # not exported by EDGAR; reached through the module (no new dep)

const Row = @NamedTuple{statement::Symbol, metric::String, period_end::Union{Date,Nothing},
                        edgar::Union{Float64,Nothing}, alphavantage::Union{Float64,Nothing},
                        rel_diff::Float64, match::Bool}

isempty(strip(try EDGAR.get_user_agent() catch; "" end)) &&
    EDGAR.set_user_agent(get(ENV, "EDGAR_UA", "EDGAR.jl validation noreply@example.com"))

# A headline metric: the candidate XBRL concepts per taxonomy, the AlphaVantage field name(s), and
# which of the three statements it belongs to (:bs balance sheet, :is income statement, :cf cash flow).
struct Metric
    name::String
    usgaap::Vector{String}
    ifrs::Vector{String}
    av::Vector{String}
    statement::Symbol
end

_instant(m::Metric) = m.statement === :bs    # balance-sheet items are point-in-time

# AlphaVantage field names verified live against the INCOME_STATEMENT / BALANCE_SHEET / CASH_FLOW
# endpoints (annualReports[] string fields).
const METRICS = [
    Metric("Assets",     ["us-gaap:Assets"], ["ifrs-full:Assets"], ["totalAssets"], :bs),
    Metric("Equity",     ["us-gaap:StockholdersEquity", "us-gaap:StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"],
                         ["ifrs-full:EquityAttributableToOwnersOfParent", "ifrs-full:Equity"],
                         ["totalShareholderEquity"], :bs),
    Metric("Revenue",    ["us-gaap:Revenues", "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax"],
                         ["ifrs-full:Revenue", "ifrs-full:RevenueFromContractsWithCustomers"],
                         ["totalRevenue"], :is),
    Metric("NetIncome",  ["us-gaap:NetIncomeLoss"],
                         ["ifrs-full:ProfitLossAttributableToOwnersOfParent", "ifrs-full:ProfitLoss"],
                         ["netIncome"], :is),
    Metric("OperCashFlow", ["us-gaap:NetCashProvidedByUsedInOperatingActivities",
                            "us-gaap:NetCashProvidedByUsedInOperatingActivitiesContinuingOperations"],
                         ["ifrs-full:CashFlowsFromUsedInOperatingActivities"],
                         ["operatingCashflow"], :cf),
]

# EDGAR.jl's classified facts for a filer's latest annual filing (SEC 10-K or ESEF annual report).
# Identical to the Yahoo oracle's EDGAR side — the EDGAR extraction under test is the same regardless
# of which external reference we compare against.
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
    return nothing
end

# EDGAR.jl's (value, period_end) for a metric: consolidated (undimensioned), annual, most-recent.
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

# Fetch one AlphaVantage fundamentals statement (its `annualReports` array) via EDGAR's cached HTTP.
# Returns `nothing` on any failure — including AlphaVantage's throttle (`Note`), premium-gate
# (`Information`) and `Error Message` bodies — so a panel run degrades gracefully (the metric shows as
# "none") rather than aborting. The API key is read from ALPHA_VANTAGE_API_KEY at call time.
function _av_reports(func::AbstractString, ticker::AbstractString)
    key = strip(get(ENV, "ALPHA_VANTAGE_API_KEY", ""))
    isempty(key) && error("set ALPHA_VANTAGE_API_KEY (free key: https://www.alphavantage.co/support/#api-key)")
    url = "https://www.alphavantage.co/query?function=$func&symbol=$ticker&apikey=$key"
    body = try EDGAR.fetch_url(url) catch; nothing end
    doc = body === nothing ? nothing : (try JSON3.read(body) catch; nothing end)
    if doc === nothing || !haskey(doc, :annualReports)
        # AlphaVantage returns throttle (`Note`), premium (`Information`) and empty bodies with HTTP
        # 200, which fetch_url would otherwise cache and serve on the next run. Purge that entry so a
        # throttled call is retried fresh next time, while genuine data stays cached.
        try; p = EDGAR.cache_path_for(url); isfile(p) && rm(p); catch; end
        return nothing
    end
    return doc.annualReports
end

# The AlphaVantage value for a metric at a period end: the annual report whose fiscalDateEnding falls
# in the same calendar year as EDGAR's period end. Values are strings ("None" / "" mean missing).
function _av_metric(reports, m::Metric, pe::Date)
    reports === nothing && return nothing
    for r in reports
        fde = get(r, :fiscalDateEnding, nothing)
        fde === nothing && continue
        d = tryparse(Date, String(fde))
        (d === nothing || Dates.year(d) != Dates.year(pe)) && continue
        for k in m.av
            v = get(r, Symbol(k), nothing)
            v === nothing && continue
            s = String(v)
            (s == "None" || isempty(s)) && continue
            f = tryparse(Float64, s)
            f === nothing || return f
        end
        return nothing       # matched the year but the field was absent/None
    end
    return nothing
end

const TOL = 0.01   # 1% (AlphaVantage standardizes / rounds)

# Sliding-window rate limiter for AlphaVantage's free tier (~5 calls/minute). We record the times of
# recent *network* calls and allow a burst of up to `maxburst` within `window` seconds — so the first
# few calls fire back-to-back and only the one that would breach the burst blocks, until the oldest
# in-window call ages out. Cached calls add no timestamp, so a fully-cached re-run never blocks.
const _CALL_TIMES = Float64[]

function _ratelimit!(maxburst::Int, window::Real)
    maxburst <= 0 && return
    now = time()
    filter!(t -> now - t < window, _CALL_TIMES)
    if length(_CALL_TIMES) >= maxburst
        wait = window - (now - minimum(_CALL_TIMES))
        wait > 0 && sleep(wait)
        let n = time(); filter!(t -> n - t < window, _CALL_TIMES) end
    end
    return
end

# Fetch a statement, gating with the rate limiter first and recording the time only if the call
# actually went to the network (cache_metrics[:requests] rose).
function _paced_reports(func::AbstractString, ticker::AbstractString, maxburst::Int, window::Real)
    _ratelimit!(maxburst, window)
    before = EDGAR.cache_metrics()[:requests]
    reports = _av_reports(func, ticker)
    EDGAR.cache_metrics()[:requests] > before && push!(_CALL_TIMES, time())
    return reports
end

"""
    validate(system::Symbol, locator, ticker; maxburst=4, window=60) -> Vector{Row}

Validate EDGAR.jl's extraction against AlphaVantage for one filer, across the three statements.
`system` is `:sec` or `:esef`, `locator` is the CIK (SEC) or LEI (ESEF), and `ticker` is the
AlphaVantage symbol (e.g. `"AAPL"`; LSE symbols use a `.LON` suffix). Returns one [`Row`](@ref) per
metric (tagged `:bs`/`:is`/`:cf`): EDGAR's value, AlphaVantage's, the `rel_diff`, and whether they
`match` within 1%.

Three API calls per filer, rate-limited to a burst of `maxburst` network calls per `window` seconds
(the free tier allows ~5/minute, so the default 4-per-60s leaves margin): calls fire back-to-back
until the burst is spent, then block only as long as needed. Cached calls don't count, so re-runs are
immediate. Pass `maxburst=0` to disable pacing (e.g. a premium key with no per-minute limit).
"""
function validate(system::Symbol, locator::AbstractString, ticker::AbstractString;
                  maxburst::Int=4, window::Real=60)
    rows = Row[]
    edgar = _edgar_rows(system, locator)
    edgar === nothing && return rows
    funds = (bs = _paced_reports("BALANCE_SHEET", ticker, maxburst, window),
             is = _paced_reports("INCOME_STATEMENT", ticker, maxburst, window),
             cf = _paced_reports("CASH_FLOW", ticker, maxburst, window))
    for m in METRICS
        e = _edgar_metric(edgar, m, system === :sec)
        if e === nothing
            push!(rows, (statement = m.statement, metric = m.name, period_end = nothing,
                         edgar = nothing, alphavantage = nothing, rel_diff = Inf, match = false)); continue
        end
        reports = m.statement === :bs ? funds.bs : m.statement === :is ? funds.is : funds.cf
        a = _av_metric(reports, m, e.period_end)
        rd = (a === nothing) ? Inf : abs(e.value - a) / max(abs(a), 1)
        push!(rows, (statement = m.statement, metric = m.name, period_end = e.period_end,
                     edgar = e.value, alphavantage = a, rel_diff = rd, match = a !== nothing && rd <= TOL))
    end
    return rows
end

# Default panel (name, system, locator, ticker, jurisdiction). AlphaVantage is US-strong, so US filers.
const FIRMS = [
    ("Apple Inc.",      :sec, "320193", "AAPL", "US"),
    ("Microsoft Corp.", :sec, "789019", "MSFT", "US"),
    ("IBM",             :sec, "51143",  "IBM",  "US"),
]

const _STMT_LABEL = Dict(:bs => "BalanceSheet", :is => "IncomeStatement", :cf => "CashFlow")

"""
    report(firms = FIRMS; maxburst=4, window=60) -> Bool

Run [`validate`](@ref) over a panel of filers, print each metric's EDGAR-vs-AlphaVantage comparison
grouped by statement, and return whether there were no mismatches (metrics AlphaVantage doesn't cover
are reported but not counted against the result). `maxburst`/`window` are forwarded to
[`validate`](@ref) to pace network calls under the free tier's ~5/minute limit; a fresh full panel
therefore takes a minute or two, while cached re-runs are immediate.
"""
function report(firms = FIRMS; maxburst::Int=4, window::Real=60)
    nfail = 0
    for (name, system, locator, ticker, jur) in firms
        println("\n", jur, "  ", name, "  [", system, "]")
        rows = try validate(system, locator, ticker; maxburst = maxburst, window = window) catch e; println("   ✗ ", e); nfail += 1; continue end
        isempty(rows) && (println("   ⏭  no EDGAR data"); continue)
        for r in rows
            tag = _STMT_LABEL[r.statement]
            if r.edgar === nothing
                @printf("   [%-15s] %-12s EDGAR: (none)\n", tag, r.metric)
            elseif r.alphavantage === nothing
                @printf("   [%-15s] %-12s EDGAR %+.6g  @%s   AlphaVantage: (none)\n", tag, r.metric, r.edgar, r.period_end)
            else
                r.match || (nfail += 1)
                @printf("   [%-15s] %-12s EDGAR %+.6g   AlphaVantage %+.6g   Δ%.3f%%  %s\n",
                        tag, r.metric, r.edgar, r.alphavantage, 100r.rel_diff, r.match ? "✓" : "✗ MISMATCH")
            end
        end
    end
    @printf("\nAlphaVantage cross-check: %d mismatch(es)\n", nfail)
    return nfail == 0
end

end # module AlphaVantageOracle

if abspath(PROGRAM_FILE) == @__FILE__
    exit(AlphaVantageOracle.report() ? 0 : 1)
end
