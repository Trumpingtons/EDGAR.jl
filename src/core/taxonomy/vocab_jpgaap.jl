# Japanese GAAP statement-classification vocabulary — the concept anchors for each face statement under
# the EDINET taxonomy used by Japanese filers. Keyed by the standard EDINET prefix `jppfs_cor` (the
# Japan Public Financial Statements "core" namespace, http://disclosure.edinet-fsa.go.jp/taxonomy/jppfs/
# <date>/jppfs_cor). Unlike Companies House (which binds the FRC namespace to arbitrary prefixes), EDINET
# filers use the **standard `jppfs_cor` prefix consistently**, so concept identity is by that prefix
# directly — no canonicalization needed. Merged into the scored registry (classify_engine.jl) like
# vocab_usgaap / vocab_ifrs / vocab_ukgaap; IFRS-adopting Japanese filers additionally match `ifrs-full`.
# Covers BOTH EDINET accounting standards: Japanese GAAP (`jppfs_cor`) and EDINET's IFRS taxonomy
# (`jpigp_cor`, with `…IFRS`-suffixed local names — EDINET IFRS filers do NOT use bare `ifrs-full`, so
# they need their own anchors). US-GAAP-adopting JP filers fall through to `vocab_usgaap`.
# Concept local-names VERIFIED against real EDINET filings (see docs/dev/edinet-plan.md E3):
#   • J-GAAP — Kakaku.com / Yahoo Japan / TIS (jppfs/jpcrp 2017-02-28).
#   • IFRS  — the official FSA IFRS sample instance (jpigp 2026 taxonomy).
const _VOCAB_JPGAAP = Dict(
    "BalanceSheet" => (
        primary = String[],
        alternative = String[],
        key_concepts = ["jppfs_cor:Assets", "jppfs_cor:Liabilities", "jppfs_cor:NetAssets",
                        "jppfs_cor:LiabilitiesAndNetAssets", "jppfs_cor:CurrentAssets",
                        "jppfs_cor:NoncurrentAssets",
                        # EDINET IFRS
                        "jpigp_cor:AssetsIFRS", "jpigp_cor:LiabilitiesIFRS", "jpigp_cor:EquityIFRS",
                        "jpigp_cor:LiabilitiesAndEquityIFRS", "jpigp_cor:CurrentAssetsIFRS",
                        "jpigp_cor:NonCurrentAssetsIFRS"]),
    "IncomeStatement" => (
        primary = String[],
        alternative = String[],
        key_concepts = ["jppfs_cor:NetSales", "jppfs_cor:GrossProfit", "jppfs_cor:OperatingIncome",
                        "jppfs_cor:OrdinaryIncome", "jppfs_cor:IncomeBeforeIncomeTaxes",
                        "jppfs_cor:ProfitLoss", "jppfs_cor:ProfitLossAttributableToOwnersOfParent",
                        # EDINET IFRS
                        "jpigp_cor:RevenueIFRS", "jpigp_cor:OperatingProfitLossIFRS",
                        "jpigp_cor:ProfitLossBeforeTaxIFRS", "jpigp_cor:ProfitLossIFRS",
                        "jpigp_cor:ProfitLossAttributableToOwnersOfParentIFRS"]),
    "CashFlow" => (
        primary = String[],
        alternative = String[],
        key_concepts = ["jppfs_cor:NetCashProvidedByUsedInOperatingActivities",
                        "jppfs_cor:NetCashProvidedByUsedInInvestmentActivities",
                        "jppfs_cor:NetCashProvidedByUsedInFinancingActivities",
                        "jppfs_cor:NetIncreaseDecreaseInCashAndCashEquivalents",
                        # EDINET IFRS
                        "jpigp_cor:NetCashProvidedByUsedInOperatingActivitiesIFRS",
                        "jpigp_cor:NetCashProvidedByUsedInInvestingActivitiesIFRS",
                        "jpigp_cor:NetCashProvidedByUsedInFinancingActivitiesIFRS"]),
    "Equity" => (
        primary = String[],
        alternative = String[],
        key_concepts = ["jppfs_cor:NetAssets", "jppfs_cor:ShareholdersEquity",
                        "jppfs_cor:CapitalStock", "jpigp_cor:EquityIFRS"]),
)
