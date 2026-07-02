# India (NSE / BSE, Ind-AS) FilingSystem — the 6th FilingSystem. Indian listed-company financial
# results are lodged as Ind-AS XBRL (the IFRS-converged Indian Accounting Standards) under SEBI's
# Listing Obligations and Disclosure Requirements (Reg. 33). Disclosure is MULTI-CHANNEL: the corporate
# registrar (MCA21, paid — out of scope) and the stock exchanges (NSE, BSE — keyless). EDGAR.jl builds on
# the exchange channel: NSE exposes a keyless discovery→XBRL seam (a cookie-gated JSON results API whose
# records carry a direct Ind-AS instance URL). See docs/dev/india-plan.md.
#
# This file is I0 — the SEAM only: the `FilingSystem` type, its credential tag and its HTTP headers, so
# `using EDGAR` loads clean. Offline parse (I1), NSE discovery/fetch (I2), the dedicated `vocab_indas.jl`
# (I3) and labels/oracle (I4) come next. NB the taxonomy is the INVERSE of Korea: Ind-AS concepts sit in a
# national `in-bse-fin` namespace with IFRS-identical local names, so — decision locked 2026-07 — India
# gets a dedicated `vocab_indas.jl` keyed on that namespace (like jpgaap/ukgaap), not ifrs-full reuse.

"""
    India <: FilingSystem

India's exchange-published disclosure system (NSE / BSE). Listed companies file quarterly and annual
financial results as Ind-AS XBRL under SEBI Reg. 33. A filing is a single XBRL instance (linkbases are
NOT bundled — the standard-taxonomy-only shape, as at Companies House), parsed through the shared
jurisdiction-agnostic XBRL extractor. Identity is the company's ISIN
(`EntityId(:isin, "INE002A01018")`), with the NSE ticker (`EntityId(:nse_symbol, "RELIANCE")`) and the
six-digit BSE scrip code (`EntityId(:scrip_code, …)`) as secondary schemes.

Access is **keyless** — no API key, only a browser User-Agent and (for NSE) a cookie bootstrap handled by
the discovery layer (I2). Discover filings with `NSEFilings` (planned); fetch with [`fetch_filing`](@ref).
"""
struct India <: FilingSystem end

# Credentials-registry key. India needs no API key (the exchange channel is keyless), but a tag keeps it
# uniform with the other systems and lets `set_credentials`/`get_credential` work if ever needed.
system_tag(::India) = :india

# A realistic desktop-browser User-Agent. NSE's public JSON endpoints reject non-browser clients and gate
# on a cookie bootstrap (minted from the homepage, done in the discovery layer at I2); a plausible UA is a
# precondition. An explicit `headers` vector also replaces `fetch_url`'s default SEC User-Agent, which is
# what we want for a non-SEC system. No `Authorization`/key header — India is keyless.
const _INDIA_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " *
                  "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

system_headers(::India) = ["User-Agent" => _INDIA_UA,
                           "Accept"     => "application/json, text/html, */*"]
