using Pkg

# When developing locally, activate the package project so Documenter can find
# the package source. In CI we may prefer a separate docs project, but to keep
# instantiation robust we activate the root project for both cases.
root = normpath(joinpath(@__DIR__, ".."))
Pkg.activate(root)

# Ensure Documenter is available in this environment
try
    @eval using Documenter
catch
    Pkg.add("Documenter")
    @eval using Documenter
end

using EDGAR

makedocs(
    modules = [EDGAR],
    sitename = "EDGAR.jl",
    authors = "Your Name",
    format = Documenter.HTML(),
    pages = [
        "Home" => "index.md",
        "API" => "api.md",
    ],
    clean = true,
)

println("Docs built to docs/build")

# Only deploy via Documenter when a DOCUMENTER_KEY is provided (SSH key).
# We rely on the GitHub Pages actions workflow to publish `docs/build` by
# default, so avoid automatic pushes from Documenter unless an SSH key is
# explicitly configured in `DOCUMENTER_KEY`.
if !isempty(get(ENV, "DOCUMENTER_KEY", ""))
    try
        deploydocs(repo = "Trumpingtons/EDGAR.jl", branch = "gh-pages")
    catch err
        @warn "deploydocs failed; skipping deploy in this environment" error=err
    end
end
