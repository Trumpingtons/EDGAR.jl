# Table-classification taxonomy + per-language matching (document-first PDF repository).
#
# A repository table is classified by matching its enclosing section title / caption against a registry
# of TABLE CLASSES. The registry is deliberately OPEN: we start with the core financial statements
# (balance_sheet / income_statement / cash_flow / equity_changes) because they matter most here, but it
# is NOT financial-statement-locked — other periodic quantitative tables (e.g. fund-portfolio holdings,
# loan books, production volumes) are added as new `TableClass` entries via `register_table_class!`, with
# no change to the classifier or schema. Patterns are multi-language (EN/DE/FR/ES/IT + CJK) so one
# registry serves every jurisdiction; the per-jurisdiction profile just narrows which languages apply.

"""
    TableClass(key, description, patterns)

One class of quantitative table. `key` is the canonical tag stored in `tables.statement_type`
(e.g. `"balance_sheet"`); `patterns` are case-insensitive heading/caption regexes in any language.
"""
struct TableClass
    key::String
    kind::String          # category written to tables.kind: "statement" (BS/IS/CF/EC), "portfolio", …
    description::String
    patterns::Vector{Regex}
end

# The open registry. Order matters: the first matching class wins, so more specific classes precede
# looser ones. Append new classes with `register_table_class!` — financial or not.
const TABLE_CLASSES = TableClass[
    TableClass("balance_sheet", "statement", "Balance sheet / statement of financial position", [
        r"balance sheets?"i, r"statements? of financial position"i,
        r"statements? of assets (?:and|&) liabilities"i, r"statements? of net assets"i,   # registered funds (sing./plur.)
        r"\w*bilanz\b"i, r"\bbilan\b"i,   # \w* so the German COMPOUND "Konzernbilanz"/"Einzelbilanz" matches (not "Bilanzsumme"/"Bilanzierung", which have no boundary after "bilanz")
        r"situation financière"i, r"estado de situación financiera"i, r"stato patrimoniale"i,
        r"balanço patrimonial"i,   # pt (Brazil/Portugal)
        r"资产负债表", r"財政状態計算書|貸借対照表", r"재무상태표|대차대조표",
        r"отч[её]т о финансовом положении"i, r"бухгалтерский баланс"i]),
    TableClass("income_statement", "statement", "Income statement / profit or loss / comprehensive income", [
        r"income statements?"i, r"statements? of profit (?:or|and) loss"i, r"profit and loss account"i,
        r"statements? of comprehensive income"i, r"statements? of operations"i,   # registered funds (sing./plur.)
        r"statements? of earnings"i, r"statements? of income"i,   # NA usage — Loblaw/Dollarama "Statements of Earnings"
        r"gewinn-?\s*und\s*verlustrechnung"i, r"\bGuV\b",
        r"compte de résultat"i, r"cuenta de (?:pérdidas y ganancias|resultados)"i,
        r"conto economico"i, r"(?:utile|reddito|redditività) complessiv[ao]"i,   # IT: P&L + comprehensive income (utile complessivo)
        r"demonstraç(?:ão|ões) d[eo]s? resultados?"i,   # pt "Demonstração do Resultado (do Exercício)"
        r"利润表|损益表|综合收益表", r"損益計算書|包括利益計算書", r"손익계산서|포괄손익계산서",
        r"отч[её]т о (?:прибыл|совокупном доходе|финансовых результатах)"i, r"о прибыли или убытке"i]),
    TableClass("cash_flow", "statement", "Cash-flow statement", [
        r"cash ?flows?"i, r"statements? of cash flows?"i, r"kapitalflussrechnung"i,
        r"(?:flux|variation) de (?:la )?trésorerie"i, r"estado de flujos de efectivo"i, r"rendiconto finanziario"i,
        r"demonstraç(?:ão|ões) d[eo]s? fluxos? de caixa"i,   # pt
        r"现金流量表", r"キャッシュ・?フロー計算書", r"현금흐름표",
        r"отч[её]т о движении денежных средств"i]),
    TableClass("equity_changes", "statement", "Statement of changes in equity", [
        r"changes in equity"i, r"changes in net assets"i,   # registered funds
        r"eigenkapital(?:veränderungsrechnung|spiegel)"i,
        r"variation des capitaux propres"i, r"estado de cambios en el patrimonio"i,
        r"variazioni.{0,25}patrimonio netto"i,   # IT: (prospetto delle) variazioni (nelle voci) del/di patrimonio netto
        r"(?:所有者|股东)权益变动表", r"株主資本等変動計算書", r"자본변동표",
        r"отч[её]т об изменени.{0,15}капитал"i]),
    # Non-statement quantitative table — its own kind ("portfolio"), demonstrating the open registry.
    TableClass("fund_portfolio", "portfolio", "Fund portfolio holdings (schedule of investments)", [
        r"schedule of investments"i, r"portfolio of investments"i, r"portfolio holdings"i,
        r"consolidated schedule of investments"i, r"inventaire du portefeuille"i]),
]

"""
    register_table_class!(key, kind, description, patterns) -> TableClass

Add a new table class to [`TABLE_CLASSES`](@ref) (e.g. a loan book or production-volumes table). `kind` is
the category stored in `tables.kind` (`"statement"`, `"portfolio"`, or your own, e.g. `"schedule"`).
Inserted at the front so it takes precedence; returns the class. The classifier and DuckDB schema need no
other change.
"""
function register_table_class!(key::AbstractString, kind::AbstractString, description::AbstractString,
                               patterns::Vector{Regex})
    tc = TableClass(String(key), String(kind), String(description), patterns)
    pushfirst!(TABLE_CLASSES, tc)
    return tc
end

"""
    table_class_kind(key) -> Union{String,Nothing}

The `kind` category (e.g. `"statement"`, `"portfolio"`) for a `statement_type` key, or `nothing` if the key
is not registered. Used by `classify_tables!` to set `tables.kind`.
"""
table_class_kind(key::AbstractString) = (for tc in TABLE_CLASSES
        tc.key == key && return tc.kind
    end; nothing)

"""
    classify_table_class(heading) -> Union{String,Nothing}

Return the `statement_type` key of the first [`TableClass`](@ref) whose patterns match `heading` (a table's
section title or caption), or `nothing` if none — meaning the table is descriptive, not a recognised class.
"""
function classify_table_class(heading::AbstractString)
    for tc in TABLE_CLASSES, p in tc.patterns
        occursin(p, heading) && return tc.key
    end
    return nothing
end
