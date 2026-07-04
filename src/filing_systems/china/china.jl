# China (CSRC / CNINFO, CAS) FilingSystem — the 7th FilingSystem, and the FIRST PDF-native jurisdiction.
# Chinese listed-company annual reports are surfaced through CNINFO, the national disclosure
# portal run by a Shenzhen Securities Information (SZSE) subsidiary, covering every Shanghai + Shenzhen +
# Beijing listed company. Unlike the six prior systems, China's only complete keyless channel yields
# PDF annual reports under CAS/ASBE (Chinese Accounting Standards) — there is NO practical keyless XBRL
# feed (the MOF CAS taxonomy host is geo-blocked, and the exchange XBRL platforms expose no live API). So
# China is the flagship consumer of the PDF extractor (extractors/pdf.jl), and its first CJK consumer.
# See docs/dev/china-plan.md.
#
# This file is C0 — the SEAM only: the `FilingSystem` type, its credential tag and its HTTP headers, so
# `using EDGAR` loads clean. CNINFO discovery (C1, the keyless topSearch orgId resolver + hisAnnouncement
# query) and fetch_filing → PDF `Filing` + narratives (C2) come next; CAS facts via the PDF extractor
# with a dedicated `vocab_cas.jl` (C3) and the oracle (C4) are the gated later phases.

"""
    China <: FilingSystem

China's CSRC-mandated disclosure system, surfaced through the **CNINFO** national portal.
Listed companies (Shanghai/Shenzhen/Beijing) publish periodic reports as **PDF** under **CAS/ASBE**
(Chinese Accounting Standards) — there is no keyless XBRL, so a China filing is a PDF whose facts are
recovered by the shared PDF extractor (unlike every prior XBRL/iXBRL system). Identity is the packed
CNINFO code+orgId (`EntityId(:cninfo, "000001,gssz0000001")`) — the six-digit exchange code plus CNINFO's
internal `orgId`, resolved together from a bare code or company name by the discovery layer's `topSearch`
resolver (C1), the way DART resolves a `stock_code` to a `corp_code`.

Access is **keyless** — no API key, only a browser User-Agent and a CNINFO `Referer`. Discover filings
with `CNINFOFilings` (planned, C1); fetch with [`fetch_filing`](@ref) (C2).
"""
struct China <: FilingSystem end

# Credentials-registry key. China needs no API key (CNINFO is keyless), but a tag keeps it uniform with
# the other systems and lets `set_credentials`/`get_credential` work if ever needed.
system_tag(::China) = :china

# A realistic desktop-browser User-Agent. CNINFO's JSON endpoints (topSearch, hisAnnouncement) and the
# static PDF host (static.cninfo.com.cn) both reject non-browser clients and want a CNINFO `Referer`; a
# plausible UA + Referer is the whole access story (no cookie bootstrap, no key). An explicit `headers`
# vector also replaces `fetch_url`'s default SEC User-Agent, which is what we want for a non-SEC system.
const _CHINA_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " *
                  "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# CNINFO endpoint hosts (used from C1/C2): the portal (JSON query layer) and the static document host.
const _CNINFO_BASE   = "http://www.cninfo.com.cn"
const _CNINFO_STATIC = "http://static.cninfo.com.cn"

system_headers(::China) = ["User-Agent"      => _CHINA_UA,
                           "Accept"          => "application/json, text/plain, */*",
                           "Accept-Language" => "zh-CN,zh;q=0.9,en;q=0.8",
                           "Referer"         => "$_CNINFO_BASE/"]

# ── C2: fetch → PDF Filing ──────────────────────────────────────────────────────────────────────
# A China filing is a PDF, so fetch_filing downloads the annual-report PDF (or takes a local path) and builds
# a `:pdf` Filing whose `content` is the on-disk PDF path — the contract the shared PDF extractor consumes
# (`facts(f)` → extract_pdf; `narratives(f)` → structured_document). China is the first system to fully wire
# the fetch → :pdf-Filing seam (the CH/NSM path left byte-retention as a TODO). See docs/dev/china-plan.md.

# On-disk path for a downloaded CNINFO PDF, under China's effective cache dir. Keyed on the document basename
# (CNINFO adjunctUrl basenames like "1222881496.PDF" are globally unique), so a re-fetch is a no-op once saved.
function _china_pdf_path(src::AbstractString)
    name = basename(src)
    (isempty(name) || !occursin('.', name)) && (name = string(isempty(name) ? "cninfo" : name, ".pdf"))
    return joinpath(get_cache_dir(effective_cache_mode(China())), "china", name)
end

"""
    fetch_filing(::China, src; entity=nothing, ref="") -> Filing

Fetch a Chinese annual report into a `:pdf` [`Filing`](@ref). `src` is a CNINFO PDF URL (from
[`discover(::CNINFOFilings)`](@ref)) or a local PDF path; the bytes are saved under China's cache dir and the
Filing's `content` is that on-disk path — the source the shared PDF extractor reads, so `facts(f)` (via the
PDF extractor with CAS-label classification, C3) and `narratives(f)` flow through the same API as every other
system. `entity` defaults from discovery (the packed `:cninfo` code+orgId).
"""
function fetch_filing(::China, src::AbstractString; entity::Union{EntityId,Nothing}=nothing, ref::AbstractString="")
    path = if isfile(src)
        src
    else
        p = _china_pdf_path(src)
        if !isfile(p)
            bytes = fetch_url(src; headers = system_headers(China()), use_cache = false,
                              cache_mode = effective_cache_mode(China()))
            bytes === nothing && error("could not fetch CNINFO PDF $(repr(src))")
            mkpath(dirname(p)); write(p, bytes)
        end
        p
    end
    ent = entity === nothing ? EntityId(:cninfo, "") : entity
    return Filing(China(), ent, isempty(ref) ? basename(src) : String(ref), basename(path), src, :pdf, path)
end
