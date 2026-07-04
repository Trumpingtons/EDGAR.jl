# HKFRS (Hong Kong Financial Reporting Standards) classification vocabulary — the ENGLISH-label analogue of
# vocab_cas. Hong Kong is PDF-native like China, but its reports are in English under HKFRS, which is
# IFRS-converged, so a statement line maps to an `ifrs-full` concept (shared with ESEF/DART/etc.), keyed on
# the English label. Unlike China's exact-key CJK table, English total lines vary in phrasing across filers
# ("Profit for the year" / "Profit for the period"; "Net cash generated from / used in operating activities"),
# so classification is PATTERN-based, and STATEMENT-aware — "Equity holders of the Company" is profit
# attributable to owners in the income statement but equity attributable to owners in the balance sheet.
# Only the HEADLINE lines needed for cross-foot + the external-data benchmark are mapped; the fine line items
# are left unclassified (carried by their label). See docs/dev/hkex-plan.md (HK2).

# Normalise an English statement label for matching: lower-case, collapse whitespace, drop a trailing
# note-reference and asterisks/footnote marks ("Marketing Services*", "Revenue 6").
function _hkfrs_norm(s::AbstractString)
    t = lowercase(strip(String(s)))
    t = replace(t, r"[*†‡]" => "")
    t = replace(t, r"\s+" => " ")
    return strip(t)
end

"""
    hkfrs_concept(label, statement) -> Union{Nothing, NamedTuple{(:concept,:instant)}}

Classify an English HKFRS statement `label` (as clustered from a PDF row) to its `ifrs-full` concept and
period type, within a known `statement` ("BalanceSheet" / "IncomeStatement" / "CashFlow"), or `nothing` if it
is not a recognised headline anchor. Pattern-based (English phrasings vary) and statement-aware. Only the
totals needed for cross-foot and the benchmark are mapped. See [`extract_hkfrs_pdf`](@ref).
"""
function hkfrs_concept(label::AbstractString, statement::AbstractString)
    t = _hkfrs_norm(label)
    isempty(t) && return nothing
    inst = statement == "BalanceSheet"
    C(c) = (concept = c, instant = inst)

    if statement == "BalanceSheet"
        t == "total assets"                                    && return C("ifrs-full:Assets")
        t == "total liabilities"                               && return C("ifrs-full:Liabilities")
        t == "total equity"                                    && return C("ifrs-full:Equity")
        (t == "total equity and liabilities" ||
         t == "total liabilities and equity")                 && return C("ifrs-full:EquityAndLiabilities")
        occursin(r"^(total )?equity attributable to (equity holders|owners)", t) &&
            return C("ifrs-full:EquityAttributableToOwnersOfParent")
        t == "non-controlling interests"                       && return C("ifrs-full:NoncontrollingInterests")

    elseif statement == "IncomeStatement"
        (t == "revenue" || t == "revenues" || t == "turnover" ||
         t == "total revenue" || t == "total revenues")       && return C("ifrs-full:Revenue")
        t == "gross profit"                                    && return C("ifrs-full:GrossProfit")
        occursin(r"^cost of (revenue|sales|goods sold)", t)    && return C("ifrs-full:CostOfSales")
        (occursin(r"^operating profit", t) || occursin(r"^profit from operat", t)) &&
            return C("ifrs-full:ProfitLossFromOperatingActivities")
        (occursin("profit before", t) && occursin("tax", t))   && return C("ifrs-full:ProfitLossBeforeTax")
        (t == "profit for the year" || t == "profit for the period" ||
         occursin(r"^profit(/\(loss\))? for the (year|period)", t)) && return C("ifrs-full:ProfitLoss")
        occursin(r"(equity holders|owners) of the (company|parent)", t) &&
            return C("ifrs-full:ProfitLossAttributableToOwnersOfParent")

    elseif statement == "CashFlow"
        iscash = occursin("net cash", t) || occursin("cash generated", t) || occursin("cash used", t)
        iscash && occursin("operating activities", t)          && return C("ifrs-full:CashFlowsFromUsedInOperatingActivities")
        iscash && occursin("investing activities", t)          && return C("ifrs-full:CashFlowsFromUsedInInvestingActivities")
        iscash && occursin("financing activities", t)          && return C("ifrs-full:CashFlowsFromUsedInFinancingActivities")
        occursin(r"net (\(?(increase|decrease)\)?)", t) && occursin("cash", t) &&
            return C("ifrs-full:IncreaseDecreaseInCashAndCashEquivalents")
    end
    return nothing
end
