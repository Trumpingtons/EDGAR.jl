# DART / OpenDART (South Korea, FSS) FilingSystem — offline parse of an OpenDART financial-statement
# XBRL package (a ZIP of the instance + bundled linkbases), reusing the ESEF report-package reader. The
# parsed content flows through the same jurisdiction-agnostic XBRL extractor as every other system. Korea
# adopted full IFRS (K-IFRS), so most concepts are bare `ifrs-full` (the classification thesis). DART is
# the 5th FilingSystem; it mirrors EDINET but with three deviations: the OpenDART key is a query
# parameter (not a header), DART has a clean corp_code↔stock_code resolver (corpCode.xml), and the
# taxonomy is K-IFRS. See docs/dev/dart-plan.md.

"""
    DART <: FilingSystem

South Korea's FSS disclosure system (DART / OpenDART). Annual business reports (사업보고서) expose their
financials as an XBRL package (instance + bundled taxonomy) that parses through the shared
report-package path. Identity is the DART corporate code (`EntityId(:corp_code, "00126380")`) and/or the
KRX stock code (`EntityId(:stock_code, "005930")`); taxonomy is K-IFRS (the shared `ifrs-full`
vocabulary). Discover filings with [`OpenDARTApi`](@ref) (free `crtfc_key`); fetch with
[`fetch_filing`](@ref).
"""
struct DART <: FilingSystem end

# Credentials-registry key (so `set_credentials(DART(); api_key=…)` / `get_credential` work, like EDINET/CH).
system_tag(::DART) = :dart

const _DART_API_BASE = "https://opendart.fss.or.kr/api"

# DART authenticates with `crtfc_key` as a QUERY PARAMETER on every request — OpenDART offers no header
# auth — so unlike EDINET there is no authorization header: `system_headers(::DART)` is empty. Passing
# this empty vector explicitly to `fetch_url` still bypasses the SEC User-Agent requirement (an explicit
# `headers` replaces the default UA), which is what we want for a non-SEC system.
system_headers(::DART) = Pair{String,String}[]

# The free OpenDART API key (`crtfc_key`), from the credentials registry (`set_credentials(DART();
# api_key=…)`) or, failing that, the `DART_API_KEY` / `OPENDART_API_KEY` environment variable; absent
# all, a clear error before any call.
function _dart_key()
    key = get_credential(DART(), :api_key)
    (key === nothing || isempty(key)) && (key = get(ENV, "DART_API_KEY", get(ENV, "OPENDART_API_KEY", "")))
    isempty(key) && throw(ArgumentError(
        "No OpenDART API key set. Register a free key at https://opendart.fss.or.kr/ and set it with:\n" *
        "    set_credentials(DART(); api_key = \"your-key\")\n" *
        "or set the DART_API_KEY (or OPENDART_API_KEY) environment variable."))
    return key
end

# Build an OpenDART API URL: `<base>/<endpoint>?crtfc_key=…&<params>`. The key is a query parameter
# (DART has no header auth), so it lands in the request URL — and thus in the on-disk cache key. That is
# acceptable for a local cache; see docs/dev/dart-plan.md.
function _dart_url(endpoint::AbstractString; params...)
    q = "crtfc_key=$(_dart_key())"
    for (k, v) in params
        v === nothing && continue
        q *= "&$(k)=$(v)"
    end
    return "$_DART_API_BASE/$endpoint?$q"
end

# Raw bytes of an OpenDART ZIP — a local path, or a remote OpenDART API URL (key already in the query).
# `use_cache=false` forces a fresh network fetch (used by the corp-index miss-refresh). The cache mode is
# DART's effective policy (N6) — so `set_cache_policy(DART(); cache=:persistent)` makes these slow
# downloads survive across sessions while other systems stay temporary.
function _dart_zip_bytes(src::AbstractString; use_cache::Bool=true)
    if startswith(src, "http://") || startswith(src, "https://")
        b = fetch_url(src; headers = system_headers(DART()), use_cache = use_cache,
                      cache_mode = effective_cache_mode(DART()))
        b === nothing && error("could not fetch DART document $(repr(src))")
        return Vector{UInt8}(b)
    end
    return read(src)
end

# Locate the primary XBRL instance in an OpenDART `fnlttXbrl` package: inline-XBRL (`.htm`/`.xhtml`)
# preferred, else the classic `.xbrl` instance (DART financial-statement packages are typically classic
# `.xbrl`). Entry layout to be confirmed against a real package (see dart-plan.md D1.2). Returns
# `(name, kind)` with `kind ∈ (:ixbrl, :xbrl)`, or nothing.
function _dart_primary_report(z::ZipReader)
    names = _rp_names(z)
    pick(exts) = findfirst(n -> any(e -> endswith(lowercase(n), e), exts), names)
    i = pick((".htm", ".xhtml", ".html")); i !== nothing && return (names[i], :ixbrl)
    i = pick((".xbrl",));                   i !== nothing && return (names[i], :xbrl)
    return nothing
end

"""
    fetch_filing(::DART, src; entity=nothing, ref="") -> Filing

Parse an OpenDART financial-statement XBRL package — a local path or an authenticated `fnlttXbrl` API URL
— into a [`Filing`](@ref), reusing the report-package path. `entity` defaults from discovery (which knows
the `corp_code`). The resulting filing flows through the same `facts(f; classify, labels)` API as every
other system.
"""
function fetch_filing(::DART, src::AbstractString; entity::Union{EntityId,Nothing}=nothing, ref::AbstractString="")
    z = ZipReader(_dart_zip_bytes(src))
    rep = _dart_primary_report(z)
    rep === nothing && error("no XBRL instance in DART package $(repr(src))")
    name, kind = rep
    content = _rp_read(z, name)
    ent = entity === nothing ? EntityId(:corp_code, "") : entity
    return Filing(DART(), ent, isempty(ref) ? basename(src) : String(ref), basename(name), src, kind, content)
end

# DART method of the per-system linkbase fetcher (core/extract_xbrl.jl): the presentation / calculation /
# label linkbases are bundled in the `fnlttXbrl` package, so re-read it from `f.url` and read the entry by
# suffix. Returns "" on any failure (which classification tolerates).
#
# DART splits the LABEL linkbase per language — `…_lab-ko.xml` (Korean) and `…_lab-en.xml` (English), each
# single-language — unlike EDINET's one bilingual file. So for `suffix=="lab"` with a requested `lang`, we
# must pick that language's file (`lang="en"` → `_lab-en.xml`); otherwise `label_map`'s `xml:lang` filter
# would drop everything from the wrong-language file (the cause of the empty-labels bug). Falls back to the
# first label file when the language isn't present; the other linkbases (pre/cal/def) are single files.
function _fetch_linkbase(::DART, f::Filing, suffix::AbstractString; lang=nothing)
    bytes = try _dart_zip_bytes(f.url) catch; return "" end
    z = ZipReader(bytes)
    if suffix == "lab" && lang !== nothing
        primary = split(lowercase(String(lang)), '-')[1]        # "en-US" → "en"
        lb = _rp_linkbase(z, "lab-" * primary)
        isempty(lb) || return lb
    end
    return _rp_linkbase(z, suffix)
end
