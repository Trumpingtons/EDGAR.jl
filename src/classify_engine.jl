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
                        "statementofcondition", "financialcondition", "assetsandliabilities"],
     concept_patterns = [r"StatementOfFinancialPositionAbstract$"i, r"BalanceSheets?Abstract$"i]),
    (label = "IncomeStatement",
     role_substrings = ["incomestatement", "statementofincome", "statementsofincome",
                        "statementofoperations", "statementsofoperations", "profitorloss"],
     concept_patterns = [r"IncomeStatementAbstract$"i, r"Statements?OfIncomeAbstract$"i]),
    (label = "CashFlow",
     role_substrings = ["cashflow", "statementofcashflows"],
     concept_patterns = [r"StatementOfCashFlowsAbstract$"i, r"CashFlowsAbstract$"i]),
    (label = "Equity",
     role_substrings = ["stockholdersequity", "shareholdersequity", "changesinequity",
                        "partnerscapital", "statementofequity", "changesinnetassets", "componentsofequity"],
     concept_patterns = [r"StatementOfStockholdersEquityAbstract$"i, r"StatementOfShareholdersEquityAbstract$"i,
                         r"StatementOfChangesInEquityAbstract$"i, r"StockholdersEquityRollForward$"i]),
    (label = "ComprehensiveIncome",
     role_substrings = ["comprehensiveincome", "othercomprehensive"],
     concept_patterns = [r"ComprehensiveIncomeAbstract$"i]),
    # Fund / BDC / investment-company face statements (us-gaap only; no IFRS equivalent).
    (label = "ScheduleOfInvestments",
     role_substrings = ["scheduleofinvestments", "investmentholdings", "portfolioinvestments"],
     concept_patterns = [r"ScheduleOfInvestmentsAbstract$"i, r"InvestmentHoldingsAbstract$"i]),
    (label = "FinancialHighlights",
     role_substrings = ["financialhighlights"],
     concept_patterns = [r"FinancialHighlightsAbstract$"i]),
    (label = "CoverPage",
     role_substrings = ["coverpage", "documentandentity", "coverabstract"],
     concept_patterns = [r"CoverAbstract$"i]),
]

# When a concept appears in several face statements, keep the highest-priority one. The core six rank
# ahead of the fund-specific statements so a shared concept (e.g. an equity total) stays with the core.
const _STATEMENT_PRIORITY = ["IncomeStatement", "BalanceSheet", "CashFlow",
                             "ComprehensiveIncome", "Equity",
                             "ScheduleOfInvestments", "FinancialHighlights", "CoverPage"]

# Role-name fragment terms that mark a non-face section (notes/details/parenthetical/policies/
# disclosures). Scored as a strong negative delta in `_classify_role`. "detail" (singular) also catches
# "...Detail"/"...Details"; "disclosure" catches the generically-named detail R-files in the
# FilingSummary path whose role still embeds a statement word (e.g. "...IncomeStatementsDetail").
# NB: "schedule" is deliberately NOT a fragment term — "Schedule of Investments" is a fund face
# statement; a generic "Schedule of X" disclosure matches no face statement and is rejected anyway.
const _FRAGMENT_TERMS = ("parenthetical", "detail", "tables", "policies", "narrative", "disclosure")

# A score delta large enough to push any positive match below the classification threshold — the
# additive equivalent of an outright reject (for fragment roles and disclosure-only concept sets).
const _DISQUALIFY = 100

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

# The FilingSummary `<LongName>` categories whose reports are face statements (or the cover);
# anything else (Disclosure/Schedule/…) is a note/detail. Fed to `_classify_role` as a scoring signal.
const _FACE_REPORT_CATEGORIES = ("statement", "document", "cover")

"""
    _classify_role(role, concepts=String[]; category="") -> String

Classify a presentation/calculation role into a face statement label (`"BalanceSheet"`,
`"IncomeStatement"`, `"CashFlow"`, `"Equity"`, `"ComprehensiveIncome"`, the fund/BDC statements
`"ScheduleOfInvestments"` and `"FinancialHighlights"`, or `"CoverPage"`) or `""` for
notes/details/other. `role` is the role URI or human name; `concepts` is the (optional) set of
concepts in the role — when supplied (the presentation-linkbase path) it strengthens or rescues the
decision where the role name is opaque. `category` is the SEC FilingSummary `<LongName>` category
(`"Statement"`/`"Disclosure"`/…) when classifying from FilingSummary — an authoritative signal that a
report is a note/detail rather than a face statement. Multi-signal scoring adapted from edgartools,
over the taxonomy-merged [`STATEMENT_REGISTRY`](@ref).
"""
function _classify_role(role::AbstractString, concepts = String[]; category::AbstractString = "",
                        relaxed::Bool = false)
    nrole = _norm_role(role)
    cset = concepts isa AbstractSet ? concepts : Set(concepts)
    # Role-level penalty deltas, additive with the positive signals below so the whole decision is one
    # uniform score against a single threshold (adapted from edgartools' _score_statement_quality):
    #  • a notes/detail/parenthetical/schedule/disclosure role is not a face statement (#503/8ad8);
    #  • a role whose only concepts are abstract headers (`…Abstract`) or note text blocks
    #    (`…TextBlock…`) is a disclosure, even if its name matches a statement — e.g. an equity NOTE
    #    role named "StockholdersEquity", or a segment-reconciliation role named "…IncomeStatements"
    #    (#659; only when concepts are supplied);
    #  • a FilingSummary report whose authoritative LongName category is not a face category is a
    #    note/detail even when its generic role/name matches a statement word (MSFT detail R-files).
    # All three are disqualifying — the penalty exceeds the maximum attainable positive score. With
    # `relaxed=true` the fragment + abstract/TextBlock disqualifiers are skipped, so a note/detail role
    # is classified by its statement *intent* (used by `reconstruct_from_notes` to find the note that
    # stands in for a statement a filer did not file as a face section). The category gate still applies.
    penalty = 0
    relaxed || any(occursin(t, nrole) for t in _FRAGMENT_TERMS) && (penalty += _DISQUALIFY)
    relaxed || (!isempty(cset) && all(c -> endswith(c, "Abstract") || occursin("TextBlock", c), cset)) && (penalty += _DISQUALIFY)
    (!isempty(category) && lowercase(category) ∉ _FACE_REPORT_CATEGORIES) && (penalty += _DISQUALIFY)
    # Pure comprehensive-income demotion (adapted from edgartools #506/#584): a "Comprehensive Income
    # Statements" role name embeds the substring "incomestatement" without being the income statement;
    # demote the income match below the comprehensive-income match UNLESS the role is a *combined*
    # operations + comprehensive-income statement, detected by a distinct operations/income indicator.
    pure_ci = (occursin("comprehensiveincome", nrole) || occursin("othercomprehensive", nrole)) &&
              !any(occursin(x, nrole) for x in ("operations", "statementofincome", "statementsofincome"))
    best = ""; bestscore = 0
    for t in STATEMENT_REGISTRY
        s = -penalty
        any(rs -> occursin(rs, nrole), t.role_substrings) && (s += 3)
        any(in(cset), t.primary) && (s += 4)
        any(in(cset), t.alternative) && (s += 4)
        any(cp -> any(c -> occursin(cp, c), cset), t.concept_patterns) && (s += 3)
        s += min(count(in(cset), t.key_concepts), 3)
        (pure_ci && t.label == "IncomeStatement") && (s -= 4)
        s > bestscore && (bestscore = s; best = t.label)
    end
    return bestscore >= 3 ? best : ""
end

# ── Query-time statement resolution (resolver) ───────────────────────────────
# Adapted from edgartools' find_statement fallbacks. When a requested face statement is not present
# as its own section, fall back to a section that *subsumes* it — but only when that section actually
# holds the requested type's essential concepts (#608: never alias a pure-OCI statement to the income
# statement). A *combined* "Statement of Operations and Comprehensive Income" serves BOTH, so income
# and comprehensive income fall back to each other (#608, either direction — the income statement is
# sought in CI, and CI is sought in the combined income statement); an older filing may instead embed
# comprehensive income inside the statement of changes in equity (#706). Each hop is gated on content.
const _STATEMENT_FALLBACK = Dict(
    "IncomeStatement"     => ["ComprehensiveIncome"],            # combined P&L + OCI carries the income statement
    "ComprehensiveIncome" => ["IncomeStatement", "Equity"],     # combined statement carries CI; or CI embedded in equity
)

# The ordered fallback sections to try for a requested `statement` — every section reachable through
# the fallback graph (breadth-first, nearest first, no revisits).
function _fallback_chain(statement::AbstractString)
    chain = String[]; seen = Set([statement]); queue = copy(get(_STATEMENT_FALLBACK, statement, String[]))
    while !isempty(queue)
        s = popfirst!(queue)
        s in seen && continue
        push!(seen, s); push!(chain, s)
        append!(queue, get(_STATEMENT_FALLBACK, s, String[]))
    end
    return chain
end

# The anchor concepts that prove a section really holds a given statement type's content.
_essential_concepts(label::AbstractString) =
    (i = findfirst(t -> t.label == label, STATEMENT_REGISTRY); i === nothing ? String[] : STATEMENT_REGISTRY[i].key_concepts)

"""
    select_statement(rows, statement) -> rows

The fact rows belonging to a financial `statement`, applying the query-time resolver: if the
requested statement has no section of its own but a section that **subsumes** it does — and that
section actually contains the requested type's essential concepts — return those rows instead.

The canonical case is an IFRS single-statement filing whose income statement is the top of a
combined "Statement of Profit or Loss and Other Comprehensive Income": `select_statement(rows,
"IncomeStatement")` then returns the comprehensive-income rows (which hold the P&L). The fallback
chains transitively (income -> comprehensive income -> equity, for older filings that embed
comprehensive income in the statement of changes in equity). A pure other-comprehensive-income
section (no P&L) is **not** aliased to the income statement. Adapted from edgartools (#608/#706).
"""
function select_statement(rows, statement::AbstractString)
    direct = [r for r in rows if r.statement == statement]
    isempty(direct) || return direct
    ess = Set(_essential_concepts(statement))
    for alt in _fallback_chain(statement)
        altrows = [r for r in rows if r.statement == alt]
        isempty(altrows) && continue
        any(r -> r.concept in ess, altrows) && return altrows   # #608/#706: alt must hold the requested anchors
    end
    return direct
end
