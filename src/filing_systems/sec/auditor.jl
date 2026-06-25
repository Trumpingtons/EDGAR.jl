# Auditor information — a faithful port of edgartools' company_reports/auditor.py
# (`extract_auditor_info`). The auditor is reported as DEI (Document and Entity Information) XBRL facts in
# annual filings (10-K / 20-F / 40-F): name, location, the PCAOB firm id, and the ICFR attestation flag.
# These are non-numeric facts, so the numeric `facts(::Filing)` pipeline skips them; this reads them
# directly off the instance. 🔵 SEC-specific (fetches the SEC extracted instance as a fallback).

"""
    AuditorInfo

The independent auditor of an annual filing, from its DEI XBRL facts: `name`, `location`, the PCAOB
`firm_id` (`0` when absent/unparseable), and `icfr_attestation` (whether the auditor attested to
internal control over financial reporting).
"""
struct AuditorInfo
    name::String
    location::String
    firm_id::Int
    icfr_attestation::Bool
end

Base.show(io::IO, a::AuditorInfo) =
    print(io, "AuditorInfo(", repr(a.name), ", ", repr(a.location),
          ", firm_id=", a.firm_id, ", icfr=", a.icfr_attestation, ")")

# DEI string facts (auditor name/location) carry HTML entities that must be DECODED, not stripped — an
# auditor is "Ernst & Young LLP", not "Ernst  Young LLP" — so this uses its own cleaner rather than
# `_xbrl_text` (which strips entities, fine for numbers/text-blocks).
const _DEI_ENTITIES = Dict("amp" => "&", "lt" => "<", "gt" => ">", "quot" => "\"", "apos" => "'", "nbsp" => " ")
function _dei_clean(s::AbstractString)
    notags = replace(s, r"(?is)<[^>]*>" => " ")
    decoded = replace(notags, r"&(#x?[0-9a-fA-F]+|\w+);" => function (e)
        name = e[2:end-1]
        if startswith(name, "#x") || startswith(name, "#X")
            c = tryparse(Int, name[3:end]; base = 16); return c === nothing ? e : string(Char(c))
        elseif startswith(name, "#")
            c = tryparse(Int, name[2:end]); return c === nothing ? e : string(Char(c))
        end
        return get(_DEI_ENTITIES, name, e)
    end)
    return strip(replace(decoded, r"\s+" => " "))
end

# The text value of the first XBRL fact for a DEI concept (e.g. "dei:AuditorName"), entity-decoded.
# Covers inline iXBRL (`ix:nonNumeric` for strings, `ix:nonFraction` for the numeric firm id) and the
# classic instance (a concept-named element). Returns "" if the concept is not present.
function _dei_fact(content::AbstractString, name::AbstractString)
    for tag in ("nonNumeric", "nonFraction")
        for m in eachmatch(Regex("(?is)<ix:$tag\\b([^>]*)>(.*?)</ix:$tag>"), content)
            a = _attrs(m.captures[1])
            get(a, "name", "") == name || continue
            # A boolean flag (e.g. IcfrAuditorAttestationFlag) carries its value in the inline
            # value-fixed `fixed-true` / `fixed-false` transform — authoritative regardless of the
            # element's rendered content (often a "☒" ballot-box glyph), so it is checked first.
            fmt = get(a, "format", "")
            occursin("fixed-true", fmt) && return "true"
            occursin("fixed-false", fmt) && return "false"
            return _dei_clean(m.captures[2])
        end
    end
    m = match(Regex("(?is)<$name\\b[^>]*>([^<]*)</$name>"), content)
    return m === nothing ? "" : _dei_clean(m.captures[1])
end

# Assemble an AuditorInfo from one document's content, or `nothing` if it carries no auditor name.
function _auditor_from(content::AbstractString)
    name = _dei_fact(content, "dei:AuditorName")
    isempty(name) && return nothing
    firm = strip(_dei_fact(content, "dei:AuditorFirmId"))
    icfr = lowercase(strip(_dei_fact(content, "dei:IcfrAuditorAttestationFlag")))
    return AuditorInfo(name, _dei_fact(content, "dei:AuditorLocation"),
                       something(tryparse(Int, firm), 0), icfr == "true")
end

"""
    auditor(f::Filing) -> Union{Nothing,AuditorInfo}

Extract the auditor's [`AuditorInfo`](@ref) from a filing's DEI XBRL facts (`dei:AuditorName`,
`dei:AuditorLocation`, `dei:AuditorFirmId`, `dei:IcfrAuditorAttestationFlag`) — a faithful port of
edgartools' `extract_auditor_info`. Reads the primary document, falling back to the SEC's extracted
instance for foreign / multi-part filings whose cover document carries no DEI facts. `nothing` if absent.
"""
function auditor(f::Filing)
    a = _auditor_from(f.content)
    a !== nothing && return a
    (f.kind === :xbrl || !startswith(f.url, "https://www.sec.gov/Archives/")) && return nothing
    try
        base = _filing_dir(f)
        body = fetch_url(base * "/" * _xbrl_instance(base))
        return body === nothing ? nothing : _auditor_from(String(body))
    catch
        return nothing
    end
end
