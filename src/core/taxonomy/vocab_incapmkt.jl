# in-capmkt (SEBI Integrated Filing) statement-classification vocabulary for India (NSE/BSE). This is the
# SECOND India taxonomy family — the CURRENT filing framework. SEBI's **Integrated Filing (Financial)**
# (~2025) serves EVERY sector on ONE taxonomy, `in-capmkt` (`www.sebi.gov.in/xbrl/2025-01-31/in-capmkt`),
# reachable via `discover(IntegratedFilings(); symbol=…)`. It supersedes the frozen `in-bse-fin` feed
# (`vocab_indas.jl`), so classifying it is what places recent (2025+) results.
#
# `EDGAR.jl` classifies by NAMESPACE, not prefix, so `in-capmkt:Assets` does NOT match the `in-bse-fin`
# vocabulary even though the LOCAL names are identical — hence this dedicated national vocabulary (the same
# by-namespace pattern as vocab_indas / vocab_jpgaap / vocab_ukgaap).
#
# Two sector families share the namespace, so both are anchored here:
#   • **General / Banking / NBFC** (`INTEGRATED_FILING_{INDAS,BANKING,NBFC_INDAS}_…`) — the SAME local names
#     as the `in-bse-fin` results feed (RevenueFromOperations / ProfitLossForPeriod / Assets / InterestEarned
#     / Deposits / Advances), just re-namespaced to `in-capmkt`.
#   • **Insurance** (`INTEGRATED_FILING_{LI,GI}_…`) — an insurance-specific shape with no `in-bse-fin`
#     equivalent: a premium-driven revenue account (Life: GrossPremiumIncome / NetSurplusDeficit; General:
#     GrossPremiumsWritten / UnderwritingProfitOrLoss) and an insurer balance sheet (ShareholdersFunds /
#     PolicyholdersFunds / PolicyLiabilities). These anchor the insurers' P&L, which the bundled `in-capmkt`
#     presentation linkbases (`data/in-capmkt-pre-{li,gi}-2025-01-31.xml`) otherwise name by a role
#     (`StatementOfFinancialResultsOf{Life,General}InsuranceCompanies`) the generic role-words don't catch.
#
# Verified live (2026-07): general — TCS (`INTEGRATED_FILING_INDAS_`); life — SBI Life / HDFC Life
# (`INTEGRATED_FILING_LI_`); general insurance — ICICI Lombard (`INTEGRATED_FILING_GI_`).
const _VOCAB_INCAPMKT = Dict(
    "BalanceSheet" => (
        primary = String[],
        alternative = ["in-capmkt:StatementOfFinancialPositionAbstract",
                       "in-capmkt:BalanceSheetAbstract"],
        key_concepts = ["in-capmkt:Assets", "in-capmkt:EquityAndLiabilities",
                        "in-capmkt:Equity", "in-capmkt:Liabilities",
                        # banking (Banking Regulation Act balance sheet)
                        "in-capmkt:Deposits", "in-capmkt:Advances",
                        # insurance balance sheet (Life & General)
                        "in-capmkt:ShareholdersFunds", "in-capmkt:PolicyholdersFunds",
                        "in-capmkt:PolicyLiabilities"]),
    "IncomeStatement" => (
        primary = String[],
        alternative = ["in-capmkt:IncomeStatementAbstract",
                       "in-capmkt:StatementOfProfitAndLossAbstract",
                       "in-capmkt:StatementOfFinancialResultsIndASAbstract"],
        key_concepts = ["in-capmkt:RevenueFromOperations", "in-capmkt:Income",
                        "in-capmkt:ProfitBeforeTax", "in-capmkt:ProfitLossForPeriod",
                        "in-capmkt:ProfitLossForPeriodFromContinuingOperations",
                        # banking
                        "in-capmkt:InterestEarned", "in-capmkt:InterestExpended",
                        "in-capmkt:ProfitLossForThePeriod",
                        # life insurance (revenue/policyholders' & profit & loss/shareholders' accounts)
                        "in-capmkt:GrossPremiumIncome", "in-capmkt:NetPremiumIncome",
                        "in-capmkt:NetSurplusDeficit", "in-capmkt:ProfitLossBeforeTax",
                        "in-capmkt:ProfitLossAfterTaxAndExtraordinaryItems",
                        # general insurance
                        "in-capmkt:GrossPremiumsWritten", "in-capmkt:NetPremiumWritten",
                        "in-capmkt:PremiumEarned", "in-capmkt:UnderwritingProfitOrLoss",
                        "in-capmkt:OperatingProfitOrLoss"]),
    "CashFlow" => (
        primary = String[],
        alternative = ["in-capmkt:StatementOfCashFlowsAbstract"],
        key_concepts = ["in-capmkt:CashFlowsFromUsedInOperatingActivities",
                        "in-capmkt:IncreaseDecreaseInCashAndCashEquivalents"]),
    "ComprehensiveIncome" => (
        primary = String[],
        alternative = ["in-capmkt:StatementOfComprehensiveIncomeAbstract"],
        key_concepts = ["in-capmkt:ComprehensiveIncomeForThePeriod",
                        "in-capmkt:OtherComprehensiveIncomeNetOfTaxes"]),
)
