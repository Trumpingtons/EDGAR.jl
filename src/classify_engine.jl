# Statement-classification ENGINE — jurisdiction- and taxonomy-agnostic. This holds the *logic*
# (the multi-signal scorer + exclusions + priority) and the *structure/naming* of the face statements
# (role-name fragments and concept-name patterns), all common to every taxonomy and jurisdiction. The
# taxonomy-specific concept anchors come from the vocabulary files (vocab_usgaap.jl, vocab_ifrs.jl),
# which this merges into `STATEMENT_REGISTRY`. See the manual, § "Statement classification: two
# orthogonal axes". The scorer + data are a translation/adaptation of edgartools' statement matcher
# (MIT (c) Dwight Gunning; see src/data/edgartools_concept_mappings.NOTICE.md).

# Normalise a role string to lowercase alphanumerics, so "Statement of Profit or Loss",
# "StatementOfProfitOrLoss" and ".../role/StatementOfProfitOrLoss" all compare equal.
_norm_role(s::AbstractString) = lowercase(replace(last(split(s, "/")), r"[^A-Za-z0-9]" => ""))

# A merged statement-type definition used by the scorer.
const _StmtDef = @NamedTuple{label::String, primary::Vector{String}, alternative::Vector{String},
    concept_patterns::Vector{Regex}, key_concepts::Vector{String}, role_substrings::Vector{String}}

# The face statements: their role-name fragments and concept-name patterns. Both are taxonomy-
# agnostic — role naming is shared, and the patterns are suffix matches that hit `us-gaap:X` and
# `ifrs-full:X` alike. The explicit concept anchors (primary/alternative/key) are contributed
# per-taxonomy by the vocabulary files and merged in by `_build_statement_registry`.
const _STATEMENT_ROLES = [
    (label = "BalanceSheet",
     role_substrings = ["balancesheet", "statementoffinancialposition", "financialposition",
                        "statementofcondition", "financialcondition"],
     concept_patterns = [r"StatementOfFinancialPositionAbstract$"i, r"BalanceSheetAbstract$"i]),
    (label = "IncomeStatement",
     role_substrings = ["incomestatement", "statementofincome", "statementsofincome",
                        "statementofoperations", "statementsofoperations", "profitorloss"],
     concept_patterns = [r"IncomeStatementAbstract$"i, r"StatementOfIncomeAbstract$"i]),
    (label = "CashFlow",
     role_substrings = ["cashflow", "statementofcashflows"],
     concept_patterns = [r"StatementOfCashFlowsAbstract$"i, r"CashFlowsAbstract$"i]),
    (label = "Equity",
     role_substrings = ["stockholdersequity", "shareholdersequity", "changesinequity",
                        "partnerscapital", "statementofequity"],
     concept_patterns = [r"StatementOfStockholdersEquityAbstract$"i, r"StatementOfShareholdersEquityAbstract$"i,
                         r"StatementOfChangesInEquityAbstract$"i, r"StockholdersEquityRollForward$"i]),
    (label = "ComprehensiveIncome",
     role_substrings = ["comprehensiveincome", "othercomprehensive"],
     concept_patterns = [r"ComprehensiveIncomeAbstract$"i]),
    (label = "CoverPage",
     role_substrings = ["coverpage", "documentandentity", "coverabstract"],
     concept_patterns = Regex[]),
]

# When a concept appears in several face statements, keep the highest-priority one.
const _STATEMENT_PRIORITY = ["IncomeStatement", "BalanceSheet", "CashFlow",
                             "ComprehensiveIncome", "Equity", "CoverPage"]

# Role-name fragments that mark a non-face section (notes/details/parenthetical/policies).
const _ROLE_EXCLUDE = ("parenthetical", "details", "tables", "policies", "narrative")

# The taxonomy vocabularies merged into the effective registry. Loading every taxonomy is the
# behaviour-preserving default; selecting only the taxonomies a filing actually uses (by concept
# prefix) is a later refinement.
const _TAXONOMY_VOCABULARIES = [_VOCAB_USGAAP, _VOCAB_IFRS]

# Merge the engine's statement roles with all taxonomy vocabularies into the scored registry.
function _build_statement_registry()
    out = _StmtDef[]
    for s in _STATEMENT_ROLES
        primary = String[]; alternative = String[]; key_concepts = String[]
        for vocab in _TAXONOMY_VOCABULARIES
            e = get(vocab, s.label, nothing)
            e === nothing && continue
            append!(primary, e.primary); append!(alternative, e.alternative); append!(key_concepts, e.key_concepts)
        end
        push!(out, (label = s.label, primary = unique!(primary), alternative = unique!(alternative),
                    concept_patterns = s.concept_patterns, key_concepts = unique!(key_concepts),
                    role_substrings = s.role_substrings))
    end
    return out
end

const STATEMENT_REGISTRY = _build_statement_registry()

"""
    _classify_role(role, concepts=String[]) -> String

Classify a presentation/calculation role into a face statement label (`"BalanceSheet"`,
`"IncomeStatement"`, `"CashFlow"`, `"Equity"`, `"ComprehensiveIncome"`, `"CoverPage"`) or `""`
for notes/details/other. `role` is the role URI or human name; `concepts` is the (optional) set of
concepts in the role — when supplied (the presentation-linkbase path) it strengthens or rescues the
decision where the role name is opaque. Multi-signal scoring adapted from edgartools, over the
taxonomy-merged [`STATEMENT_REGISTRY`](@ref).
"""
function _classify_role(role::AbstractString, concepts = String[])
    nrole = _norm_role(role)
    any(occursin(p, nrole) for p in _ROLE_EXCLUDE) && return ""
    cset = concepts isa AbstractSet ? concepts : Set(concepts)
    # Essential-content validation (adapted from edgartools #659): a face statement is built from
    # line-item concepts. A role whose only concepts are abstract headers (`…Abstract`) or note
    # text blocks (`…TextBlock…`) is a disclosure/note — even if its *name* matches a statement
    # (e.g. an equity NOTE role named "StockholdersEquity", or a segment reconciliation disclosure
    # named "…IncomeStatements"). Reject it. (Only when concepts are supplied.)
    isempty(cset) || any(c -> !endswith(c, "Abstract") && !occursin("TextBlock", c), cset) || return ""
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
