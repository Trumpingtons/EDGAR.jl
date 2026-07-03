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

system_headers(::India) = ["User-Agent"      => _INDIA_UA,
                           "Accept"          => "application/json, text/plain, */*",
                           "Accept-Language" => "en-US,en;q=0.9"]

# ── NSE session (cookie bootstrap) ──────────────────────────────────────────────────────────────
#
# NSE's public JSON endpoints reject a cookieless client: a request must carry cookies minted by first
# loading the homepage in a browser-like session. We bootstrap once (GET the homepage, collect its
# `Set-Cookie` headers), cache the resulting Cookie header in-process, and attach it --- plus a
# `Referer` --- to every NSE request. The cookies are short-lived, so the cache has a short TTL and the
# discovery layer re-bootstraps on a failed call. The archive host (`nsearchives.nseindia.com`) shares
# the `.nseindia.com` cookie domain, so the same header serves both discovery and the XBRL download.

const _NSE_HOME       = "https://www.nseindia.com/"
const _NSE_COOKIE     = Ref{String}("")
const _NSE_COOKIE_TS  = Ref{Float64}(0.0)
const _NSE_COOKIE_TTL = 600.0   # seconds — NSE session cookies are short-lived

# Browser \emph{navigation} headers for the homepage bootstrap. The richer set (a document `Accept`,
# `Accept-Language`, `Upgrade-Insecure-Requests` and the `Sec-Fetch-*` navigation hints) is what gets
# NSE's Akamai edge to serve the page and set session cookies; the leaner API `system_headers(India())`
# alone is refused (403). These are used ONLY to mint cookies.
const _NSE_NAV_HEADERS = [
    "User-Agent"                => _INDIA_UA,
    "Accept"                    => "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
    "Accept-Language"           => "en-US,en;q=0.9",
    "Upgrade-Insecure-Requests" => "1",
    "Sec-Fetch-Dest"            => "document",
    "Sec-Fetch-Mode"            => "navigate",
    "Sec-Fetch-Site"            => "none",
]

# Mint (or reuse) the NSE Cookie header. `force=true` always re-bootstraps (refresh-on-failure). Cookies
# are harvested even from a non-200 (Akamai's challenge response still carries `Set-Cookie`), deduped by
# name (last wins). `status_exception=false` so a 403 does not abort before we read the cookies.
function _nse_cookies(; force::Bool=false)
    (!force && !isempty(_NSE_COOKIE[]) && time() - _NSE_COOKIE_TS[] < _NSE_COOKIE_TTL) && return _NSE_COOKIE[]
    r = try
        http_get(_NSE_HOME; headers = _NSE_NAV_HEADERS, read_idle_timeout = 15,
                 cookies = false, status_exception = false, redirect = true)
    catch e
        error("NSE cookie bootstrap failed ($_NSE_HOME): $e")
    end
    names = String[]; vals = Dict{String,String}()          # dedup by name, preserve first-seen order
    for (k, v) in r.headers
        lowercase(k) == "set-cookie" || continue
        nv = String(first(split(v, ';')))                    # "name=value" before the first ';'
        nm = String(first(split(nv, '=')))
        haskey(vals, nm) || push!(names, nm)
        vals[nm] = nv
    end
    isempty(names) && error("NSE cookie bootstrap returned no cookies ($_NSE_HOME; status $(r.status))")
    _NSE_COOKIE[] = join((vals[n] for n in names), "; "); _NSE_COOKIE_TS[] = time()
    return _NSE_COOKIE[]
end

# HTTP headers for an authenticated NSE request: the browser headers + a `Referer` + the session Cookie.
_nse_headers(; referer::AbstractString = _NSE_HOME, force::Bool=false) =
    [system_headers(India())..., "Referer" => String(referer), "Cookie" => _nse_cookies(; force = force)]

# Drop the cached NSE session (forces a fresh bootstrap on the next call).
_nse_reset!() = (_NSE_COOKIE[] = ""; _NSE_COOKIE_TS[] = 0.0; nothing)

# ── I1: offline parse of a single Ind-AS XBRL instance ──────────────────────────────────────────
#
# An NSE filing is a single CLASSIC XBRL instance (`<xbrli:xbrl>` with `in-bse-fin:` concept-named
# facts) — NOT inline XBRL, and NOT a package: the linkbases are the published BSE standard taxonomy,
# referenced by <link:schemaRef>, not bundled (the standard-taxonomy-only shape, as at Companies House).
# So `fetch_filing` just reads the instance bytes and builds an `:xbrl` Filing; the shared extractor's
# classic-instance path (`_classic_facts`) parses concept elements against the instance's own contexts
# and units. Raw `facts(f; classify=false)` needs no taxonomy; classification is the dedicated
# `vocab_indas.jl` (I3) and human labels are the remote BSE label linkbase (I4).

# Identity carried INSIDE the instance: the context entity `<identifier>` and its `scheme`. The two India
# taxonomy families identify differently — the `in-bse-fin` results feed uses NSE's symbol URI
# (`http://www.nseindia.com/NSESymbol`, value = the ticker `RELIANCE`), while the `in-capmkt` Integrated
# Filing uses SEBI's ScripCode URI (`http://www.sebi.gov.in/in-capmkt/ScripCode`, value = the BSE scrip
# code). Discovery supplies the identity from the feed record, so a caller-given `entity` always wins over
# this; it is the offline fallback. Returns `:nse_symbol` / `:scrip_code` accordingly, else an empty `:isin`.
function _india_entity(content::AbstractString)
    m = match(r"(?is)<(?:\w+:)?identifier\b[^>]*\bscheme=\"([^\"]*)\"[^>]*>\s*([^<\s]+)", content)
    m === nothing && return EntityId(:isin, "")
    scheme, val = m.captures[1], String(m.captures[2])
    occursin("nseindia.com", scheme) && return EntityId(:nse_symbol, val)
    occursin(r"(?i)sebi\.gov\.in.*ScripCode", scheme) && return EntityId(:scrip_code, val)
    return EntityId(:isin, "")
end

# ── Period normalisation ────────────────────────────────────────────────────────────────────────
#
# NSE Ind-AS instances carry UNRELIABLE `<xbrli:period>` dates: every plain duration context is stamped
# with the SAME quarter-end dates — e.g. both `OneD` (current quarter, 3 months) and `FourD` (year-to-
# date / full year, 12 months) declare `2024-01-01→2024-03-31` — so the reporting period a fact belongs
# to CANNOT be read from `startDate`/`endDate` (verified on Reliance FY24 and Infosys FY24). The TRUE
# period is, however, present as EXPLICIT facts *inside each context's own concepts*:
# `in-bse-fin:DateOfStartOfReportingPeriod` / `DateOfEndOfReportingPeriod` tagged with that context's id.
# So `FourD` carries `DateOfStartOfReportingPeriod=2023-04-01` (the FY start) while `OneD` carries
# `2024-01-01` (the quarter start) — the authoritative distinction the `<xbrli:period>` dates lose.
#
# `_india_normalize_periods` rewrites each duration context's `<xbrli:startDate>`/`<xbrli:endDate>` to the
# authoritative dates its own `DateOf…ReportingPeriod` facts declare, BEFORE the shared extractor parses
# the instance — the same fetch-time content-rewrite pattern as Companies House canonicalisation. The
# result: `facts()` reports the correct 3-month vs 12-month period per fact, with no change to the shared
# extractor. Instant contexts and any duration context that declares no such facts are left untouched.

# `contextRef → (start, end)` from the instance's `in-bse-fin:DateOf{Start,End}OfReportingPeriod` facts.
# A fact `<in-bse-fin:DateOfStartOfReportingPeriod contextRef="FourD" …>2023-04-01</…>` contributes the
# start for context `FourD`; the matching End fact contributes its end. Only contexts with BOTH are kept.
function _india_reporting_periods(content::AbstractString)
    starts = Dict{String,String}(); ends = Dict{String,String}()
    # Namespace-agnostic (`in-bse-fin:` results feed OR `in-capmkt:` Integrated Filing); a filing with no
    # such date facts yields an empty map, so `_india_normalize_periods` is a no-op for it.
    for m in eachmatch(r"(?is)<[\w.-]+:DateOf(Start|End)OfReportingPeriod\b[^>]*\bcontextRef=\"([^\"]+)\"[^>]*>\s*([0-9]{4}-[0-9]{2}-[0-9]{2})", content)
        (m.captures[1] == "Start" ? starts : ends)[m.captures[2]] = m.captures[3]
    end
    periods = Dict{String,Tuple{String,String}}()
    for (ctx, s) in starts
        haskey(ends, ctx) && (periods[ctx] = (s, ends[ctx]))
    end
    return periods
end

# Rewrite each duration context's period dates to the authoritative reporting-period dates its own facts
# declare. No-op for a context with no such facts (its dates are left as-is), and for instant contexts.
function _india_normalize_periods(content::AbstractString)
    periods = _india_reporting_periods(content)
    isempty(periods) && return content
    return replace(content, r"(?is)<xbrli:context\s+id=\"([^\"]+)\">(.*?)</xbrli:context>" => function (block)
        m = match(r"(?is)<xbrli:context\s+id=\"([^\"]+)\">(.*?)</xbrli:context>", block)
        ctx = m.captures[1]
        haskey(periods, ctx) || return block
        occursin("<xbrli:startDate>", block) || return block          # duration contexts only
        s, e = periods[ctx]
        block = replace(block, r"(?is)<xbrli:startDate>[^<]*</xbrli:startDate>" => "<xbrli:startDate>$s</xbrli:startDate>")
        block = replace(block, r"(?is)<xbrli:endDate>[^<]*</xbrli:endDate>"     => "<xbrli:endDate>$e</xbrli:endDate>")
        return block
    end)
end

"""
    fetch_filing(::India, src; entity=nothing, ref="") -> Filing

Read an NSE **Ind-AS XBRL instance** — a local path (offline) or an `http(s)://` URL — into a
[`Filing`](@ref). The instance is classic XBRL, so the filing is `:xbrl` and flows through the same
`facts(f; classify, labels)` API as every other system. `entity` defaults from discovery (which knows
the ISIN, I2); offline it is parsed from the instance's context identifier (the NSE symbol). `ref`
defaults to the source basename.

```julia
f = fetch_filing(India(), "test/data/india/reliance-fy2024.xml")
facts(f)                       # raw Ind-AS facts (classification is I3; needs vocab_indas.jl)
```
"""
function fetch_filing(::India, src::AbstractString;
                      entity::Union{EntityId,Nothing}=nothing, ref::AbstractString="")
    raw = if startswith(src, "http://") || startswith(src, "https://")
        b = fetch_url(src; headers = _nse_headers())   # NSE archive needs the session cookie + Referer
        b === nothing && error("could not fetch India XBRL instance $(repr(src))")
        Vector{UInt8}(b)
    else
        read(src)
    end
    content = _india_normalize_periods(String(raw))
    ent = entity === nothing ? _india_entity(content) : entity
    # Integrated Filing serves BOTH a classic XBRL (`.xml`) and an inline XBRL (`.html`); tag the kind from
    # the extension so `facts` uses the right extractor. Ind-AS results-feed instances are always `.xml`.
    kind = endswith(lowercase(basename(src)), r"\.x?html?") ? :ixbrl : :xbrl
    return Filing(India(), ent, isempty(ref) ? basename(src) : String(ref), basename(src), src, kind, content)
end

# ── Standard-taxonomy linkbase (BSE Financial Results taxonomy, bundled) ────────────────────────
#
# NSE instances carry NO bundled linkbase — they reference the published BSE Financial Results taxonomy
# by a RELATIVE `schemaRef` (e.g. `Ind-AS_entry_point_2020-03-31.xsd`). BSE does not host that taxonomy
# at a resolvable URL (its namespace URL serves the exchange homepage), but NSE publishes the taxonomy
# packages on its keyless archive; since the taxonomy is dated and stable, we bundle its PRESENTATION
# linkbase as a repo data file (the EDINET pattern) rather than fetch it per filing. That linkbase groups
# every concept into its statement role (`StatementOfAssetsAndLiabilitiesIndAS` → BalanceSheet, the
# results P&L role → IncomeStatement, `CashFlowStatementIndirect` → CashFlow, …), so `facts(f;
# classify=true)` classifies the FULL statements, not just the `vocab_indas` key anchors.
#
# SEBI's per-company-class formats bind different taxonomy versions (Ind-AS general 2020-03-31, banking
# 2019-09-30, …), each with its own presentation linkbase; the instance's `schemaRef` entry-point name
# selects which bundled linkbase to use.

const _INDIA_DATA_DIR = joinpath(@__DIR__, "data")

# The bundled presentation-linkbase file for a filing, chosen by its SEBI company-class FORMAT. The four
# `in-bse-fin` formats each need their OWN linkbase — several share a version tag but differ (an NBFC or a
# bank balance sheet is not a general one), so the version alone cannot choose. The authoritative signal is
# the instance FILENAME PREFIX (`INDAS_` / `BANKING_` / `NBFC_INDAS_`), which discovery preserves in
# `f.document`; offline instances that lack it fall back to the `schemaRef` entry-point name, and a general
# Ind-AS default catches the rest.
#
# Two taxonomy families, routed by the filename prefix (both preserved in `f.document` by discovery):
#   • `INTEGRATED_FILING_…` — SEBI's CURRENT Integrated Filing framework, on the `in-capmkt` taxonomy
#     (`vocab_incapmkt`). One combined taxonomy covers every sector, so each `INTEGRATED_FILING_{INDAS,
#     BANKING,NBFC_INDAS,LI,GI}_…` prefix selects its own `in-capmkt` linkbases — including the insurers
#     (Life/General), which the old `in-bse-fin` feed never carried.
#   • everything else — the frozen `in-bse-fin` results feed (`vocab_indas`), routed as before.
#
# Both the presentation (`_india_pre_file`) and label (`_india_lab_file`) linkbases key off ONE format
# discriminator (`_india_format`), so the two stay in lock-step: every format resolves to a matching
# `pre`/`label` pair bundled in `data/`.
function _india_format(f::Filing)
    doc = uppercase(f.document)
    if startswith(doc, "INTEGRATED_FILING")               # in-capmkt (Integrated Filing) — by sector prefix
        occursin("RESULTIR", doc) && return :cap_reit      # REITs / InvITs (INTEGRATED_FILING_RESULTIR_)
        occursin("BANKING", doc)  && return :cap_banking
        occursin("NBFC", doc)     && return :cap_nbfc
        occursin("_LI", doc)      && return :cap_li        # Life insurance
        occursin("_GI", doc)      && return :cap_gi        # General insurance
        return :cap_indas                                  # general Ind-AS (default)
    end
    startswith(doc, "BANKING") && return :bse_banking
    startswith(doc, "NBFC")    && return :bse_nbfc
    startswith(doc, "INDAS")   && return :bse_indas
    m = match(r"(?is)schemaRef\b[^>]*\bhref=\"([^\"]+)\"", f.content)          # offline fallback (entry point)
    ep = m === nothing ? "" : lowercase(m.captures[1])
    occursin("other_than_banks", ep) && return :bse_other
    occursin("banking", ep)          && return :bse_banking
    return :bse_indas                                                         # default: general Ind-AS
end

# format => (presentation linkbase, label linkbase) — the bundled `data/` file pair for each format.
const _INDIA_LINKBASES = Dict(
    :cap_indas   => ("in-capmkt-pre-indas-2025-01-31.xml",   "in-capmkt-lab-indas-2025-01-31.xml"),
    :cap_banking => ("in-capmkt-pre-banking-2025-01-31.xml", "in-capmkt-lab-banking-2025-01-31.xml"),
    :cap_nbfc    => ("in-capmkt-pre-nbfc-2025-01-31.xml",    "in-capmkt-lab-nbfc-2025-01-31.xml"),
    :cap_li      => ("in-capmkt-pre-li-2025-01-31.xml",      "in-capmkt-lab-li-2025-01-31.xml"),
    :cap_gi      => ("in-capmkt-pre-gi-2025-01-31.xml",      "in-capmkt-lab-gi-2025-01-31.xml"),
    :cap_reit    => ("in-capmkt-pre-reit-2026-01-31.xml",    "in-capmkt-lab-reit-2026-01-31.xml"),  # REITs/InvITs (v2026-01-31)
    :bse_indas   => ("in-bse-fin-pre-2020-03-31.xml",        "in-bse-fin-label-2020-03-31.xml"),
    :bse_banking => ("in-bse-fin-pre-2019-09-30.xml",        "in-bse-fin-label-2019-09-30.xml"),
    :bse_nbfc    => ("in-bse-fin-pre-nbfc-2020-03-31.xml",   "in-bse-fin-label-nbfc-2020-03-31.xml"),
    :bse_other   => ("in-bse-fin-pre-other-2019-09-30.xml",  "in-bse-fin-label-other-2019-09-30.xml"),
)

_india_pre_file(f::Filing) = _INDIA_LINKBASES[_india_format(f)][1]
_india_lab_file(f::Filing) = _INDIA_LINKBASES[_india_format(f)][2]

# India method of the per-system linkbase fetcher (core/extract_xbrl.jl). Returns the bundled BSE/SEBI
# presentation linkbase (`classify`) or label linkbase (`labels`) for the filing's format; "" otherwise.
# Labels are English-only (India files in English) — no `lang` split, unlike EDINET/DART.
function _fetch_linkbase(::India, f::Filing, suffix::AbstractString; lang=nothing)
    file = suffix == "pre" ? _india_pre_file(f) : suffix == "lab" ? _india_lab_file(f) : ""
    isempty(file) && return ""
    path = joinpath(_INDIA_DATA_DIR, file)
    isfile(path) ? read(path, String) : ""
end
