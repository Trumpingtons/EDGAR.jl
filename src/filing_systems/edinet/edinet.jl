# EDINET (Japan FSA) FilingSystem — offline parse of an EDINET submission ZIP (inline XBRL + bundled
# taxonomy), reusing the ESEF report-package reader. An EDINET submission differs from an ESEF package
# only in entry layout: the primary instance lives under `XBRL/PublicDoc/` (not `reports/`). The parsed
# content then flows through the same jurisdiction-agnostic XBRL extractor. See docs/dev/edinet-plan.md.

"""
    EDINET <: FilingSystem

Japan's FSA disclosure system (EDINET). Annual securities reports (有価証券報告書) are submission ZIPs of
inline XBRL + bundled taxonomy that parse through the shared report-package path. Identity is the EDINET
code (`EntityId(:edinet, "E#####")`); taxonomy is Japanese GAAP (`jpcrp`/`jppfs`) or IFRS. Discover
filings with [`EDINETApi`](@ref) (free Subscription-Key); fetch with [`fetch_filing`](@ref).
"""
struct EDINET <: FilingSystem end

# Credentials-registry key (so `set_credentials(EDINET(); api_key=…)` / `get_credential` work, like CH).
system_tag(::EDINET) = :edinet

const _EDINET_API_BASE = "https://api.edinet-fsa.go.jp/api/v2"

# The HTTP headers for an EDINET API request (N3): the free Subscription-Key, taken from the credentials
# registry (`set_credentials(EDINET(); api_key = …)`) or, failing that, the `EDINET_API_KEY` environment
# variable; absent both, a clear error before any call. EDINET v2 runs on Azure API Management, which
# accepts the key via the `Ocp-Apim-Subscription-Key` header.
function system_headers(::EDINET)
    key = get_credential(EDINET(), :api_key)
    (key === nothing || isempty(key)) && (key = get(ENV, "EDINET_API_KEY", ""))
    isempty(key) && throw(ArgumentError(
        "No EDINET API key set. Register a free Subscription-Key at https://api.edinet-fsa.go.jp/ and set it with:\n" *
        "    set_credentials(EDINET(); api_key = \"your-key\")\n" *
        "or set the EDINET_API_KEY environment variable."))
    return ["Ocp-Apim-Subscription-Key" => key]
end

# Raw bytes of an EDINET submission ZIP — a local path, or a remote (authenticated) document-API URL
# (the Subscription-Key is added as a header, never put in the URL).
function _edinet_zip_bytes(src::AbstractString)
    if startswith(src, "http://") || startswith(src, "https://")
        b = fetch_url(src; headers = system_headers(EDINET()))
        b === nothing && error("could not fetch EDINET document $(repr(src))")
        return Vector{UInt8}(b)
    end
    return read(src)
end

# Locate the primary XBRL instance in an EDINET submission ZIP: the public document under
# `XBRL/PublicDoc/`. A real annual report bundles BOTH a single complete classic `.xbrl` instance (which
# `manifest_PublicDoc.xml` names as the `preferredFilename`) AND the inline-XBRL `.htm` document set — the
# latter split across ~24 fragment files (`0000000_header…`, `0101010_honbun…`, …). The classic `.xbrl`
# carries ALL facts in one file, whereas any single `.htm` is only a fragment (the header doc has one
# fact), so the `.xbrl` is preferred; the `.htm` set is a fallback for filings that ship inline only.
# (Confirmed against a real Toyota annual report, E02144.) Returns `(name, kind)` with
# `kind ∈ (:xbrl, :ixbrl)`, or nothing.
function _edinet_primary_report(z::ZipReader)
    names = filter(n -> occursin(r"publicdoc/"i, n), _rp_names(z))
    isempty(names) && (names = _rp_names(z))
    pick(exts) = findfirst(n -> any(e -> endswith(lowercase(n), e), exts), names)
    i = pick((".xbrl",));                   i !== nothing && return (names[i], :xbrl)
    i = pick((".htm", ".xhtml", ".html")); i !== nothing && return (names[i], :ixbrl)
    return nothing
end

"""
    fetch_filing(::EDINET, src; entity=nothing, ref="") -> Filing

Parse an EDINET submission ZIP — a local path or an authenticated document-API URL — into a
[`Filing`](@ref), reusing the report-package path. `entity` defaults from discovery (which knows the
EDINET code). The resulting filing flows through the same `facts(f; classify, labels)` API as every
other system.
"""
function fetch_filing(::EDINET, src::AbstractString; entity::Union{EntityId,Nothing}=nothing, ref::AbstractString="")
    z = ZipReader(_edinet_zip_bytes(src))
    rep = _edinet_primary_report(z)
    rep === nothing && error("no XBRL instance (XBRL/PublicDoc/*) in EDINET submission $(repr(src))")
    name, kind = rep
    content = _rp_read(z, name)
    ent = entity === nothing ? EntityId(:edinet, "") : entity
    return Filing(EDINET(), ent, isempty(ref) ? basename(src) : String(ref), basename(name), src, kind, content)
end

# EDINET method of the per-system linkbase fetcher (core/extract_xbrl.jl): the presentation /
# calculation / label linkbases are bundled in the submission ZIP, so re-read it from `f.url` and read
# the entry by suffix. Returns "" on any failure (which classification tolerates).
function _fetch_linkbase(::EDINET, f::Filing, suffix::AbstractString; lang=nothing)
    bytes = try _edinet_zip_bytes(f.url) catch; return "" end
    z = ZipReader(bytes)
    # EDINET splits the label linkbase per language — `…_lab.xml` (Japanese, the filing's native language)
    # and `…_lab-en.xml` (English), each single-language — NOT one bilingual file (confirmed against a real
    # Toyota annual report). So for "lab" with a requested language, pick that file: `en` → `_lab-en.xml`;
    # `ja` (or any non-en) → the BARE `_lab.xml`. Else `label_map`'s `xml:lang` filter drops everything from
    # the wrong-language file. `lang=nothing` keeps the prior first-match behaviour.
    if suffix == "lab" && lang !== nothing
        primary = split(lowercase(String(lang)), '-')[1]
        if primary == "en"
            lb = _rp_linkbase(z, "lab-en"); isempty(lb) || return lb
        else
            i = findfirst(n -> endswith(lowercase(n), "_lab.xml"), _rp_names(z))
            i === nothing || return _rp_read(z, _rp_names(z)[i])
        end
    end
    return _rp_linkbase(z, suffix)
end
