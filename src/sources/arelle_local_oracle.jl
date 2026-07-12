# Local-Arelle oracle — a do-it-yourself validation source that runs Arelle yourself.
#
# NOTE: this file is NOT part of the EDGAR module (it is not `include`d by src/EDGAR.jl). It is a
# self-contained helper you load on demand. Unlike `arelle_esef_oracle.jl` (which fetches Arelle's *published*
# xBRL-JSON from filings.xbrl.org and so adds no dependency), this oracle runs **Arelle itself** as a
# subprocess on a locally downloaded XBRL package — so it needs the **Arelle CLI** installed
# (https://arelle.org). In return it works for jurisdictions filings.xbrl.org does NOT host — notably
# **Korea (DART)** and Japan (EDINET) — and it compares **every** fact, *including dimensional ones*, so it
# can validate the **statement of changes in equity** (the per-equity-component movements table) that the
# consolidated/undimensioned remote oracle, Yahoo and OpenDART's `fnlttSinglAcntAll` cannot.
#
# What it checks: Arelle (the reference XBRL processor, an independent implementation) parses the SAME
# bytes EDGAR.jl parses, and we assert that EDGAR.jl's value for every fact — keyed by
# concept + period + full dimension set — equals Arelle's. A same-document, fact-level, dimension-aware
# parser check.
#
# Arelle is located via, in order: the `ARELLE_CMD` env var; `arelleCmdLine` on `PATH`; the macOS app
# (`/Applications/Arelle.app/Contents/MacOS/arelleCmdLine`). Set `ARELLE_CMD` if yours is elsewhere.
#
# Usage (needs Arelle; discover the filing yourself for any system, e.g. DART with a free OpenDART key):
#   set_credentials(DART(); api_key = ENV["DART_API_KEY"])
#   include(joinpath(pkgdir(EDGAR), "src", "sources", "arelle_local_oracle.jl"))
#   using .ArelleLocalOracle
#   f    = fetch_filing(first(discover(OpenDARTApi(); corp_code = dart_corp_code("005930"))))
#   rows = ArelleLocalOracle.validate(f)
#   ArelleLocalOracle.report(rows)                             # per-statement parity, incl. SCE
#   filter(r -> !r.match, rows)                                # any discrepancies

module ArelleLocalOracle

using EDGAR, Dates, Printf
const JSON3 = EDGAR.JSON3            # not exported by EDGAR; reached through the module (no new dep)
import ZipArchives                  # an EDGAR dependency, so available in the package environment

# One comparison row: EDGAR.jl's value for a fact and Arelle's value for the same (concept, period, dims).
const Row = @NamedTuple{statement::String, concept::String, period_end::Union{Date,Nothing},
                        dims::String, edgar::Float64, arelle::Union{Float64,Nothing}, match::Bool}

const RTOL = 1e-6

# Locate the Arelle command line.
function _arelle_cmd()
    c = get(ENV, "ARELLE_CMD", "")
    isempty(c) || return c
    w = Sys.which("arelleCmdLine"); w === nothing || return w
    mac = "/Applications/Arelle.app/Contents/MacOS/arelleCmdLine"
    isfile(mac) && return mac
    error("Arelle CLI not found. Install Arelle (https://arelle.org) and/or set ENV[\"ARELLE_CMD\"].")
end

# ── canonical dimension key: sorted "axis=member|axis=member" (order-independent) ──
function _edgar_dims(d::AbstractString)
    (isempty(d) || d == "{}") && return ""
    m = JSON3.read(d, Dict{String,String})
    join(sort(["$k=$v" for (k, v) in m]), "|")
end
# Arelle's factList "Dimensions" column is a flat, unquoted, comma-separated `axis,member,axis,member,…`.
function _arelle_dims(rest::AbstractString)
    toks = filter(!isempty, strip.(split(rest, ",")))
    isempty(toks) && return ""
    join(sort(["$(toks[i])=$(toks[i+1])" for i in 1:2:length(toks)-1]), "|")
end

_num(s) = tryparse(Float64, replace(replace(strip(String(s)), "\"" => ""), "," => ""))

# Materialise a filing's XBRL package to a temp dir of loose files; return (dir, instance_path). Re-fetches
# `f.url` (the package ZIP) through EDGAR's cached fetcher with the system's headers/cache policy, unless
# `f.url` is already a local file. Uses the system `unzip`.
function _materialise(f)
    src = f.url
    # Loose single instance (e.g. SEC inline XBRL): not a ZIP package. Its DTS (us-gaap + the filer's
    # extension) resolves RELATIVE to the source, so hand Arelle the URL/path directly — it fetches the
    # document and its taxonomy itself. (A local loose instance works only if its DTS sits beside it.)
    endswith(lowercase(src), ".zip") || return mktempdir(; prefix = "arelle_local_"), src
    bytes = if startswith(src, "http://") || startswith(src, "https://")
        hdr = try EDGAR.system_headers(f.system) catch; nothing end
        EDGAR.fetch_url(src; headers = hdr, cache_mode = EDGAR.effective_cache_mode(f.system))
    else
        read(src)
    end
    bytes === nothing && error("could not fetch package $src")
    dir = mktempdir(; prefix = "arelle_local_")
    z = ZipArchives.ZipReader(Vector{UInt8}(bytes))
    names = ZipArchives.zip_names(z)
    # A formal report/taxonomy package (ESEF/UKSEF) carries `META-INF/taxonomyPackage.xml` (+ `catalog.xml`)
    # that REMAPS the standard taxonomy. Arelle must load such a package AS A PACKAGE (`--file` on the zip)
    # so the catalog resolves — otherwise the standard concepts have no schema and factList values come back
    # empty. Loose packages (e.g. DART `fnlttXbrl`) have no `META-INF`: extract them (preserving the
    # directory structure) and point Arelle at the instance.
    if any(n -> occursin(r"META-INF/(taxonomyPackage|catalog)\.xml"i, n), names)
        zp = joinpath(dir, "package.zip"); write(zp, bytes)
        return dir, zp
    end
    for n in names
        endswith(n, "/") && continue
        dest = joinpath(dir, n); mkpath(dirname(dest))
        open(dest, "w") do io; write(io, ZipArchives.zip_readentry(z, n)); end
    end
    # Find the primary instance anywhere in the tree: a classic `.xbrl`, else inline-XBRL (`.xhtml`/`.htm`,
    # ESEF/EDINET). Prefer an entry under `reports/` or `PublicDoc/` when several inline docs exist.
    allf = String[]
    for (root, _, fs) in walkdir(dir), fn in fs; push!(allf, joinpath(root, fn)); end
    function pick(exts)
        cands = filter(p -> any(e -> endswith(lowercase(p), e), exts), allf)
        isempty(cands) && return nothing
        pref = filter(p -> occursin(r"/reports/|/publicdoc/"i, p), cands)
        return first(isempty(pref) ? cands : pref)
    end
    inst = something(pick((".xbrl",)), pick((".xhtml", ".htm", ".html")), Some(nothing))
    inst === nothing && error("no XBRL instance found in package $src")
    return dir, inst
end

# Run Arelle on `instance`, returning its facts indexed by (concept, start, end, dims) => value.
function _arelle_facts(instance::AbstractString)
    csv = tempname() * ".csv"
    cmd = `$(_arelle_cmd()) --file $instance --facts $csv --factListCols "Name unitRef Dec Value Period Dimensions"`
    run(pipeline(cmd; stdout = devnull, stderr = devnull))
    isfile(csv) || error("Arelle produced no facts file (taxonomy resolution may have failed)")
    out = Dict{Tuple{String,String,String,String},Float64}()
    # Columns: Name,unitRef,Dec,Value,Start,End/Instant[,Dimensions]. The Dimensions field is a flat
    # unquoted `axis,member,…` list AND is OMITTED entirely for undimensioned facts (no trailing comma),
    # so it must be optional — else every undimensioned fact (e.g. entity-level counts) would be skipped.
    line = r"^([^,]+),([^,]*),([^,]*),(\"[^\"]*\"|[^,]*),([^,]*),([^,]*)(?:,(.*))?$"
    open(csv) do io
        readline(io)  # header
        for ln in eachline(io)
            m = match(line, ln); m === nothing && continue
            v = _num(m.captures[4]); v === nothing && continue
            dims = m.captures[7] === nothing ? "" : _arelle_dims(m.captures[7])
            out[(String(m.captures[1]), String(m.captures[5]), String(m.captures[6]), dims)] = v
        end
    end
    return out
end

"""
    validate(f::Filing; classify=true) -> Vector{Row}

Validate EDGAR.jl's extraction of a filing against a **local Arelle** parse of the same XBRL package.
Materialises `f`'s package, runs `arelleCmdLine` on it, and returns one [`Row`](@ref) per EDGAR fact:
its `statement` (from EDGAR's classification), `concept`, `period_end`, `dims`, the `edgar` value, the
`arelle` value for the same (concept, period, dimensions) tuple (or `nothing`), and whether they `match`
(within `1e-6`). Because it keys on the **full dimension set**, it covers dimensional statements — in
particular the statement of changes in equity (`statement == "Equity"`).
"""
function validate(f)
    dir, inst = _materialise(f)
    try
        ar = _arelle_facts(inst)
        # Compare RAW (as-stored) values on both sides — Arelle reports raw, and EDGAR's *classified*
        # value flips sign for `negatedLabel` / cash-outflow concepts (an as-presented convention, not the
        # bytes). So use `facts(f)` (raw) for the value, and `facts(f; classify=true)` only for the
        # statement LABEL, joined per fact on (concept, contextRef).
        stmt = Dict{Tuple{String,String},String}()
        for r in EDGAR.facts(f; classify = true)
            stmt[(r.concept, r.context_ref)] = String(r.statement)
        end
        rows = Row[]
        for r in EDGAR.facts(f)
            start = r.is_instant ? "" : (r.period_start === nothing ? "" : string(r.period_start))
            key = (r.concept, start, string(r.period_end), _edgar_dims(r.dimensions))
            av = get(ar, key, nothing)
            ok = av !== nothing && abs(av - r.value) <= RTOL * max(abs(r.value), 1)
            push!(rows, (statement = get(stmt, (r.concept, r.context_ref), ""), concept = r.concept,
                         period_end = r.period_end, dims = r.dimensions, edgar = r.value, arelle = av, match = ok))
        end
        return rows
    finally
        rm(dir; force = true, recursive = true)
    end
end

"""
    report(rows) -> rows

Print a per-statement parity summary (how many of EDGAR.jl's facts Arelle confirms, statement by
statement — including `Equity`, the statement of changes in equity), then return the rows.

For a DART filer, discover + fetch the filing yourself, then `report(validate(f))`:
`f = fetch_filing(first(discover(OpenDARTApi(); corp_code))); report(validate(f))`.
"""
function report(rows::Vector{Row})
    @printf("Local-Arelle oracle: %d/%d EDGAR facts confirmed (%.1f%%)\n",
            count(r -> r.match, rows), length(rows),
            100 * count(r -> r.match, rows) / max(length(rows), 1))
    stmts = unique(r.statement for r in rows)
    order = ["BalanceSheet", "IncomeStatement", "ComprehensiveIncome", "CashFlow", "Equity", ""]
    for s in vcat(filter(x -> x in stmts, order), filter(x -> !(x in order), collect(stmts)))
        sub = filter(r -> r.statement == s, rows); isempty(sub) && continue
        tag = isempty(s) ? "(unclassified)" : s
        @printf("  %-20s %4d / %4d\n", tag, count(r -> r.match, sub), length(sub))
    end
    miss = filter(r -> !r.match, rows)
    if !isempty(miss)
        @printf("  %d not confirmed (showing up to 8):\n", length(miss))
        for r in Iterators.take(miss, 8)
            @printf("    [%s] %-40s edgar=%.0f arelle=%s\n", r.statement, r.concept, r.edgar,
                    r.arelle === nothing ? "NO-KEY" : @sprintf("%.0f", r.arelle))
        end
    end
    return rows
end

end # module
