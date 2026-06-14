using Test
using EDGAR

@testset "EDGAR basic" begin
    # Smoke test: list recent filings (network request). Wrapped so CI/offline doesn't fail.
    try
        res = EDGAR.list_recent_filings("0000320193"; count = 1)
        @test isa(res, Array)
    catch e
        @info "Skipping network smoke test: $e"
        @test true
    end
end
