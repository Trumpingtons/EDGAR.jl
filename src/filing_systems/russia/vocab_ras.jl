# Russia — vocab_ras: the OKUD line-code → statement-type classification (R3). The RAS analogue of
# `vocab_cas` (China) / `vocab_indas` (India), but SIMPLER: the OKUD forms — 0710001 (balance sheet),
# 0710002 (income statement), 0710004 (cash flow), 0710003 (changes in equity) — number every line by
# regulation, so classification is a static NUMERIC map, not label-matching. `_ras_statement(code)`
# assigns a statement to EVERY code by its leading digit (complete coverage); `_RAS_LABELS` gives English
# labels for the headline lines. Both are applied by `_rfsd_facts` under `classify` / `labels`.

# Statement family from the OKUD code's leading digit — covers all `line_XXXX` codes (incl. aggregates
# like `line_321x`, whose leading digit still classifies them):
#   1xxx = balance sheet · 2xxx = income statement · 3xxx = changes in equity · 4xxx = cash flow
#   (6xxx = targeted-use-of-funds report for non-profits — left unclassified.)
function _ras_statement(code::AbstractString)
    ncodeunits(code) ≥ 6 || return ""
    d = codeunit(code, 6)                    # the first digit after "line_"
    d == UInt8('1') && return "BalanceSheet"
    d == UInt8('2') && return "IncomeStatement"
    d == UInt8('3') && return "Equity"
    d == UInt8('4') && return "CashFlow"
    return ""
end

# English labels for the standard OKUD headline lines (subtotals + major items). A firm reports only a
# subset; unmapped codes still classify by statement but carry no label.
const _RAS_LABELS = Dict{String,String}(
    # ── Balance sheet (0710001) — assets ──
    "line_1100" => "Total non-current assets",
    "line_1110" => "Intangible assets",
    "line_1120" => "Research and development results",
    "line_1150" => "Property, plant and equipment",
    "line_1160" => "Income-generating investments in tangible assets",
    "line_1170" => "Non-current financial investments",
    "line_1180" => "Deferred tax assets",
    "line_1190" => "Other non-current assets",
    "line_1200" => "Total current assets",
    "line_1210" => "Inventories",
    "line_1220" => "VAT on acquired assets",
    "line_1230" => "Trade and other receivables",
    "line_1240" => "Current financial investments",
    "line_1250" => "Cash and cash equivalents",
    "line_1260" => "Other current assets",
    "line_1600" => "Total assets",
    # ── Balance sheet — equity & liabilities ──
    "line_1300" => "Total equity",
    "line_1310" => "Share capital",
    "line_1320" => "Treasury shares",
    "line_1340" => "Revaluation of non-current assets",
    "line_1350" => "Additional paid-in capital",
    "line_1360" => "Reserve capital",
    "line_1370" => "Retained earnings (accumulated deficit)",
    "line_1400" => "Total non-current liabilities",
    "line_1410" => "Long-term borrowings",
    "line_1420" => "Deferred tax liabilities",
    "line_1430" => "Non-current provisions",
    "line_1450" => "Other non-current liabilities",
    "line_1500" => "Total current liabilities",
    "line_1510" => "Short-term borrowings",
    "line_1520" => "Trade and other payables",
    "line_1530" => "Deferred income",
    "line_1540" => "Current provisions",
    "line_1550" => "Other current liabilities",
    "line_1700" => "Total equity and liabilities",
    # ── Income statement (0710002) ──
    "line_2110" => "Revenue",
    "line_2120" => "Cost of sales",
    "line_2100" => "Gross profit (loss)",
    "line_2210" => "Selling expenses",
    "line_2220" => "Administrative expenses",
    "line_2200" => "Profit (loss) from sales",
    "line_2310" => "Income from participation in other entities",
    "line_2320" => "Interest receivable",
    "line_2330" => "Interest payable",
    "line_2340" => "Other income",
    "line_2350" => "Other expenses",
    "line_2300" => "Profit (loss) before tax",
    "line_2410" => "Income tax",
    "line_2411" => "Current income tax",
    "line_2412" => "Deferred income tax",
    "line_2400" => "Net profit (loss)",
    "line_2510" => "Result of revaluation (OCI)",
    "line_2520" => "Other comprehensive income",
    "line_2500" => "Total comprehensive result for the period",
    "line_2900" => "Basic earnings per share",
    "line_2910" => "Diluted earnings per share",
    # ── Cash flow (0710004) ──
    "line_4100" => "Net cash flows from operating activities",
    "line_4110" => "Operating cash inflows",
    "line_4120" => "Operating cash outflows",
    "line_4200" => "Net cash flows from investing activities",
    "line_4210" => "Investing cash inflows",
    "line_4220" => "Investing cash outflows",
    "line_4300" => "Net cash flows from financing activities",
    "line_4310" => "Financing cash inflows",
    "line_4320" => "Financing cash outflows",
    "line_4400" => "Net increase (decrease) in cash and cash equivalents",
    "line_4450" => "Balance of cash at beginning of period",
    "line_4500" => "Balance of cash at end of period",
)

"""
    ras_label(code) -> String

The English label for a Russian **OKUD** line code — e.g. `ras_label("line_2110") == "Revenue"` — or `""`
if the code is not a mapped headline line. Accepts the bare code or the `ras:`-prefixed concept. This is
the label [`facts`](@ref)`(f; labels = true)` fills for a Russian `:ras` filing (R3, `vocab_ras`).
"""
ras_label(code::AbstractString) = get(_RAS_LABELS, startswith(code, "ras:") ? code[5:end] : code, "")
