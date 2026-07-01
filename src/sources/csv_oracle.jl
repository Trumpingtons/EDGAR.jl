# EDINET CSV oracle — a do-it-yourself, same-document validation source.
#
# NOTE: this file is NOT part of the EDGAR module (it is not `include`d by src/EDGAR.jl). It is a
# self-contained helper you load on demand to reassure yourself that EDGAR.jl's extraction matches the
# regulator's own parse of the SAME filing. Keeping it out of the module means it adds no dependencies.
#
# What it checks: EDINET's document API serves every filing as both the submission ZIP (type=1 — the bytes
# `facts(f)`/`narratives(f)` parse) AND a CSV (type=5 — the FSA's own parse of that identical document). So
# it pits our extractor against an authoritative, free, fact-level parse of the byte-identical source — the
# JP analogue of the Arelle/filings.xbrl.org oracle (which does not carry Japan). It validates BOTH numeric
# facts and narrative text-blocks, and surfaces every discrepancy for you to eyeball against the filing.
#
# Usage:
#   include(joinpath(pkgdir(EDGAR), "src", "sources", "csv_oracle.jl"))
#   using .CsvOracle
#   f = fetch_filing(EDINET(), "submission.zip")
#   rep = CsvOracle.validate(f, "jpcrp030000-asr-….csv")   # prints facts + narratives parity
#   CsvOracle.text_diff(rep, "jpcrp_cor:BusinessRisksTextBlock")  # ours vs CSV text, side by side

module CsvOracle

using EDGAR, Printf

# ── The type=5 CSV reader — UTF-16-LE, tab-separated, RFC4180 quoting (fields may contain embedded
# newlines/tabs inside quotes; naive line-splitting truncates multi-line text-block cells). ───────────
function _read_tsv(path::AbstractString)
    txt = transcode(String, reinterpret(UInt16, read(path)))        # UTF-16-LE → UTF-8
    startswith(txt, '﻿') && (txt = txt[nextind(txt, firstindex(txt)):end])   # strip BOM
    rows = Vector{Vector{String}}(); rec = String[]; field = IOBuffer(); inq = false
    i, last = firstindex(txt), lastindex(txt)
    while i <= last
        c = txt[i]
        if inq
            if c == '"'
                j = nextind(txt, i)
                if j <= last && txt[j] == '"'     # "" → an escaped quote inside the field
                    write(field, '"'); i = j
                else
                    inq = false
                end
            else
                write(field, c)
            end
        elseif c == '"'
            inq = true
        elseif c == '\t'
            push!(rec, String(take!(field)))
        elseif c == '\n'
            push!(rec, String(take!(field))); push!(rows, rec); rec = String[]
        elseif c != '\r'
            write(field, c)
        end
        i = nextind(txt, i)
    end
    (field.size > 0 || !isempty(rec)) && (push!(rec, String(take!(field))); push!(rows, rec))
    return rows
end

# One CSV fact: the columns EDINET publishes. `value` is the raw string (numeric or text-block prose).
const CsvRow = @NamedTuple{concept::String, context::String, unit::String, label::String, value::String}

function _load(path::AbstractString)
    rows = _read_tsv(path)
    isempty(rows) && error("empty CSV: $path")
    hdr = rows[1]
    col(name) = something(findfirst(==(name), hdr), 0)
    ci, cx, cu, cl, cv = col("要素ID"), col("コンテキストID"), col("ユニットID"), col("項目名"), col("値")
    (ci == 0 || cx == 0 || cv == 0) && error("unexpected CSV header (not an EDINET type=5 file): $hdr")
    out = CsvRow[]
    for r in rows[2:end]
        length(r) < length(hdr) && continue
        push!(out, (concept = r[ci], context = r[cx], unit = cu == 0 ? "" : r[cu],
                    label = cl == 0 ? "" : r[cl], value = r[cv]))
    end
    return out
end

# ── Oracle projections ───────────────────────────────────────────────────────
# Numeric facts: rows with a unit and a parseable value, keyed (concept, context) → value.
function _oracle_facts(recs)
    d = Dict{Tuple{String,String},Float64}()
    for r in recs
        isempty(r.unit) && continue
        v = tryparse(Float64, replace(r.value, "," => "")); v === nothing && continue
        get!(d, (r.concept, r.context), v)
    end
    return d
end
# Narrative text-blocks: concept ends in "TextBlock" with non-empty text, keyed (concept, context) → text.
function _oracle_narratives(recs)
    d = Dict{Tuple{String,String},String}()
    for r in recs
        (endswith(r.concept, "TextBlock") && !isempty(strip(r.value))) || continue
        get!(d, (r.concept, r.context), r.value)
    end
    return d
end

_nows(s) = replace(s, r"[\s　]" => "")    # content-equality ignores whitespace (incl. full-width space)

# ── validate(f, csv) — facts + narratives parity, printed; returns a report you can drill into. ───────
struct Report
    facts_ours::Dict{Tuple{String,String},Float64}
    facts_orc::Dict{Tuple{String,String},Float64}
    narr_ours::Dict{Tuple{String,String},String}
    narr_orc::Dict{Tuple{String,String},String}
end

function validate(f, csv::AbstractString; io::IO = stdout)
    recs = _load(csv)
    fo = Dict((String(r.concept), String(r.context_ref)) => Float64(r.value)
              for r in EDGAR.facts(f) if r.value !== nothing)
    fc = _oracle_facts(recs)
    no = Dict((String(r.concept), String(r.context_ref)) => String(r.text)
              for r in EDGAR.narratives(f))
    nc = _oracle_narratives(recs)

    _section(io, "NUMERIC facts", fo, fc; num = true)
    _section(io, "NARRATIVE text-blocks", no, nc; num = false)
    return Report(fo, fc, no, nc)
end

function _section(io, title, ours, orc; num::Bool)
    shared = intersect(keys(ours), keys(orc))
    if num
        matched = count(k -> isapprox(ours[k], orc[k]; rtol = 1e-6, atol = 0.5), shared)
        diff = [k for k in shared if !isapprox(ours[k], orc[k]; rtol = 1e-6, atol = 0.5)]
    else
        matched = count(k -> _nows(ours[k]) == _nows(orc[k]), shared)
        diff = [k for k in shared if _nows(ours[k]) != _nows(orc[k])]
    end
    onlyOurs, onlyOrc = setdiff(keys(ours), keys(orc)), setdiff(keys(orc), keys(ours))
    @printf(io, "\n=== %s ===\n", title)
    @printf(io, "  ours=%d  oracle=%d  matched=%d  differ=%d  only-ours=%d  only-oracle=%d\n",
            length(ours), length(orc), matched, length(diff), length(onlyOurs), length(onlyOrc))
    for k in first(sort(diff; by = k -> num ? 0 : -abs(length(ours[k]) - length(orc[k]))), 8)
        num ? @printf(io, "    DIFFER %-55s ours=%s oracle=%s\n", k[1], ours[k], orc[k]) :
              @printf(io, "    DIFFER %-55s ours=%dch oracle=%dch\n", k[1], length(ours[k]), length(orc[k]))
    end
    for k in first(collect(onlyOrc), 6)
        @printf(io, "    only-oracle %-55s [%s]\n", k[1], k[2])
    end
end

# text_diff(rep, concept) — the human affordance: our text vs the CSV's, side by side, for one concept.
function text_diff(rep::Report, concept::AbstractString; ctx::Union{Nothing,AbstractString} = nothing)
    k = nothing
    for kk in keys(rep.narr_ours)
        (kk[1] == concept && (ctx === nothing || kk[2] == ctx)) && (k = kk; break)
    end
    k === nothing && return println("no narrative for ", concept)
    o = get(rep.narr_ours, k, ""); c = get(rep.narr_orc, k, "")
    @printf("concept %s  [%s]\n  ours=%dch (nows %d)  csv=%dch (nows %d)  content-equal=%s\n",
            k[1], k[2], length(o), length(_nows(o)), length(c), length(_nows(c)), _nows(o) == _nows(c))
    println("  --- OURS head ---\n  ", first(o, 300))
    println("  --- CSV  head ---\n  ", first(c, 300))
end

# report(pairs) — run several (filing, csv) pairs, one summary each.
function report(pairs)
    for (f, csv) in pairs
        validate(f, csv)
    end
end

end # module
