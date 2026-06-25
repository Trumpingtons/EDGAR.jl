# Arelle xBRL-JSON oracle — a do-it-yourself validation source.
#
# NOTE: this file is NOT part of the EDGAR module (it is not `include`d by src/EDGAR.jl). It is a
# self-contained helper you load on demand to reassure yourself that EDGAR.jl's extraction matches an
# independent reference. Keeping it out of the module means it adds no dependencies to the package.
#
# What it checks: for an ESEF/UKSEF filing it compares every consolidated numeric fact EDGAR.jl
# extracts from the inline XBRL against the SAME filing's **xBRL-JSON** as published by
# filings.xbrl.org — which is produced by **Arelle**, the reference XBRL processor. So it pits our
# extractor against an independent, standards-grade parse of the identical document (EU + UK coverage).
#
# This mirrors ESEF.jl's `pluck_xbrl_json` (MIT, trr266) — read a filing's xBRL-JSON facts — using
# just the HTTP+JSON it needs (via EDGAR's own cached fetcher), so no extra dependency is pulled in.
# Credit: ESEF.jl.
#
# Usage:
#   include(joinpath(pkgdir(EDGAR), "src", "sources", "arelle_oracle.jl"))
#   using .ArelleOracle
#   rows = ArelleOracle.validate("549300P8N0P6KDGTJ206"; year = 2023)  # Vector of comparison rows
#   ArelleOracle.report()                                              # run the built-in firm panel

module ArelleOracle

using EDGAR, Dates, Printf
const JSON3 = EDGAR.JSON3            # not exported by EDGAR; reached through the module (no new dep)

const FXBRL = "https://filings.xbrl.org"

# One comparison row: the oracle's value for a fact and the value EDGAR.jl extracted for it.
const Row = @NamedTuple{concept::String, unit::String, period_end::Union{Date,Nothing},
                        edgar::Union{Float64,Nothing}, reference::Float64, rel_diff::Float64, match::Bool}

isempty(strip(try EDGAR.get_user_agent() catch; "" end)) &&
    EDGAR.set_user_agent(get(ENV, "EDGAR_UA", "EDGAR.jl validation noreply@example.com"))

# filings.xbrl.org filings for an LEI: (package, json, period, country), absolute URLs.
function _filings(lei::AbstractString)
    flt = "%5B%7B%22name%22%3A%22entity.identifier%22%2C%22op%22%3A%22eq%22%2C%22val%22%3A%22$lei%22%7D%5D"
    body = EDGAR.fetch_url("$FXBRL/api/filings?filter=$flt&page%5Bsize%5D=50")
    body === nothing && error("filings.xbrl.org query failed for $lei")
    doc = JSON3.read(body)
    out = NamedTuple{(:package, :json, :period, :country),Tuple{String,String,Union{Date,Nothing},String}}[]
    for f in get(doc, :data, ())
        a = f.attributes
        pkg = get(a, :package_url, nothing); js = get(a, :json_url, nothing)
        (pkg === nothing || js === nothing) && continue
        push!(out, (package = FXBRL * String(pkg), json = FXBRL * String(js),
                    period = tryparse(Date, String(get(a, :period_end, ""))), country = String(get(a, :country, ""))))
    end
    return out
end

# Drop OIM/XBRL namespace prefixes so units compare equal: "iso4217:EUR"→"EUR", "…/xbrli:shares"→"…/shares".
_norm_unit(u::AbstractString) = replace(replace(String(u), "iso4217:" => ""), "xbrli:" => "")

# End Date of an OIM period: the instant, or a duration's end component ("start/end").
function _oim_end(period::AbstractString)
    s = occursin('/', period) ? String(split(period, '/')[end]) : String(period)
    dt = tryparse(DateTime, s); dt !== nothing && return Date(dt)
    return tryparse(Date, s)
end

# The consolidated numeric oracle facts from a filing's xBRL-JSON: (concept, unit, value, enddate).
# Consolidated = only the four core OIM aspects (concept/entity/period/unit); numeric = has a unit.
function _oracle_facts(json_url::AbstractString)
    body = EDGAR.fetch_url(json_url); body === nothing && error("could not fetch xBRL-JSON $json_url")
    doc = JSON3.read(body)
    out = NamedTuple{(:concept, :unit, :value, :enddate),Tuple{String,String,Float64,Union{Date,Nothing}}}[]
    for (_, f) in get(doc, :facts, Dict())
        dim = get(f, :dimensions, nothing); dim === nothing && continue
        haskey(dim, :unit) || continue
        length(keys(dim)) == 4 || continue
        v = tryparse(Float64, string(get(f, :value, ""))); v === nothing && continue
        push!(out, (concept = String(dim.concept), unit = _norm_unit(String(dim.unit)),
                    value = v, enddate = _oim_end(String(get(dim, :period, "")))))
    end
    return out
end

const RTOL = 1e-4

# EDGAR.jl's value for an oracle fact: a consolidated (undimensioned) fact with the same concept+unit
# and period end within ±1 day (OIM instant convention), or `nothing` if EDGAR has no such fact.
function _edgar_value(edgar, o)
    for e in edgar
        e.concept == o.concept || continue
        _norm_unit(e.unit) == o.unit || continue
        (e.dimensions == "{}" || isempty(e.dimensions)) || continue
        o.enddate === nothing || abs((e.period_end - o.enddate).value) <= 1 || continue
        return e.value
    end
    return nothing
end

"""
    validate(lei; year=nothing, lang="en") -> Vector{Row}

Validate EDGAR.jl's extraction of a filer's ESEF filing against the Arelle-produced xBRL-JSON on
filings.xbrl.org. Returns one [`Row`](@ref) per consolidated oracle fact: its `concept`, `unit`,
`period_end`, the `edgar` value (or `nothing` if EDGAR didn't extract it), the `reference` value, the
`rel_diff`, and whether they `match` (within `1e-4`). Pass `year`/`lang` to pick among a filer's
packages. Feed the result to `PrettyTables`, or filter to `r -> !r.match` to see any discrepancies.
"""
function validate(lei::AbstractString; year::Union{Int,Nothing}=nothing, lang::AbstractString="en")
    fs = _filings(lei)
    isempty(fs) && return Row[]
    cand = [f for f in fs if endswith(f.json, "$lang.json") && (year === nothing || (f.period !== nothing && Dates.year(f.period) == year))]
    isempty(cand) && (cand = fs)
    f = cand[argmax([something(x.period, Date(0)) for x in cand])]
    oracle = _oracle_facts(f.json)
    edgar = EDGAR.facts(fetch_filing(ESEF(), f.package))
    rows = Row[]
    for o in oracle
        ev = _edgar_value(edgar, o)
        rd = ev === nothing ? Inf : abs(ev - o.value) / max(abs(o.value), 1)
        push!(rows, (concept = o.concept, unit = o.unit, period_end = o.enddate,
                     edgar = ev, reference = o.value, rel_diff = rd, match = ev !== nothing && rd <= RTOL))
    end
    return rows
end

# Is oracle fact `o` present? (used to confirm a specific EDGAR fact against the reference)
function _in_oracle(oracle, concept, unit, value, pe)
    u = _norm_unit(unit)
    for o in oracle
        o.concept == concept || continue
        o.unit == u || continue
        (pe === nothing || o.enddate === nothing || abs((pe - o.enddate).value) <= 1) || continue
        abs(o.value - value) <= RTOL * max(abs(value), 1) && return true
    end
    return false
end

"""
    statements(lei; year=nothing, lang="en") -> Vector{NamedTuple}

Per-statement parity for a filer: bucket EDGAR.jl's facts by statement (via the presentation linkbase,
`statement_map`) and, for each of the three core statements, report how many of its consolidated
line-item facts the Arelle xBRL-JSON oracle confirms. Values are compared **raw** (as-stored) on both
sides — never the classified/as-presented values, which would differ in sign for `negatedLabel`
concepts. Returns rows `(statement, matched, total)` for `BalanceSheet`, `IncomeStatement`,
`CashFlow`, answering "does EDGAR.jl extract each statement correctly?" fact-by-fact against the
reference processor.
"""
function statements(lei::AbstractString; year::Union{Int,Nothing}=nothing, lang::AbstractString="en")
    fs = _filings(lei)
    isempty(fs) && return NamedTuple[]
    cand = [f for f in fs if endswith(f.json, "$lang.json") && (year === nothing || (f.period !== nothing && Dates.year(f.period) == year))]
    isempty(cand) && (cand = fs)
    f = cand[argmax([something(x.period, Date(0)) for x in cand])]
    oracle = _oracle_facts(f.json)
    fil = fetch_filing(ESEF(), f.package)
    # Bucket by the presentation linkbase (concept => statement), but compare RAW values: the xBRL-JSON
    # oracle is as-STORED (Arelle applies no presentation sign flips), so we must use `facts(fil)`
    # (raw) here, not `facts(fil; classify=true)` (as-PRESENTED). The two differ in sign for any concept
    # a filer tags with a negatedLabel — common on cash-flow lines (e.g. taxes paid) — which would
    # otherwise show up as spurious "mismatches" even though the magnitude is identical.
    sm = EDGAR.statement_map(fil)
    raw = EDGAR.facts(fil)
    nodim(r) = r.dimensions == "{}" || isempty(r.dimensions)
    out = NamedTuple{(:statement, :matched, :total),Tuple{String,Int,Int}}[]
    for stmt in ("BalanceSheet", "IncomeStatement", "CashFlow")
        ef = [r for r in raw if get(sm, r.concept, "") == stmt && nodim(r)]
        matched = count(r -> _in_oracle(oracle, r.concept, r.unit, r.value, r.period_end), ef)
        push!(out, (statement = stmt, matched = matched, total = length(ef)))
    end
    return out
end

# Default panel of ESEF/UKSEF filers (name, LEI, year).
const FIRMS = [
    ("Citycon Oyj (EU)",  "549300P8N0P6KDGTJ206", 2023),
    ("F-Secure Oyj (EU)", "9845006BFDJF0375E466", nothing),
    ("Nokia Oyj (EU)",    "549300A0JPRWG1KI7U06", nothing),
    ("Kainos Group (GB)", "213800H2PQMIF3OVZY47", nothing),
]

"""
    report(firms = FIRMS) -> Bool

Run [`validate`](@ref) over a panel of filers, print a per-filer parity summary, and return whether
every filer reached ≥95% fact parity. Convenient one-call sanity check.
"""
function report(firms = FIRMS)
    ok = true
    tot_m = tot_n = 0
    for (name, lei, year) in firms
        rows = try validate(lei; year = year) catch e; println("\n", name, "  ✗ ", e); ok = false; continue end
        m = count(r -> r.match, rows); n = length(rows)
        tot_m += m; tot_n += n
        rate = 100m / max(n, 1)
        @printf("\n%-18s %d/%d facts reproduced (%.1f%%)\n", name, m, n, rate)
        for s in try statements(lei; year = year) catch; NamedTuple[] end          # per-statement (BS/IS/CF)
            @printf("   %-16s %d/%d\n", s.statement, s.matched, s.total)
        end
        for r in first([r for r in rows if !r.match], 5)
            @printf("   unmatched: %-50s ref %+.6g %s @%s\n", r.concept, r.reference, r.unit, r.period_end)
        end
        rate < 95 && (ok = false)
    end
    @printf("\nArelle xBRL-JSON parity: %d/%d (%.1f%%)\n", tot_m, tot_n, 100tot_m / max(tot_n, 1))
    return ok
end

end # module ArelleOracle

if abspath(PROGRAM_FILE) == @__FILE__
    exit(ArelleOracle.report() ? 0 : 1)    # `julia --project arelle_oracle.jl`
end
