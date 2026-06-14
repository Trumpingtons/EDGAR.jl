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
    sitename = "EDGAR",
    authors = "Antonio Saragga Seabra",
    format = Documenter.HTML(),
    pages = [
        "Home" => "index.md",
        "Examples" => "examples.md",
        "API" => "api.md",
    ],
    clean = true,
)

println("Docs built to docs/build")

# Deploy the versioned docs to the gh-pages branch. deploydocs is a no-op unless
# it detects a deploying CI build (the right branch/tag plus GITHUB_TOKEN), so it
# is safe to call unconditionally — local builds simply skip the deploy.
deploydocs(
    repo = "github.com/Trumpingtons/EDGAR.jl.git",
    devbranch = "main",
    push_preview = false,
)
