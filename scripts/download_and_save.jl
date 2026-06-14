#!/usr/bin/env julia
import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using EDGAR

function usage()
    println("Usage: julia --project scripts/download_and_save.jl <CIK> <ACCESSION> [outdir]")
    println("Example: julia --project scripts/download_and_save.jl 0000320193 0000320193-23-000052 output")
end

if length(ARGS) < 2
    usage(); exit(1)
end

cik = ARGS[1]
accession = ARGS[2]
outdir = length(ARGS) >= 3 ? ARGS[3] : "output"

println("Downloading filing $accession for CIK $cik...")
path = EDGAR.download_filing(cik, accession; destdir="filings")
println("Downloaded to: $path")

println("Parsing filing...")
text = EDGAR.parse_filing(path)

meta = Dict("cik" => cik, "accession" => accession, "source_path" => path)
paths = EDGAR.save_filing(text, meta; outdir=outdir)
println("Saved text to: $(paths[1])")
println("Saved metadata to: $(paths[2])")
