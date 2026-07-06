# Russia route 2 — vocab_cbr: the bank chart-of-accounts → statement classification (C4). The bank analogue
# of vocab_ras, but over the CBR 1st-order (3-digit) accounts of Form 0409101 (Положение 809-П). There is ONE
# presentation statement, "BankBalanceSheet" (a bank has no revenue/COGS): `_cbr_line(account)` maps each
# account to a condensed balance-sheet line, and the fact's `section` dimension (Актив / Пассив) already
# fixes the side, so a line label + section together are the statement line. Unmapped accounts return ""
# and fall to "Other assets" / "Other liabilities" by section — never dropped, so Σ Актив = Σ Пассив holds.
# Applied by `_cbr_form_facts` under `classify` / `labels` (mirrors R3). Form 0409102 (P&L) is a follow-on.

const CBR_BALANCE_SHEET = "BankBalanceSheet"

# A 1st-order account code → condensed bank-balance-sheet line (English). Ranges follow the Russian bank
# chart of accounts; the `section` dimension distinguishes the asset vs liability presentation of the
# two-sided (парные) accounts (correspondent, interbank, financial result).
function _cbr_line(account::AbstractString)
    n = tryparse(Int, account)
    n === nothing && return ""
    200 ≤ n ≤ 206            && return "Cash and precious metals"
    n in (301, 302)          && return "Correspondent accounts"
    n in (303, 304, 305, 306)&& return "Interbranch and other settlements"
    310 ≤ n ≤ 330            && return "Interbank loans and deposits"
    401 ≤ n ≤ 409            && return "Customer current accounts"
    410 ≤ n ≤ 440            && return "Customer deposits"
    441 ≤ n ≤ 473            && return "Loans to customers"
    501 ≤ n ≤ 519            && return "Securities"
    520 ≤ n ≤ 525            && return "Issued debt securities"
    604 ≤ n ≤ 610            && return "Fixed and intangible assets"
    n == 102                 && return "Share capital"
    n in (104, 105, 106, 107)&& return "Additional and reserve capital"
    n in (108, 109)          && return "Retained earnings"
    n in (706, 707, 708)     && return "Financial result of the year"
    return ""                                    # → "Other assets" / "Other liabilities" by section
end

"""
    cbr_line(account) -> String

The condensed bank-balance-sheet line an account rolls into (e.g. `cbr_line("450") == "Loans to customers"`,
`cbr_line("102") == "Share capital"`), or `""` for accounts that fall to the section's "Other" line. Accepts
the bare code or the `cbr:`-prefixed concept. See [`facts`](@ref)`(f; classify = true, labels = true)`.
"""
cbr_line(account::AbstractString) = _cbr_line(startswith(account, "cbr:") ? account[5:end] : account)

# The (statement, line label) for an account given its section — the classification `_cbr_form_facts` applies.
function _cbr_classify(account::AbstractString, section::AbstractString)
    line = _cbr_line(account)
    isempty(line) && (line = section == "Пассив" ? "Other liabilities" : "Other assets")
    return (CBR_BALANCE_SHEET, line)
end
