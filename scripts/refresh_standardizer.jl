#!/usr/bin/env julia
# Maintainer tool — refresh the vendored edgartools concept-mapping snapshot.
#
# Re-downloads `edgar/xbrl/standardization/concept_mappings.json` from upstream edgartools and
# overwrites `src/data/edgartools_concept_mappings.json`. Run it periodically to pick up upstream
# mapping fixes (e.g. the revenue-hierarchy split that distinguishes "Revenue" from
# "Contract Revenue"). The licence is MIT and unchanged; the NOTICE/LICENSE files stay as they are.
#
#   julia --project scripts/refresh_standardizer.jl            # refresh from the default branch
#   julia --project scripts/refresh_standardizer.jl <ref>      # …from a tag/branch/commit
#
# The download is validated as JSON and the mapping is counted before it replaces the vendored
# copy, so a broken upstream file never lands. Inspect the diff with `git diff` afterwards.
import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using Downloads, JSON3

ref = isempty(ARGS) ? "main" : ARGS[1]
url = "https://raw.githubusercontent.com/dgunning/edgartools/$ref/edgar/xbrl/standardization/concept_mappings.json"
dest = joinpath(@__DIR__, "..", "src", "data", "edgartools_concept_mappings.json")

# Count company concepts across the standard => [concepts] entries (skipping `_comment_*` keys).
function count_entries(raw)
    standards = 0; concepts = 0
    for (standard, cs) in pairs(raw)
        startswith(String(standard), "_") && continue
        cs isa JSON3.Array || continue
        standards += 1; concepts += length(cs)
    end
    return (standards, concepts)
end

println("Downloading $url ...")
tmp = Downloads.download(url)
body = read(tmp, String)
raw = JSON3.read(body)                         # throws on malformed JSON -> nothing is overwritten
ns, nc = count_entries(raw)
ns == 0 && error("downloaded mapping has no standard-concept entries — refusing to overwrite")

if isfile(dest)
    os, oc = count_entries(JSON3.read(read(dest, String)))
    println("Current vendored mapping: $os standard concepts, $oc company concepts")
end
write(dest, body)
println("Wrote $dest")
println("New vendored mapping:     $ns standard concepts, $nc company concepts")
println("Review with `git diff -- $(relpath(dest))` and re-run the tests.")
