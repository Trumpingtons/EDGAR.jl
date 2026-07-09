# Yahoo Finance provider for the fundamentals oracle (see fundamentals_oracle.jl). Backend: YFinance
# (a hard EDGAR dependency, which also supplies prices/quotes), so `provider = :yahoo` works out of the
# box on `using EDGAR` with no configuration. Yahoo covers 100+ countries — the default, global provider.

struct Yahoo <: FundamentalsProvider end
_provider(::Val{:yahoo}) = Yahoo()
provider_name(::Yahoo) = "Yahoo"
default_scheme(::Yahoo) = :morningstar   # Yahoo serves Morningstar-standardised fundamentals

# Yahoo's standardized line-item keys per headline metric. Tried in order; the first present, non-zero
# value wins (e.g. Equity prefers common-stockholders' equity over the gross minority-interest total).
const YAHOO_KEYS = Dict(
    "Assets"       => ["TotalAssets"],
    "Equity"       => ["StockholdersEquity", "TotalEquityGrossMinorityInterest", "CommonStockEquity"],
    "Revenue"      => ["TotalRevenue", "OperatingRevenue"],
    "NetIncome"    => ["NetIncome", "NetIncomeCommonStockholders"],
    "OperCashFlow" => ["OperatingCashFlow", "CashFlowFromContinuingOperatingActivities"],
)
provider_concepts(::Yahoo, name::AbstractString) = get(YAHOO_KEYS, name, String[])

# Fetch the three statements' annual fundamentals (a dict per statement, keyed by line-item with a
# parallel `timestamp` array). Any statement may come back `nothing` (network/coverage) — handled downstream.
function provider_fetch(::Yahoo, ticker::AbstractString)
    f(kind) = try YFinance.get_Fundamental(ticker, kind, "annual", today() - Year(4), today()) catch; nothing end
    return (bs = f("balance_sheet"), is = f("income_statement"), cf = f("cash_flow"))
end

# The provider value for a metric at a period end: the column whose timestamp falls in the same calendar
# year as EDGAR's period end, first non-zero candidate key.
function provider_value(::Yahoo, d, keys::Vector{String}, pe::Date)
    (d === nothing || !haskey(d, "timestamp")) && return nothing
    idx = findfirst(t -> Dates.year(t) == Dates.year(pe), d["timestamp"])
    idx === nothing && return nothing
    for k in keys
        haskey(d, k) && d[k][idx] !== nothing && d[k][idx] != 0 && return Float64(d[k][idx])
    end
    return nothing
end

# Default panel (name, system, locator, ticker, jurisdiction). Yahoo is global, so a cross-jurisdiction mix.
const ORACLE_FIRMS = [
    ("Apple Inc.",       :sec,   "320193",               "AAPL",        "US"),
    ("Microsoft Corp.",  :sec,   "789019",               "MSFT",        "US"),
    ("Citycon Oyj",      :esef,  "549300P8N0P6KDGTJ206", "CTY1S.HE",    "EU"),
    ("Nokia Oyj",        :esef,  "549300A0JPRWG1KI7U06", "NOKIA.HE",    "EU"),
    # India — NSE ticker as locator, Yahoo `.NS` symbol. General (Ind-AS) filers so Revenue/NetIncome map
    # cleanly. (Avoid dual-listed ADR names like Infosys — Yahoo serves their fundamentals in USD.)
    ("Tata Consultancy", :india, "TCS",                  "TCS.NS",      "IN"),
    ("Maruti Suzuki",    :india, "MARUTI",               "MARUTI.NS",   "IN"),
    ("Reliance Inds.",   :india, "RELIANCE",             "RELIANCE.NS", "IN"),
]
default_firms(::Yahoo) = ORACLE_FIRMS

# German DAX panel (G4). Germany is PDF-native with no OAM retrieval, so the locator is a stashed
# consolidated-IFRS report PDF; the Yahoo symbol is the Xetra `.DE` listing. Run `report(ORACLE_DE_FIRMS)`.
const ORACLE_DE_FIRMS = [
    ("Siemens AG",    :germany, "~/EDGAR-Reports/DE-SiemensFR2023.pdf",         "SIE.DE",  "DE"),
    ("Volkswagen AG", :germany, "~/EDGAR-Reports/DE-VolkswagenKonzern2023.pdf", "VOW3.DE", "DE"),
    ("BASF SE",       :germany, "~/EDGAR-Reports/DE-BASFBericht2023.pdf",       "BAS.DE",  "DE"),
]

# ESEF (retrievable) panel — France/Italy/Spain/Netherlands large-caps discovered on filings.xbrl.org by
# LEI and parsed through the standard `ifrs-full` path. All match to <=0.01% EXCEPT Heineken Revenue: a
# documented net-of-excise standardisation (see ORACLE_EXPECTED_MISMATCHES). Run `report(ORACLE_EU_FIRMS)`.
const ORACLE_EU_FIRMS = [
    ("L'Oréal SA",    :esef, "529900JI1GG6F7RKVI53", "OR.PA",   "FR"),
    ("Moncler S.p.A.", :esef, "815600EBD7FB00525B20", "MONC.MI", "IT"),
    ("Inditex SA",    :esef, "549300TTCXZOGZM2EY83", "ITX.MC",  "ES"),
    ("Heineken N.V.", :esef, "724500K5PTPSST86UQ23", "HEIA.AS", "NL"),
]
