using Test
using EDGAR

@testset "multi_page_fragment" begin
    sample_path = joinpath(@__DIR__, "data", "sample_multi_main.html")
    txt = read(sample_path, String)
    sections = EDGAR.extract_section(txt, ["Item 7", "Management's Discussion"], base_path=sample_path)

    @test haskey(sections, "Item 7")
    @test !isempty(sections["Item 7"]) 
    @test occursin("other page", lowercase(sections["Item 7"]))
end
