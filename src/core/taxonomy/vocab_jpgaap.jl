# Japanese GAAP statement-classification vocabulary — the concept anchors for each face statement under
# the EDINET taxonomy used by Japanese filers. Keyed by the standard EDINET prefix `jppfs_cor` (the
# Japan Public Financial Statements "core" namespace, http://disclosure.edinet-fsa.go.jp/taxonomy/jppfs/
# <date>/jppfs_cor). Unlike Companies House (which binds the FRC namespace to arbitrary prefixes), EDINET
# filers use the **standard `jppfs_cor` prefix consistently**, so concept identity is by that prefix
# directly — no canonicalization needed. Merged into the scored registry (classify_engine.jl) like
# vocab_usgaap / vocab_ifrs / vocab_ukgaap; IFRS-adopting Japanese filers additionally match `ifrs-full`.
# Concept local-names verified against a real EDINET annual securities report (有価証券報告書): Kakaku.com
# FY2017, jppfs/jpcrp 2017-02-28 taxonomy (see docs/dev/edinet-plan.md E3).
const _VOCAB_JPGAAP = Dict(
    "BalanceSheet" => (
        primary = String[],
        alternative = String[],
        key_concepts = ["jppfs_cor:Assets", "jppfs_cor:Liabilities", "jppfs_cor:NetAssets",
                        "jppfs_cor:LiabilitiesAndNetAssets", "jppfs_cor:CurrentAssets",
                        "jppfs_cor:NoncurrentAssets"]),
    "IncomeStatement" => (
        primary = String[],
        alternative = String[],
        key_concepts = ["jppfs_cor:NetSales", "jppfs_cor:GrossProfit", "jppfs_cor:OperatingIncome",
                        "jppfs_cor:OrdinaryIncome", "jppfs_cor:IncomeBeforeIncomeTaxes",
                        "jppfs_cor:ProfitLoss", "jppfs_cor:ProfitLossAttributableToOwnersOfParent"]),
    "CashFlow" => (
        primary = String[],
        alternative = String[],
        key_concepts = ["jppfs_cor:NetCashProvidedByUsedInOperatingActivities",
                        "jppfs_cor:NetCashProvidedByUsedInInvestmentActivities",
                        "jppfs_cor:NetCashProvidedByUsedInFinancingActivities",
                        "jppfs_cor:NetIncreaseDecreaseInCashAndCashEquivalents"]),
    "Equity" => (
        primary = String[],
        alternative = String[],
        key_concepts = ["jppfs_cor:NetAssets", "jppfs_cor:ShareholdersEquity",
                        "jppfs_cor:CapitalStock"]),
)
