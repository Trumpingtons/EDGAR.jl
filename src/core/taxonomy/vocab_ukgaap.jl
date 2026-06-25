# UK GAAP / FRC statement-classification vocabulary: the concept anchors for each face statement under
# the published FRC taxonomy suite used by Companies House filers (FRS 101 / 102 / 105 and UK-IFRS).
# Keyed by the CANONICAL FRC prefix `uk-core` (the financial-reporting `core` namespace,
# http://xbrl.frc.org.uk/fr/<date>/core). CH filers bind that namespace to arbitrary prefixes
# (`uk-core`, `ns5`, …); the Companies House fetch path canonicalizes them to `uk-core` first
# (see `_ch_canonicalize` in filing_systems/companies_house/), so concept identity is by namespace,
# not the filer's prefix. Merged into the scored registry (classify_engine.jl) like vocab_usgaap /
# vocab_ifrs; UK-IFRS filers additionally match `ifrs-full`. Concept local-names verified against real
# FRC iXBRL filings (Companies House bulk Accounts Data Product). NOTE: many small companies file
# balance-sheet-only (filleted) accounts, so IncomeStatement/CashFlow anchors only fire on fuller ones.
const _VOCAB_UKGAAP = Dict(
    "BalanceSheet" => (
        primary = String[],
        alternative = String[],
        key_concepts = ["uk-core:NetAssetsLiabilities", "uk-core:Equity",
                        "uk-core:TotalAssetsLessCurrentLiabilities",
                        "uk-core:NetCurrentAssetsLiabilities", "uk-core:ShareholderFunds"]),
    "IncomeStatement" => (
        primary = String[],
        alternative = String[],
        key_concepts = ["uk-core:TurnoverRevenue", "uk-core:GrossProfitLoss",
                        "uk-core:OperatingProfitLoss", "uk-core:ProfitLoss",
                        "uk-core:ProfitLossOnOrdinaryActivitiesBeforeTax"]),
    "CashFlow" => (
        primary = String[],
        alternative = String[],
        key_concepts = ["uk-core:NetCashFlowsFromUsedInOperatingActivities",
                        "uk-core:NetCashGeneratedFromOperations"]),
    "Equity" => (
        primary = String[],
        alternative = String[],
        key_concepts = ["uk-core:Equity", "uk-core:ShareCapital"]),
)
