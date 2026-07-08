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
function _ifrs_norm(s::AbstractString)
    t = lowercase(strip(String(s)))
    t = replace(t, r"[*†‡]" => "")
    # Drop a leading enumerator — German statements number their lines ("1. Konzernumsatz", "A. Langfristige
    # Vermögenswerte", "II. Firmenwerte"). Strip a leading arabic/roman/letter item marker + separator so the
    # label matches on its text.
    t = replace(t, r"^\s*(?:\d{1,2}|[ivxlcivxlc]{1,4}|[a-z])[.)]\s+" => "")
    t = replace(t, r"\s+" => " ")
    return strip(t)
end

"""
    ifrs_label_concept(label, statement) -> Union{Nothing, NamedTuple{(:concept,:instant,:balance)}}

Classify an English HKFRS statement `label` (as clustered from a PDF row) to its `ifrs-full` concept, period
type and **balance** (`:debit` / `:credit` / `:none`), within a known `statement` ("BalanceSheet" /
"IncomeStatement" / "CashFlow"), or `nothing` if it is not a recognised headline anchor. Pattern-based
(English phrasings vary) and statement-aware. The `balance` separates the line item's **value** from its
**contribution**: a debit line (e.g. cost of sales) is printed in parentheses because it is *subtracted*, but
its value is the positive magnitude — the sign belongs to the calculation, not the stored fact, matching the
`ifrs-full` XBRL convention. `:none` marks genuinely-signed lines (cash-flow net flows). Only the totals needed
for cross-foot and the benchmark are mapped. See [`extract_ifrs_pdf`](@ref).
"""
function ifrs_label_concept(label::AbstractString, statement::AbstractString)
    t = _ifrs_norm(label)
    isempty(t) && return nothing
    inst = statement == "BalanceSheet"
    C(c, bal::Symbol) = (concept = c, instant = inst, balance = bal)

    if statement == "BalanceSheet"
        t == "total assets"                                    && return C("ifrs-full:Assets", :debit)
        t == "total liabilities"                               && return C("ifrs-full:Liabilities", :credit)
        # REIT / investment fund: units are the residual "net assets attributable to unitholders" (the equity-
        # equivalent), and the liabilities line explicitly EXCLUDES them — test that liabilities line FIRST so
        # it is not captured by the net-assets rule below.
        occursin(r"(?i)total liabilities.*(excluding|net assets)", t) && return C("ifrs-full:Liabilities", :credit)
        (occursin("net assets attributable to", t) && occursin("unitholder", t)) &&
            return C("ifrs-full:Equity", :credit)             # REIT "Net assets attributable to Unitholders"
        # current/non-current subtotals — standard ifrs-full elements (a net-assets-format balance sheet, e.g.
        # PetroChina/CKH, carries these instead of a single Total assets/Total liabilities; Total assets is then
        # NoncurrentAssets + CurrentAssets, a computation, not a stored line).
        occursin(r"^total non.?current assets$", t)            && return C("ifrs-full:NoncurrentAssets", :debit)
        t == "total current assets"                            && return C("ifrs-full:CurrentAssets", :debit)
        occursin(r"^total non.?current liabilities$", t)       && return C("ifrs-full:NoncurrentLiabilities", :credit)
        t == "total current liabilities"                       && return C("ifrs-full:CurrentLiabilities", :credit)
        # "Total ordinary shareholders' funds" is the owners'-of-parent subtotal (excludes NCI + perpetual
        # capital), so it must be tested BEFORE the whole-equity "shareholders' funds" rule below.
        (t == "total ordinary shareholders' funds" || occursin("ordinary shareholders' funds", t)) &&
            return C("ifrs-full:EquityAttributableToOwnersOfParent", :credit)
        (t == "total equity" || t == "net assets" ||
         (occursin("shareholders", t) && occursin("funds", t) && !occursin("ordinary", t))) &&
            return C("ifrs-full:Equity", :credit)             # whole equity: UK "Total shareholders' funds", "Total equity"
        (t == "total equity and liabilities" ||
         t == "total liabilities and equity")                 && return C("ifrs-full:EquityAndLiabilities", :credit)
        # the owners'-of-parent equity subtotal, however its leading noun is phrased — "Equity attributable
        # to equity holders of the Company", a bank's "Capital and reserves attributable to equity holders".
        (occursin(r"attributable to (?:the )?(?:equity holders|owners|(?:equity )?shareholders)", t) &&
         !occursin("non-controlling", t))                     && return C("ifrs-full:EquityAttributableToOwnersOfParent", :credit)  # incl. "equity shareholders"
        t == "non-controlling interests"                       && return C("ifrs-full:NoncontrollingInterests", :credit)
        # --- German (Konzernbilanz). Totals are "Summe …" (Bilanzsumme = total assets). Test the current/
        # non-current and owners'-equity subtotals BEFORE the umbrella totals they are substrings of.
        occursin(r"summe (?:kurzfristige[rn]?|kurzfristiger) vermögenswerte", t) && return C("ifrs-full:CurrentAssets", :debit)
        occursin(r"summe (?:langfristige[rn]?|langfristiger) vermögenswerte", t) && return C("ifrs-full:NoncurrentAssets", :debit)
        (occursin("summe aktiva", t) || t == "bilanzsumme")    && return C("ifrs-full:Assets", :debit)
        occursin(r"summe (?:kurzfristige[rn]?|kurzfristiger) verbindlichkeiten", t) && return C("ifrs-full:CurrentLiabilities", :credit)
        occursin(r"summe (?:langfristige[rn]?|langfristiger) verbindlichkeiten", t) && return C("ifrs-full:NoncurrentLiabilities", :credit)
        occursin("summe verbindlichkeiten", t)                 && return C("ifrs-full:Liabilities", :credit)
        occursin("summe passiva", t)                           && return C("ifrs-full:EquityAndLiabilities", :credit)
        # owners'-of-parent equity subtotal ("Summe Eigenkapital der Aktionäre der …") — tested before the
        # whole-equity "Summe Eigenkapital" it contains.
        (occursin("eigenkapital der aktionäre", t) || occursin("eigenkapital der anteilseigner", t) ||
         occursin("eigentümer des mutterunternehmens", t) ||   # Fielmann "Eigenkapital der Eigentümer des Mutterunternehmens"
         occursin(r"den (?:aktionären|anteilseignern).{0,30}zustehende", t)) && return C("ifrs-full:EquityAttributableToOwnersOfParent", :credit)
        occursin("summe eigenkapital", t)                      && return C("ifrs-full:Equity", :credit)
        occursin("nicht beherrschende anteile", t)             && return C("ifrs-full:NoncontrollingInterests", :credit)

    elseif statement == "IncomeStatement"
        (t == "revenue" || t == "revenues" || t == "turnover" || t == "operating revenue" ||
         t == "total revenue" || t == "total revenues")       && return C("ifrs-full:Revenue", :credit)
        t == "gross profit"                                    && return C("ifrs-full:GrossProfit", :credit)
        occursin(r"^cost of (revenue|sales|goods sold)", t)    && return C("ifrs-full:CostOfSales", :debit)
        # Bank interest lines — all three are STANDARD ifrs-full elements (verified against Santander's ESEF
        # tagging: RevenueFromInterest − InterestExpense = InterestRevenueExpense, i.e. net interest income).
        t == "interest income"                                 && return C("ifrs-full:RevenueFromInterest", :credit)
        t == "interest expense"                                && return C("ifrs-full:InterestExpense", :debit)
        t == "net interest income"                             && return C("ifrs-full:InterestRevenueExpense", :credit)
        (occursin(r"^operating profit", t) || occursin(r"^profit from operat", t)) &&
            return C("ifrs-full:ProfitLossFromOperatingActivities", :credit)
        (occursin("before tax", t) ||                                  # UK "…before taxation" / "…before tax"
         (occursin("profit before", t) && occursin("tax", t)))  && return C("ifrs-full:ProfitLossBeforeTax", :credit)
        (t == "profit for the year" || t == "profit for the period" ||
         t == "profit after tax" || t == "profit after taxation" ||          # CK Hutchison's net-income line
         occursin(r"^profit(/\(loss\))? for the (year|period)", t) ||
         occursin("for the financial year", t))                 && return C("ifrs-full:ProfitLoss", :credit)  # UK "Profit for the financial year" (OCR-tolerant)
        (occursin(r"(?i)(profit|loss) for the (year|period)", t) && occursin("unitholder", t)) &&
            return C("ifrs-full:ProfitLoss", :credit)          # REIT "Loss for the year, before transactions with Unitholders"
        # profit attribution — test the NCI/minority split FIRST so it is not captured by the owners' rule
        # (CK Hutchison: "Profit attributable to non-controlling interests and holders of perpetual capital…").
        occursin(r"attributable to (non-controlling|minority)", t) &&
            return C("ifrs-full:ProfitLossAttributableToNoncontrollingInterests", :credit)
        (occursin(r"(?:equity holders|equity shareholders|owners) of the (?:company|parent)", t) ||
         occursin(r"attributable to (?:the )?(?:ordinary |equity )?shareholders", t)) &&   # CKH "ordinary", China Mobile "equity"
            return C("ifrs-full:ProfitLossAttributableToOwnersOfParent", :credit)
        # --- German (Konzern-Gewinn- und Verlustrechnung). Note the attribution lines ("Nicht beherrschende
        # Anteile" / "Aktionäre der …") sit under a "Davon entfallen auf:" heading; test the NCI split first.
        (startswith(t, "umsatzerlöse") || startswith(t, "konzernumsatz") || t == "umsatz")  && return C("ifrs-full:Revenue", :credit)
        startswith(t, "umsatzkosten")                          && return C("ifrs-full:CostOfSales", :debit)
        startswith(t, "bruttoergebnis")                        && return C("ifrs-full:GrossProfit", :credit)
        occursin("nicht beherrschende anteile", t)             && return C("ifrs-full:ProfitLossAttributableToNoncontrollingInterests", :credit)
        (occursin("aktionäre der", t) || occursin("anteilseigner der", t) ||
         occursin("eigentümer des mutterunternehmens", t)) && return C("ifrs-full:ProfitLossAttributableToOwnersOfParent", :credit)
        (occursin("vor ertragsteuern", t) || occursin("vor steuern", t))   && return C("ifrs-full:ProfitLossBeforeTax", :credit)
        (occursin("gewinn nach steuern", t) || occursin("ergebnis nach steuern", t) ||
         occursin("jahresüberschuss", t) || occursin("konzernergebnis", t) ||
         occursin("periodenergebnis", t))                      && return C("ifrs-full:ProfitLoss", :credit)

    elseif statement == "CashFlow"
        iscash = occursin("net cash", t) || occursin("cash generated", t) || occursin("cash used", t)
        iscash && occursin("operating activities", t)          && return C("ifrs-full:CashFlowsFromUsedInOperatingActivities", :none)
        iscash && occursin("investing activities", t)          && return C("ifrs-full:CashFlowsFromUsedInInvestingActivities", :none)
        iscash && occursin("financing activities", t)          && return C("ifrs-full:CashFlowsFromUsedInFinancingActivities", :none)
        occursin(r"net (\(?(increase|decrease)\)?)", t) && occursin("cash", t) &&
            return C("ifrs-full:IncreaseDecreaseInCashAndCashEquivalents", :none)
        # --- German (Konzern-Kapitalflussrechnung). A filer with discontinued operations reports THREE lines per
        # activity — continuing / discontinued / combined; map only the COMBINED total ("fortgeführte und nicht
        # fortgeführte Aktivitäten"), or the sole line when there is no discontinued split, so the concept is not
        # triple-counted.
        de_comb = occursin("fortgeführte und nicht fortgeführte", t)
        de_sub  = occursin("fortgeführte", t) || occursin("nicht fortgeführt", t)
        (startswith(t, "cashflow aus betrieblicher") && (de_comb || !de_sub)) && return C("ifrs-full:CashFlowsFromUsedInOperatingActivities", :none)
        (startswith(t, "cashflow aus investitions") && (de_comb || !de_sub))  && return C("ifrs-full:CashFlowsFromUsedInInvestingActivities", :none)
        (startswith(t, "cashflow aus finanzierungs") && (de_comb || !de_sub)) && return C("ifrs-full:CashFlowsFromUsedInFinancingActivities", :none)
        startswith(t, "veränderung der zahlungsmittel")        && return C("ifrs-full:IncreaseDecreaseInCashAndCashEquivalents", :none)
    end
    return nothing
end
