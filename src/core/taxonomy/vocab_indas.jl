# Ind-AS (`in-bse-fin`) statement-classification vocabulary for India (NSE/BSE). India is the inverse of
# Korea: its concepts have IFRS-identical LOCAL names but live in a national namespace,
# `in-bse-fin` (BSE's Financial Results taxonomy) — and `EDGAR.jl` classifies by NAMESPACE, not prefix,
# so `in-bse-fin:Assets` does NOT match the shared `ifrs-full` vocabulary. Hence this dedicated national
# vocabulary (the decision locked in docs/dev/india-plan.md I3), the same by-namespace pattern as
# vocab_jpgaap / vocab_ukgaap.
#
# Two India specifics shape it:
#   • NSE results instances carry NO bundled presentation linkbase (standard-taxonomy-only, the Companies
#     House shape). So classification cannot come from presentation roles — it comes from these
#     `key_concepts` anchors via the intrinsic-fallback path (`_INTRINSIC_STATEMENTS` in
#     statement_map_multi), exactly as Companies House classifies with no linkbase.
#   • SEBI prescribes a DIFFERENT results format per company class (see docs/manual §13.3): the general
#     `INDAS_` template (RevenueFromOperations / ProfitLossForPeriod), the `BANKING_` template (a Banking
#     Regulation Act shape — InterestEarned / InterestExpended / Deposits / Advances, and
#     ProfitLossFor*The*Period), and `NBFC_INDAS_`. The anchors below cover all of them, so one vocabulary
#     classifies every India filing regardless of format.
#
# Verified anchors present in real filings: general — Reliance / IOC / Infosys (INDAS_); banking — HDFC
# Bank (BANKING_); NBFC — Bajaj Finance (NBFC_INDAS_).
const _VOCAB_INDAS = Dict(
    "BalanceSheet" => (
        primary = String[],
        alternative = ["in-bse-fin:StatementOfFinancialPositionAbstract",
                       "in-bse-fin:BalanceSheetAbstract"],
        key_concepts = ["in-bse-fin:Assets", "in-bse-fin:EquityAndLiabilities",
                        "in-bse-fin:Equity", "in-bse-fin:Liabilities",
                        # banking (Banking Regulation Act balance sheet)
                        "in-bse-fin:Deposits", "in-bse-fin:Advances"]),
    "IncomeStatement" => (
        primary = String[],
        alternative = ["in-bse-fin:IncomeStatementAbstract",
                       "in-bse-fin:StatementOfProfitOrLossAbstract"],
        key_concepts = ["in-bse-fin:RevenueFromOperations", "in-bse-fin:Income",
                        "in-bse-fin:ProfitBeforeTax", "in-bse-fin:ProfitLossForPeriod",
                        # banking
                        "in-bse-fin:InterestEarned", "in-bse-fin:InterestExpended",
                        "in-bse-fin:ProfitLossForThePeriod",
                        "in-bse-fin:ProfitLossFromOrdinaryActivitiesBeforeTax"]),
    "CashFlow" => (
        primary = String[],
        alternative = ["in-bse-fin:StatementOfCashFlowsAbstract"],
        key_concepts = ["in-bse-fin:CashFlowsFromUsedInOperatingActivities",
                        "in-bse-fin:IncreaseDecreaseInCashAndCashEquivalents"]),
    "ComprehensiveIncome" => (
        primary = String[],
        alternative = ["in-bse-fin:StatementOfComprehensiveIncomeAbstract"],
        key_concepts = ["in-bse-fin:ComprehensiveIncomeForThePeriod",
                        "in-bse-fin:OtherComprehensiveIncomeNetOfTaxes"]),
)
