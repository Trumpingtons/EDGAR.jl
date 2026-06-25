# Concept standardization (W4) is PLUGGABLE and ships with NO opinionated default. A
# "standard concept" mapping — collapsing the different tags companies use for the same line
# (Revenues / RevenueFromContractWithCustomer… / SalesRevenueNet → Revenue) — is a curated,
# opinionated artifact, and conflating distinct lines is easy to get wrong. So EDGAR.jl stays
# neutral: `standardize` returns `nothing` until you choose a mapping with `set_standardizer`.
#
# Selectable providers are a roadmap (documented in the manual): "reference" sources (the
# us-gaap taxonomy, the SEC Financial Statement Data Sets) give canonical concepts and labels
# but do not collapse synonyms; "community" mappings (e.g. edgartools', MIT-licensed) do the
# synonym collapse but are opinionated and must carry their attribution if adopted.

const _STANDARDIZER = Ref{Function}(_ -> nothing)   # default: no standardization

"""
    standardize(concept) -> Union{String,Nothing}

Map an issuer's XBRL `concept` (e.g. `"us-gaap:SalesRevenueNet"`) to a common **standard
concept** (`"Revenue"`) for cross-company comparison, using the mapping currently selected with
[`set_standardizer`](@ref). Returns `nothing` when no mapping is configured (the default) or the
concept is unmapped. This drives the `standard_concept` column of every fact; the original
`concept` and `label` are always preserved alongside it (the dual-label approach), so
standardization never loses information.
"""
standardize(concept::AbstractString) = _STANDARDIZER[](concept)

"""
    set_standardizer(mapping) -> Function

Choose the concept-standardization mapping used by [`standardize`](@ref). `mapping` may be:

- a `Dict` of `concept => standard_concept`,
- a function `concept -> Union{String,Nothing}`, or
- `:none` — disable standardization (the default).

EDGAR.jl ships **no** built-in mapping on purpose: a standardization mapping is opinionated and
easy to get wrong (two distinct lines must not collapse to one). Supply your own, or adopt a
third-party one — if you do, honour its licence (e.g. the edgartools mapping is MIT and must be
attributed). Returns the active standardizer function.

```julia
set_standardizer(Dict(
    "us-gaap:SalesRevenueNet" => "Revenue",
    "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax" => "Revenue"))
standardize("us-gaap:SalesRevenueNet")   # "Revenue"
set_standardizer(:none)                  # back to the default (no standardization)
```
"""
set_standardizer(f::Function) = (_STANDARDIZER[] = f; f)
set_standardizer(d::AbstractDict) = set_standardizer(c -> get(d, String(c), nothing))
function set_standardizer(s::Symbol)
    if s === :none
        return set_standardizer(_ -> nothing)
    elseif s === :edgartools
        return set_standardizer(edgartools_mapping())
    end
    throw(ArgumentError("unknown standardizer $(repr(s)) — pass `:none`, `:edgartools`, " *
                        "a `Dict`, or a function"))
end

# The vendored edgartools mapping (MIT — see src/core/taxonomy/data/edgartools_concept_mappings.NOTICE.md),
# parsed and inverted once: `concept => standard_concept`. The source file is
# `standard_concept => [company concepts]` with `us-gaap_X` keys, so we invert it and normalise
# the prefix separator (`us-gaap_Revenues` -> `us-gaap:Revenues`). `_comment_*` keys are skipped.
const _EDGARTOOLS = Ref{Union{Nothing,Dict{String,String}}}(nothing)

"""
    edgartools_mapping() -> Dict{String,String}

The community concept-standardization mapping vendored from
[edgartools](https://github.com/dgunning/edgartools) (MIT-licensed; see
`src/core/taxonomy/data/edgartools_concept_mappings.NOTICE.md`), as a `concept => standard_concept` dict —
e.g. `"us-gaap:Revenues" => "Revenue"`, `"us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax" => "Contract Revenue"`.
Activate it with `set_standardizer(:edgartools)`; this accessor returns the dict itself (parsed
once and cached) for inspection or extension.
"""
function edgartools_mapping()
    _EDGARTOOLS[] === nothing || return _EDGARTOOLS[]
    raw = JSON3.read(read(joinpath(@__DIR__, "taxonomy", "data", "edgartools_concept_mappings.json"), String))
    m = Dict{String,String}()
    for (standard, concepts) in pairs(raw)
        startswith(String(standard), "_") && continue          # skip _comment_* keys
        concepts isa JSON3.Array || continue
        for c in concepts
            m[replace(String(c), "_" => ":"; count = 1)] = String(standard)
        end
    end
    _EDGARTOOLS[] = m
    return m
end
