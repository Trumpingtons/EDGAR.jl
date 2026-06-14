using Test
using EDGAR

@testset "remote_fragment_fetch" begin
    # Monkeypatch EDGAR.http_get to avoid real network calls
    struct FakeResp
        status::Int
        body::Vector{UInt8}
    end
    orig = EDGAR.http_get
    EDGAR.http_get = (url; kwargs...) -> FakeResp(200, Vector{UInt8}(codeunits("<html><body><div id=\"itemX\"><p>Remote content</p></div></body></html>")))

    # clear cache dir
    try
        for f in readdir(joinpath(pwd(), ".edgar_cache"))
            rm(joinpath(pwd(), ".edgar_cache", f))
        end
    catch
    end

    # fetch remote URL (simulated)
    url = "https://example.test/other.html#itemX"
    raw = EDGAR.fetch_url("https://example.test/other.html")
    @test raw !== nothing

    # now extract via extract_section (should fetch and find fragment)
    html_main = "<html><body><div id=\"toc\"><a href=\"https://example.test/other.html#itemX\">Item X</a></div></body></html>"
    sections = EDGAR.extract_section(html_main, ["Item X"], base_path="/dev/null")
    @test haskey(sections, "Item X")
    @test occursin("remote content", lowercase(sections["Item X"]))

    # metrics show at least one request
    m = EDGAR.cache_metrics()
    @test m[:requests] >= 1

    # cleanup monkeypatch
    EDGAR.http_get = orig
end
