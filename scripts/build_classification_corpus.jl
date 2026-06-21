#!/usr/bin/env julia
# Maintainer tool — (re)build the offline statement-classification corpus used by the test suite
# (test/data/classification_corpus.json). For a curated set of real filings spanning taxonomies and
# sectors, it captures each presentation/FilingSummary role as a case `(filer, accession, taxonomy,
# jurisdiction, role, concepts, expected)` — `concepts` is exactly what `_classify_role` receives in
# production, so the corpus reproduces real inputs offline. `expected` is seeded from the current
# classifier (these filers are validated-correct); when porting a new rule (Phase R2), add the
# offending filing here and set `expected` to the CORRECT label — the test goes red, then the rule
# makes it green (the fail->correct discipline).
#
#   julia --project scripts/build_classification_corpus.jl
import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using EDGAR
import EDGAR: JSON3
set_user_agent(get(ENV, "SEC_USER_AGENT", "EDGAR.jl corpus builder noreply@example.com"))

# Curated seed: (filer, cik, form). Spans us-gaap mainstream / bank / BDC / FilingSummary-fallback /
# ProfitLoss-filer, and ifrs-full 20-F (incl. AZN's combined P&L+OCI edge).
const SEED = [
    ("ORCL", first(cik("ORCL"; by=:ticker)).cik, "10-Q"),   # us-gaap tech
    ("STT",  first(cik("STT";  by=:ticker)).cik, "10-Q"),   # bank: "Statement of Condition"
    ("ARCC", first(cik("ARCC"; by=:ticker)).cik, "10-Q"),   # BDC
    ("MSFT", "0000789019", "10-Q"),                          # FilingSummary fallback
    ("PNC",  first(cik("PNC";  by=:ticker)).cik, "10-Q"),    # ProfitLoss filer
    ("SAP",  first(cik("SAP";  by=:ticker)).cik, "20-F"),    # ifrs-full
    ("NVS",  first(cik("NVS";  by=:ticker)).cik, "20-F"),    # ifrs-full
    ("AZN",  first(cik("AZN";  by=:ticker)).cik, "20-F"),    # ifrs-full combined P&L+OCI
]

# Roles (role-name, concepts) of a filing: from the presentation linkbase if present, else the
# FilingSummary R-files. Mirrors how `statement_map` sources them.
function filing_roles(f)
    pre = EDGAR._fetch_linkbase(f, "pre")
    if !isempty(pre)
        out = Tuple{String,Vector{String}}[]
        for m in eachmatch(r"(?is)<(?:link:)?presentationLink\b[^>]*\brole=\"([^\"]+)\"[^>]*>(.*?)</(?:link:)?presentationLink>", pre)
            concepts = unique!(String[replace(String(l.captures[1]), "_" => ":"; count=1)
                                      for l in eachmatch(r"xlink:href=\"[^\"#]*#([^\"]+)\"", m.captures[2])])
            push!(out, (String(m.captures[1]), concepts))
        end
        return out
    end
    base = EDGAR._filing_dir(f.cik, f.accession)
    fs = EDGAR.fetch_url("$base/FilingSummary.xml")
    fs === nothing && return Tuple{String,Vector{String}}[]
    return [(r.statement * " | " * r.file,  # role label not in FS; use the rendered statement name
             EDGAR._rfile_concepts(String(something(EDGAR.fetch_url("$base/$(r.file)"), UInt8[]))))
            for r in EDGAR._filing_summary_reports(String(fs))]
end

taxonomy(concepts) = any(startswith(c, "ifrs-full:") for c in concepts) ? "ifrs-full" : "us-gaap"

cases = Any[]
for (filer, cikv, form) in SEED
    rows = filings_by_cik(cikv; forms=form)
    isempty(rows) && (@warn "no $form for $filer"; continue)
    f = fetch_filing(cikv, rows[1].accession)
    roles = filing_roles(f)
    faces = 0; negs = 0
    for (role, concepts) in roles
        isempty(concepts) && continue
        cls = EDGAR._classify_role(role, concepts)
        nrole = lowercase(replace(last(split(role, "/")), r"[^A-Za-z0-9]" => ""))
        isface = !isempty(cls)
        isneg = isempty(cls) && (occursin("parenthetical", nrole) || occursin("details", nrole)) && negs < 2
        (isface || isneg) || continue
        isface ? (faces += 1) : (negs += 1)
        push!(cases, (filer=filer, accession=f.accession, taxonomy=taxonomy(concepts),
                      jurisdiction="SEC", role=role, expected=cls, concepts=sort(concepts)))
    end
    @info "captured" filer faces negatives=negs
end
sort!(cases, by = c -> (c.filer, c.role))

doc = (_doc = "Offline statement-classification corpus for EDGAR.jl (Phase R). Each case asserts " *
              "_classify_role(role, concepts) == expected. `expected` is the validated-correct label " *
              "(seeded from the classifier on known-good filings). Regenerate with " *
              "scripts/build_classification_corpus.jl. Add red cases here when porting a rule (R2).",
       cases = cases)
dest = joinpath(@__DIR__, "..", "test", "data", "classification_corpus.json")
open(dest, "w") do io; JSON3.pretty(io, doc); end
println("Wrote $(length(cases)) cases to $dest")
