# Hong Kong (HKEX / HKEXnews, HKFRS) FilingSystem — the 8th FilingSystem, and the SECOND PDF-native
# jurisdiction. Hong Kong listed-company annual reports are surfaced through HKEXnews, the designated
# disclosure portal run by Hong Kong Exchanges and Clearing (HKEX), covering every Main Board + GEM issuer.
# Like China, HKEX mandates NO XBRL/iXBRL for issuer financials — the annual report is a PDF — so Hong Kong is
# a consumer of the shared PDF extractor. Unlike China, the reports are in ENGLISH under HKFRS (an
# IFRS-converged framework), so classification reuses the `ifrs-full` concepts through a light English label
# map (no CJK `vocab_cas` analogue). See docs/dev/hkex-plan.md.
#
# This file is HK0 — the SEAM only: the `FilingSystem` type, its credential tag and its HTTP headers, so
# `using EDGAR` loads clean. HKEXnews discovery (HK1, the keyless `prefix.do` stockId resolver +
# `titleSearchServlet.do` document query) and fetch_filing → PDF `Filing` (HK1) come next; English-IFRS facts
# via the PDF extractor (HK2) and the external-data benchmark (HK4) are the gated later phases.

"""
    HKEX <: FilingSystem

Hong Kong's HKEX-run disclosure system, surfaced through the **HKEXnews** portal (`www1.hkexnews.hk`).
Listed companies (Main Board / GEM) publish periodic reports as **English PDF** under **HKFRS** (an
IFRS-converged framework) — there is no keyless XBRL, so a Hong Kong filing is a PDF whose facts are
recovered by the shared PDF extractor (like China, unlike every prior XBRL/iXBRL system). Because HKFRS face
statements match `ifrs-full`, classification reuses those concepts through a light English label map rather
than a national-language vocabulary. Identity is the five-digit **stock code** paired with HKEXnews's
internal `stockId` (`EntityId(:hkex, "00700")`), resolved together from a bare code or company name by the
discovery layer (HK1).

Access is **keyless** — no API key, only a browser User-Agent and an HKEXnews `Referer`. Discover filings
with `HKEXFilings` (planned, HK1); fetch with [`fetch_filing`](@ref) (HK1).
"""
struct HKEX <: FilingSystem end

# Credentials-registry key. HKEX needs no API key (HKEXnews is keyless), but a tag keeps it uniform with the
# other systems and lets `set_credentials`/`get_credential` work if ever needed.
system_tag(::HKEX) = :hkex

# A realistic desktop-browser User-Agent. HKEXnews's JSON endpoints (prefix.do, titleSearchServlet.do) and the
# document PDF host want a browser UA and an HKEXnews `Referer`; a plausible UA + Referer is the whole access
# story (no cookie bootstrap, no key). An explicit `headers` vector also replaces `fetch_url`'s default SEC
# User-Agent, which is what we want for a non-SEC system.
const _HKEX_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " *
                 "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# HKEXnews host (used from HK1): the portal serves both the JSON query layer (search/) and the document PDFs
# (listedco/…). https is required.
const _HKEXNEWS_BASE = "https://www1.hkexnews.hk"

system_headers(::HKEX) = ["User-Agent"      => _HKEX_UA,
                          "Accept"          => "application/json, text/plain, */*",
                          "Accept-Language" => "en-US,en;q=0.9",
                          "Referer"         => "$_HKEXNEWS_BASE/search/titlesearch.xhtml"]
