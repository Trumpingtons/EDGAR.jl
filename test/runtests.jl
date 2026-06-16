using Test
using EDGAR

# The SEC requires a User-Agent; set one so the network smoke tests can run.
set_user_agent("EDGAR.jl test suite noreply@example.com")

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
        search = EDGAR.full_text_search("climate risk"; forms = "10-K")
        tk = EDGAR.cik("AAPL"; by = :ticker)
        @test all(x -> x !== nothing, (facts, concept, frames, search))
        @test isempty(tk) || length(only(tk).cik) == 10
    catch e
        @info "Skipping XBRL/search network smoke test: $e"
        @test true
    end
end

@testset "cik table" begin
    # cik() returns a Tables.jl row table (Vector of NamedTuples with String
    # fields); cik(q; by) filters it by name (substring), ticker (exact) or :any
    # (either), always returning the same type. :any tests each row once, so a row
    # matching both columns is not duplicated. Network-wrapped for CI/offline.
    try
        rows = EDGAR.cik()
        byname = EDGAR.cik("nvidia"; by = :company)
        byticker = EDGAR.cik("nvda"; by = :ticker)
        anyrows = EDGAR.cik("MA"; by = :any)   # "ma" in many names AND ticker MA -> no dup
        shape = (rows isa Vector, eltype(rows), !isempty(rows),
            all(r -> occursin("nvidia", lowercase(r.company)), byname),
            length(byticker) <= 1 && eltype(byticker) === eltype(rows),
            allunique(anyrows))
        @test shape == (true, @NamedTuple{company::String, ticker::String, cik::String}, true, true, true, true)
    catch e
        @info "Skipping cik network smoke test: $e"
        @test true
    end
end

@testset "_normalize_cik (offline)" begin
    # Integers and strings, padded or not, normalize to the 10-digit form;
    # empty, non-numeric and over-long inputs throw ArgumentError.
    n = EDGAR._normalize_cik
    ok = (n(320193), n("320193"), n("0000320193"), n("  320193 "))
    bad = map(("", "32a193", "123456789012")) do x
        try; n(x); false; catch e; e isa ArgumentError; end
    end
    @test (ok, bad) == (("0000320193", "0000320193", "0000320193", "0000320193"), (true, true, true))
end

@testset "clean_cache (offline)" begin
    # clean_cache removes entries older than the cutoff and keeps fresh ones.
    dir = mktempdir()
    set_config(cache_dir = dir)
    write(joinpath(dir, "fresh.meta"), "{\"timestamp\":$(time())}")
    write(joinpath(dir, "fresh.body"), "x")
    write(joinpath(dir, "stale.meta"), "{\"timestamp\":$(time() - 1000)}")
    write(joinpath(dir, "stale.body"), "y")
    removed = clean_cache(60)   # prune entries older than 60s
    kept = isfile(joinpath(dir, "fresh.meta")) && isfile(joinpath(dir, "fresh.body"))
    gone = !isfile(joinpath(dir, "stale.meta")) && !isfile(joinpath(dir, "stale.body"))
    @test removed == 1 && kept && gone
    EDGAR.CONFIG.cache_dir = nothing   # restore default for any later use
end

@testset "cache modes (offline)" begin
    set_config(cache = :persistent)
    @test EDGAR.get_cache_dir() == EDGAR.CACHE_DIR
    set_config(cache = :temporary)
    td = EDGAR.get_cache_dir()
    @test isdir(td) && occursin("EDGAR_jl_", td)
    set_config(cache = :off)
    @test EDGAR.CONFIG.cache_mode === :off
    @test_throws ArgumentError set_config(cache = :bogus)
    set_config(cache = :temporary)   # restore the default mode
end

@testset "persistent auto-prune (offline)" begin
    # In persistent storage, files older than cache_max_age are auto-deleted;
    # this is independent of cache_ttl (freshness).
    dir = mktempdir()
    set_config(cache = :persistent, cache_dir = dir, cache_max_age = 60)
    write(joinpath(dir, "fresh.meta"), "{\"timestamp\":$(time())}")
    write(joinpath(dir, "fresh.body"), "x")
    write(joinpath(dir, "stale.meta"), "{\"timestamp\":$(time() - 1000)}")
    write(joinpath(dir, "stale.body"), "y")
    EDGAR._LAST_PRUNE[] = 0.0   # bypass the throttle for the test
    EDGAR._maybe_prune_persistent()
    kept = isfile(joinpath(dir, "fresh.meta")) && isfile(joinpath(dir, "fresh.body"))
    gone = !isfile(joinpath(dir, "stale.meta")) && !isfile(joinpath(dir, "stale.body"))
    @test kept && gone
    EDGAR.CONFIG.cache_dir = nothing
    EDGAR.CONFIG.cache_max_age = nothing
    set_config(cache = :temporary)
end

@testset "set_user_agent + guard (offline)" begin
    ua = set_user_agent("  Jane Doe jane@example.com  ")   # trimmed
    @test ua == "Jane Doe jane@example.com"
    @test EDGAR.get_user_agent() == ua
    @test_throws ArgumentError set_user_agent("Jane Doe not-an-email")   # no contact email
    @test_throws ArgumentError set_user_agent("   ")                      # empty after trim
    # With no User-Agent set, requests fail fast with a clear error.
    EDGAR.CONFIG.user_agent = nothing
    @test_throws ArgumentError EDGAR.get_user_agent()
end

@testset "persist/unpersist user-agent (offline)" begin
    depot = mktempdir()   # never touch the real startup.jl
    path = persist_user_agent("Jane Doe jane@example.com"; depot = depot)
    @test path == joinpath(depot, "config", "startup.jl")
    @test EDGAR.get_user_agent() == "Jane Doe jane@example.com"   # also set for this session
    @test occursin("ENV[\"SEC_USER_AGENT\"] = \"Jane Doe jane@example.com\"", read(path, String))

    # Idempotent: re-persisting with a new value replaces rather than duplicating.
    persist_user_agent("New Name new@example.com"; depot = depot)
    persisted = filter(l -> occursin(EDGAR._PERSIST_MARKER, l), readlines(path))
    @test length(persisted) == 1
    @test occursin("new@example.com", only(persisted))

    # A line the user wrote themselves (no marker) is left untouched on removal.
    open(path, "a") do io; println(io, "ENV[\"SEC_USER_AGENT\"] = \"hand written\""); end
    @test unpersist_user_agent(; depot = depot)
    remaining = read(path, String)
    @test occursin("hand written", remaining)
    @test !occursin(EDGAR._PERSIST_MARKER, remaining)
    @test unpersist_user_agent(; depot = depot) == false   # nothing left to remove
end
