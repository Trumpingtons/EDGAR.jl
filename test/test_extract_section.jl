using Test
using EDGAR

@testset "extract_section" begin
    sample_path = joinpath(@__DIR__, "data", "sample_filing.html")
    txt = read(sample_path, String)
    sections = EDGAR.extract_section(txt, ["Item 7", "Management's Discussion"])

    @test haskey(sections, "Item 7")
    @test !isempty(sections["Item 7"])
    @test occursin("Discussion of Operations", sections["Item 7"]) || occursin("Management", sections["Item 7"]) 
end
