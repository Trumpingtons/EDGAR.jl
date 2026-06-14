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
