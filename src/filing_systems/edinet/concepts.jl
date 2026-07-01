# EDINET standard-taxonomy concept table (see docs/manual EDGAR.tex §sec:edinet-concepts). The submission
# tags each figure with a concept (e.g. `jppfs_cor:NetSales`) but ships neither its `balance` (debit/credit
# — the sign convention) nor a portable label; both live in the 72 MB standard taxonomy the filing only
# references. We pre-distil that once into `data/edinet_concepts_<effective-date>.json` and load it here.

# Effective-date-stamped tables shipped in the repo, oldest→newest. Newest is a safe superset for sign
# (balance never changes across versions), so it is the default; older tables retain labels for concepts
# the newer one has since deprecated.
const _EDINET_CONCEPT_VERSIONS = ["2024-11-01", "2025-11-01"]

# Memoized parsed tables, keyed by version string → Dict{qname => Dict{field => value}}.
const _EDINET_CONCEPT_CACHE = Dict{String,Dict{String,Any}}()

# The parsed concept table for one taxonomy version (default: newest). Loaded once and memoized.
function _edinet_concepts(version::AbstractString = last(_EDINET_CONCEPT_VERSIONS))
    get!(_EDINET_CONCEPT_CACHE, version) do
        path = joinpath(@__DIR__, "data", "edinet_concepts_$(version).json")
        isfile(path) || error("EDINET concept table not found: $(path)")
        JSON3.read(read(path, String), Dict{String,Any})
    end
end

# One concept's record (`balance`, `label_en`, `label_ja`, `type`, `periodType`, `deprecated`), or nothing
# if the concept is not in the standard taxonomy (a filer extension — its balance lives in the filing).
function edinet_concept(qname::AbstractString; version::AbstractString = last(_EDINET_CONCEPT_VERSIONS))
    get(_edinet_concepts(version), String(qname), nothing)
end

# A concept's balance: `"debit"`, `"credit"`, or `nothing` (non-monetary / unknown / extension concept).
function edinet_balance(qname::AbstractString; version::AbstractString = last(_EDINET_CONCEPT_VERSIONS))
    r = edinet_concept(qname; version)
    r === nothing ? nothing : get(r, "balance", nothing)
end

# A concept's human label in `lang` (`"en"` → `label_en`, anything else → `label_ja`), or nothing.
function edinet_label(qname::AbstractString; lang::AbstractString = "en",
                      version::AbstractString = last(_EDINET_CONCEPT_VERSIONS))
    r = edinet_concept(qname; version)
    r === nothing && return nothing
    v = get(r, startswith(lowercase(lang), "en") ? "label_en" : "label_ja", nothing)
    v === nothing ? nothing : String(v)
end

# `_standard_labels` hook (see core/extract_xbrl.jl). EDINET bundles only the filer's EXTENSION labels, so
# the standard-concept labels — the vast majority, incl. every text-block — must come from the standard
# taxonomy. Supply them from the concept table (the **verbose** role, matching the CSV oracle byte-for-byte);
# `label_map` merges these UNDER the filing's bundled labels, so an issuer relabel still wins. Japanese —
# the honbun/native and CSV-oracle language (`label_en` is available via `edinet_label` for English callers).
function _standard_labels(::EDINET, ::Filing)
    out = Dict{String,String}()
    for (qname, rec) in _edinet_concepts()
        v = get(rec, "label_ja", nothing)
        v === nothing || (out[qname] = String(v))
    end
    return out
end
