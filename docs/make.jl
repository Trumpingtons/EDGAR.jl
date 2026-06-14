using Pkg

# Build the docs in the dedicated docs/ environment (docs/Project.toml carries
# Documenter). EDGAR is developed from the repo root by path, so Documenter and
# its dependencies stay OUT of the package's own Project.toml/Manifest.toml.
Pkg.activate(@__DIR__)
Pkg.develop(PackageSpec(path = dirname(@__DIR__)))
Pkg.instantiate()

using Documenter
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
