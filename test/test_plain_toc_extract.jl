using Test
using EDGAR

@testset "plain_toc_extract" begin
    sample_path = joinpath(@__DIR__, "data", "sample_plain_toc_filing.html")
    txt = read(sample_path, String)
    sections = EDGAR.extract_section(txt, ["Item 7", "Management's Discussion"])

    @test haskey(sections, "Item 7")
    @test !isempty(sections["Item 7"]) 
    @test occursin("Discussion of Operations", sections["Item 7"]) || occursin("Management", sections["Item 7"]) 
end
