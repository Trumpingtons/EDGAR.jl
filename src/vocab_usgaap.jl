# US-GAAP statement-classification vocabulary: the concept anchors for each face statement under the
# `us-gaap` taxonomy (SEC filers). The engine (classify_engine.jl) merges this with the other
# taxonomy vocabularies into the scored registry. Concept lists adapted from edgartools (MIT; see
# src/data/edgartools_concept_mappings.NOTICE.md). Each entry: `primary`/`alternative` abstract roots
# and `key_concepts` anchors; concept-name patterns and role-name patterns are taxonomy-agnostic and
# live in the engine.
const _VOCAB_USGAAP = Dict(
    "BalanceSheet" => (
        primary = ["us-gaap:StatementOfFinancialPositionAbstract"],
        alternative = ["us-gaap:BalanceSheetAbstract"],
        key_concepts = ["us-gaap:Assets", "us-gaap:Liabilities", "us-gaap:StockholdersEquity",
                        "us-gaap:LiabilitiesAndStockholdersEquity"]),
    "IncomeStatement" => (
        primary = ["us-gaap:IncomeStatementAbstract"],
        alternative = ["us-gaap:StatementOfIncomeAbstract"],
        key_concepts = ["us-gaap:Revenues", "us-gaap:NetIncomeLoss", "us-gaap:ProfitLoss"]),
    "CashFlow" => (
        primary = ["us-gaap:StatementOfCashFlowsAbstract"],
        alternative = String[],
        key_concepts = ["us-gaap:NetCashProvidedByUsedInOperatingActivities",
                        "us-gaap:CashAndCashEquivalentsPeriodIncreaseDecrease"]),
    "Equity" => (
        primary = ["us-gaap:StatementOfStockholdersEquityAbstract"],
        alternative = ["us-gaap:StatementOfShareholdersEquityAbstract",
                       "us-gaap:StatementOfPartnersCapitalAbstract"],
        key_concepts = ["us-gaap:StockholdersEquity", "us-gaap:RetainedEarningsAccumulatedDeficit",
                        "us-gaap:CommonStockValue", "us-gaap:RetainedEarnings"]),
    "ComprehensiveIncome" => (
        primary = ["us-gaap:StatementOfIncomeAndComprehensiveIncomeAbstract"],
        alternative = ["us-gaap:StatementOfComprehensiveIncomeAbstract"],
        key_concepts = ["us-gaap:ComprehensiveIncomeNetOfTax",
                        "us-gaap:ComprehensiveIncomeNetOfTaxIncludingPortionAttributableToNoncontrollingInterest"]),
    # Fund / BDC / investment-company face statements (no IFRS equivalent — us-gaap only).
    "ScheduleOfInvestments" => (
        primary = ["us-gaap:ScheduleOfInvestmentsAbstract"],
        alternative = ["us-gaap:InvestmentsDebtAndEquitySecuritiesAbstract",
                       "us-gaap:InvestmentHoldingsAbstract"],
        key_concepts = ["us-gaap:InvestmentOwnedAtFairValue", "us-gaap:InvestmentOwnedAtCost",
                        "us-gaap:InvestmentOwnedBalancePrincipalAmount",
                        "us-gaap:InvestmentOwnedBalanceShares",
                        "us-gaap:InvestmentOwnedPercentOfNetAssets"]),
    "FinancialHighlights" => (
        primary = ["us-gaap:InvestmentCompanyFinancialHighlightsAbstract"],
        alternative = ["us-gaap:InvestmentCompanyAbstract"],
        key_concepts = ["us-gaap:NetAssetValuePerShare", "us-gaap:InvestmentCompanyNetAssets",
                        "us-gaap:InvestmentCompanyTotalReturn", "us-gaap:InvestmentCompanyExpenseRatio"]),
)
