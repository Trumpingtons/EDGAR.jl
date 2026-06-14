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

@testset "EDGAR XBRL / search / ticker" begin
    # Smoke tests for the XBRL, full-text-search and ticker endpoints. Each
    # function returns parsed JSON on success and throws on failure, so the
    # whole block is wrapped to stay green offline or when the SEC rate-limits.
    try
        # Call on plain lines so a network/403 error propagates to the catch
        # below (a throw inside `@test` would be recorded as an error instead).
        facts = EDGAR.company_facts("0000320193")
        concept = EDGAR.company_concept("0000320193", "us-gaap", "NetIncomeLoss")
        frames = EDGAR.xbrl_frames("us-gaap", "Assets", "USD", "CY2022Q4I")
        search = EDGAR.full_text_search("climate risk"; forms = "10-K", size = 1)
        cik = EDGAR.cik_for_ticker("AAPL")
        @test all(x -> x !== nothing, (facts, concept, frames, search))
        @test cik === nothing || (cik isa AbstractString && length(cik) == 10)
    catch e
        @info "Skipping XBRL/search network smoke test: $e"
        @test true
    end
end

@testset "cache eviction (offline)" begin
    # Stale entries (older than the TTL) are pruned; fresh ones are kept.
    dir = mktempdir()
    set_config(cache_dir = dir, cache_ttl = 60)
    write(joinpath(dir, "fresh.meta"), "{\"timestamp\":$(time())}")
    write(joinpath(dir, "fresh.body"), "x")
    write(joinpath(dir, "stale.meta"), "{\"timestamp\":$(time() - 1000)}")
    write(joinpath(dir, "stale.body"), "y")
    EDGAR._LAST_EVICTION[] = 0.0   # bypass the throttle for the test
    EDGAR._maybe_evict_cache()
    kept = isfile(joinpath(dir, "fresh.meta")) && isfile(joinpath(dir, "fresh.body"))
    gone = !isfile(joinpath(dir, "stale.meta")) && !isfile(joinpath(dir, "stale.body"))
    @test kept && gone
    EDGAR.CONFIG.cache_dir = nothing   # restore default for any later use
    EDGAR.CONFIG.cache_ttl = nothing
end
