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
    d == UInt8('6') && return "TargetedFunds"       # 0710006 report on targeted use of funds (non-profits)
    return ""
end

# Period type + span for a code, given the reporting `year`. Balance-sheet lines and the equity-statement
# balances are INSTANTS; income / cash-flow / equity-movement lines are DURATIONS. The statement of changes
# in equity (0710003) carries prior-year comparatives, so its opening balances (3100 = two years back,
# 3200 = prior year) and its prior-year movements (`line_32xx`) are stamped at the correct EARLIER year-ends;
# the reporting-year balance (3300), net assets (3600) and reporting-year movements (`line_33xx`) at `year`.
const _RAS_EQ_BALANCE_OFFSET = Dict("line_3100" => -2, "line_3200" => -1, "line_3300" => 0)

function _ras_period(code::AbstractString, year::Integer)
    stmt = _ras_statement(code)
    if stmt == "BalanceSheet"
        return (true, nothing, Date(year, 12, 31))                              # instant @ reporting year-end
    elseif stmt == "Equity"
        haskey(_RAS_EQ_BALANCE_OFFSET, code) &&
            return (true, nothing, Date(year + _RAS_EQ_BALANCE_OFFSET[code], 12, 31))
        code == "line_3600" && return (true, nothing, Date(year, 12, 31))       # net assets = instant
        off = startswith(code, "line_32") ? -1 : 0                              # 32xx = prior-year movements
        return (false, Date(year + off, 1, 1), Date(year + off, 12, 31))
    elseif stmt == "TargetedFunds"
        code == "line_6100" && return (true, nothing, Date(year - 1, 12, 31))   # opening balance = instant
        code == "line_6400" && return (true, nothing, Date(year, 12, 31))       # closing balance = instant
        return (false, Date(year, 1, 1), Date(year, 12, 31))                    # receipts / uses = duration
    else                                                                        # IncomeStatement / CashFlow
        return (false, Date(year, 1, 1), Date(year, 12, 31))
    end
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
    # ── Statement of changes in equity (0710003) ──
    "line_3100" => "Equity at 31 Dec (two years before reporting)",
    "line_3200" => "Equity at 31 Dec (prior year)",
    "line_3300" => "Equity at 31 Dec (reporting year)",
    "line_3210" => "Increase in equity, prior year (total)",
    "line_3211" => "Increase, prior year — net profit",
    "line_3212" => "Increase, prior year — revaluation of property",
    "line_3213" => "Increase, prior year — income recognised directly in equity",
    "line_3214" => "Increase, prior year — additional share issue",
    "line_3215" => "Increase, prior year — increase in par value",
    "line_3216" => "Increase, prior year — reorganisation",
    "line_3220" => "Decrease in equity, prior year (total)",
    "line_3221" => "Decrease, prior year — loss",
    "line_3222" => "Decrease, prior year — revaluation of property",
    "line_3223" => "Decrease, prior year — expenses recognised directly in equity",
    "line_3224" => "Decrease, prior year — decrease in par value",
    "line_3225" => "Decrease, prior year — decrease in number of shares",
    "line_3226" => "Decrease, prior year — reorganisation",
    "line_3227" => "Decrease, prior year — dividends",
    "line_3230" => "Change in additional capital, prior year",
    "line_3240" => "Change in reserve capital, prior year",
    "line_3310" => "Increase in equity (total)",
    "line_3311" => "Increase — net profit",
    "line_3312" => "Increase — revaluation of property",
    "line_3313" => "Increase — income recognised directly in equity",
    "line_3314" => "Increase — additional share issue",
    "line_3315" => "Increase — increase in par value",
    "line_3316" => "Increase — reorganisation",
    "line_3320" => "Decrease in equity (total)",
    "line_3321" => "Decrease — loss",
    "line_3322" => "Decrease — revaluation of property",
    "line_3323" => "Decrease — expenses recognised directly in equity",
    "line_3324" => "Decrease — decrease in par value",
    "line_3325" => "Decrease — decrease in number of shares",
    "line_3326" => "Decrease — reorganisation",
    "line_3327" => "Decrease — dividends",
    "line_3330" => "Change in additional capital",
    "line_3340" => "Change in reserve capital",
    "line_3600" => "Net assets",
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
    # ── Report on targeted use of funds (0710006) — non-profits ──
    "line_6100" => "Funds balance at beginning of year",
    "line_6200" => "Total funds received",
    "line_6210" => "Received — entrance fees",
    "line_6215" => "Received — membership fees",
    "line_6220" => "Received — targeted contributions",
    "line_6230" => "Received — voluntary contributions and donations",
    "line_6240" => "Received — profit from income-generating activity",
    "line_6250" => "Received — other",
    "line_6300" => "Total funds used",
    "line_6310" => "Used — targeted events / programmes",
    "line_6311" => "Used — social and charitable aid",
    "line_6312" => "Used — conferences, meetings and seminars",
    "line_6313" => "Used — other events",
    "line_6320" => "Used — administrative upkeep",
    "line_6321" => "Used — wages",
    "line_6322" => "Used — non-wage payments",
    "line_6323" => "Used — travel and business trips",
    "line_6324" => "Used — upkeep of premises, buildings and transport",
    "line_6325" => "Used — repair of fixed assets",
    "line_6326" => "Used — other administrative",
    "line_6330" => "Used — acquisition of fixed assets and inventory",
    "line_6350" => "Used — other",
    "line_6400" => "Funds balance at end of year",
)

"""
    ras_label(code) -> String

The English label for a Russian **OKUD** line code — e.g. `ras_label("line_2110") == "Revenue"` — or `""`
if the code is not a mapped headline line. Accepts the bare code or the `ras:`-prefixed concept. This is
the label [`facts`](@ref)`(f; labels = true)` fills for a Russian `:ras` filing (R3, `vocab_ras`).
"""
ras_label(code::AbstractString) = get(_RAS_LABELS, startswith(code, "ras:") ? code[5:end] : code, "")
