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

# ── I1: offline parse of a single Ind-AS XBRL instance ──────────────────────────────────────────
#
# An NSE filing is a single CLASSIC XBRL instance (`<xbrli:xbrl>` with `in-bse-fin:` concept-named
# facts) — NOT inline XBRL, and NOT a package: the linkbases are the published BSE standard taxonomy,
# referenced by <link:schemaRef>, not bundled (the standard-taxonomy-only shape, as at Companies House).
# So `fetch_filing` just reads the instance bytes and builds an `:xbrl` Filing; the shared extractor's
# classic-instance path (`_classic_facts`) parses concept elements against the instance's own contexts
# and units. Raw `facts(f; classify=false)` needs no taxonomy; classification is the dedicated
# `vocab_indas.jl` (I3) and human labels are the remote BSE label linkbase (I4).

# Identity carried INSIDE the instance: the context entity `<identifier>` whose scheme is NSE's symbol
# URI (`http://www.nseindia.com/NSESymbol`), e.g. `RELIANCE` — the NSE ticker, NOT the ISIN. The ISIN is
# supplied by discovery (I2) from the results-API record, so a caller-given `entity` always wins over
# this. Returns `EntityId(:nse_symbol, sym)`, or an empty `:isin` id when no NSE identifier is present.
function _india_entity(content::AbstractString)
    m = match(r"(?is)<(?:\w+:)?identifier\b[^>]*\bscheme=\"[^\"]*nseindia\.com[^\"]*\"[^>]*>\s*([^<\s]+)", content)
    return m === nothing ? EntityId(:isin, "") : EntityId(:nse_symbol, String(m.captures[1]))
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
    for m in eachmatch(r"(?is)<in-bse-fin:DateOf(Start|End)OfReportingPeriod\b[^>]*\bcontextRef=\"([^\"]+)\"[^>]*>\s*([0-9]{4}-[0-9]{2}-[0-9]{2})", content)
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
        b = fetch_url(src; headers = system_headers(India()))
        b === nothing && error("could not fetch India XBRL instance $(repr(src))")
        Vector{UInt8}(b)
    else
        read(src)
    end
    content = _india_normalize_periods(String(raw))
    ent = entity === nothing ? _india_entity(content) : entity
    return Filing(India(), ent, isempty(ref) ? basename(src) : String(ref), basename(src), src, :xbrl, content)
end

# India method of the per-system linkbase fetcher (core/extract_xbrl.jl). NSE instances bundle NO
# linkbases — they reference the published BSE standard taxonomy by URL — so at I1 this returns "" for
# every suffix: raw facts need no linkbase, and classification will use `vocab_indas.jl` (I3). Fetching
# the remote BSE label linkbase for human-readable labels is I4.
_fetch_linkbase(::India, f::Filing, suffix::AbstractString; lang=nothing) = ""
