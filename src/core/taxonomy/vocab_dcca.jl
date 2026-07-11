# Danish DCCA (xbrl.dcca.dk / `fsa:`) → IFRS translation. The Danish Business Authority's (Erhvervsstyrelsen)
# digital annual reports tag under the national DCCA taxonomy, whose concepts largely mirror IFRS by name.
# This map "promotes" the headline national concepts to their `ifrs-full` equivalents, so a fact extracted as
# `fsa:Revenue` carries `standard_concept = "ifrs-full:Revenue"` — the national-vocabulary layer a specialised
# jurisdiction adds, here for Denmark's register filings (which arrive via Generic, not ESEF). This is an
# objective taxonomy TRANSLATION (national concept → the IFRS concept it corresponds to), distinct from the
# opinionated synonym-collapse of `set_standardizer`, so it is consulted automatically by `standardize`.
# Headline concepts only (income statement + balance-sheet totals) — extend as coverage is needed.
const _DCCA_TO_IFRS = Dict{String,String}(
    "fsa:Revenue"                                   => "ifrs-full:Revenue",
    "fsa:GrossProfitLoss"                           => "ifrs-full:GrossProfit",
    "fsa:ProfitLossFromOrdinaryOperatingActivities" => "ifrs-full:ProfitLossFromOperatingActivities",
    "fsa:ProfitLossFromOrdinaryActivitiesBeforeTax" => "ifrs-full:ProfitLossBeforeTax",
    "fsa:TaxExpense"                                => "ifrs-full:IncomeTaxExpenseContinuingOperations",
    "fsa:ProfitLoss"                                => "ifrs-full:ProfitLoss",
    "fsa:EmployeeBenefitsExpense"                   => "ifrs-full:EmployeeBenefitsExpense",
    "fsa:Assets"                                    => "ifrs-full:Assets",
    "fsa:NoncurrentAssets"                          => "ifrs-full:NoncurrentAssets",
    "fsa:CurrentAssets"                             => "ifrs-full:CurrentAssets",
    "fsa:PropertyPlantAndEquipment"                 => "ifrs-full:PropertyPlantAndEquipment",
    "fsa:RightofuseAssets"                          => "ifrs-full:RightofuseAssets",
    "fsa:CashAndCashEquivalents"                    => "ifrs-full:CashAndCashEquivalents",
    "fsa:Equity"                                    => "ifrs-full:Equity",
    "fsa:RetainedEarnings"                          => "ifrs-full:RetainedEarnings",
    "fsa:Provisions"                                => "ifrs-full:Provisions",
    "fsa:LiabilitiesOtherThanProvisions"            => "ifrs-full:Liabilities",
)

"""
    dcca_ifrs(concept) -> Union{String,Nothing}

The `ifrs-full` concept a Danish DCCA (`fsa:`) concept translates to, or `nothing`. Namespace-gated, so a
non-DCCA concept never touches the table. Consulted automatically by [`standardize`](@ref).
"""
dcca_ifrs(concept::AbstractString) =
    startswith(concept, "fsa:") ? get(_DCCA_TO_IFRS, concept, nothing) : nothing
