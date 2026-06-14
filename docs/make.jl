using Pkg
Pkg.activate(@__DIR__)
Pkg.instantiate()

using Documenter, EDGAR

makedocs(
    modules = [EDGAR],
    sitename = "EDGAR.jl",
    authors = ["Your Name"],
    format = Documenter.HTML(),
    pages = [
        "Home" => "index.md",
        "API" => "api.md",
    ],
    clean = true,
)

println("Docs built to docs/build")

# Deploy to GitHub Pages when running in CI (GitHub Actions)
try
    deploydocs(
        repo = "https://github.com/Trumpingtons/EDGAR.jl.git",
        branch = "gh-pages",
        provider = Documenter.GitHubActions()
    )
catch err
    @warn "deploydocs failed; skipping deploy in this environment" error=err
end
