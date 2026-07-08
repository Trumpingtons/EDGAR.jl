# India auditor reader — the reader behind the generic `auditor(f::Filing)` (dispatched from core/auditor.jl)
# for India filings. SEBI's Integrated Filing (`in-capmkt`) tags the statutory auditor and the audit opinion
# as XBRL facts; the NSE equity feed (`in-bse-fin`) tags only the opinion declaration, not the firm.
#
# - `in-capmkt:AuditorsFirmName` — the audit firm. India mandates JOINT statutory audits for many issuers
#   (banks, insurers, large NBFCs), so this is tagged once per auditor (dimensioned on `AuditorAxis`); we
#   collect and join them, in document order.
# - opinion — `in-capmkt:OpinionOfAuditors` when a qualification is detailed, else the routine
#   `…:DeclarationOfUnmodifiedOpinionOrStatementOnImpactOfAuditQualification` (the "unmodified opinion" line,
#   present in both channels).

# All values of a concept in an India instance, entity-decoded, in document order. Covers the classic
# instance (`<in-capmkt:Concept …>value</…>`) and the inline-iXBRL variant of the Integrated Filing
# (`<ix:nonNumeric name="in-capmkt:Concept" …>value</ix:nonNumeric>`). Returns every occurrence (joint
# auditors tag `AuditorsFirmName` more than once); reuses `_dei_clean` (tag-strip + entity-decode).
function _india_facts(content::AbstractString, concept::AbstractString)
    out = String[]
    for m in eachmatch(r"(?is)<ix:nonNumeric\b([^>]*)>(.*?)</ix:nonNumeric>", content)
        get(_attrs(m.captures[1]), "name", "") == concept || continue
        v = _dei_clean(m.captures[2]); isempty(v) || push!(out, v)
    end
    if isempty(out)
        for m in eachmatch(Regex("(?is)<$(concept)\\b[^>]*>(.*?)</$(concept)>"), content)
            v = _dei_clean(m.captures[1]); isempty(v) || push!(out, v)
        end
    end
    return out
end

# Assemble an `AuditorInfo` from an India instance, or `nothing` when no audit firm is tagged (the equity
# `in-bse-fin` feed, which names no firm). `firm_id`/`icfr_attestation` stay `nothing` — those are SEC/DEI
# concepts with no Ind-AS analogue.
function _india_auditor(f::Filing)
    firms = unique(_india_facts(f.content, "in-capmkt:AuditorsFirmName"))
    isempty(firms) && return nothing
    ops = _india_facts(f.content, "in-capmkt:OpinionOfAuditors")
    isempty(ops) && (ops = _india_facts(f.content,
        "in-capmkt:DeclarationOfUnmodifiedOpinionOrStatementOnImpactOfAuditQualification"))
    return AuditorInfo(join(firms, "; "); opinion = isempty(ops) ? nothing : first(ops))
end
