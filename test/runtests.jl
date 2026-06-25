using Test
using EDGAR
using Dates
using HTTP: URIs   # for asserting the discovery filter querystring (B2)
import DuckDB                 # loads the EDGARDuckDBExt package extension (qualified, no name clash)
using DuckDB: DBInterface

# The SEC requires a User-Agent; set one so the network smoke tests can run.
set_user_agent("EDGAR.jl test suite noreply@example.com")

# Network-dependent tests are grouped (below) and gated by RUN_NETWORK so the suite can run
# offline only:  EDGAR_NETWORK_TESTS=false julia --project=. -e 'using Pkg; Pkg.test()'
const RUN_NETWORK = get(ENV, "EDGAR_NETWORK_TESTS", "true") != "false"
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

# A throwaway keyed FilingSystem to exercise the generic credentials registry before a real keyed
# system (Companies House) exists. Defined at top level so it is available when the testset runs.
struct _CredTestSys <: FilingSystem end
EDGAR.system_tag(::_CredTestSys) = :_credtest

@testset "per-system credentials (N3, offline)" begin
    saved_ua = EDGAR.CONFIG.user_agent

    # Generic keyed system: store, read back, merge (not replace), unknown key ⇒ nothing.
    set_credentials(_CredTestSys(); api_key = "abc123", secret = "s3cr3t")
    @test EDGAR.get_credential(_CredTestSys(), :api_key) == "abc123"
    @test EDGAR.get_credential(_CredTestSys(), :secret) == "s3cr3t"
    @test EDGAR.get_credential(_CredTestSys(), :missing) === nothing
    set_credentials(_CredTestSys(); api_key = "xyz")            # merge
    @test EDGAR.get_credential(_CredTestSys(), :api_key) == "xyz"
    @test EDGAR.get_credential(_CredTestSys(), :secret) == "s3cr3t"
    # A system with nothing stored ⇒ nothing, no error.
    @test EDGAR.get_credential(SEC(), :api_key) === nothing

    # SEC routing: set_credentials(SEC(); user_agent) delegates to set_user_agent (validated + stored
    # in the dedicated slot), and system_headers(::SEC) reflects it.
    @test set_credentials(SEC(); user_agent = "Jane Doe jane@example.com") == "Jane Doe jane@example.com"
    @test EDGAR.get_user_agent() == "Jane Doe jane@example.com"
    @test EDGAR.system_headers(SEC()) == ["User-Agent" => "Jane Doe jane@example.com"]
    @test_throws ArgumentError set_credentials(SEC(); user_agent = "no-email")   # validated like set_user_agent
    @test_throws ArgumentError set_credentials(SEC())                            # user_agent required

    delete!(EDGAR.CREDENTIALS, :_credtest)
    EDGAR.CONFIG.user_agent = saved_ua
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

@testset "sections: form-agnostic item segmentation (offline)" begin
    # TextAnalysis (header vs regular text) — by word case and word count, like edgartools.
    # (Header detection lives in the ChunkedDoc module, which sections() now delegates to.)
    long = "We design and manufacture industrial widgets and we have done so for many years " *
           "building a strong reputation across many regions and markets over a long period of time."
    @test (EDGAR.ChunkedDoc.ta_is_header(EDGAR.ChunkedDoc.TextAnalysis("RISK FACTORS")),       # mostly upper-case
           EDGAR.ChunkedDoc.ta_is_header(EDGAR.ChunkedDoc.TextAnalysis("Risk Factors")),       # mostly title-case
           EDGAR.ChunkedDoc.ta_is_header(EDGAR.ChunkedDoc.TextAnalysis(long)),                 # prose is not a header
           EDGAR.ChunkedDoc.ta_is_regular_text(EDGAR.ChunkedDoc.TextAnalysis(long))) == (true, true, false, true)

    # PageRange parsing for the cross-reference-index strategy (skips "(a)" footnotes).
    @test EDGAR._parse_pageranges("4-7, 9-11, (a), 25") ==
          [EDGAR.PageRange(4, 7), EDGAR.PageRange(9, 11), EDGAR.PageRange(25, 25)]

    # End-to-end: an item header runs into its paragraph; the next "Item N" starts a new section.
    # Generic — no per-form item list is consulted.
    html = """<html><body>
    <p>Item 1. Business</p><p>$long</p>
    <p>Item 1A. Risk Factors</p><p>Competition and supply-chain disruption and regulatory change are
       among the principal risks that could affect our results of operations in any given fiscal year
       and we monitor them across the whole enterprise on a continuous ongoing basis every quarter.</p>
    </body></html>"""
    secs = EDGAR.sections(html; form = "10-K")
    byid = Dict(s.item => s.text for s in secs)
    @test ([s.item for s in secs], occursin("design and manufacture", byid["Item 1"]),
           occursin("Competition", byid["Item 1A"])) == (["Item 1", "Item 1A"], true, true)
end

@testset "company-report extractions: subsidiaries / auditor / 6-K / items (offline)" begin
    # EX-21 parser: 3-col (name / ownership / jurisdiction) with a header row, a section-label row,
    # an empty spacer column, footnote markers; plus a 2-column table.
    ex21 = """<html><body>
    <table>
      <tr><th>Name of Subsidiary</th><th></th><th>Ownership %</th><th>Jurisdiction</th></tr>
      <tr><td>U.S. Subsidiaries:</td><td></td><td></td><td></td></tr>
      <tr><td>Acme Holdings, Inc. (1)</td><td></td><td>100</td><td>Delaware</td></tr>
      <tr><td>Beta Corp.*</td><td></td><td>80%</td><td>Nevada</td></tr>
    </table>
    <table>
      <tr><td>Gamma Ltd</td><td>England</td></tr>
    </table>
    </body></html>"""
    subs = EDGAR.parse_subsidiaries(ex21)
    @test [(s.name, s.jurisdiction, s.ownership) for s in subs] ==
          [("Acme Holdings, Inc.", "Delaware", 100.0), ("Beta Corp.", "Nevada", 80.0),
           ("Gamma Ltd", "England", nothing)]

    # Auditor from a synthetic inline instance: entity-decoded name, and the ICFR flag taken from the
    # value-fixed `fixed-true` transform (the rendered content is a "☒" glyph, not "true").
    inst = """
    <ix:nonNumeric name="dei:AuditorName">Ernst &amp; Young LLP</ix:nonNumeric>
    <ix:nonNumeric name="dei:AuditorLocation">San Jose, California</ix:nonNumeric>
    <ix:nonFraction name="dei:AuditorFirmId" contextRef="c" unitRef="u">42</ix:nonFraction>
    <ix:nonNumeric name="dei:IcfrAuditorAttestationFlag" format="ixt:fixed-true">☒</ix:nonNumeric>
    """
    a = EDGAR._auditor_from(inst)
    @test (a.name, a.location, a.firm_id, a.icfr_attestation) ==
          ("Ernst & Young LLP", "San Jose, California", 42, true)

    # 6-K cover-page metadata (the entity-decoded text the regexes straddle).
    cover = "Commission File Number 001-14948  For the month of March 2026  " *
            "Form 20-F  [ X ]  Form 40-F  Material Contained in this Report: Press release dated " *
            "March 1, 2026. SIGNATURES"
    c = EDGAR._parse_cover_page(cover)
    @test (c.commission_file_number, c.report_month, c.annual_report_form, c.content_description) ==
          ("001-14948", "March 2026", "20-F", "Press release dated March 1, 2026.")

    # extract_items_from_sections: capture-group match at start, " - " fallback, whole-title fallback.
    secs = [(item = "", title = "Item 2.02 - Results of Operations"),
            (item = "", title = "Item 9.01 Financial Statements and Exhibits"),
            (item = "", title = "Press Release")]
    @test EDGAR.extract_items_from_sections(secs, r"(Item\s+\d+\.\s*\d+)"i) ==
          ["Item 2.02", "Item 9.01", "Press Release"]
end

@testset "picker: select_section / select_sections (offline)" begin
    # Drive the picker server headlessly: a fake `opener` POSTs selections to the
    # local endpoint instead of launching a browser. No network involved.
    f = EDGAR.Filing("0000104169", "0000104169-26-000102", "wmt.htm",
        "https://www.sec.gov/Archives/edgar/data/104169/000010416926000102/wmt.htm",
        :ixbrl, "<html><head></head><body><table><tr><td>x</td></tr></table></body></html>")
    payload(sel) = EDGAR.JSON3.write((version = 1,
        provenance = (cik = f.entity.value, accession = f.ref, url = f.url),
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

@testset "negated presentation labels flip the sign (offline)" begin
    # A face-statement role may present a concept with a negatedLabel/negatedTerseLabel, so the rendered
    # statement shows the opposite sign of the stored value (general: treasury stock as contra-equity, or
    # a filer that stores operating cash flow negated). _concept_negations finds them; classify-time
    # extraction flips them so the value matches the as-reported statement.
    pre = """
    <link:linkbase>
    <link:presentationLink xlink:role="http://x/role/StatementsOfCashFlows">
      <link:loc xlink:href="x.xsd#us-gaap_NetCashProvidedByUsedInOperatingActivities" xlink:label="op"/>
      <link:loc xlink:href="x.xsd#us-gaap_NetCashProvidedByUsedInFinancingActivities" xlink:label="fin"/>
      <link:presentationArc xlink:to="op" preferredLabel="http://www.xbrl.org/2009/role/negatedTerseLabel"/>
      <link:presentationArc xlink:to="fin" preferredLabel="http://www.xbrl.org/2003/role/terseLabel"/>
    </link:presentationLink></link:linkbase>"""
    @test EDGAR._concept_negations(pre) == Set(["us-gaap:NetCashProvidedByUsedInOperatingActivities"])

    xml = """
    <xbrl xmlns="http://www.xbrl.org/2003/instance">
    <context id="d"><entity><identifier scheme="x">x</identifier></entity><period><startDate>2026-01-01</startDate><endDate>2026-03-31</endDate></period></context>
    <unit id="usd"><measure>iso4217:USD</measure></unit>
    <us-gaap:NetCashProvidedByUsedInOperatingActivities contextRef="d" unitRef="usd" decimals="-6">-2873000000</us-gaap:NetCashProvidedByUsedInOperatingActivities>
    </xbrl>"""
    f = EDGAR.Filing("x", "acc", "x.xml", "https://x/x.xml", :xbrl, xml)
    raw = EDGAR._extract_facts(f)
    flipped = EDGAR._extract_facts(f; negations = Set(["us-gaap:NetCashProvidedByUsedInOperatingActivities"]))
    @test (raw[1].value, flipped[1].value) == (-2873000000.0, 2873000000.0)   # negated -> as reported (+)
end

@testset "statement classification from presentation linkbase (W5, offline)" begin
    @test (EDGAR._classify_role("http://x/role/CondensedConsolidatedStatementsofIncome"),
           EDGAR._classify_role("http://x/role/CondensedConsolidatedBalanceSheets"),
           EDGAR._classify_role("http://x/role/CondensedConsolidatedStatementsofCashFlows"),
           EDGAR._classify_role("http://x/role/StatementsofShareholdersEquity"),
           EDGAR._classify_role("http://x/role/StatementsofComprehensiveIncome"),
           EDGAR._classify_role("http://x/role/BalanceSheetsParenthetical"),
           EDGAR._classify_role("http://x/role/NetIncomePerCommonShareDetails"),
           EDGAR._classify_role("http://x/role/Contingencies"),
           EDGAR._classify_role("http://x/role/ConsolidatedStatementsOfEarnings")) ==   # NUE: income statement named "Earnings"
          ("IncomeStatement", "BalanceSheet", "CashFlow", "Equity", "ComprehensiveIncome", "", "", "", "IncomeStatement")

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

@testset "concept-intrinsic membership (combined statements, offline)" begin
    # A combined statement is one role serving two statements. The role classifies to one, but a curated
    # key-anchor concept belongs to its statement by definition: ComprehensiveIncomeNetOfTax in a combined
    # operations+CI role (classifies IncomeStatement) is still a CI member; NetIncomeLoss in a combined CI
    # role (classifies ComprehensiveIncome) is still an income-statement member.
    pre = """
    <link:linkbase>
    <link:presentationLink xlink:role="http://x/role/StatementsOfOperationsAndComprehensiveIncome">
      <link:loc xlink:href="x.xsd#us-gaap_Revenues"/>
      <link:loc xlink:href="x.xsd#us-gaap_ComprehensiveIncomeNetOfTax"/></link:presentationLink>
    <link:presentationLink xlink:role="http://x/role/StatementsOfComprehensiveIncome">
      <link:loc xlink:href="x.xsd#us-gaap_NetIncomeLoss"/>
      <link:loc xlink:href="x.xsd#us-gaap_OtherComprehensiveIncomeNetOfTax"/></link:presentationLink>
    </link:linkbase>"""
    cs = EDGAR._concept_statements(pre)
    @test (cs["us-gaap:ComprehensiveIncomeNetOfTax"],   # role IncomeStatement + intrinsic ComprehensiveIncome
           cs["us-gaap:NetIncomeLoss"]) ==              # role ComprehensiveIncome + intrinsic IncomeStatement (primary)
          (["IncomeStatement", "ComprehensiveIncome"], ["IncomeStatement", "ComprehensiveIncome"])
end

@testset "reconstruct_from_notes (statement filed as a note, offline)" begin
    # A filer that presents the statement of changes in equity only as a NOTE: the role is a "…Details"
    # disclosure (rejected by classification) but relaxed-classifies to Equity by name + roll-forward
    # concept. reconstruct_from_notes re-tags its facts to Equity, MARKED as reconstructed; facts outside
    # the note (Assets) are untouched.
    pre = """
    <link:linkbase>
    <link:presentationLink xlink:role="http://x/role/ConsolidatedStatementsOfChangesInEquityDetails">
      <link:loc xlink:href="x.xsd#us-gaap_StockholdersEquity"/>
      <link:loc xlink:href="x.xsd#us-gaap_IncreaseDecreaseInStockholdersEquityRollForward"/>
      <link:loc xlink:href="x.xsd#us-gaap_DividendsCommonStock"/></link:presentationLink>
    <link:presentationLink xlink:role="http://x/role/BalanceSheets">
      <link:loc xlink:href="x.xsd#us-gaap_Assets"/></link:presentationLink>
    </link:linkbase>"""
    row(concept, val) = EDGAR.fact_row(EDGAR.Fact(; concept, value = val, period_end = Date("2026-04-30"),
        is_instant = true, cik = "c", accession = "a", unit = "USD", context_ref = concept, unit_ref = "usd"))
    rows = [row("us-gaap:StockholdersEquity", 5000.0), row("us-gaap:DividendsCommonStock", 30.0),
            row("us-gaap:Assets", 9000.0)]   # Assets is not in the equity note -> not reconstructed
    rec = EDGAR.reconstruct_from_notes(pre, rows, "Equity")
    @test Set((r.concept, r.statement, r.statements, startswith(r.source_selector, "reconstructed:")) for r in rec) ==
          Set([("us-gaap:StockholdersEquity", "Equity", "[\"Equity\"]", true),
               ("us-gaap:DividendsCommonStock", "Equity", "[\"Equity\"]", true)])
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
    combinedis = [row("IncomeStatement", "us-gaap:Revenues"),          # SPG/REIT combined operations + CI:
                  row("IncomeStatement", "us-gaap:NetIncomeLoss"),     #   the CI total lives in the income statement
                  row("IncomeStatement", "us-gaap:ComprehensiveIncomeNetOfTax")]
    plainis = [row("IncomeStatement", "us-gaap:Revenues")]             # plain income statement, no CI content

    @test (EDGAR.select_statement(combined, "IncomeStatement") == combined,           # #608 alias to CI
           EDGAR.select_statement(pureoci, "IncomeStatement"),                         # pure OCI: no alias
           EDGAR.select_statement(direct, "IncomeStatement"),                          # direct wins, no alias
           EDGAR.select_statement(embedeq, "ComprehensiveIncome") == embedeq,          # #706 CI -> Equity
           EDGAR.select_statement(embedeq, "IncomeStatement") == embedeq,              # transitive IS -> CI -> Equity
           EDGAR.select_statement(combinedis, "ComprehensiveIncome") == combinedis,    # #608 CI <- combined income statement
           EDGAR.select_statement(plainis, "ComprehensiveIncome")) ==                  # no CI content: no false alias
          (true, [], [direct[1]], true, true, true, [])
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

@testset "ESEF: offline report-package extraction (B1)" begin
    # A real (size-reduced) ESEF report package: GLEIF's 2024 annual report as a classic XBRL
    # instance bundled with its presentation/calculation/label linkbases (see the NOTICE beside it).
    # Exercises the FilingSystem seam end-to-end with NO network: a non-SEC system (ESEF), LEI
    # identity (not CIK), the ifrs-full taxonomy (not us-gaap), and linkbases bundled in the ZIP
    # (not loose Archives files) — all through the same `fetch_filing`/`facts` API as SEC.
    pkg = joinpath(@__DIR__, "data", "esef", "gleif-2024-min.zip")
    f = fetch_filing(ESEF(), pkg)
    @test f.system isa ESEF
    @test f.kind === :xbrl
    @test f.entity == EntityId(:lei, "506700GE1G29325QX363")   # identity is the LEI, read from the instance

    rows = facts(f; classify = true, labels = true)
    @test length(rows) > 100                                    # the IFRS instance's numeric facts

    # IFRS concepts are classified into face statements via the bundled presentation linkbase + the
    # shared ifrs-full vocabulary (vocab_ifrs.jl) — no SEC FilingSummary involved.
    assets = filter(r -> r.concept == "ifrs-full:Assets", rows)
    @test !isempty(assets)
    @test all(r -> r.statement == "BalanceSheet", assets)
    @test any(r -> r.period_end == Date(2024, 12, 31) && r.value ≈ 1.8814882e7 && r.unit == "USD", assets)

    pl = filter(r -> r.concept == "ifrs-full:ProfitLoss" && r.period_end == Date(2024, 12, 31), rows)
    @test !isempty(pl)
    @test all(r -> r.statement == "IncomeStatement", pl)

    @test any(r -> r.statement == "BalanceSheet", rows)
    @test any(r -> r.statement == "IncomeStatement", rows)
    @test any(r -> r.statement == "CashFlow", rows)

    # The linkbase-driven enrichment API resolves against the ZIP-bundled linkbases.
    @test statement_map(f)["ifrs-full:Assets"] == "BalanceSheet"
    @test !isempty(calculations(f))
    # Labels for the issuer's EXTENSION concepts are bundled (`_lab-en.xml`); ifrs-full standard
    # labels are not shipped in the package, so only extension concepts carry a native label here.
    lm = label_map(f)
    @test any(k -> startswith(k, "gleif:"), keys(lm))
end

@testset "ESEF: discovery + handle fetch (B2)" begin
    # ── Offline: the discovery nouns (FilingHandle, FilingSource) and handle-based fetch ──
    # A FilingHandle whose `url` is the LOCAL fixture exercises `fetch_filing(h)` →
    # `fetch_filing(::ESEF, h::FilingHandle)` → `fetch_filing(::ESEF, src; entity, ref)` with no
    # network: identity + ref come from the handle (as discovery would supply them), not re-parsed.
    pkg = joinpath(@__DIR__, "data", "esef", "gleif-2024-min.zip")
    h = FilingHandle(; system = ESEF(), entity = EntityId(:lei, "506700GE1G29325QX363"),
                     ref = "gleif-2024", url = pkg, period_end = Date(2024, 12, 31), country = "CH")
    @test h.system isa ESEF
    f = fetch_filing(h)
    @test f.system isa ESEF
    @test f.entity == EntityId(:lei, "506700GE1G29325QX363")   # taken from the handle
    @test f.ref == "gleif-2024"                                 # taken from the handle
    @test any(r -> r.concept == "ifrs-full:Assets" && r.statement == "BalanceSheet",
              facts(f; classify = true))

    # The filings.xbrl.org filter querystring is built correctly (pure; no network).
    @test EDGAR._fxbrl_filter(Pair{String,String}[]) == ""
    fs = EDGAR._fxbrl_filter(["entity.identifier" => "549300P8N0P6KDGTJ206"])
    @test startswith(fs, "&filter=")
    @test occursin("entity.identifier", URIs.unescapeuri(fs))
    @test occursin("549300P8N0P6KDGTJ206", URIs.unescapeuri(fs))

end

@testset "Companies House: offline iXBRL parse + FRC canonicalization (C1)" begin
    # Companies House is the third FilingSystem: a single inline-XBRL accounts document (no report
    # package), company-number identity, the FRC taxonomy with NO bundled linkbase. Two fixtures (see
    # the NOTICE beside them): a real small FRS-102 filing, and a synthetic doc that binds the FRC core
    # namespace to a generic `ns5` prefix to test canonicalization. No network.
    dir = joinpath(@__DIR__, "data", "companies_house")

    # 1) Real small filing: company-number identity, inline-XBRL, balance-sheet classification via the
    #    uk-core vocabulary (these are filleted accounts — balance sheet only, no P&L).
    f = fetch_filing(CompaniesHouse(), joinpath(dir, "small-frs102.html"))
    @test f.system isa CompaniesHouse
    @test f.kind === :ixbrl
    @test f.entity == EntityId(:companies_house, "00021497")
    rows = facts(f; classify = true)
    @test !isempty(rows)
    @test any(r -> r.concept == "uk-core:NetAssetsLiabilities" && r.statement == "BalanceSheet", rows)

    # 2) FRC prefix canonicalization: the synthetic filing tags concepts as `ns5:` (a generic prefix
    #    bound to the FRC core namespace). After fetch they must be canonical `uk-core:`, so the
    #    same vocabulary classifies them — proving classification is by namespace, not the filer's prefix.
    g = fetch_filing(CompaniesHouse(), joinpath(dir, "ns5-canon-min.html"))
    @test g.entity == EntityId(:companies_house, "99999999")
    @test !occursin("name=\"ns5:", g.content)          # prefixes rewritten
    @test occursin("name=\"uk-core:", g.content)
    grows = facts(g; classify = true)
    @test any(r -> r.concept == "uk-core:NetAssetsLiabilities" && r.statement == "BalanceSheet", grows)
    @test any(r -> r.concept == "uk-core:TurnoverRevenue" && r.statement == "IncomeStatement", grows)

    # A PDF (paper/dormant accounts) is a typed, non-fatal `:pdf` filing, not an error.
    pdf = joinpath(tempdir(), "ch-fake.pdf"); write(pdf, "%PDF-1.7\nnot real")
    p = fetch_filing(CompaniesHouse(), pdf)
    @test p.kind === :pdf
    @test isempty(p.content)
    rm(pdf; force = true)
end

@testset "Companies House: bulk Accounts Data Product (C2, offline)" begin
    # The keyless bulk source. `bulk-min.zip` is a tiny synthetic archive (one bulk-named entry) so the
    # whole discover→handle→fetch→classify path runs offline. The entry-name parser handles plain and
    # jurisdiction-prefixed (SC/NI) numbers.
    @test EDGAR._ch_bulk_entry_meta("Prod223_4245_07709636_20241231.html") ==
          (number = "07709636", period_end = Date(2024, 12, 31))
    @test EDGAR._ch_bulk_entry_meta("Prod223_4245_SC012345_20251231.html").number == "SC012345"
    @test EDGAR._ch_bulk_entry_meta("not-a-bulk-file.html").number == ""
    @test EDGAR._ch_bulk_url(Date(2026, 6, 19)) ==
          "https://download.companieshouse.gov.uk/Accounts_Bulk_Data-2026-06-19.zip"

    dir = joinpath(@__DIR__, "data", "companies_house")
    # Seed the single-slot archive memo with the fixture so `discover` (which builds the archive URL
    # from the date) reads it offline instead of downloading.
    d = Date(2025, 12, 31)
    url = EDGAR._ch_bulk_url(d)
    EDGAR._CH_BULK_MEMO[] = (url, read(joinpath(dir, "bulk-min.zip")))
    try
        hs = discover(CompaniesHouseBulk(); date = d)
        @test length(hs) == 1
        h = only(hs)
        @test h.system isa CompaniesHouse
        @test h.entity == EntityId(:companies_house, "99999999")
        @test h.ref == "Prod223_4245_99999999_20251231.html"
        @test h.period_end == d
        @test endswith(h.url, ".zip")

        # company_number filter
        @test isempty(discover(CompaniesHouseBulk(); date = d, company_number = "00000000"))
        @test length(discover(CompaniesHouseBulk(); date = d, company_number = "99999999")) == 1

        # fetch the handle → reads the entry from the (memoised) archive, canonicalizes, classifies
        f = fetch_filing(h)
        @test f.system isa CompaniesHouse
        @test f.kind === :ixbrl
        @test any(r -> r.concept == "uk-core:NetAssetsLiabilities" && r.statement == "BalanceSheet",
                  facts(f; classify = true))
    finally
        EDGAR._CH_BULK_MEMO[] = ("", UInt8[])   # don't leak the seeded memo into other tests
    end
end

# iXBRL decimal-comma parsing — focused, individually-runnable testsets (see the file):
#   julia --project=. test/test_decimal_comma.jl
include(joinpath(@__DIR__, "test_decimal_comma.jl"))

@testset "find_paragraphs (intra-filing text search, offline)" begin
    # Search WITHIN one fetched filing for paragraphs containing a literal phrase (jurisdiction-
    # agnostic; SEC iXBRL and ESEF iXHTML alike). Each hit carries its 1-based paragraph index, and
    # matching ignores inline markup + collapsed whitespace.
    html = """<html><body>
    <p>The Company faces <b>climate-related</b> risks across its operations.</p>
    <div>We operate many <span>shopping</span> centres in the Nordics.</div>
    <p>This paragraph mentions nothing relevant.</p>
    </body></html>"""
    hits = find_paragraphs(html, "climate-related risks")
    @test hits isa Vector{@NamedTuple{index::Int, paragraph::String}}
    @test length(hits) == 1                                   # phrase spans an inline <b> tag
    @test hits[1].index == 1                                  # first paragraph of the document
    @test occursin("climate-related risks", lowercase(hits[1].paragraph))
    # the index locates the paragraph among ALL paragraphs
    @test EDGAR._paragraphs(html)[hits[1].index] == hits[1].paragraph
    @test only(find_paragraphs(html, "shopping centres")).index == 2   # phrase spans an inline <span>
    # case sensitivity
    @test length(find_paragraphs(html, "CLIMATE-RELATED RISKS")) == 1               # ignorecase default
    @test isempty(find_paragraphs(html, "Climate-Related Risks"; ignorecase = false))
    @test isempty(find_paragraphs(html, "absent zzz phrase"))          # "or no paragraph"
    # the Filing convenience method returns the same row table
    f = EDGAR.Filing(ESEF(), EntityId(:lei, "L"), "r", "d.xhtml", "https://x/d.xhtml", :ixbrl, html)
    @test only(find_paragraphs(f, "shopping centres")).index == 2
end


# ── Network (live) — all tests that hit the network, grouped so they skip as a set ──────
if RUN_NETWORK
# do-it-yourself oracles (src/sources/, not part of the package) — loaded only for the live tests
include(joinpath(@__DIR__, "..", "src", "sources", "arelle_oracle.jl"))   # -> ArelleOracle (needs only EDGAR)
include(joinpath(@__DIR__, "..", "src", "sources", "yahoo_oracle.jl"))    # -> YahooOracle (uses YFinance)
@testset "network (live)" begin
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

@testset "ESEF: live discovery + fetch (B2)" begin
    # ── Network: live discover + fetch from filings.xbrl.org (wrapped so CI/offline stays green) ──
    try
        hs = discover(FilingsXBRLOrg(); lei = "549300P8N0P6KDGTJ206", year = 2023)  # Citycon Oyj
        @test !isempty(hs)
        @test all(x -> x.system isa ESEF && x.entity.scheme === :lei, hs)
        @test all(x -> startswith(x.url, "https://filings.xbrl.org/"), hs)
        en = first(filter(x -> endswith(x.url, "-en.zip"), hs))
        ff = fetch_filing(en)
        @test ff.kind === :ixbrl                                  # ESEF primary report is inline XBRL
        rows = facts(ff; classify = true)
        @test length(rows) > 100
        @test any(r -> r.concept == "ifrs-full:Assets" && r.statement == "BalanceSheet", rows)
    catch e
        @info "Skipping ESEF network discovery test: $e"
        @test true
    end
end
    # ── Oracle validation: BS / IS / CF for fresh filers, via validate() (see src/sources/) ──
    @testset "oracle validation: US 10-K Coca-Cola (Yahoo)" begin
        try
            y = YahooOracle.validate(:sec, "21344", "KO")
            present = [r for r in y if r.edgar !== nothing && r.yahoo !== nothing]
            @test !isempty(present)
            @test all(r -> r.match, present)                                  # every covered total agrees
            @test all(st -> any(r -> r.statement == st && r.match, present), (:bs, :is, :cf))  # BS/IS/CF covered
        catch e
            @info "Skipping US oracle validation (network): $e"; @test true
        end
    end

    @testset "oracle validation: UK Jupiter Fund Mgmt (Arelle + Yahoo)" begin
        try
            a = ArelleOracle.statements("5493003DJ1G01IMQ7S28")
            @test Set(r.statement for r in a) == Set(["BalanceSheet", "IncomeStatement", "CashFlow"])
            @test all(r -> r.total > 0 && r.matched == r.total, a)            # 100% fact parity vs Arelle
            y = YahooOracle.validate(:esef, "5493003DJ1G01IMQ7S28", "JUP.L")
            present = [r for r in y if r.edgar !== nothing && r.yahoo !== nothing]
            @test !isempty(present)
            @test all(r -> r.match, present)
            @test all(st -> any(r -> r.statement == st && r.match, present), (:bs, :is, :cf))
        catch e
            @info "Skipping UK oracle validation (network): $e"; @test true
        end
    end

    @testset "oracle validation: EU Signify (Arelle + Yahoo)" begin
        try
            a = ArelleOracle.statements("549300072P3J1X8NZO35")
            @test Set(r.statement for r in a) == Set(["BalanceSheet", "IncomeStatement", "CashFlow"])
            @test all(r -> r.total > 0 && r.matched == r.total, a)            # 100% fact parity vs Arelle
            y = YahooOracle.validate(:esef, "549300072P3J1X8NZO35", "LIGHT.AS")
            present = [r for r in y if r.edgar !== nothing && r.yahoo !== nothing]
            @test !isempty(present)
            @test all(r -> r.match, present)
            @test all(st -> any(r -> r.statement == st && r.match, present), (:bs, :is, :cf))
        catch e
            @info "Skipping EU oracle validation (network): $e"; @test true
        end
    end

end  # @testset "network (live)"
end  # if RUN_NETWORK