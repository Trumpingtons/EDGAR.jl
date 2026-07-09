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
    india::Vector{String}     # India: in-capmkt (Integrated Filing) then in-bse-fin (old feed) — same local names
    china::Vector{String}     # China: cas: label-derived concepts from the PDF path (extract_cas_pdf)
    yahoo::Vector{String}
    statement::Symbol
end

_instant(m::Metric) = m.statement === :bs    # balance-sheet items are point-in-time

# India note (see the india-nse-xbrl-quirks memo / manual §13.5): net income is the OWNERS-OF-PARENT
# figure Yahoo reports (not ProfitLossForPeriod, which includes minority interest); revenue is
# RevenueFromOperations (which for some filers carries a small excise/GST definitional gap vs Yahoo —
# an approximate check, hence the 1% tolerance may flag those). Concepts are listed for BOTH India
# taxonomies (in-capmkt current, in-bse-fin old); the same-local-name pairs are tried in order.
# China note: `cas:` concepts come from the PDF label path (vocab_cas). Net income prefers the
# parent-attributable figure (归属于母公司股东的净利润) Yahoo reports, falling back to total 净利润 (banks,
# where minority interest is negligible). Revenue is 营业收入 (cas:Revenue), then 营业总收入 (cas:TotalRevenue).
# Germany note: German consolidated reports go through the shared IFRS PDF path (ifrs-full concepts), so the
# IFRS candidate lists apply. Two APPROXIMATE gaps are expected (Yahoo standardises), like India's revenue:
# Siemens' reported Umsatzerlöse (€77.8bn) exceeds Yahoo's standardised revenue (~€74.9bn, continuing-ops);
# Volkswagen's net income attributable to VW AG shareholders (€16.0bn, what the metric selects) differs from
# Yahoo's standardised net income (~€16.5bn). The unambiguous totals — Assets, Equity, operating cash flow —
# match to well within 1%.
const METRICS = [
    Metric("Assets",     ["us-gaap:Assets"], ["ifrs-full:Assets"],
                         ["in-capmkt:Assets", "in-bse-fin:Assets"], ["cas:Assets"], ["TotalAssets"], :bs),
    Metric("Equity",     ["us-gaap:StockholdersEquity", "us-gaap:StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"],
                         ["ifrs-full:EquityAttributableToOwnersOfParent", "ifrs-full:Equity"],
                         ["in-capmkt:EquityAttributableToOwnersOfParent", "in-capmkt:Equity",
                          "in-bse-fin:EquityAttributableToOwnersOfParent", "in-bse-fin:Equity"],
                         ["cas:EquityAttributableToParent", "cas:Equity"],
                         ["StockholdersEquity", "TotalEquityGrossMinorityInterest", "CommonStockEquity"], :bs),
    Metric("Revenue",    ["us-gaap:Revenues", "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax"],
                         ["ifrs-full:Revenue", "ifrs-full:RevenueFromContractsWithCustomers"],
                         ["in-capmkt:RevenueFromOperations", "in-bse-fin:RevenueFromOperations"],
                         ["cas:TotalRevenue", "cas:Revenue"],   # Yahoo TotalRevenue = 营业总收入; banks lack it → 营业收入合计
                         ["TotalRevenue", "OperatingRevenue"], :is),
    Metric("NetIncome",  ["us-gaap:NetIncomeLoss"],
                         ["ifrs-full:ProfitLossAttributableToOwnersOfParent", "ifrs-full:ProfitLoss"],
                         ["in-capmkt:ProfitOrLossAttributableToOwnersOfParent", "in-capmkt:ProfitLossForPeriod",
                          "in-bse-fin:ProfitOrLossAttributableToOwnersOfParent", "in-bse-fin:ProfitLossForPeriod"],
                         ["cas:ProfitAttributableToParent", "cas:ProfitLoss"],
                         ["NetIncome", "NetIncomeCommonStockholders"], :is),
    Metric("OperCashFlow", ["us-gaap:NetCashProvidedByUsedInOperatingActivities",
                            "us-gaap:NetCashProvidedByUsedInOperatingActivitiesContinuingOperations"],
                         ["ifrs-full:CashFlowsFromUsedInOperatingActivities"],
                         ["in-capmkt:CashFlowsFromUsedInOperatingActivities", "in-bse-fin:CashFlowsFromUsedInOperatingActivities"],
                         ["cas:NetCashFlowsFromOperating"],
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
    elseif system === :dart
        # `locator` is a 6-digit KRX stock_code or an 8-digit corp_code; take the most recent annual report.
        cc = occursin(r"^\d{6}$", strip(locator)) ? EDGAR.dart_corp_code(locator) : String(strip(locator))
        hs = discover(OpenDARTApi(); corp_code = cc, bgn_de = today() - Year(2), end_de = today())
        isempty(hs) && return nothing
        rows = EDGAR.facts(fetch_filing(first(hs)); classify = true)
        # DART tags the consolidated FACE on `ConsolidatedMember` (not undimensioned), so normalize those
        # face facts to undimensioned — dropping note breakdowns (extra axes → comma) and the
        # separate-company facts — so the shared consolidated/undimensioned metric picker finds them.
        isface(d) = isempty(d) || d == "{}" || (occursin("ConsolidatedMember", d) && !occursin(",", d))
        return [merge(r, (dimensions = "{}",)) for r in rows if isface(r.dimensions)]
    elseif system === :india
        # `locator` is the NSE ticker. Prefer the CURRENT Integrated Filing (in-capmkt); its annual column
        # is the >300-day duration the metric picker selects. Fall back to the frozen results feed (in-bse-fin).
        hs = try discover(IntegratedFilings(); symbol = locator, consolidated = true) catch; FilingHandle[] end
        isempty(hs) && (hs = try discover(NSEFilings(); symbol = locator, consolidated = true) catch; FilingHandle[] end)
        isempty(hs) && return nothing
        return EDGAR.facts(fetch_filing(first(hs)); classify = true)
    elseif system === :china
        # `locator` is a CNINFO six-digit code (annual report auto-selected) OR a local PDF path (a stashed
        # filer, to avoid re-fetching). Facts come from the CAS PDF path (Docling), already classified.
        path = isfile(locator) ? String(locator) : begin
            hs = discover(CNINFOFilings(); code = String(locator), years = 1)
            isempty(hs) && return nothing
            String(fetch_filing(China(), first(hs)).content)
        end
        return EDGAR.extract_cas_pdf(path)
    elseif system === :germany
        # `locator` is a local German CONSOLIDATED-IFRS report PDF — Germany has no programmatic OAM retrieval
        # (the plan's PDF route), so the user supplies the stashed report. Facts come from the shared German/
        # IFRS PDF path on ifrs-full concepts, so the IFRS metric concepts below apply unchanged.
        path = expanduser(String(locator))
        isfile(path) || return nothing
        return EDGAR.extract_ifrs_pdf(path)
    elseif system === :hkex
        # `locator` is an HKEXnews five-digit stock code (annual report auto-selected) OR a local PDF path
        # (a stashed filer). Facts come from the shared English-PDF path (Docling), on ifrs-full concepts —
        # so the IFRS metric concepts apply unchanged.
        path = isfile(locator) ? String(locator) : begin
            hs = discover(HKEXFilings(); code = String(locator), years = 2)
            isempty(hs) && return nothing
            String(fetch_filing(first(hs)).content)
        end
        return EDGAR.extract_ifrs_pdf(path)
    end
    return nothing                       # :edinet not implemented yet
end

# The metric's candidate concepts for a system's taxonomy (SEC → us-gaap, India → in-capmkt/in-bse-fin,
# everything else → IFRS, the ESEF/most-jurisdictions default).
_metric_concepts(m::Metric, system::Symbol) =
    system === :sec ? m.usgaap : system === :india ? m.india : system === :china ? m.china : m.ifrs

# EDGAR.jl's (value, period_end) for a metric: consolidated (undimensioned), annual, most-recent.
# Candidates are tried in order, so the first listed concept wins when a filing tags several (e.g. IFRS
# net income prefers profit attributable to owners of parent — what Yahoo reports — over total profit).
function _edgar_metric(rows, m::Metric, system::Symbol)
    nodim(r) = r.dimensions == "{}" || isempty(r.dimensions)
    for c in _metric_concepts(m, system)
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
`system` is `:sec`, `:esef`, `:dart`, `:india`, `:china`, `:hkex` or `:germany`; `locator` is the CIK
(SEC), LEI (ESEF), corp/stock code (DART), NSE ticker (India), CNINFO code (China) or HKEXnews five-digit
code (Hong Kong) — or, for the PDF systems (China/HK/Germany), a local report path; and `ticker` is the Yahoo symbol (e.g.
`"AAPL"`, `"CTY1S.HE"`, `"TCS.NS"`, `"0700.HK"`) — needed because a filing knows only its own
identifier, not the exchange symbol. Returns
one [`Row`](@ref) per metric (tagged `:bs`/`:is`/`:cf`): EDGAR's value, Yahoo's, the `rel_diff`, and
whether they `match` within 1%.
"""
function validate(system::Symbol, locator::AbstractString, ticker::AbstractString)
    rows = Row[]
    edgar = _edgar_rows(system, locator)
    edgar === nothing && return rows
    funds = (bs = _yahoo_fund(ticker, "balance_sheet"),
             is = _yahoo_fund(ticker, "income_statement"),
             cf = _yahoo_fund(ticker, "cash_flow"))
    for m in METRICS
        e = _edgar_metric(edgar, m, system)
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
    # India — NSE ticker as locator, Yahoo `.NS` symbol. General (Ind-AS) filers so Revenue/NetIncome map
    # cleanly (insurers' premium accounts have no single Yahoo-comparable revenue line).
    # (avoid dual-listed ADR names like Infosys — Yahoo serves their fundamentals in USD, not INR.)
    ("Tata Consultancy", :india, "TCS",      "TCS.NS",      "IN"),
    ("Maruti Suzuki",    :india, "MARUTI",   "MARUTI.NS",   "IN"),
    ("Reliance Inds.",   :india, "RELIANCE", "RELIANCE.NS", "IN"),
]

# German DAX panel (G4). Germany is PDF-native with no OAM retrieval, so the locator is a stashed
# consolidated-IFRS report PDF; the Yahoo symbol is the Xetra `.DE` listing. Run `report(DE_FIRMS)`.
const DE_FIRMS = [
    ("Siemens AG",    :germany, "~/EDGAR-Reports/DE-SiemensFR2023.pdf",         "SIE.DE",  "DE"),
    ("Volkswagen AG", :germany, "~/EDGAR-Reports/DE-VolkswagenKonzern2023.pdf", "VOW3.DE", "DE"),
    ("BASF SE",       :germany, "~/EDGAR-Reports/DE-BASFBericht2023.pdf",       "BAS.DE",  "DE"),
]

# ESEF (retrievable) panel — France/Italy/Spain/Netherlands large-caps discovered on filings.xbrl.org by
# LEI and parsed through the standard `ifrs-full` path. Non-bank, EUR-reporting (no USD/ADR trap), so the
# five headline metrics map cleanly to Yahoo/Morningstar. All match to <=0.01% EXCEPT Heineken Revenue: a
# documented Morningstar standardisation (net-of-excise) — EDGAR reports gross `ifrs-full:Revenue`, Yahoo
# serves `heia:RevenueLessExciseTaxExpense`, the €6.1bn excise pass-through (manual §Netherlands validation).
const EU_FIRMS = [
    ("L'Oréal SA",       :esef, "529900JI1GG6F7RKVI53", "OR.PA",   "FR"),
    ("Moncler S.p.A.",   :esef, "815600EBD7FB00525B20", "MONC.MI", "IT"),
    ("Inditex SA",       :esef, "549300TTCXZOGZM2EY83", "ITX.MC",  "ES"),
    ("Heineken N.V.",    :esef, "724500K5PTPSST86UQ23", "HEIA.AS", "NL"),
]

const _STMT_LABEL = Dict(:bs => "BalanceSheet", :is => "IncomeStatement", :cf => "CashFlow")

# (ticker, metric) pairs where EDGAR and Yahoo legitimately disagree because Morningstar applies a
# documented standardisation — NOT extraction defects. Allow-listed so `report` stays green unless a
# *new* metric breaks; each entry cites the manual section that reconciles it. A pair that unexpectedly
# starts matching is harmless (prints ✓); one that keeps diverging is expected and not counted.
#   • Heineken Revenue: EDGAR reports gross `ifrs-full:Revenue`; Yahoo serves `heia:RevenueLessExcise‑
#     TaxExpense` (net of the €6.1bn alcohol-excise pass-through). Manual §Netherlands validation.
const EXPECTED_MISMATCHES = Set([("HEIA.AS", "Revenue")])

"""
    report(firms = FIRMS) -> Bool

Run [`validate`](@ref) over a panel of filers, print each metric's EDGAR-vs-Yahoo comparison grouped
by statement, and return whether there were no *unexpected* mismatches. Metrics Yahoo doesn't cover are
reported but not counted; documented Morningstar standardisations in [`EXPECTED_MISMATCHES`](@ref) are
flagged (`◑ documented`) but likewise not counted against the result.
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
                expected = !r.match && (ticker, r.metric) in EXPECTED_MISMATCHES
                r.match || expected || (nfail += 1)
                mark = r.match ? "✓" : expected ? "◑ documented" : "✗ MISMATCH"
                @printf("   [%-15s] %-12s EDGAR %+.6g   Yahoo %+.6g   Δ%.3f%%  %s\n",
                        tag, r.metric, r.edgar, r.yahoo, 100r.rel_diff, mark)
            end
        end
    end
    @printf("\nYahoo cross-check: %d unexpected mismatch(es)\n", nfail)
    return nfail == 0
end

end # module YahooOracle

if abspath(PROGRAM_FILE) == @__FILE__
    exit(YahooOracle.report() ? 0 : 1)
end
