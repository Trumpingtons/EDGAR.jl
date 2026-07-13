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
    t = replace(t, r"[’‘`´]" => "'")   # typographic apostrophes → ASCII (fr "chiffre d'affaires", it "utile dell'esercizio")
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
        # optional "Summe": BASF prints the bare "Kurzfristige/Langfristige Vermögenswerte" subtotal (Siemens
        # "Summe …"); anchored so a line item "Sonstige langfristige Vermögenswerte" does not match.
        occursin(r"^(?:summe )?(?:kurzfristige[rn]?|kurzfristiger) vermögenswerte$", t) && return C("ifrs-full:CurrentAssets", :debit)
        occursin(r"^(?:summe )?(?:langfristige[rn]?|langfristiger) vermögenswerte$", t) && return C("ifrs-full:NoncurrentAssets", :debit)
        (occursin("summe aktiva", t) || t == "bilanzsumme" || t == "gesamtvermögen")  && return C("ifrs-full:Assets", :debit)  # BASF: "Gesamtvermögen"
        occursin(r"summe (?:kurzfristige[rn]?|kurzfristiger) verbindlichkeiten", t) && return C("ifrs-full:CurrentLiabilities", :credit)
        occursin(r"summe (?:langfristige[rn]?|langfristiger) verbindlichkeiten", t) && return C("ifrs-full:NoncurrentLiabilities", :credit)
        occursin("summe verbindlichkeiten", t)                 && return C("ifrs-full:Liabilities", :credit)
        (occursin("summe passiva", t) || t == "gesamtkapital") && return C("ifrs-full:EquityAndLiabilities", :credit)  # BASF: "Gesamtkapital"
        # owners'-of-parent equity subtotal ("Summe Eigenkapital der Aktionäre der …") — tested before the
        # whole-equity "Summe Eigenkapital" it contains.
        (occursin("eigenkapital der aktionäre", t) || occursin("eigenkapital der anteilseigner", t) ||
         occursin("eigentümer des mutterunternehmens", t) ||   # Fielmann "Eigenkapital der Eigentümer des Mutterunternehmens"
         occursin(r"den (?:aktionären|anteilseignern).{0,30}zustehende", t)) && return C("ifrs-full:EquityAttributableToOwnersOfParent", :credit)
        occursin("summe eigenkapital", t)                      && return C("ifrs-full:Equity", :credit)
        occursin("nicht beherrschende anteile", t)             && return C("ifrs-full:NoncontrollingInterests", :credit)
        # --- Romance balance sheets (pt/fr/it/es). Test the current/non-current & owners'-of-parent subtotals
        # BEFORE the umbrella totals they are substrings of. Docling occasionally drops an inter-word space in
        # ALL-CAPS Italian totals ("PATRIMONIONETTO", "NETTOEPASSIVITÀ"), so those allow an optional space.
        # Portuguese (WEG): "Total do Ativo/Passivo", "Patrimônio Líquido"; French (TotalEnergies): "Total
        # actif", "Total passif et capitaux propres", "Total des capitaux propres"; Italian (Enel): "TOTALE
        # ATTIVITÀ", "TOTALE PATRIMONIO NETTO E PASSIVITÀ".
        occursin(r"^total (?:do )?ativos? não[- ]?circulantes?$"i, t) && return C("ifrs-full:NoncurrentAssets", :debit)  # pt
        occursin(r"^total (?:do )?ativos? circulantes?$"i, t)         && return C("ifrs-full:CurrentAssets", :debit)
        occursin(r"^total (?:do )?passivos? não[- ]?circulantes?$"i, t) && return C("ifrs-full:NoncurrentLiabilities", :credit)
        occursin(r"^total (?:do )?passivos? circulantes?$"i, t)       && return C("ifrs-full:CurrentLiabilities", :credit)
        occursin(r"^total actifs? non[- ]?courants?$"i, t)            && return C("ifrs-full:NoncurrentAssets", :debit)   # fr
        occursin(r"^total actifs? courants?$"i, t)                    && return C("ifrs-full:CurrentAssets", :debit)
        occursin(r"^total passifs? non[- ]?courants?$"i, t)           && return C("ifrs-full:NoncurrentLiabilities", :credit)
        occursin(r"^total passifs? courants?$"i, t)                   && return C("ifrs-full:CurrentLiabilities", :credit)
        occursin(r"total (?:des )?capitaux propres.*part"i, t)        && return C("ifrs-full:EquityAttributableToOwnersOfParent", :credit)  # fr, before whole-equity
        (occursin(r"^total (?:do )?ativos?$"i, t) || occursin(r"^total actif$"i, t) ||
         occursin(r"^totale attivit[àa]$"i, t))                       && return C("ifrs-full:Assets", :debit)
        (occursin(r"^total (?:do )?passivos?$"i, t) || occursin(r"^totale passivit[àa]$"i, t)) &&
            return C("ifrs-full:Liabilities", :credit)
        (occursin(r"^total passif et capitaux propres$"i, t) ||
         occursin(r"^totale patrimonio ?netto ?e ?passivit[àa]$"i, t)) && return C("ifrs-full:EquityAndLiabilities", :credit)
        (occursin(r"^patrim[ôo]nio l[íi]quido$"i, t) || occursin(r"^total (?:des )?capitaux propres$"i, t) ||
         occursin(r"^totale patrimonio ?netto$"i, t))                && return C("ifrs-full:Equity", :credit)
        # Spanish (Inditex): Docling glues words in ALL-CAPS totals ("TOTALPASIVOYPATRIMONIONETO",
        # "PATRIMONIONETO"), so allow optional space between words. Test owners'-of-parent before whole equity.
        occursin(r"^total\s*activo$"i, t)                            && return C("ifrs-full:Assets", :debit)  # es
        occursin(r"^total\s*pasivo\s*y\s*patrimonio\s*neto$"i, t)    && return C("ifrs-full:EquityAndLiabilities", :credit)
        occursin(r"^patrimonio\s*neto atribuido a la dominante"i, t) && return C("ifrs-full:EquityAttributableToOwnersOfParent", :credit)
        occursin(r"^patrimonio\s*neto$"i, t)                         && return C("ifrs-full:Equity", :credit)
        # Nordic (sv/da). Docling glues ALL-CAPS Swedish totals ("SUMMATILLGÅNGAR", "SUMMAEGETKAPITAL"), so
        # allow optional spaces. Test the current/non-current subtotals before the umbrella totals. sv "summa"
        # = total; da "… i alt" = total, with "aktiver" (assets) / "passiver" (equity+liabilities) sides.
        (occursin(r"^summa\s*anläggningstillgångar$"i, t) || occursin(r"^anlægsaktiver i alt$"i, t)) && return C("ifrs-full:NoncurrentAssets", :debit)  # sv/da
        (occursin(r"^summa\s*omsättningstillgångar$"i, t) || occursin(r"^omsætningsaktiver i alt$"i, t)) && return C("ifrs-full:CurrentAssets", :debit)
        (occursin(r"^summa\s*eget\s*kapital\s*och\s*skulder$"i, t) || occursin(r"^passiver i alt$"i, t)) && return C("ifrs-full:EquityAndLiabilities", :credit)
        (occursin(r"^summa\s*tillgångar$"i, t) || occursin(r"^aktiver i alt$"i, t)) && return C("ifrs-full:Assets", :debit)
        (occursin(r"^summa\s*eget\s*kapital$"i, t) || occursin(r"^egenkapital i alt$"i, t)) && return C("ifrs-full:Equity", :credit)
        # Dutch (nl, Liander): "Totaal activa/vaste activa/vlottende activa", "Totaal (eigen vermogen en)
        # verplichtingen", "Totaal eigen vermogen". Anchored, so the subtotals don't match the umbrella totals.
        occursin(r"^totaal vaste activa$"i, t)                       && return C("ifrs-full:NoncurrentAssets", :debit)  # nl
        occursin(r"^totaal vlottende activa$"i, t)                   && return C("ifrs-full:CurrentAssets", :debit)
        occursin(r"^totaal langlopende verplichtingen$"i, t)         && return C("ifrs-full:NoncurrentLiabilities", :credit)
        occursin(r"^totaal kortlopende verplichtingen$"i, t)         && return C("ifrs-full:CurrentLiabilities", :credit)
        occursin(r"^totaal eigen vermogen en verplichtingen$"i, t)   && return C("ifrs-full:EquityAndLiabilities", :credit)
        occursin(r"^totaal verplichtingen$"i, t)                     && return C("ifrs-full:Liabilities", :credit)
        occursin(r"^totaal activa$"i, t)                             && return C("ifrs-full:Assets", :debit)
        occursin(r"^totaal eigen vermogen$"i, t)                     && return C("ifrs-full:Equity", :credit)
        # Polish (pl, KGHM). "RAZEM AKTYWA", "Aktywa trwałe/obrotowe", "Kapitał własny (akcjonariuszy Jednostki
        # Dominującej)", "RAZEM ZOBOWIĄZANIA I KAPITAŁ WŁASNY". Anchored; owners'-of-parent tested via its own line.
        occursin(r"^aktywa trwałe$"i, t)                             && return C("ifrs-full:NoncurrentAssets", :debit)  # pl
        occursin(r"^aktywa obrotowe$"i, t)                           && return C("ifrs-full:CurrentAssets", :debit)
        occursin(r"^zobowiązania długoterminowe$"i, t)               && return C("ifrs-full:NoncurrentLiabilities", :credit)
        occursin(r"^zobowiązania krótkoterminowe$"i, t)              && return C("ifrs-full:CurrentLiabilities", :credit)
        occursin(r"^(?:razem aktywa|aktywa razem)$"i, t)             && return C("ifrs-full:Assets", :debit)
        occursin(r"^(?:razem zobowiązania i kapitał własny|kapitał własny i zobowiązania razem)$"i, t) && return C("ifrs-full:EquityAndLiabilities", :credit)
        occursin(r"^kapitał własny akcjonariuszy jednostki dominującej$"i, t) && return C("ifrs-full:EquityAttributableToOwnersOfParent", :credit)
        occursin(r"^kapitał własny$"i, t)                            && return C("ifrs-full:Equity", :credit)
        # Finnish (fi, Kesko) "… yhteensä" / Norwegian (no, NorgesGruppen) "Sum …". Docling may glue fi
        # "Oma pääoma" → "omapääoma", so allow an optional space.
        (occursin(r"^pitkäaikaiset varat yhteensä$"i, t) || occursin(r"^sum anleggsmidler$"i, t)) && return C("ifrs-full:NoncurrentAssets", :debit)  # fi/no
        (occursin(r"^lyhytaikaiset varat yhteensä$"i, t) || occursin(r"^sum omløpsmidler$"i, t)) && return C("ifrs-full:CurrentAssets", :debit)
        (occursin(r"^pitkäaikaiset velat yhteensä$"i, t) || occursin(r"^sum langsiktig gjeld$"i, t)) && return C("ifrs-full:NoncurrentLiabilities", :credit)
        (occursin(r"^lyhytaikaiset velat yhteensä$"i, t) || occursin(r"^sum kortsiktig gjeld$"i, t)) && return C("ifrs-full:CurrentLiabilities", :credit)
        (occursin(r"^oma ?pääoma ja velat yhteensä$"i, t) || occursin(r"^sum egenkapital og gjeld$"i, t)) && return C("ifrs-full:EquityAndLiabilities", :credit)
        (occursin(r"^velat yhteensä$"i, t) || occursin(r"^sum gjeld$"i, t)) && return C("ifrs-full:Liabilities", :credit)
        (occursin(r"^varat yhteensä$"i, t) || occursin(r"^sum eiendeler$"i, t)) && return C("ifrs-full:Assets", :debit)
        (occursin(r"^oma ?pääoma yhteensä$"i, t) || occursin(r"^sum egenkapital$"i, t)) && return C("ifrs-full:Equity", :credit)
        # Japanese (ja, Fast Retailing IFRS) / Korean (ko, Samsung K-IFRS). CJK totals carry no leading
        # enumerator, so anchor on the total line. ja "資産合計/資本合計/負債及び資本合計"; ko (FSS-standard)
        # "자산총계/자본총계/부채와자본총계". [ko BS/IS labels are the standard forms — the Samsung BS PDF's font
        # did not decode; ko cash-flow IS from the live parse.]
        occursin("親会社の所有者に帰属する持分", t)                    && return C("ifrs-full:EquityAttributableToOwnersOfParent", :credit)  # ja
        occursin(r"^流動資産合計$", t)                                && return C("ifrs-full:CurrentAssets", :debit)  # ja
        occursin(r"^非流動資産合計$", t)                              && return C("ifrs-full:NoncurrentAssets", :debit)
        (occursin(r"^負債及び資本合計$", t) || occursin(r"^부채와?자본총계$", t)) && return C("ifrs-full:EquityAndLiabilities", :credit)  # ja/ko
        (occursin(r"^負債合計$", t)         || occursin(r"^부채총계$", t))       && return C("ifrs-full:Liabilities", :credit)
        (occursin(r"^資産合計$", t)         || occursin(r"^자산총계$", t))       && return C("ifrs-full:Assets", :debit)
        (occursin(r"^資本合計$", t)         || occursin(r"^자본총계$", t))       && return C("ifrs-full:Equity", :credit)

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
        # --- Romance income statements (pt/fr/it). Revenue: pt "Receita (líquida)", fr "Chiffre d'affaires",
        # it "Ricavi" (exact — the sub-line "Ricavi delle vendite…" must not match). Net profit: pt "Lucro
        # líquido (do exercício)", fr "Résultat net de l'ensemble consolidé", it "Utile dell'esercizio".
        (t == "ricavi" || t == "chiffre d'affaires" || occursin(r"^receitas?(?: líquidas?| de vendas| operacional)?$"i, t)) &&
            return C("ifrs-full:Revenue", :credit)
        (occursin(r"^risultato operativo$"i, t) || occursin(r"^résultat (?:net )?opérationnel"i, t) ||
         occursin(r"^resultado operacional"i, t))              && return C("ifrs-full:ProfitLossFromOperatingActivities", :credit)
        (occursin(r"risultato prima delle imposte"i, t) || occursin(r"résultat avant impôt"i, t) ||
         occursin(r"(?:lucro|resultado) antes (?:do|dos|de).*(?:imposto|tributos)"i, t)) &&
            return C("ifrs-full:ProfitLossBeforeTax", :credit)
        (occursin(r"^utile(?:/\(perdita\))? dell'esercizio"i, t) || occursin(r"résultat net de l'ensemble consolidé"i, t) ||
         occursin(r"^(?:lucro|prejuízo) líquido(?: do exercício| consolidado)?$"i, t)) &&
            return C("ifrs-full:ProfitLoss", :credit)
        # Spanish (Inditex): "Ventas"/"Importe neto de la cifra de negocios"; EBIT "Resultados de explotación";
        # "Resultados antes de impuestos"; net "Resultado neto del ejercicio" / "…atribuido a la dominante".
        # Docling glues ALL-CAPS lines, so allow optional spaces; no `$` where a "(EBIT)"/"(BAI)" suffix trails.
        (t == "ventas" || occursin(r"importe neto de la cifra de negocios"i, t)) && return C("ifrs-full:Revenue", :credit)  # es
        occursin(r"^resultados?\s*de\s*explotación"i, t)         && return C("ifrs-full:ProfitLossFromOperatingActivities", :credit)
        occursin(r"^resultados?\s*antes\s*de\s*impuestos"i, t)   && return C("ifrs-full:ProfitLossBeforeTax", :credit)
        occursin(r"^resultado\s*neto\s*atribuido\s*a\s*la\s*dominante"i, t) && return C("ifrs-full:ProfitLossAttributableToOwnersOfParent", :credit)
        occursin(r"^resultado\s*neto\s*del\s*ejercicio"i, t)     && return C("ifrs-full:ProfitLoss", :credit)
        # Nordic (sv/da). Revenue: sv "Nettoomsättning" / da "Nettoomsætning". EBIT: sv "Rörelseresultat" /
        # da "Driftsresultat". Pre-tax: sv "Resultat efter finansiella poster" (the Swedish pre-tax subtotal) /
        # da "Resultat før skat". Net: sv/da "Årets resultat" (shared).
        (t == "nettoomsättning" || t == "nettoomsætning")       && return C("ifrs-full:Revenue", :credit)  # sv/da
        (t == "rörelseresultat" || t == "driftsresultat")       && return C("ifrs-full:ProfitLossFromOperatingActivities", :credit)
        (occursin(r"^resultat efter finansiella poster$"i, t) || occursin(r"^resultat før skat$"i, t)) && return C("ifrs-full:ProfitLossBeforeTax", :credit)
        occursin(r"^årets resultat$"i, t)                        && return C("ifrs-full:ProfitLoss", :credit)
        # Dutch (nl, Liander): "Netto-omzet"; EBIT "Bedrijfsresultaat"; pre-tax "Resultaat voor belastingen";
        # net "Resultaat na belastingen".
        occursin(r"^netto-?omzet$"i, t)                          && return C("ifrs-full:Revenue", :credit)  # nl
        occursin(r"^bedrijfsresultaat$"i, t)                     && return C("ifrs-full:ProfitLossFromOperatingActivities", :credit)
        occursin(r"^resultaat voor belastingen$"i, t)            && return C("ifrs-full:ProfitLossBeforeTax", :credit)
        occursin(r"^resultaat na belastingen$"i, t)              && return C("ifrs-full:ProfitLoss", :credit)
        # Polish (pl, KGHM): revenue "Przychody z umów z klientami" / "Przychody (netto) ze sprzedaży"; operating
        # "Zysk (strata) z działalności operacyjnej"; pre-tax "…przed opodatkowaniem"; net "(Strata)/zysk netto"
        # (NOT "…ze sprzedaży", the profit-on-sales subtotal, nor "…przypadający", the attribution line).
        occursin(r"^przychody (?:z umów z klientami|netto ze sprzedaży|ze sprzedaży)"i, t) && return C("ifrs-full:Revenue", :credit)  # pl
        occursin(r"zysk.{0,12}z działalności operacyjnej$"i, t)  && return C("ifrs-full:ProfitLossFromOperatingActivities", :credit)
        occursin(r"przed opodatkowaniem$"i, t)                   && return C("ifrs-full:ProfitLossBeforeTax", :credit)
        occursin(r"^(?:\(?strata\)?/zysk|zysk(?: \(strata\))?) netto$"i, t) && return C("ifrs-full:ProfitLoss", :credit)
        # Finnish (fi): "Liikevaihto"/"Liikevoitto"/"Tulos ennen veroja"/"Tilikauden tulos". Norwegian (no):
        # "Sum driftsinntekter"/"Resultat før skattekostnad"/"Årsresultat" (operating "Driftsresultat" shared
        # with da/sv above).
        (occursin(r"^liikevaihto$"i, t) || occursin(r"^sum driftsinntekter$"i, t)) && return C("ifrs-full:Revenue", :credit)  # fi/no
        (occursin(r"^liikevoitto$"i, t) || occursin(r"^liiketulos$"i, t)) && return C("ifrs-full:ProfitLossFromOperatingActivities", :credit)
        (occursin(r"^tulos ennen veroja$"i, t) || occursin(r"^resultat før skat(?:t|tekostnad)?$"i, t)) && return C("ifrs-full:ProfitLossBeforeTax", :credit)
        (occursin(r"^tilikauden tulos$"i, t) || occursin(r"^årsresultat$"i, t)) && return C("ifrs-full:ProfitLoss", :credit)
        # Japanese (ja): 売上収益 / 営業利益 / 税引前利益 / 当期利益. Korean (ko): 매출액|수익(매출액) / 영업이익 /
        # 법인세비용차감전순이익 / 당기순이익 (± "(손실)").
        (occursin(r"^売上収益$", t) || occursin(r"^매출액$", t) || occursin(r"^수익\(매출액\)$", t)) && return C("ifrs-full:Revenue", :credit)  # ja/ko
        occursin(r"^売上総利益$", t)                                  && return C("ifrs-full:GrossProfit", :credit)  # ja
        (occursin(r"^営業利益$", t) || occursin(r"^영업이익(?:\(손실\))?$", t)) && return C("ifrs-full:ProfitLossFromOperatingActivities", :credit)  # ja/ko
        (occursin(r"^税引前利益$", t) || occursin(r"^법인세비용차감전순이익$", t)) && return C("ifrs-full:ProfitLossBeforeTax", :credit)
        (occursin(r"^当期利益$", t) || occursin(r"^당기순이익(?:\(손실\))?$", t)) && return C("ifrs-full:ProfitLoss", :credit)

    elseif statement == "CashFlow"
        # "net cash from/used in", "cash generated from", or "cash flow(s) from/used in/provided by" + the
        # activity — NA filers (Loblaw) write "Cash flows from operating activities" with no "net".
        iscash = occursin("net cash", t) || occursin("cash generated", t) || occursin("cash used", t) ||
                 occursin(r"cash flows? (?:from|used in|provided by)", t)
        iscash && occursin("operating activities", t)          && return C("ifrs-full:CashFlowsFromUsedInOperatingActivities", :none)
        iscash && occursin("investing activities", t)          && return C("ifrs-full:CashFlowsFromUsedInInvestingActivities", :none)
        iscash && occursin("financing activities", t)          && return C("ifrs-full:CashFlowsFromUsedInFinancingActivities", :none)
        # net change in cash — with or without a leading "net" ("Decrease in cash and cash equivalents", Loblaw)
        ((occursin(r"net \(?(?:increase|decrease)", t) || occursin(r"^\(?(?:increase|decrease).{0,45}in cash", t)) &&
         occursin("cash", t)) && return C("ifrs-full:IncreaseDecreaseInCashAndCashEquivalents", :none)
        # --- German (Konzern-Kapitalflussrechnung). A filer with discontinued operations reports THREE lines per
        # activity — continuing / discontinued / combined; map only the COMBINED total ("fortgeführte und nicht
        # fortgeführte Aktivitäten"), or the sole line when there is no discontinued split, so the concept is not
        # triple-counted.
        de_comb = occursin("fortgeführte und nicht fortgeführte", t)
        de_sub  = occursin("fortgeführte", t) || occursin("nicht fortgeführt", t)
        # operating cash flow — "aus betrieblicher Tätigkeit" (Siemens) or "laufendes Geschäft" (Volkswagen's
        # wording for cash generated by the ongoing operating business).
        ((startswith(t, "cashflow aus betrieblicher") || startswith(t, "cashflow laufendes geschäft")) &&
         (de_comb || !de_sub)) && return C("ifrs-full:CashFlowsFromUsedInOperatingActivities", :none)
        (startswith(t, "cashflow aus investitions") && (de_comb || !de_sub))  && return C("ifrs-full:CashFlowsFromUsedInInvestingActivities", :none)
        (startswith(t, "cashflow aus finanzierungs") && (de_comb || !de_sub)) && return C("ifrs-full:CashFlowsFromUsedInFinancingActivities", :none)
        startswith(t, "veränderung der zahlungsmittel")        && return C("ifrs-full:IncreaseDecreaseInCashAndCashEquivalents", :none)
        # --- Romance cash flows (pt/fr/it). it "Cash flow da attività operativa/di investimento/di
        # finanziamento (a)/(b)/(c)"; fr "Flux de trésorerie d'exploitation / d'investissement / de
        # financement"; pt "Fluxo de caixa líquido (originado/aplicado) em atividades operacionais/de
        # investimento/de financiamento". Net change: it "Incremento/(Decremento) disponibilità liquide",
        # fr "Augmentation (diminution) de la trésorerie", pt "(Redução)/aumento (…) de caixa".
        (occursin(r"cash flow da attività operativa"i, t) || occursin(r"flux de trésorerie d.exploitation"i, t) ||
         occursin(r"fluxo de caixa.*atividades? operaci"i, t) || occursin(r"flujos.*actividades de explotación"i, t))  && return C("ifrs-full:CashFlowsFromUsedInOperatingActivities", :none)
        (occursin(r"cash flow da attività di investimento"i, t) || occursin(r"flux de trésorerie d.investissement"i, t) ||
         occursin(r"fluxo de caixa.*atividades? de investimento"i, t) || occursin(r"flujos.*actividades de inversión"i, t)) && return C("ifrs-full:CashFlowsFromUsedInInvestingActivities", :none)
        (occursin(r"cash flow da attività di finanziamento"i, t) || occursin(r"flux de trésorerie de financement"i, t) ||
         occursin(r"fluxo de caixa.*atividades? de financiamento"i, t) || occursin(r"flujos.*actividades de financiación"i, t)) && return C("ifrs-full:CashFlowsFromUsedInFinancingActivities", :none)
        (occursin(r"incremento.*decremento.*disponibilità liquide"i, t) || occursin(r"augmentation.*diminution.*trésorerie"i, t) ||
         occursin(r"(?:redução|aumento).*(?:caixa|equivalentes)"i, t) || occursin(r"variación neta de efectivo"i, t))  && return C("ifrs-full:IncreaseDecreaseInCashAndCashEquivalents", :none)
        # --- Nordic (sv/da). Docling glues ALL-CAPS Swedish totals ("KASSAFLÖDEFRÅNDENLÖPANDEVERKSAMHETEN"), so
        # allow optional spaces. sv "Kassaflöde från den löpande verksamheten / investeringsverksamheten /
        # finansieringsverksamheten"; da "Pengestrømme (vedrørende|fra) drift / investeringer / finansiering".
        (occursin(r"kassaflöde\s*från\s*den\s*löpande\s*verksamheten"i, t) || occursin(r"pengestrømme (?:vedrørende|fra) drift"i, t)) && return C("ifrs-full:CashFlowsFromUsedInOperatingActivities", :none)
        (occursin(r"kassaflöde\s*från\s*investeringsverksamheten"i, t) || occursin(r"pengestrømme (?:vedrørende|fra) investering"i, t)) && return C("ifrs-full:CashFlowsFromUsedInInvestingActivities", :none)
        (occursin(r"kassaflöde\s*från\s*finansieringsverksamheten"i, t) || occursin(r"pengestrømme (?:vedrørende|fra) finansiering"i, t)) && return C("ifrs-full:CashFlowsFromUsedInFinancingActivities", :none)
        (occursin(r"^årets kassaflöde$"i, t) || occursin(r"^årets ændring i likvide beholdninger$"i, t)) && return C("ifrs-full:IncreaseDecreaseInCashAndCashEquivalents", :none)
        # Dutch (nl, Liander): "Kasstroom uit operationele/investerings/financieringsactiviteiten"; net change
        # "Nettokasstroom" / "Mutatie geldmiddelen".
        occursin(r"kasstroom uit operationele activiteiten"i, t) && return C("ifrs-full:CashFlowsFromUsedInOperatingActivities", :none)  # nl
        occursin(r"kasstroom uit investeringsactiviteiten"i, t)  && return C("ifrs-full:CashFlowsFromUsedInInvestingActivities", :none)
        occursin(r"kasstroom uit financieringsactiviteiten"i, t) && return C("ifrs-full:CashFlowsFromUsedInFinancingActivities", :none)
        (occursin(r"^nettokasstroom$"i, t) || occursin(r"^mutatie geldmiddelen"i, t)) && return C("ifrs-full:IncreaseDecreaseInCashAndCashEquivalents", :none)
        # Polish (pl, KGHM): "Przepływy pieniężne netto z działalności operacyjnej/inwestycyjnej/finansowej";
        # net change "PRZEPŁYWY PIENIĘŻNE NETTO" / "Zmiana stanu środków pieniężnych".
        occursin(r"przepływy pieniężne netto z działalności operacyjnej"i, t)  && return C("ifrs-full:CashFlowsFromUsedInOperatingActivities", :none)  # pl
        occursin(r"przepływy pieniężne netto z działalności inwestycyjnej"i, t) && return C("ifrs-full:CashFlowsFromUsedInInvestingActivities", :none)
        occursin(r"przepływy pieniężne netto z działalności finansowej"i, t)   && return C("ifrs-full:CashFlowsFromUsedInFinancingActivities", :none)
        (occursin(r"^przepływy pieniężne netto$"i, t) || occursin(r"^zmiana stanu środków pieniężnych"i, t)) && return C("ifrs-full:IncreaseDecreaseInCashAndCashEquivalents", :none)
        # Finnish (fi): "Liiketoiminnan/Investointien/Rahoituksen nettorahavirta"; net "Rahavarojen muutos".
        # Norwegian (no): "Netto kontantstrøm(mer) fra operasjonelle/investerings/finansieringsaktiviteter";
        # net "Netto endring i bankinnskudd og kontanter".
        (occursin(r"liiketoiminnan nettorahavirta"i, t) || occursin(r"netto kontantstrøm(?:mer)? fra operasjonelle"i, t)) && return C("ifrs-full:CashFlowsFromUsedInOperatingActivities", :none)  # fi/no
        (occursin(r"investointien nettorahavirta"i, t) || occursin(r"netto kontantstrøm(?:mer)? fra investering"i, t)) && return C("ifrs-full:CashFlowsFromUsedInInvestingActivities", :none)
        (occursin(r"rahoituksen nettorahavirta"i, t) || occursin(r"netto kontantstrøm(?:mer)? fra finansiering"i, t)) && return C("ifrs-full:CashFlowsFromUsedInFinancingActivities", :none)
        (occursin(r"^rahavarojen muutos$"i, t) || occursin(r"netto endring i (?:bankinnskudd|kontanter)"i, t)) && return C("ifrs-full:IncreaseDecreaseInCashAndCashEquivalents", :none)
        # Japanese (ja): "…活動によるキャッシュ・フロー". Korean (ko, live Samsung): "영업/투자/재무활동현금흐름"
        # (the line keeps a Ⅰ./Ⅱ. unicode prefix, so match the core substring).
        (occursin("営業活動によるキャッシュ・フロー", t) || occursin(r"영업활동\s?현금흐름", t)) && return C("ifrs-full:CashFlowsFromUsedInOperatingActivities", :none)  # ja/ko
        (occursin("投資活動によるキャッシュ・フロー", t) || occursin(r"투자활동\s?현금흐름", t)) && return C("ifrs-full:CashFlowsFromUsedInInvestingActivities", :none)
        (occursin("財務活動によるキャッシュ・フロー", t) || occursin(r"재무활동\s?현금흐름", t)) && return C("ifrs-full:CashFlowsFromUsedInFinancingActivities", :none)
        (occursin("現金及び現金同等物の増減額", t) || occursin(r"현금및현금성자산의\s?순?증가", t)) && return C("ifrs-full:IncreaseDecreaseInCashAndCashEquivalents", :none)
    end
    return nothing
end
