using Test
using EDGAR
using Dates
import DuckDB                 # loads the EDGARDuckDBExt package extension (qualified, no name clash)
using DuckDB: DBInterface

# The SEC requires a User-Agent; set one so the network smoke tests can run.
set_user_agent("EDGAR.jl test suite noreply@example.com")

@testset "EDGAR basic" begin
    # Smoke test: list a filer's filings (network request). Wrapped so CI/offline doesn't fail.
    try
        res = EDGAR.filings_by_cik("0000320193"; forms = "8-K")
        @test res isa Vector && (isempty(res) || haskey(res[1], :form))
        # fetch the most recent filing into memory and save it
        f = EDGAR.fetch_filing("0000320193", res[1].accession)
        ok = f isa EDGAR.Filing && f.kind in (:ixbrl, :xbrl, :html) && !isempty(f.content)
        saved = mktempdir() do d
            isfile(EDGAR.save_filing(f; destdir = d))
        end
        @test ok && saved
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
        byfiler = EDGAR.filings_by_cik(320193; forms = "8-K")
        prof = EDGAR.profile(320193)
        tk = EDGAR.cik("AAPL"; by = :ticker)
        @test all(x -> x !== nothing, (facts, concept, frames))
        # both searches return plain row tables; text rows carry score, filer rows isXBRL
        @test search isa Vector && haskey(search[1], :score)
        @test byfiler isa Vector && haskey(byfiler[1], :isXBRL)
        @test prof.entityType in ("operating", "investment") && !isempty(prof.name)
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
        byname = EDGAR.cik("nvidia"; by = :name)
        byticker = EDGAR.cik("nvda"; by = :ticker)
        anyrows = EDGAR.cik("MA")   # default :any; "ma" in many names AND ticker MA -> no dup
        shape = (rows isa Vector, eltype(rows), !isempty(rows),
            all(r -> occursin("nvidia", lowercase(r.entity)), byname),
            length(byticker) <= 1 && eltype(byticker) === eltype(rows),
            allunique(anyrows))
        @test shape == (true, @NamedTuple{entity::String, ticker::String, cik::String}, true, true, true, true)
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

@testset "extract_section (offline fixtures)" begin
    # The HTML fixtures under test/data exercise extract_section without the
    # network: synthetic TOC/heading variants plus a trimmed real Apple 10-K.
    for t in ["test_extract_section", "test_toc_anchor_extract", "test_plain_toc_extract",
              "test_numbered_toc_extract", "test_multi_page_fragment", "test_real_10k_extract"]
        include(joinpath(@__DIR__, "$t.jl"))
    end
end

@testset "picker: select_section / select_sections (offline)" begin
    # Drive the picker server headlessly: a fake `opener` POSTs selections to the
    # local endpoint instead of launching a browser. No network involved.
    f = EDGAR.Filing("0000104169", "0000104169-26-000102", "wmt.htm",
        "https://www.sec.gov/Archives/edgar/data/104169/000010416926000102/wmt.htm",
        :ixbrl, "<html><head></head><body><table><tr><td>x</td></tr></table></body></html>")
    payload(sel) = EDGAR.JSON3.write((version = 1,
        provenance = (cik = f.cik, accession = f.accession, url = f.url),
        selector = sel, kind = "table", text = "Net sales 175684",
        html = "<table><tr><td>x</td></tr></table>"))
    post(url, path, body) = EDGAR.HTTP.post(url * path, ["Content-Type" => "application/json"], body)

    # single mode: one pick comes back as a Selection
    single_opener(url) = @async (sleep(0.2); post(url, "select", payload("a")))
    a = select_section(f; timeout = 20, opener = single_opener)
    @test (typeof(a), a.kind, a.selector) == (EDGAR.Selection, :table, "a")

    # multi mode: two distinct picks + a duplicate + done -> a de-duplicated vector
    multi_opener(url) = @async begin
        sleep(0.2)
        post(url, "select", payload("a")); post(url, "select", payload("a"))
        post(url, "select", payload("b")); post(url, "done", "{}")
    end
    b = select_sections(f; timeout = 20, opener = multi_opener)
    @test (b isa Vector{EDGAR.Selection}, [s.selector for s in b]) == (true, ["a", "b"])

    # the Selection preview page is self-contained and carries provenance
    @test occursin("EDGAR selection", EDGAR._selection_page(a))

    # 2.1 transport: a table-bearing payload parses into sel.table (header + rows)
    tpayload = EDGAR.JSON3.write((version = 1,
        provenance = (cik = "1", accession = "x", url = "u"), selector = "t", kind = "table",
        text = "x", html = "<table></table>",
        table = (header = ["", "2026", "2025"],
                 rows = [["Net sales", "175,684", "163,981"], ["Total revenues", "177,751", "165,609"]])))
    st = EDGAR.parse_selection(tpayload)
    @test (st.table.header, st.table.rows) ==
          (["", "2026", "2025"], [["Net sales", "175,684", "163,981"], ["Total revenues", "177,751", "165,609"]])
end

@testset "picker statement-tagging: _classify_selection (offline)" begin
    fct(concept) = EDGAR.Fact(; concept, value = 1.0, period_end = Date("2026-04-30"),
        is_instant = false, cik = "c", accession = "a")
    sel = EDGAR.Selection(; cik = "c", accession = "a", kind = :table,
        facts = [fct("us-gaap:Revenues"), fct("us-gaap:LossContingency")])   # second is note-only
    stmts = Dict("us-gaap:Revenues" => "IncomeStatement")
    out = EDGAR._classify_selection(sel, stmts)
    @test [f.statement for f in out.facts] == ["IncomeStatement", ""]        # unmapped keeps ""
    # nothing to do -> returned unchanged (same object)
    @test EDGAR._classify_selection(sel, Dict{String,String}()) === sel
end

@testset "presentation: markdown(::Selection) (offline)" begin
    # A faithful grid as the browser sends it (Step 2.1): a blank spacer row, and the
    # `$` marker in its own column only on some rows (Net sales), which shifts the value
    # row to row. markdown() drops the blank-ish cells per row and left-packs, realigning
    # the columns; the first surviving row becomes the header.
    rows = [["", "", "", "", ""],                                  # blank spacer row
            ["(Amounts in millions)", "", "2026", "", "2025"],      # period header
            ["Net sales", "\$", "175,684", "\$", "163,981"],        # $ in its own column
            ["Membership and other income", "2,067", "", "1,628", ""],  # no $: value shifts left
            ["Interest income", "(79)", "", "(93)", ""]]            # parenthesised negatives
    sel = EDGAR.Selection(; cik = "0000104169", accession = "0000104169-26-000102",
        url = "https://www.sec.gov/x/wmt-20260430.htm", selector = "div > table", kind = :table,
        table = (header = String[], rows = rows))
    @test markdown(sel; provenance = false) == """
        | (Amounts in millions) | 2026 | 2025 |
        | --- | --- | --- |
        | Net sales | 175,684 | 163,981 |
        | Membership and other income | 2,067 | 1,628 |
        | Interest income | (79) | (93) |"""
    @test startswith(markdown(sel),
        "> Source: SEC EDGAR — CIK 0000104169, accession 0000104169-26-000102 (table)")

    # prose collapses blank-line runs to single paragraph breaks
    p = EDGAR.Selection(; cik = "1", accession = "a", url = "u", selector = "s", kind = :prose,
        text = "Basis of Presentation\n\n\nThe statements were prepared...")
    @test markdown(p; provenance = false) == "Basis of Presentation\n\nThe statements were prepared..."
end

@testset "facts: 3.2 transport (offline)" begin
    # The browser resolves each <ix:nonFraction> against the context/unit maps and sends
    # the fact transport shape; parse_selection normalises value × 10^scale × sign,
    # resolves the period (duration vs instant) and dimensions, and keeps the raw refs.
    payload = EDGAR.JSON3.write((version = 1,
        provenance = (cik = "0000104169", accession = "0000104169-26-000102", url = "u"),
        selector = "t", kind = "table", text = "x", html = "<table></table>", table = nothing,
        facts = [
          (concept = "us-gaap:Revenues", label = "Total revenues", value = "177,751",
           scale = 6, sign = "", decimals = -6, unit = "USD", unitRef = "usd", contextRef = "c-1",
           periodStart = "2026-02-01", periodEnd = "2026-04-30", isInstant = false, dimensions = Dict()),
          (concept = "us-gaap:MinorityInterest", label = "NCI", value = "160",
           scale = 6, sign = "-", decimals = -6, unit = "USD", unitRef = "usd", contextRef = "c-2",
           periodStart = nothing, periodEnd = "2026-04-30", isInstant = true,
           dimensions = Dict("us-gaap:SegAxis" => "wmt:USMember"))]))
    s = EDGAR.parse_selection(payload)
    f1, f2 = s.facts[1], s.facts[2]
    @test (length(s.facts), f1.value, f1.is_instant, f1.period_start, f1.unit, f1.label,
           f2.value, f2.is_instant, f2.dimensions, f2.decimals, f2.context_ref) ==
          (2, 177751 * 10.0^6, false, Date("2026-02-01"), "USD", "Total revenues",
           -160 * 10.0^6, true, Dict("us-gaap:SegAxis" => "wmt:USMember"), -6, "c-2")
end

@testset "facts: 3.3 row-table + 3.4 empty (offline)" begin
    mk(ctx) = EDGAR.Fact(; concept = "us-gaap:Revenues", value = 1.77751e11, unit = "USD",
        period_start = Date("2026-02-01"), period_end = Date("2026-04-30"), is_instant = false,
        cik = "0000104169", accession = "0000104169-26-000102", context_ref = ctx, unit_ref = "usd",
        dimensions = Dict("ax" => "mb"), decimals = -6, label = "Total revenues",
        source_selector = "div > table")
    # c-1 picked twice (same natural key) + c-2: de-duplicated to two rows
    sel = EDGAR.Selection(; cik = "0000104169", accession = "0000104169-26-000102", kind = :table,
        facts = [mk("c-1"), mk("c-1"), mk("c-2")])
    rows = facts(sel)
    @test (length(rows), rows[1] isa EDGAR.FactRow, rows[1].concept, rows[1].value,
           rows[1].dimensions, rows[1].period_start, [r.context_ref for r in rows]) ==
          (2, true, "us-gaap:Revenues", 1.77751e11, "{\"ax\":\"mb\"}", Date("2026-02-01"), ["c-1", "c-2"])

    # 3.4 graceful empty: a prose-only selection yields an empty, typed table — no error
    @test facts(EDGAR.Selection(; kind = :prose, text = "Basis of Presentation")) == EDGAR.FactRow[]
end

@testset "facts_json round-trip (offline)" begin
    mk(c, v, pe, ctx; inst = false, dims = Dict{String,String}()) = EDGAR.Fact(; concept = c,
        label = "L:" * c, value = v, unit = "USD", period_start = inst ? nothing : pe - Dates.Month(3),
        period_end = pe, is_instant = inst, cik = "0000104169", accession = "acc",
        context_ref = ctx, unit_ref = "usd", dimensions = dims, decimals = -6,
        source_selector = "div>table")
    sel = EDGAR.Selection(; cik = "0000104169", accession = "acc", url = "u", selector = "div>table",
        kind = :table, facts = [mk("us-gaap:Revenues", 177751e6, Date("2026-04-30"), "c1"),
            mk("us-gaap:Assets", 260823e6, Date("2026-04-30"), "c2"; inst = true,
               dims = Dict("seg" => "US"))])
    js = facts_json(sel)
    p = tempname() * ".facts.json"
    try
        write(p, js)
        @test (facts(read_facts_json(js)) == facts(sel),        # string round-trip
               facts(read_facts_json(p)) == facts(sel),         # file round-trip
               occursin("\"concept\": \"us-gaap:Assets\"", js), # pretty, semantic
               isempty(facts(read_facts_json(facts_json(EDGAR.Selection(; kind = :prose)))))) ==
              (true, true, true, true)                          # prose -> empty facts
    finally
        isfile(p) && rm(p)
    end
end

@testset "standardize (pluggable, offline)" begin
    @test standardize("us-gaap:SalesRevenueNet") === nothing      # no default mapping shipped
    try
        set_standardizer(Dict("us-gaap:SalesRevenueNet" => "Revenue",
                              "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax" => "Revenue"))
        @test (standardize("us-gaap:SalesRevenueNet"), standardize("us-gaap:Assets")) == ("Revenue", nothing)
        f = EDGAR.Fact(; concept = "us-gaap:SalesRevenueNet", value = 1.0e9, period_end = Date("2026-04-30"),
            is_instant = false, unit = "USD", cik = "c", accession = "a")
        @test EDGAR.fact_row(f).standard_concept == "Revenue"     # flows into the row table
        set_standardizer(c -> startswith(c, "us-gaap:") ? "USGAAP" : nothing)   # a function works too
        @test standardize("us-gaap:Assets") == "USGAAP"
        @test_throws ArgumentError set_standardizer(:bogus_provider)   # unknown named provider
    finally
        set_standardizer(:none)
    end
    @test standardize("us-gaap:Assets") === nothing               # reset
end

@testset "standardizer :edgartools (offline, vendored MIT mapping)" begin
    try
        set_standardizer(:edgartools)
        # the "revenue hierarchy fix": Net sales (Contract Revenue) is NOT Total revenues (Revenue)
        @test (standardize("us-gaap:Revenues"),
               standardize("us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax"),
               standardize("us-gaap:SalesRevenueNet"),
               standardize("xx:Unmapped")) == ("Revenue", "Contract Revenue", "Revenue", nothing)
        @test length(edgartools_mapping()) > 100
    finally
        set_standardizer(:none)
    end
end

@testset "edge cases (W8, offline)" begin
    # (a) a non-XBRL filing -> no facts, no error (graceful empty)
    nox = EDGAR.Filing("c", "a", "x.htm", "u", :html,
        "<html><body><p>Plain HTML, no XBRL.</p><table><tr><td>x</td></tr></table></body></html>")
    @test facts(nox) == EDGAR.FactRow[]
    @test isempty(EDGAR._concept_statements(""))               # absent/empty linkbase -> empty map

    # (b) a mixed selection (table + surrounding prose) still renders its table as Markdown
    mixed = EDGAR.Selection(; cik = "c", accession = "a", kind = :mixed,
        table = (header = String[], rows = [["", "2026"], ["Net sales", "100"]]),
        text = "(Amounts in millions)\nNet sales 100")
    @test occursin("Net sales", markdown(mixed; provenance = false))

    # (c) a dimensional fact is kept distinct from its consolidated sibling (dimensions in the key)
    d(dims) = EDGAR.Fact(; concept = "us-gaap:Revenues", value = 100.0, period_end = Date("2026-04-30"),
        is_instant = false, unit = "USD", cik = "c", accession = "a",
        context_ref = isempty(dims) ? "c0" : "c1", unit_ref = "usd", dimensions = dims)
    rows = facts(EDGAR.Selection(; cik = "c", accession = "a", kind = :table,
        facts = [d(Dict{String,String}()), d(Dict("seg" => "US"))]))
    @test (length(rows), Set(r.dimensions for r in rows)) == (2, Set(["{}", "{\"seg\":\"US\"}"]))

    # (d) HTML-entity nil values must not leak entity digits, and `ixt:fixed-zero` dashes are 0:
    #   A — bare `&#8212;` (em dash) -> dropped (not 8212)
    #   B — `&#160;42&#160;` (nbsp around a number) -> 42 (not 16042160)
    #   C — `&#8212;` with format=ixt:fixed-zero -> the value 0 (not dropped, not 8212)
    ent = EDGAR.Filing("c", "a", "x.htm", "u", :ixbrl, """
        <html><body><ix:header><ix:resources>
        <xbrli:context id="d1"><xbrli:entity><xbrli:identifier scheme="x">c</xbrli:identifier></xbrli:entity><xbrli:period><xbrli:startDate>2026-02-01</xbrli:startDate><xbrli:endDate>2026-04-30</xbrli:endDate></xbrli:period></xbrli:context>
        <xbrli:unit id="usd"><xbrli:measure>iso4217:USD</xbrli:measure></xbrli:unit>
        </ix:resources></ix:header>
        <ix:nonFraction name="us-gaap:A" contextRef="d1" unitRef="usd" scale="0">&#8212;</ix:nonFraction>
        <ix:nonFraction name="us-gaap:B" contextRef="d1" unitRef="usd" scale="0">&#160;42&#160;</ix:nonFraction>
        <ix:nonFraction name="us-gaap:C" contextRef="d1" unitRef="usd" format="ixt:fixed-zero" scale="6">&#8212;</ix:nonFraction>
        </body></html>""")
    byc = Dict(r.concept => r.value for r in facts(ent))
    @test (length(byc), get(byc, "us-gaap:B", -1), get(byc, "us-gaap:C", -1), haskey(byc, "us-gaap:A")) ==
          (2, 42.0, 0.0, false)
end

@testset "facts(::Filing) native extraction (W2, offline)" begin
    ix = """
    <html><body><ix:header><ix:resources>
    <xbrli:context id="d1"><xbrli:entity><xbrli:identifier scheme="http://www.sec.gov/CIK">0000104169</xbrli:identifier></xbrli:entity><xbrli:period><xbrli:startDate>2026-02-01</xbrli:startDate><xbrli:endDate>2026-04-30</xbrli:endDate></xbrli:period></xbrli:context>
    <xbrli:context id="i1"><xbrli:entity><xbrli:identifier scheme="http://www.sec.gov/CIK">0000104169</xbrli:identifier></xbrli:entity><xbrli:period><xbrli:instant>2026-04-30</xbrli:instant></xbrli:period></xbrli:context>
    <xbrli:unit id="usd"><xbrli:measure>iso4217:USD</xbrli:measure></xbrli:unit>
    </ix:resources></ix:header><table>
    <ix:nonFraction name="us-gaap:Revenues" contextRef="d1" unitRef="usd" scale="6" decimals="-6" id="f1">177,751</ix:nonFraction>
    <ix:nonFraction name="us-gaap:Assets" contextRef="i1" unitRef="usd" scale="6" decimals="-6" id="f2">289,607</ix:nonFraction>
    <ix:nonFraction name="us-gaap:NonoperatingIncomeExpense" contextRef="d1" unitRef="usd" scale="6" id="f3">(275)</ix:nonFraction>
    </table></body></html>"""
    fix = EDGAR.Filing("0000104169", "acc", "wmt.htm", "https://x/wmt.htm", :ixbrl, ix)
    rix = facts(fix)
    byc(c) = first(r for r in rix if r.concept == c)
    @test (length(rix), byc("us-gaap:Revenues").value, byc("us-gaap:Revenues").is_instant,
           byc("us-gaap:Assets").value, byc("us-gaap:Assets").is_instant,
           byc("us-gaap:NonoperatingIncomeExpense").value) ==
          (3, 177751e6, false, 289607e6, true, -275e6)    # parentheses -> negative

    xml = """
    <xbrl><xbrli:context id="d1"><xbrli:entity><xbrli:identifier scheme="x">0000104169</xbrli:identifier></xbrli:entity><xbrli:period><xbrli:startDate>2026-02-01</xbrli:startDate><xbrli:endDate>2026-04-30</xbrli:endDate></xbrli:period></xbrli:context>
    <xbrli:unit id="usd"><xbrli:measure>iso4217:USD</xbrli:measure></xbrli:unit>
    <us-gaap:Revenues contextRef="d1" unitRef="usd" decimals="-6">177751000000</us-gaap:Revenues>
    <dei:EntityRegistrantName contextRef="d1">Walmart Inc.</dei:EntityRegistrantName>
    </xbrl>"""
    fxml = EDGAR.Filing("0000104169", "acc", "wmt.xml", "https://x/wmt.xml", :xbrl, xml)
    rxml = facts(fxml)   # the non-numeric dei element (no unitRef) is skipped
    @test (length(rxml), rxml[1].concept, rxml[1].value, rxml[1].period_end) ==
          (1, "us-gaap:Revenues", 177751000000.0, Date("2026-04-30"))

    # A classic instance that declares the XBRL namespace as the default (unprefixed <context>/<unit>)
    # and carries the sign in the value text (-19001…) — both must parse (prefix-optional regexes +
    # leading-minus handling); without either, contexts/units parse as 0 (so 0 facts) or the negative
    # cash-flow value flips positive.
    bare = """
    <xbrl xmlns="http://www.xbrl.org/2003/instance">
    <context id="d1"><entity><identifier scheme="x">x</identifier></entity><period><startDate>2025-01-01</startDate><endDate>2025-12-31</endDate></period></context>
    <unit id="usd"><measure>iso4217:USD</measure></unit>
    <us-gaap:NetCashProvidedByUsedInOperatingActivities contextRef="d1" unitRef="usd" decimals="-6">-19001000000</us-gaap:NetCashProvidedByUsedInOperatingActivities>
    </xbrl>"""
    rbare = facts(EDGAR.Filing("x", "acc", "x.xml", "https://x/x.xml", :xbrl, bare))
    @test (length(rbare), rbare[1].concept, rbare[1].value) ==
          (1, "us-gaap:NetCashProvidedByUsedInOperatingActivities", -19001000000.0)
end

@testset "statement classification from presentation linkbase (W5, offline)" begin
    @test (EDGAR._classify_role("http://x/role/CondensedConsolidatedStatementsofIncome"),
           EDGAR._classify_role("http://x/role/CondensedConsolidatedBalanceSheets"),
           EDGAR._classify_role("http://x/role/CondensedConsolidatedStatementsofCashFlows"),
           EDGAR._classify_role("http://x/role/StatementsofShareholdersEquity"),
           EDGAR._classify_role("http://x/role/StatementsofComprehensiveIncome"),
           EDGAR._classify_role("http://x/role/BalanceSheetsParenthetical"),
           EDGAR._classify_role("http://x/role/NetIncomePerCommonShareDetails"),
           EDGAR._classify_role("http://x/role/Contingencies")) ==
          ("IncomeStatement", "BalanceSheet", "CashFlow", "Equity", "ComprehensiveIncome", "", "", "")

    # bank / broker-dealer balance sheet naming (never says "balance sheet")
    @test (EDGAR._classify_role("ConsolidatedStatementOfCondition"),
           EDGAR._classify_role("StatementOfFinancialCondition"),
           EDGAR._classify_role("CONSOLIDATED STATEMENT OF CONDITION (Parenthetical)")) ==
          ("BalanceSheet", "BalanceSheet", "")

    # adapted-from-edgartools scorer: IFRS role names + concept-based rescue
    @test (EDGAR._classify_role("StatementOfProfitOrLoss"),                       # IFRS income role
           EDGAR._classify_role("StatementOfChangesInEquity"),                    # IFRS equity role
           EDGAR._classify_role("r4", ["ifrs-full:StatementOfProfitOrLossAbstract", "ifrs-full:ProfitLoss"]),  # opaque role rescued by IFRS abstract root
           EDGAR._classify_role("r7", ["ifrs-full:Assets", "ifrs-full:Liabilities", "ifrs-full:Equity"]),     # rescued by 3 IFRS anchors
           EDGAR._classify_role("r9", ["us-gaap:SomethingRandom"])) ==            # nothing recognised
          ("IncomeStatement", "Equity", "IncomeStatement", "BalanceSheet", "")

    # Pure-comprehensive-income guard (#506/#584): "Comprehensive Income Statements" embeds the
    # substring "incomestatement" but is NOT the income statement; a combined operations + CI role is.
    @test (EDGAR._classify_role("Role_StatementCOMPREHENSIVEINCOMESTATEMENTS"),       # MSFT R3: pure CI
           EDGAR._classify_role("StatementsOfOperationsAndComprehensiveIncome"),      # combined: still income
           EDGAR._classify_role("Role_StatementINCOMESTATEMENTS")) ==                 # plain income
          ("ComprehensiveIncome", "IncomeStatement", "IncomeStatement")

    # Expanded vocabulary (edgartools-parity audit): fund/BDC face statements + name-only rescues.
    @test (EDGAR._classify_role("ConsolidatedStatementsOfAssetsAndLiabilities"),            # BDC balance sheet (name only)
           EDGAR._classify_role("ConsolidatedScheduleOfInvestments"),                        # fund schedule of investments
           EDGAR._classify_role("r", ["us-gaap:InvestmentOwnedAtFairValue",                  # ...rescued by 3 holdings concepts
                                       "us-gaap:InvestmentOwnedAtCost", "us-gaap:InvestmentOwnedBalanceShares"]),
           EDGAR._classify_role("FinancialHighlights"),                                       # investment-company highlights
           EDGAR._classify_role("ScheduleOfInvestmentsDetails")) ==                           # ...its detail is still rejected
          ("BalanceSheet", "ScheduleOfInvestments", "ScheduleOfInvestments", "FinancialHighlights", "")

    pre = """
    <link:linkbase>
    <link:presentationLink xlink:role="http://x/role/StatementsofIncome">
      <link:loc xlink:href="x.xsd#us-gaap_Revenues"/>
      <link:loc xlink:href="x.xsd#us-gaap_NetIncomeLoss"/></link:presentationLink>
    <link:presentationLink xlink:role="http://x/role/BalanceSheets">
      <link:loc xlink:href="x.xsd#us-gaap_Assets"/></link:presentationLink>
    <link:presentationLink xlink:role="http://x/role/StatementsofShareholdersEquity">
      <link:loc xlink:href="x.xsd#us-gaap_NetIncomeLoss"/></link:presentationLink>
    <link:presentationLink xlink:role="http://x/role/ContingenciesDetails">
      <link:loc xlink:href="x.xsd#us-gaap_LossContingency"/></link:presentationLink>
    </link:linkbase>"""
    cs = EDGAR._concept_statements(pre)   # concept -> every section it appears in (priority-sorted)
    @test (cs["us-gaap:Revenues"], cs["us-gaap:Assets"], cs["us-gaap:NetIncomeLoss"],
           get(cs, "us-gaap:LossContingency", ["(none)"])) ==
          (["IncomeStatement"], ["BalanceSheet"],
           ["IncomeStatement", "Equity"],   # multi-homed: in both the income statement and the equity roll-forward
           ["(none)"])                       # only in a Details role -> unclassified, absent

    # the statements map flows into the extracted facts' `statement` field
    ix = """<html><body><ix:header><ix:resources>
    <xbrli:context id="d1"><xbrli:entity><xbrli:identifier scheme="x">c</xbrli:identifier></xbrli:entity><xbrli:period><xbrli:startDate>2026-02-01</xbrli:startDate><xbrli:endDate>2026-04-30</xbrli:endDate></xbrli:period></xbrli:context>
    <xbrli:unit id="usd"><xbrli:measure>iso4217:USD</xbrli:measure></xbrli:unit>
    </ix:resources></ix:header>
    <ix:nonFraction name="us-gaap:Revenues" contextRef="d1" unitRef="usd" scale="6" id="f1">100</ix:nonFraction>
    </body></html>"""
    f = EDGAR.Filing("c", "a", "x.htm", "u", :ixbrl, ix)
    fwith = EDGAR._extract_facts(f; statements = Dict("us-gaap:Revenues" => ["IncomeStatement"]))
    @test (fwith[1].statement, fwith[1].statements) == ("IncomeStatement", ["IncomeStatement"])
end

@testset "numwordsen spelled-out numbers (offline)" begin
    # the word -> digits parser
    @test (EDGAR._numwordsen("No"), EDGAR._numwordsen("Forty-two"),
           EDGAR._numwordsen("one hundred"), EDGAR._numwordsen("two hundred thousand"),
           EDGAR._numwordsen("one million two hundred thousand"),
           EDGAR._numwordsen("not a number")) ==
          ("0", "42", "100", "200000", "1200000", nothing)

    # a fact with format=ixt-sec:numwordsen is read from its words (and a non-number is dropped)
    ix = """<html><body><ix:header><ix:resources>
    <xbrli:context id="i1"><xbrli:entity><xbrli:identifier scheme="x">c</xbrli:identifier></xbrli:entity><xbrli:period><xbrli:instant>2026-04-30</xbrli:instant></xbrli:period></xbrli:context>
    <xbrli:unit id="shares"><xbrli:measure>xbrli:shares</xbrli:measure></xbrli:unit>
    </ix:resources></ix:header>
    <ix:nonFraction name="us-gaap:W" contextRef="i1" unitRef="shares" format="ixt-sec:numwordsen" scale="0">Forty-two</ix:nonFraction>
    <ix:nonFraction name="us-gaap:Z" contextRef="i1" unitRef="shares" format="ixt-sec:numwordsen" scale="0">No</ix:nonFraction>
    <ix:nonFraction name="us-gaap:Bad" contextRef="i1" unitRef="shares" format="ixt-sec:numwordsen" scale="0">pending</ix:nonFraction>
    </body></html>"""
    byc = Dict(r.concept => r.value for r in facts(EDGAR.Filing("c", "a", "x.htm", "u", :ixbrl, ix)))
    @test (length(byc), get(byc, "us-gaap:W", -1), get(byc, "us-gaap:Z", -1), haskey(byc, "us-gaap:Bad")) ==
          (2, 42.0, 0.0, false)
end

@testset "label_map native labels from label linkbase (offline)" begin
    lab = """
    <link:linkbase>
    <link:loc xlink:href="x.xsd#us-gaap_Revenues" xlink:label="loc_Rev"/>
    <link:loc xlink:href="x.xsd#us-gaap_Assets" xlink:label="loc_Ast"/>
    <link:labelArc xlink:from="loc_Rev" xlink:to="lab_Rev"/>
    <link:labelArc xlink:from="loc_Ast" xlink:to="lab_Ast"/>
    <link:label xlink:label="lab_Rev" xlink:role="http://www.xbrl.org/2003/role/label">Net sales</link:label>
    <link:label xlink:label="lab_Rev" xlink:role="http://www.xbrl.org/2003/role/documentation">A long documentation string.</link:label>
    <link:label xlink:label="lab_Ast" xlink:role="http://www.xbrl.org/2003/role/terseLabel">Total assets</link:label>
    </link:linkbase>"""
    lm = EDGAR._concept_labels(lab)
    @test (lm["us-gaap:Revenues"], lm["us-gaap:Assets"], length(lm)) == ("Net sales", "Total assets", 2)
    @test isempty(EDGAR._concept_labels(""))           # absent/empty linkbase -> empty map

    # the labels map flows into the extracted facts' `label` field
    ix = """<html><body><ix:header><ix:resources>
    <xbrli:context id="d1"><xbrli:entity><xbrli:identifier scheme="x">c</xbrli:identifier></xbrli:entity><xbrli:period><xbrli:startDate>2026-02-01</xbrli:startDate><xbrli:endDate>2026-04-30</xbrli:endDate></xbrli:period></xbrli:context>
    <xbrli:unit id="usd"><xbrli:measure>iso4217:USD</xbrli:measure></xbrli:unit>
    </ix:resources></ix:header>
    <ix:nonFraction name="us-gaap:Revenues" contextRef="d1" unitRef="usd" scale="6" id="f1">100</ix:nonFraction>
    </body></html>"""
    f = EDGAR.Filing("c", "a", "x.htm", "u", :ixbrl, ix)
    fwith = EDGAR._extract_facts(f; labels = Dict("us-gaap:Revenues" => "Net sales"))
    @test fwith[1].label == "Net sales"
end

@testset "FilingSummary fallback classification (offline)" begin
    # defref token -> namespaced concept
    @test (EDGAR._defref_concept("defref_us-gaap_Assets"),
           EDGAR._defref_concept("defref_vktx_PrepaidClinicalTrialCosts")) ==
          ("us-gaap:Assets", "vktx:PrepaidClinicalTrialCosts")

    # concepts pulled from a rendered R-file (deduped)
    rfile = """<a onclick="top.Show.showAR(this,'defref_us-gaap_Assets',window)">Total assets</a>
               <a onclick="x('defref_us-gaap_LiabilitiesAndStockholdersEquity')">L+E</a>
               <span>defref_us-gaap_Assets</span>"""
    @test Set(EDGAR._rfile_concepts(rfile)) ==
          Set(["us-gaap:Assets", "us-gaap:LiabilitiesAndStockholdersEquity"])

    # FilingSummary <Report> parsing: face statements kept; notes/details dropped through the scorer's
    # disqualifying deltas — a fragment term in the role ("…ComprehensiveIncomeStatementsDetail", R54)
    # and, decisively, the authoritative LongName category ("Disclosure", R55: a clean statement-named
    # detail the role text alone would miss) both reject the report rather than polluting the statement.
    fs = """<FilingSummary><MyReports>
      <Report><LongName>1 - Statement - Income Statements</LongName><Role>http://x/role/StatementIncomeStatements</Role><ShortName>Income Statements</ShortName><HtmlFileName>R2.htm</HtmlFileName></Report>
      <Report><Role>http://x/role/DisclosureDerivativesComprehensiveIncomeStatementsDetail</Role><ShortName>Derivatives (Detail)</ShortName><HtmlFileName>R54.htm</HtmlFileName></Report>
      <Report><LongName>2 - Disclosure - Revenue</LongName><Role>http://x/role/StatementOfIncome</Role><ShortName>Revenue</ShortName><HtmlFileName>R55.htm</HtmlFileName></Report>
      <Report><Role>http://x/role/BalanceSheetsParenthetical</Role><ShortName>Balance Sheets (Parenthetical)</ShortName><HtmlFileName>R3.htm</HtmlFileName></Report>
      <Report><ShortName>Statements of Cash Flows</ShortName><HtmlFileName>R6.htm</HtmlFileName></Report>
      <Report><Role>http://x/role/Notes</Role><ShortName>Basis of Presentation</ShortName><HtmlFileName>R7.htm</HtmlFileName></Report>
    </MyReports></FilingSummary>"""
    @test [(r.statement, r.file) for r in EDGAR._filing_summary_reports(fs)] ==
          [("IncomeStatement", "R2.htm"), ("CashFlow", "R6.htm")]
end

@testset "classification corpus (offline, Phase R)" begin
    # Real filings' face-statement roles captured offline (test/data/classification_corpus.json,
    # built by scripts/build_classification_corpus.jl) — the fail->correct baseline for the classifier
    # across taxonomies/sectors (us-gaap mainstream/bank/BDC, ifrs-full 20-F incl. AZN combined P&L+OCI).
    corpus = EDGAR.JSON3.read(read(joinpath(@__DIR__, "data", "classification_corpus.json"), String))
    fails = String[]
    for c in corpus.cases
        got = EDGAR._classify_role(String(c.role), [String(x) for x in c.concepts])
        got == String(c.expected) ||
            push!(fails, "$(c.filer) [$(c.taxonomy)] $(last(split(String(c.role), '/'))): expected $(repr(String(c.expected))) got $(repr(got))")
    end
    isempty(fails) || @info "classification corpus mismatches" fails
    @test (length(fails), length(corpus.cases)) == (0, length(corpus.cases))
end

@testset "statement resolver (R3 query-time fallback, offline)" begin
    # select_statement aliases a requested face statement onto the section that subsumes it, gated on
    # essential content. row = (statement, concept) is all the resolver reads.
    row(stmt, concept) = (statement = stmt, concept = concept)
    combined = [row("ComprehensiveIncome", "us-gaap:Revenues"),        # AZN-style combined P&L + OCI:
                row("ComprehensiveIncome", "us-gaap:NetIncomeLoss"),   #   P&L lives in the CI section
                row("ComprehensiveIncome", "us-gaap:OtherComprehensiveIncomeNetOfTax")]
    pureoci = [row("ComprehensiveIncome", "us-gaap:OtherComprehensiveIncomeNetOfTax")]  # no P&L anchor
    direct  = [row("IncomeStatement", "us-gaap:Revenues"), row("ComprehensiveIncome", "us-gaap:Foo")]
    embedeq = [row("Equity", "us-gaap:StockholdersEquity"),            # old filing: CI embedded in equity
               row("Equity", "us-gaap:ComprehensiveIncomeNetOfTax"),
               row("Equity", "us-gaap:NetIncomeLoss")]                  # ...and P&L in turn embedded there

    @test (EDGAR.select_statement(combined, "IncomeStatement") == combined,           # #608 alias to CI
           EDGAR.select_statement(pureoci, "IncomeStatement"),                         # pure OCI: no alias
           EDGAR.select_statement(direct, "IncomeStatement"),                          # direct wins, no alias
           EDGAR.select_statement(embedeq, "ComprehensiveIncome") == embedeq,          # #706 CI -> Equity
           EDGAR.select_statement(embedeq, "IncomeStatement") == embedeq) ==           # transitive IS -> CI -> Equity
          (true, [], [direct[1]], true, true)
end

@testset "calculations (calc linkbase, W7, offline)" begin
    cal = """
    <link:linkbase>
    <link:calculationLink xlink:role="http://x/role/StatementsofIncome">
      <link:loc xlink:href="x.xsd#us-gaap_OperatingIncomeLoss" xlink:label="oi"/>
      <link:loc xlink:href="x.xsd#us-gaap_Revenues" xlink:label="rev"/>
      <link:loc xlink:href="x.xsd#us-gaap_CostOfRevenue" xlink:label="cost"/>
      <link:calculationArc xlink:from="oi" xlink:to="rev" weight="1.0"/>
      <link:calculationArc xlink:from="oi" xlink:to="cost" weight="-1.0"/></link:calculationLink>
    </link:linkbase>"""
    c = EDGAR._calculations(cal)
    @test (length(c), c[1].statement, c[1].parent, c[1].child, c[1].weight, c[2].child, c[2].weight) ==
          (2, "IncomeStatement", "us-gaap:OperatingIncomeLoss", "us-gaap:Revenues", 1.0,
           "us-gaap:CostOfRevenue", -1.0)
    @test isempty(EDGAR._calculations(""))     # no linkbase -> empty
end

@testset "golden: real captured payload -> all exports (W8, offline)" begin
    # A genuine picker transport payload for Walmart's income statement (test/data/), so the
    # whole pipeline is exercised against real data with no live browser.
    sel = EDGAR.parse_selection(read(joinpath(@__DIR__, "data", "wmt_income_payload.json"), String))
    rows = facts(sel)
    rev = first(r for r in rows if r.concept == "us-gaap:Revenues")
    md = markdown(sel; provenance = false)
    @test (sel.kind, length(rows), rev.value,
           occursin("Net sales", md) && occursin("175,684", md),
           occursin("Total revenues", md) && occursin("177,751", md),
           startswith(strip(sel.html), "<table")) ==
          (:table, 42, 1.77751e11, true, true, true)
    @test facts(read_facts_json(facts_json(sel))) == rows          # Facts JSON round-trips
    path = tempname() * ".duckdb"
    try
        n = to_duckdb(sel, path)
        con = DBInterface.connect(DuckDB.DB, path)
        v = first(DBInterface.execute(con,
            "SELECT value FROM facts WHERE concept = 'us-gaap:Revenues' AND period_end = DATE '2026-04-30'")).value
        DBInterface.close!(con)
        @test (n, v) == (42, 1.77751e11)
    finally
        isfile(path) && rm(path)
    end
end

@testset "save_selection export menu (offline)" begin
    sel = EDGAR.Selection(; cik = "c", accession = "acc1", url = "u",
        selector = "div:nth-of-type(2) > table", kind = :table,
        html = "<table><tr><td>x</td></tr></table>", text = "x",
        facts = [EDGAR.Fact(; concept = "us-gaap:Assets", value = 5000.0, period_end = Date("2026-04-30"),
            is_instant = true, unit = "USD", cik = "c", accession = "acc1", context_ref = "c1", unit_ref = "usd")])
    dir = mktempdir()
    try
        p_ix = save_selection(sel; as = :ixbrl, dir)
        p_md = save_selection(sel; as = :markdown, dir)
        p_fj = save_selection(sel; as = :facts, dir)
        n_db = save_selection(sel; as = :duckdb, dir)        # delegates to to_duckdb (DuckDB loaded)
        @test (endswith(p_ix, ".ixbrl.html"), read(p_ix, String) == sel.html,
               endswith(p_md, ".md"), read(p_md, String) == markdown(sel),
               endswith(p_fj, ".facts.json"), read(p_fj, String) == facts_json(sel),
               n_db, isfile(joinpath(dir, "facts.duckdb"))) ==
              (true, true, true, true, true, true, 1, true)
        @test_throws ArgumentError save_selection(sel; as = :pdf, dir)
    finally
        rm(dir; recursive = true)
    end
end

@testset "facts -> DuckDB sink (offline, extension)" begin
    @test Base.get_extension(EDGAR, :EDGARDuckDBExt) !== nothing   # ext loaded via `using DuckDB`
    mk(pe, ctx) = EDGAR.Fact(; concept = "us-gaap:Revenues", value = pe == Date("2026-04-30") ? 1.77751e11 : 1.65609e11,
        unit = "USD", period_start = pe - Dates.Month(3), period_end = pe, is_instant = false,
        cik = "0000104169", accession = "0000104169-26-000102", context_ref = ctx, unit_ref = "usd",
        dimensions = Dict("ax" => "mb"), decimals = -6, label = "Total revenues")
    q1, q0 = Date("2026-04-30"), Date("2025-04-30")
    # two semantically-distinct facts (different periods) plus a SEMANTIC DUPLICATE of the
    # first (same period/concept/unit/dims, different context_ref) -> the dup dedups away.
    sel = EDGAR.Selection(; cik = "0000104169", accession = "0000104169-26-000102", kind = :table,
        facts = [mk(q1, "c-1"), mk(q0, "c-2"), mk(q1, "c-9")])
    path = tempname() * ".duckdb"
    try
        n1 = to_duckdb(sel, path)                         # 2 (c-9 is a semantic dup of c-1)
        n2 = to_duckdb(sel, path)                         # re-import same filing -> idempotent
        empty = to_duckdb(EDGAR.Selection(; kind = :prose, text = "x"), path)  # no facts -> 0
        con = DBInterface.connect(DuckDB.DB, path)
        total = first(DBInterface.execute(con, "SELECT count(*) AS n FROM facts")).n
        val = first(DBInterface.execute(con, "SELECT value FROM facts WHERE period_end = DATE '2026-04-30'")).value
        src = first(DBInterface.execute(con, "SELECT source FROM facts LIMIT 1")).source
        form = first(DBInterface.execute(con, "SELECT form FROM facts LIMIT 1")).form   # API-only -> NULL
        DBInterface.close!(con)
        @test (n1, n2, empty, total, val, src, ismissing(form)) ==
              (2, 0, 0, 2, 1.77751e11, "picker", true)
        @test_throws ArgumentError to_duckdb(sel, path; table = "bad name; DROP TABLE facts")
    finally
        isfile(path) && rm(path)
    end
end

@testset "statement_view pivot (offline, extension)" begin
    mk(concept, val, pe, ctx; dims = Dict{String,String}()) = EDGAR.Fact(; concept,
        value = val, unit = "USD", period_start = pe - Dates.Month(3), period_end = pe,
        is_instant = false, cik = "c", accession = "acc1", context_ref = ctx, unit_ref = "usd",
        dimensions = dims, label = "L:" * concept)
    q1 = Date("2026-04-30"); q0 = Date("2025-04-30")
    sel = EDGAR.Selection(; cik = "c", accession = "acc1", kind = :table, facts = [
        mk("us-gaap:Revenues", 177751e6, q1, "c1"), mk("us-gaap:Revenues", 165609e6, q0, "c2"),
        mk("us-gaap:CostOfRevenue", 133058e6, q1, "c3"),                       # only the newest period
        mk("us-gaap:Revenues", 120000e6, q1, "c5"; dims = Dict("seg" => "US"))]) # dimensional
    path = tempname() * ".duckdb"
    try
        to_duckdb(sel, path)
        sv = statement_view(path)                  # consolidated: dimensional row hidden
        new, old = Symbol("2026-04-30"), Symbol("2025-04-30")   # period dates are the columns
        @test (length(sv), [r.concept for r in sv], [getproperty(r, new) for r in sv],
               ismissing(sv[1][old]), getproperty(sv[2], old)) ==
              (2, ["us-gaap:CostOfRevenue", "us-gaap:Revenues"], [1.33058e11, 1.77751e11],
               true, 1.65609e11)                   # CostOfRevenue has no 2025 -> missing
        @test length(statement_view(path; consolidated = false)) == 3    # + the dimensional row
        @test isempty(statement_view(path; accession = "nope"))          # filter -> empty, no error
    finally
        isfile(path) && rm(path)
    end
end

@testset "statement_view W6: statement / months / by (offline)" begin
    set_standardizer(Dict("us-gaap:Revenues" => "Revenue"))
    mk(concept, val, ps, pe, stmt; inst = false) = EDGAR.Fact(; concept, value = val, unit = "USD",
        period_start = inst ? nothing : ps, period_end = pe, is_instant = inst, statement = stmt,
        cik = "c", accession = "a", context_ref = string(concept, pe, ps), unit_ref = "usd",
        label = "L:" * concept)
    q1s, q1e = Date("2026-02-01"), Date("2026-04-30")
    sel = EDGAR.Selection(; cik = "c", accession = "a", kind = :filing, facts = [
        mk("us-gaap:Revenues", 100.0, q1s, q1e, "IncomeStatement"),                                 # 3-month
        mk("us-gaap:Revenues", 300.0, Date("2025-08-01"), q1e, "IncomeStatement"),                  # 9-month, SAME end date
        mk("us-gaap:CostOfRevenue", 60.0, q1s, q1e, "IncomeStatement"),
        mk("us-gaap:Assets", 5000.0, q1s, q1e, "BalanceSheet"; inst = true)])
    path = tempname() * ".duckdb"
    try
        to_duckdb(sel, path)
        # statement filter -> only the income-statement concepts (no Assets)
        @test Set(r.concept for r in statement_view(path; statement = "IncomeStatement")) ==
              Set(["us-gaap:Revenues", "us-gaap:CostOfRevenue"])
        # months=3 -> the 9-month Revenue sharing the end date is excluded, so the cell is the 3-month 100
        rev = first(r for r in statement_view(path; statement = "IncomeStatement", months = 3)
                    if r.concept == "us-gaap:Revenues")
        @test getproperty(rev, Symbol("2026-04-30")) == 100.0
        # by=:standard_concept -> Revenue row; CostOfRevenue (unmapped) is dropped (NULL std concept)
        @test [r.standard_concept for r in statement_view(path; statement = "IncomeStatement", by = :standard_concept)] == ["Revenue"]
        @test_throws ArgumentError statement_view(path; by = :nonsense)
    finally
        set_standardizer(:none); isfile(path) && rm(path)
    end
end

@testset "statement_view multi-statement membership (offline)" begin
    # A multi-homed concept (StockholdersEquity ∈ BalanceSheet + Equity) is returned for the Equity
    # view even though its PRIMARY statement is BalanceSheet — the membership-aware filter reconstructs
    # the full statement of equity (totals + movements), the gap a single `statement` tag could not fill.
    se = EDGAR.Fact(; concept = "us-gaap:StockholdersEquity", value = 5000.0, unit = "USD",
        period_end = Date("2026-04-30"), is_instant = true, statement = "BalanceSheet",
        statements = ["BalanceSheet", "Equity"], cik = "c", accession = "a",
        context_ref = "se", unit_ref = "usd", label = "Total equity")
    dv = EDGAR.Fact(; concept = "us-gaap:DividendsCommonStock", value = 30.0, unit = "USD",
        period_start = Date("2026-02-01"), period_end = Date("2026-04-30"), is_instant = false,
        statement = "Equity", statements = ["Equity"], cik = "c", accession = "a",
        context_ref = "dv", unit_ref = "usd", label = "Dividends")
    sel = EDGAR.Selection(; cik = "c", accession = "a", kind = :filing, facts = [se, dv])
    path = tempname() * ".duckdb"
    try
        to_duckdb(sel, path)
        @test (Set(r.concept for r in statement_view(path; statement = "Equity")),
               Set(r.concept for r in statement_view(path; statement = "BalanceSheet"))) ==
              (Set(["us-gaap:StockholdersEquity", "us-gaap:DividendsCommonStock"]),  # Equity: totals + movements
               Set(["us-gaap:StockholdersEquity"]))                                  # BS: the total, multi-homed
    finally
        isfile(path) && rm(path)
    end
end

@testset "warehouse: documents + extractions + facts (W1, offline)" begin
    f = EDGAR.Filing("0000104169", "0000104169-26-000102", "wmt.htm", "https://x/wmt.htm",
        :ixbrl, "<html><body><table>x</table></body></html>")
    sel = EDGAR.Selection(; cik = "0000104169", accession = "0000104169-26-000102",
        url = "https://x/wmt.htm", selector = "div > table", kind = :table,
        facts = [EDGAR.Fact(; concept = "us-gaap:SalesRevenueNet", value = 1.77751e11, unit = "USD",
            period_start = Date("2026-02-01"), period_end = Date("2026-04-30"), is_instant = false,
            cik = "0000104169", accession = "0000104169-26-000102", context_ref = "c1",
            unit_ref = "usd", label = "Total revenues")])
    path = tempname() * ".duckdb"
    try
        nd = to_duckdb(f, path)            # -> documents (Layer 1)
        nf = to_duckdb(sel, path)          # -> facts (Layer 3) + extractions (Layer 2)
        ndup = to_duckdb(f, path)          # idempotent document
        con = DBInterface.connect(DuckDB.DB, path)
        q(sql) = first(DBInterface.execute(con, sql))
        ver = q("SELECT value AS v FROM edgar_meta WHERE key = 'schema_version'").v
        # the provenance chain joins across all three tables by accession
        joined = q("""SELECT d.document AS doc FROM facts f
                      JOIN documents d ON f.accession = d.accession
                      JOIN extractions e ON f.accession = e.accession""").doc
        nextr = q("SELECT count(*) AS n FROM extractions").n
        DBInterface.close!(con)
        @test (nd, nf, ndup, ver, nextr, joined) ==
              (1, 1, 0, "3", 1, "wmt.htm")
    finally
        isfile(path) && rm(path)
    end
end

@testset "W3: archive a filing's facts into the warehouse (offline)" begin
    ix = """<html><body><ix:header><ix:resources>
    <xbrli:context id="d1"><xbrli:entity><xbrli:identifier scheme="x">0000104169</xbrli:identifier></xbrli:entity><xbrli:period><xbrli:startDate>2026-02-01</xbrli:startDate><xbrli:endDate>2026-04-30</xbrli:endDate></xbrli:period></xbrli:context>
    <xbrli:unit id="usd"><xbrli:measure>iso4217:USD</xbrli:measure></xbrli:unit>
    </ix:resources></ix:header>
    <ix:nonFraction name="us-gaap:Revenues" contextRef="d1" unitRef="usd" scale="6" id="f1">177,751</ix:nonFraction>
    <ix:nonFraction name="us-gaap:CostOfRevenue" contextRef="d1" unitRef="usd" scale="6" id="f2">133,058</ix:nonFraction>
    </body></html>"""
    f = EDGAR.Filing("0000104169", "0000104169-26-000102", "wmt.htm", "https://x/wmt.htm", :ixbrl, ix)
    path = tempname() * ".duckdb"
    try
        nd = to_duckdb(f, path; facts = true)    # document + facts(source='filing') + extraction
        con = DBInterface.connect(DuckDB.DB, path)
        q(sql) = first(DBInterface.execute(con, sql))
        @test (nd,
               q("SELECT count(*) AS n FROM documents").n,
               q("SELECT count(*) AS n FROM facts").n,
               q("SELECT DISTINCT source AS s FROM facts").s,            # tagged 'filing', not 'picker'
               q("SELECT count(*) AS n FROM extractions").n) ==
              (1, 1, 2, "filing", 1)
        DBInterface.close!(con)
    finally
        isfile(path) && rm(path)
    end
end
