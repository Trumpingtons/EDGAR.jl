# UK GAAP / FRC statement-classification vocabulary: the concept anchors for each face statement under
# the published FRC taxonomy suite used by Companies House filers (FRS 101 / 102 / 105 and UK-IFRS).
# Keyed by taxonomy PREFIX (the modern FRC `core` namespace), so it merges into the scored registry
# (classify_engine.jl) exactly like vocab_usgaap / vocab_ifrs. UK-IFRS filers additionally match
# `ifrs-full` via vocab_ifrs. NOTE: FRC instances tag few abstract *container* elements, so
# classification leans on `key_concepts` rather than `primary`/`alternative`; the exact concept set is
# a first cut to be tuned against a real fixture (C1 step 6) — see docs/dev/companies-house-plan.md §6.
const _VOCAB_UKGAAP = Dict(
    "BalanceSheet" => (
        primary = String[],
        alternative = String[],
        key_concepts = ["core:NetAssetsLiabilities", "core:Equity", "core:ShareholderFunds",
                        "core:TotalAssetsLessCurrentLiabilities", "core:NetCurrentAssetsLiabilities"]),
    "IncomeStatement" => (
        primary = String[],
        alternative = String[],
        key_concepts = ["core:TurnoverRevenue", "core:GrossProfitLoss", "core:OperatingProfitLoss",
                        "core:ProfitLoss", "core:ProfitLossOnOrdinaryActivitiesBeforeTax"]),
    "CashFlow" => (
        primary = String[],
        alternative = String[],
        key_concepts = ["core:NetCashGeneratedFromUsedInOperatingActivities",
                        "core:NetIncreaseDecreaseInCashCashEquivalents"]),
    "Equity" => (
        primary = String[],
        alternative = String[],
        key_concepts = ["core:Equity", "core:ShareCapital"]),
)
