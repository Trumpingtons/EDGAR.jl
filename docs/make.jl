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

# Only deploy when running in GitHub Actions (avoid accidental local deploys)
if get(ENV, "GITHUB_ACTIONS", "") == "true"
    try
        deploydocs(
            repo = "https://github.com/Trumpingtons/EDGAR.jl.git",
            branch = "gh-pages",
            provider = Documenter.GitHubActions()
        )
    catch err
        @warn "deploydocs failed; skipping deploy in this environment" error=err
    end
end
