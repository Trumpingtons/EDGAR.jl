# Auditor — the generic `auditor(f::Filing)` accessor, the cross-jurisdiction analogue of `narratives`.
# `AuditorInfo` (core/types.jl) is the shared return type; the per-system readers that populate it live in
# their own files (SEC: `_sec_auditor` in filing_systems/sec/auditor.jl). This file is loaded late — after
# every FilingSystem — so the dispatcher can route to each system's reader.

"""
    auditor(f::Filing) -> Union{Nothing,AuditorInfo}

The independent auditor of a filing as an [`AuditorInfo`](@ref), or `nothing` when none is disclosed —
the audit-report counterpart of [`facts`](@ref) / [`narratives`](@ref). One source-agnostic accessor;
each FilingSystem contributes its own reader:

- **SEC** — from the DEI cover-page XBRL facts (`dei:AuditorName`/`AuditorLocation`/`AuditorFirmId`/
  `IcfrAuditorAttestationFlag`); falls back to the SEC's extracted instance for foreign/multi-part filings.
- **India** — from the SEBI Integrated-Filing (`in-capmkt`) XBRL: the statutory audit firm(s) and the
  audit *opinion*. `nothing` for the NSE equity feed, which names no firm.

Other jurisdictions are populated as their tagged / text-extraction readers land (a UK *senior statutory
auditor*); until then `auditor(f)` is `nothing` off-SEC.
"""
function auditor(f::Filing)
    f.system isa SEC   && return _sec_auditor(f)
    f.system isa India && return _india_auditor(f)
    return nothing
end
