# Russia route 2 — the CBR (Bank of Russia) bank-reporting channel. The financial sector is carved out of
# RFSD (route 1) by law, so banks are reached instead through the CBR's public per-institution forms —
# Form 0409101 (turnover balance by account) and 0409102 (financial results) — served as HTML per bank
# registration number (`regnum`) and reporting date, behind the CBR's ddos-guard (a replayable cookie).
# Unlike route 1 (structured RFSD rows), these are HTML account tables on the bank chart of accounts, so they
# need their own fetch (C2), extractor (C3) and account→statement map (C4). Insurers and NPFs are NOT
# reachable: CBR publishes only aggregate sector statistics for them and their XBRL instances are not public
# (their per-entity accounts are not served in HTML the way banks' are). See docs/dev/russia-plan.md (route 2).
#
# This file is C0 — the SEAM only: the `FilingSource` type + host, so `using EDGAR` loads clean. The
# FullCoList `regnum` resolver + `discover` (C1), the Form 101/102 fetch (C2), the HTML-table extractor (C3)
# and the chart-of-accounts → bank-statement map (C4) are the next phases.

"""
    CBRBankFilings <: FilingSource

The Bank of Russia (CBR) bank-reporting channel — **route 2**, for the financial sector that RFSD (route 1)
excludes. A Russian bank publishes its statutory reporting as CBR **Form 0409101** (turnover balance by
account) and **0409102** (financial results), served as HTML per **registration number** (`regnum`) and
reporting date. Identity is `EntityId(:cbr_regnum, "1481")` (Sberbank), resolved from a name / INN through
the CBR bank directory (`FullCoList`, planned C1). Only **credit institutions** (~320 banks) are reachable:
insurers and non-state pension funds report XBRL to the CBR whose per-entity instances are not public.

Discovery (`discover`, C1) and fetch (C2) are the next phases; this is the seam so `using EDGAR` loads clean.
"""
struct CBRBankFilings <: FilingSource end

# CBR host. Behind ddos-guard — a first request sets a replayable `__ddg*_` cookie, bootstrapped in the C2
# fetch path. Form 101/102 live under `/banking_sector/credit/coinfo/`, the bank directory under
# `/banking_sector/credit/FullCoList/`. https required.
const _CBR_BASE = "https://www.cbr.ru"
