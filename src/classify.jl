# Statement classification — a multi-signal scorer ADAPTED FROM edgartools' `xbrl/statement_resolver.py`
# (MIT © Dwight Gunning; see src/data/edgartools_concept_mappings.NOTICE.md). Rather than match a
# role's *name* with substrings (brittle: banks say "Statement of Condition", IFRS says "Statement
# of Profit or Loss"), each face statement is defined by the concepts it contains — `primary`/
# `alternative` abstract roots, anchor `key_concepts`, and concept-name `concept_patterns`, all
# including IFRS (`ifrs-full:`) equivalents — plus `role_substrings` for the name. A role is scored
# against every definition and assigned the best fit, so classification survives odd naming and even
# opaque role URIs (the concepts carry it). The concept lists carry edgartools' issue-tracked
# refinements (e.g. IFRS P&L #673, operations-vs-continuing #581). This is a translation/adaptation,
# not a verbatim copy: the data and matching logic are ported; the surrounding XBRL object model is
# EDGAR.jl's own.

# Normalise a role string to lowercase alphanumerics, so "Statement of Profit or Loss",
# "StatementOfProfitOrLoss" and ".../role/StatementOfProfitOrLoss" all compare equal.
_norm_role(s::AbstractString) = lowercase(replace(last(split(s, "/")), r"[^A-Za-z0-9]" => ""))

# One statement-type definition (mirrors edgartools' StatementType). Concepts are in EDGAR.jl's
# namespaced colon form (`us-gaap:Assets`); `role_substrings` are matched against the normalised role.
const _StmtDef = @NamedTuple{label::String, primary::Vector{String}, alternative::Vector{String},
    concept_patterns::Vector{Regex}, key_concepts::Vector{String}, role_substrings::Vector{String}}

const STATEMENT_REGISTRY = _StmtDef[
    (label = "BalanceSheet",
     primary = ["us-gaap:StatementOfFinancialPositionAbstract"],
     alternative = ["us-gaap:BalanceSheetAbstract", "ifrs-full:StatementOfFinancialPositionAbstract"],
     concept_patterns = [r"StatementOfFinancialPositionAbstract$"i, r"BalanceSheetAbstract$"i],
     key_concepts = ["us-gaap:Assets", "us-gaap:Liabilities", "us-gaap:StockholdersEquity",
                     "us-gaap:LiabilitiesAndStockholdersEquity", "ifrs-full:Assets",
                     "ifrs-full:Liabilities", "ifrs-full:Equity"],
     role_substrings = ["balancesheet", "statementoffinancialposition", "financialposition",
                        "statementofcondition", "financialcondition"]),
    (label = "IncomeStatement",
     primary = ["us-gaap:IncomeStatementAbstract"],
     alternative = ["us-gaap:StatementOfIncomeAbstract", "ifrs-full:IncomeStatementAbstract",
                    "ifrs-full:StatementOfProfitOrLossAbstract"],
     concept_patterns = [r"IncomeStatementAbstract$"i, r"StatementOfIncomeAbstract$"i],
     key_concepts = ["us-gaap:Revenues", "us-gaap:NetIncomeLoss", "us-gaap:ProfitLoss",
                     "ifrs-full:Revenue", "ifrs-full:ProfitLoss"],
     role_substrings = ["incomestatement", "statementofincome", "statementsofincome",
                        "statementofoperations", "statementsofoperations", "profitorloss"]),
    (label = "CashFlow",
     primary = ["us-gaap:StatementOfCashFlowsAbstract"],
     alternative = ["ifrs-full:StatementOfCashFlowsAbstract"],
     concept_patterns = [r"StatementOfCashFlowsAbstract$"i, r"CashFlowsAbstract$"i],
     key_concepts = ["us-gaap:NetCashProvidedByUsedInOperatingActivities",
                     "us-gaap:CashAndCashEquivalentsPeriodIncreaseDecrease",
                     "ifrs-full:CashFlowsFromUsedInOperatingActivities",
                     "ifrs-full:IncreaseDecreaseInCashAndCashEquivalents"],
     role_substrings = ["cashflow", "statementofcashflows"]),
    (label = "Equity",
     primary = ["us-gaap:StatementOfStockholdersEquityAbstract"],
     alternative = ["us-gaap:StatementOfShareholdersEquityAbstract",
                    "us-gaap:StatementOfPartnersCapitalAbstract",
                    "ifrs-full:StatementOfChangesInEquityAbstract"],
     concept_patterns = [r"StatementOfStockholdersEquityAbstract$"i, r"StatementOfShareholdersEquityAbstract$"i,
                         r"StatementOfChangesInEquityAbstract$"i, r"StockholdersEquityRollForward$"i],
     key_concepts = ["us-gaap:StockholdersEquity", "us-gaap:RetainedEarningsAccumulatedDeficit",
                     "ifrs-full:Equity", "ifrs-full:IssuedCapital"],
     role_substrings = ["stockholdersequity", "shareholdersequity", "changesinequity",
                        "partnerscapital", "statementofequity"]),
    (label = "ComprehensiveIncome",
     primary = ["us-gaap:StatementOfIncomeAndComprehensiveIncomeAbstract"],
     alternative = ["us-gaap:StatementOfComprehensiveIncomeAbstract",
                    "ifrs-full:StatementOfComprehensiveIncomeAbstract",
                    "ifrs-full:StatementOfProfitOrLossAndOtherComprehensiveIncomeAbstract"],
     concept_patterns = [r"ComprehensiveIncomeAbstract$"i],
     key_concepts = ["us-gaap:ComprehensiveIncomeNetOfTax", "ifrs-full:ComprehensiveIncome",
                     "ifrs-full:OtherComprehensiveIncome"],
     role_substrings = ["comprehensiveincome", "othercomprehensive"]),
    (label = "CoverPage",
     primary = String[], alternative = String[], concept_patterns = Regex[],
     key_concepts = String[],
     role_substrings = ["coverpage", "documentandentity", "coverabstract"]),
]

# When a concept appears in several face statements, keep the highest-priority one.
const _STATEMENT_PRIORITY = ["IncomeStatement", "BalanceSheet", "CashFlow",
                             "ComprehensiveIncome", "Equity", "CoverPage"]

# Role-name fragments that mark a non-face section (notes/details/parenthetical/policies).
const _ROLE_EXCLUDE = ("parenthetical", "details", "tables", "policies", "narrative")

"""
    _classify_role(role, concepts=String[]) -> String

Classify a presentation/calculation role into a face statement label (`"BalanceSheet"`,
`"IncomeStatement"`, `"CashFlow"`, `"Equity"`, `"ComprehensiveIncome"`, `"CoverPage"`) or `""`
for notes/details/other. `role` is the role URI or human name; `concepts` is the (optional) set of
concepts in the role — when supplied (the presentation-linkbase path) it strengthens or rescues the
decision where the role name is opaque. Multi-signal scoring adapted from edgartools.
"""
function _classify_role(role::AbstractString, concepts = String[])
    nrole = _norm_role(role)
    any(occursin(p, nrole) for p in _ROLE_EXCLUDE) && return ""
    cset = concepts isa AbstractSet ? concepts : Set(concepts)
    best = ""; bestscore = 0
    for t in STATEMENT_REGISTRY
        s = 0
        any(rs -> occursin(rs, nrole), t.role_substrings) && (s += 3)
        any(in(cset), t.primary) && (s += 4)
        any(in(cset), t.alternative) && (s += 4)
        any(cp -> any(c -> occursin(cp, c), cset), t.concept_patterns) && (s += 3)
        s += min(count(in(cset), t.key_concepts), 3)
        s > bestscore && (bestscore = s; best = t.label)
    end
    return bestscore >= 3 ? best : ""
end
