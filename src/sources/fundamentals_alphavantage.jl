# AlphaVantage provider for the fundamentals oracle (see fundamentals_oracle.jl). Backend: EDGAR's own
# cached HTTP + JSON3 (no package dependency — AlphaVantage is an official, documented REST API: one GET
# with an `apikey` query parameter returns clean JSON `annualReports[]`). The on-disk response cache means
# re-running a panel costs no further calls — crucial for the free tier's 25-calls/day, ~5/min limit.
#
# Set the free key once (https://www.alphavantage.co/support/#api-key):
#   export ALPHA_VANTAGE_API_KEY="your-key"
# With no key the provider degrades gracefully — `provider_fetch` warns once and returns empty, so every
# metric shows "(none)" rather than aborting the panel. Coverage is US-strong (SEC filers); non-US
# fundamentals are sparser, so the default panel is US.

struct AlphaVantage <: FundamentalsProvider end
_provider(::Val{:alphavantage}) = AlphaVantage()
provider_name(::AlphaVantage) = "AlphaVantage"
default_scheme(::AlphaVantage) = :morningstar   # AlphaVantage serves Morningstar-style standardised fundamentals

# AlphaVantage field names (annualReports[] string fields), verified live against the INCOME_STATEMENT /
# BALANCE_SHEET / CASH_FLOW endpoints.
const AV_KEYS = Dict(
    "Assets"       => ["totalAssets"],
    "Equity"       => ["totalShareholderEquity"],
    "Revenue"      => ["totalRevenue"],
    "NetIncome"    => ["netIncome"],
    "OperCashFlow" => ["operatingCashflow"],
)
provider_concepts(::AlphaVantage, name::AbstractString) = get(AV_KEYS, name, String[])

# Sliding-window rate limiter for the free tier (~5 calls/minute). Record the times of recent *network*
# calls and allow a burst of up to `maxburst` within `window` seconds — so the first few calls fire
# back-to-back and only the one that would breach the burst blocks, until the oldest in-window call ages
# out. Cached calls add no timestamp, so a fully-cached re-run never blocks.
const _AV_CALL_TIMES = Float64[]

function _av_ratelimit!(maxburst::Int, window::Real)
    maxburst <= 0 && return
    now = time()
    filter!(t -> now - t < window, _AV_CALL_TIMES)
    if length(_AV_CALL_TIMES) >= maxburst
        wait = window - (now - minimum(_AV_CALL_TIMES))
        wait > 0 && sleep(wait)
        let n = time(); filter!(t -> n - t < window, _AV_CALL_TIMES) end
    end
    return
end

# Fetch one AlphaVantage fundamentals statement (its `annualReports` array) via EDGAR's cached HTTP.
# Returns `nothing` on any failure — including throttle (`Note`), premium-gate (`Information`) and
# `Error Message` bodies — purging that cache entry so a throttled call is retried fresh next time.
function _av_reports(func::AbstractString, ticker::AbstractString, key::AbstractString)
    url = "https://www.alphavantage.co/query?function=$func&symbol=$ticker&apikey=$key"
    body = try fetch_url(url) catch; nothing end
    doc = body === nothing ? nothing : (try JSON3.read(body) catch; nothing end)
    if doc === nothing || !haskey(doc, :annualReports)
        try; p = cache_path_for(url); isfile(p) && rm(p); catch; end
        return nothing
    end
    return doc.annualReports
end

# Fetch a statement, gating with the rate limiter first and recording the time only if the call actually
# went to the network (cache_metrics[:requests] rose).
function _av_paced(func::AbstractString, ticker::AbstractString, key::AbstractString, maxburst::Int, window::Real)
    _av_ratelimit!(maxburst, window)
    before = cache_metrics()[:requests]
    reports = _av_reports(func, ticker, key)
    cache_metrics()[:requests] > before && push!(_AV_CALL_TIMES, time())
    return reports
end

# Fetch the three statements' annualReports arrays. Three API calls per filer, rate-limited to a burst of
# 4 network calls per 60 s (the free tier allows ~5/minute); cached calls don't count, so re-runs are
# immediate. With no API key the provider degrades gracefully (warns once, returns empty).
function provider_fetch(::AlphaVantage, ticker::AbstractString)
    key = strip(get(ENV, "ALPHA_VANTAGE_API_KEY", ""))
    if isempty(key)
        @warn "AlphaVantage provider unavailable: set ALPHA_VANTAGE_API_KEY (free key: https://www.alphavantage.co/support/#api-key). Reporting metrics as (none)." maxlog=1
        return (bs = nothing, is = nothing, cf = nothing)
    end
    return (bs = _av_paced("BALANCE_SHEET",    ticker, key, 4, 60),
            is = _av_paced("INCOME_STATEMENT", ticker, key, 4, 60),
            cf = _av_paced("CASH_FLOW",        ticker, key, 4, 60))
end

# The AlphaVantage value for a metric at a period end: the annual report whose fiscalDateEnding falls in
# the same calendar year as EDGAR's period end. Values are strings ("None" / "" mean missing).
function provider_value(::AlphaVantage, reports, keys::Vector{String}, pe::Date)
    reports === nothing && return nothing
    for r in reports
        fde = get(r, :fiscalDateEnding, nothing)
        fde === nothing && continue
        d = tryparse(Date, String(fde))
        (d === nothing || Dates.year(d) != Dates.year(pe)) && continue
        for k in keys
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

# Default panel (name, system, locator, ticker, jurisdiction). AlphaVantage is US-strong, so US filers.
const ORACLE_AV_FIRMS = [
    ("Apple Inc.",      :sec, "320193", "AAPL", "US"),
    ("Microsoft Corp.", :sec, "789019", "MSFT", "US"),
    ("IBM",             :sec, "51143",  "IBM",  "US"),
]
default_firms(::AlphaVantage) = ORACLE_AV_FIRMS
