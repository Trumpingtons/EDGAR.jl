# IFRS (`ifrs-full`) statement-classification vocabulary: the concept anchors for each face statement
# under the IFRS taxonomy. SHARED across every IFRS-reporting jurisdiction — ESEF, SEDAR+ (IFRS),
# UK Companies House (IFRS), DART (K-IFRS), MOPS (TW-IFRS), EDINET (IFRS filers) — so adding those
# regimes reuses this file rather than re-deriving it. The engine (classify_engine.jl) merges it into
# the scored registry. Concept lists adapted from edgartools (MIT; see
# src/core/taxonomy/data/edgartools_concept_mappings.NOTICE.md).
const _VOCAB_IFRS = Dict(
    "BalanceSheet" => (
        primary = String[],
        alternative = ["ifrs-full:StatementOfFinancialPositionAbstract"],
        key_concepts = ["ifrs-full:Assets", "ifrs-full:Liabilities", "ifrs-full:Equity"]),
    "IncomeStatement" => (
        primary = String[],
        alternative = ["ifrs-full:IncomeStatementAbstract", "ifrs-full:StatementOfProfitOrLossAbstract"],
        key_concepts = ["ifrs-full:Revenue", "ifrs-full:ProfitLoss"]),
    "CashFlow" => (
        primary = String[],
        alternative = ["ifrs-full:StatementOfCashFlowsAbstract"],
        key_concepts = ["ifrs-full:CashFlowsFromUsedInOperatingActivities",
                        "ifrs-full:IncreaseDecreaseInCashAndCashEquivalents"]),
    "Equity" => (
        primary = String[],
        alternative = ["ifrs-full:StatementOfChangesInEquityAbstract"],
        key_concepts = ["ifrs-full:Equity", "ifrs-full:IssuedCapital"]),
    "ComprehensiveIncome" => (
        primary = String[],
        alternative = ["ifrs-full:StatementOfComprehensiveIncomeAbstract",
                       "ifrs-full:StatementOfProfitOrLossAndOtherComprehensiveIncomeAbstract"],
        key_concepts = ["ifrs-full:ComprehensiveIncome", "ifrs-full:OtherComprehensiveIncome"]),
)
