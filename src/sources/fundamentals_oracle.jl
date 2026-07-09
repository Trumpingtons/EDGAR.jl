# Fundamentals cross-check oracle — SHARED machinery (this file) + one file per provider
# (fundamentals_yahoo.jl, fundamentals_alphavantage.jl). All three are plain `include`d into EDGAR (no
# submodule wrapper), so the public verbs `validate`/`report` live directly in the `EDGAR` namespace.
#
# What it checks: do the headline numbers EDGAR.jl extracts for the three core statements agree with the
# standardized fundamentals an INDEPENDENT data provider reports? Balance sheet (Assets, Equity), income
# statement (Revenue, Net income) and cash flow (Operating cash flow). Providers serve standardized
# (Morningstar-ish) totals, so this is an APPROXIMATE, concept-mapped check within a 1% tolerance — a
# different pipeline from EDGAR's, not the same document (contrast the same-document Arelle/CSV oracles).
#
# The provider is an axis: `validate(system, locator, ticker; provider = :yahoo | :alphavantage)`. The
# EDGAR side under test (`_edgar_rows`/`_edgar_metric`, the `ORACLE_METRICS` taxonomy concepts, the `Row`
# shape, `validate`/`report`) is provider-independent and lives here; each provider file supplies only its
# three plug points — `provider_concepts`, `provider_fetch`, `provider_value` — plus its panel and name.
#
# Usage:
#   using EDGAR
#   rows = validate(:sec, "320193", "AAPL")                       # provider = :yahoo (default)
#   rows = validate(:sec, "320193", "AAPL"; provider = :alphavantage)
#   report()                                                       # run the default (Yahoo) firm panel
#   report(; provider = :alphavantage)                            # AlphaVantage panel

# One comparison row. `reference` is the provider's value (provider-neutral name; `report` labels which).
const OracleRow = @NamedTuple{statement::Symbol, metric::String, period_end::Union{Date,Nothing},
                              edgar::Union{Float64,Nothing}, reference::Union{Float64,Nothing},
                              rel_diff::Float64, match::Bool}

# A headline metric: the candidate XBRL concepts per EDGAR taxonomy and which of the three statements it
# belongs to (:bs balance sheet, :is income statement, :cf cash flow). The PROVIDER's line-item keys are
# NOT here — they live on the provider (`provider_concepts`), so a new provider needs no struct change.
struct OracleMetric
    name::String
    usgaap::Vector{String}
    ifrs::Vector{String}
    india::Vector{String}     # India: in-capmkt (Integrated Filing) then in-bse-fin (old feed) — same local names
    china::Vector{String}     # China: cas: label-derived concepts from the PDF path (extract_cas_pdf)
    statement::Symbol
end

_oracle_instant(m::OracleMetric) = m.statement === :bs    # balance-sheet items are point-in-time

# India note (see the india-nse-xbrl-quirks memo / manual §13.5): net income is the OWNERS-OF-PARENT
# figure providers report (not ProfitLossForPeriod, which includes minority interest); revenue is
# RevenueFromOperations (which for some filers carries a small excise/GST definitional gap — an
# approximate check, hence the 1% tolerance may flag those). Concepts are listed for BOTH India
# taxonomies (in-capmkt current, in-bse-fin old); the same-local-name pairs are tried in order.
# China note: `cas:` concepts come from the PDF label path (vocab_cas). Net income prefers the
# parent-attributable figure (归属于母公司股东的净利润), falling back to total 净利润 (banks, where minority
# interest is negligible). Revenue is 营业收入 (cas:Revenue), then 营业总收入 (cas:TotalRevenue).
# Germany note: German consolidated reports go through the shared IFRS PDF path (ifrs-full concepts), so the
# IFRS candidate lists apply.
const ORACLE_METRICS = [
    OracleMetric("Assets",     ["us-gaap:Assets"], ["ifrs-full:Assets"],
                 ["in-capmkt:Assets", "in-bse-fin:Assets"], ["cas:Assets"], :bs),
    OracleMetric("Equity",     ["us-gaap:StockholdersEquity", "us-gaap:StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"],
                 ["ifrs-full:EquityAttributableToOwnersOfParent", "ifrs-full:Equity"],
                 ["in-capmkt:EquityAttributableToOwnersOfParent", "in-capmkt:Equity",
                  "in-bse-fin:EquityAttributableToOwnersOfParent", "in-bse-fin:Equity"],
                 ["cas:EquityAttributableToParent", "cas:Equity"], :bs),
    OracleMetric("Revenue",    ["us-gaap:Revenues", "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax"],
                 ["ifrs-full:Revenue", "ifrs-full:RevenueFromContractsWithCustomers"],
                 ["in-capmkt:RevenueFromOperations", "in-bse-fin:RevenueFromOperations"],
                 ["cas:TotalRevenue", "cas:Revenue"], :is),
    OracleMetric("NetIncome",  ["us-gaap:NetIncomeLoss"],
                 ["ifrs-full:ProfitLossAttributableToOwnersOfParent", "ifrs-full:ProfitLoss"],
                 ["in-capmkt:ProfitOrLossAttributableToOwnersOfParent", "in-capmkt:ProfitLossForPeriod",
                  "in-bse-fin:ProfitOrLossAttributableToOwnersOfParent", "in-bse-fin:ProfitLossForPeriod"],
                 ["cas:ProfitAttributableToParent", "cas:ProfitLoss"], :is),
    OracleMetric("OperCashFlow", ["us-gaap:NetCashProvidedByUsedInOperatingActivities",
                                  "us-gaap:NetCashProvidedByUsedInOperatingActivitiesContinuingOperations"],
                 ["ifrs-full:CashFlowsFromUsedInOperatingActivities"],
                 ["in-capmkt:CashFlowsFromUsedInOperatingActivities", "in-bse-fin:CashFlowsFromUsedInOperatingActivities"],
                 ["cas:NetCashFlowsFromOperating"], :cf),
]

const ORACLE_TOL = 0.001   # 0.1% — genuine matches agree to 0.000%; documented standardisation gaps
                           # (≥1.6%) are handled by the scheme registry, so the tolerance can be tight
                           # enough to catch a real extraction regression instead of hiding it.

# ── Provider abstraction ─────────────────────────────────────────────────────
# A provider (Yahoo, AlphaVantage, …) is a singleton subtype supplying three plug points. Each provider
# file adds methods to these generics; the shared `validate`/`report` dispatch on them.
abstract type FundamentalsProvider end

"provider_concepts(p, metric_name) -> Vector{String}: the provider's standardized line-item keys."
function provider_concepts end
"provider_fetch(p, ticker) -> (bs, is, cf): the three statements as opaque per-provider payloads (any may be `nothing`)."
function provider_fetch end
"provider_value(p, payload, keys, period_end) -> Union{Float64,Nothing}: the provider's value for a metric."
function provider_value end
"provider_name(p) -> String: display name used by `report`."
function provider_name end
"default_firms(p) -> panel of (name, system, locator, ticker, jurisdiction) tuples for `report`."
function default_firms end
"default_scheme(p) -> Symbol: the provider's standardisation scheme, used when `scheme = :auto`."
function default_scheme end

# Resolve a `provider = :sym` kwarg to its singleton; each provider file adds `_provider(::Val{:sym})`.
_provider(sym::Symbol) = _provider(Val(sym))
_provider(::Val{S}) where {S} = error("unknown fundamentals provider :$S (have :yahoo, :alphavantage)")

# A default User-Agent is required for the EDGAR-side fetches. Set it lazily at first use (NOT at load —
# that would be a precompile-time side effect), only if the caller has not set one already.
_ensure_ua() = isempty(strip(try get_user_agent() catch; "" end)) &&
    set_user_agent(get(ENV, "EDGAR_UA", "EDGAR.jl validation noreply@example.com"))

# EDGAR.jl's classified facts for a filer's latest annual filing (per filing system).
function _edgar_rows(system::Symbol, locator::AbstractString)
    if system === :sec
        fs = filings_by_cik(locator; forms = "10-K")
        isempty(fs) && return nothing
        return facts(fetch_filing(locator, fs[1].accession); classify = true)
    elseif system === :esef
        hs = discover(FilingsXBRLOrg(); lei = locator)
        isempty(hs) && return nothing
        en = filter(x -> endswith(x.url, "-en.zip"), hs)
        return facts(fetch_filing(isempty(en) ? first(hs) : first(en)); classify = true)
    elseif system === :dart
        # `locator` is a 6-digit KRX stock_code or an 8-digit corp_code; take the most recent annual report.
        cc = occursin(r"^\d{6}$", strip(locator)) ? dart_corp_code(locator) : String(strip(locator))
        hs = discover(OpenDARTApi(); corp_code = cc, bgn_de = today() - Year(2), end_de = today())
        isempty(hs) && return nothing
        rows = facts(fetch_filing(first(hs)); classify = true)
        # DART tags the consolidated FACE on `ConsolidatedMember` (not undimensioned), so normalize those
        # face facts to undimensioned — dropping note breakdowns (extra axes → comma) and the
        # separate-company facts — so the shared consolidated/undimensioned metric picker finds them.
        isface(d) = isempty(d) || d == "{}" || (occursin("ConsolidatedMember", d) && !occursin(",", d))
        return [merge(r, (dimensions = "{}",)) for r in rows if isface(r.dimensions)]
    elseif system === :india
        # `locator` is the NSE ticker. Prefer the CURRENT Integrated Filing (in-capmkt); its annual column
        # is the >300-day duration the metric picker selects. Fall back to the frozen results feed (in-bse-fin).
        hs = try discover(IntegratedFilings(); symbol = locator, consolidated = true) catch; FilingHandle[] end
        isempty(hs) && (hs = try discover(NSEFilings(); symbol = locator, consolidated = true) catch; FilingHandle[] end)
        isempty(hs) && return nothing
        return facts(fetch_filing(first(hs)); classify = true)
    elseif system === :china
        # `locator` is a CNINFO six-digit code (annual report auto-selected) OR a local PDF path (a stashed
        # filer, to avoid re-fetching). Facts come from the CAS PDF path (Docling), already classified.
        path = isfile(locator) ? String(locator) : begin
            hs = discover(CNINFOFilings(); code = String(locator), years = 1)
            isempty(hs) && return nothing
            String(fetch_filing(China(), first(hs)).content)
        end
        return extract_cas_pdf(path)
    elseif system === :germany
        # `locator` is a local German CONSOLIDATED-IFRS report PDF — Germany has no programmatic OAM retrieval,
        # so the user supplies the stashed report. Facts come from the shared German/IFRS PDF path on
        # ifrs-full concepts, so the IFRS metric concepts apply unchanged.
        path = expanduser(String(locator))
        isfile(path) || return nothing
        return extract_ifrs_pdf(path)
    elseif system === :hkex
        # `locator` is an HKEXnews five-digit stock code (annual report auto-selected) OR a local PDF path
        # (a stashed filer). Facts come from the shared English-PDF path (Docling), on ifrs-full concepts —
        # so the IFRS metric concepts apply unchanged.
        path = isfile(locator) ? String(locator) : begin
            hs = discover(HKEXFilings(); code = String(locator), years = 2)
            isempty(hs) && return nothing
            String(fetch_filing(first(hs)).content)
        end
        return extract_ifrs_pdf(path)
    end
    return nothing                       # :edinet not implemented yet
end

# The metric's candidate concepts for a system's taxonomy (SEC → us-gaap, India → in-capmkt/in-bse-fin,
# China → cas, everything else → IFRS, the ESEF/most-jurisdictions default).
_metric_concepts(m::OracleMetric, system::Symbol) =
    system === :sec ? m.usgaap : system === :india ? m.india : system === :china ? m.china : m.ifrs

# EDGAR.jl's (value, period_end) for a metric: consolidated (undimensioned), annual, most-recent.
# Candidates are tried in order, so the first listed concept wins when a filing tags several (e.g. IFRS
# net income prefers profit attributable to owners of parent over total profit).
function _edgar_metric(rows, m::OracleMetric, system::Symbol)
    nodim(r) = r.dimensions == "{}" || isempty(r.dimensions)
    for c in _metric_concepts(m, system)
        cand = [r for r in rows if r.concept == c && nodim(r) && r.is_instant == _oracle_instant(m)]
        _oracle_instant(m) || (cand = [r for r in cand if r.period_start !== nothing && (r.period_end - r.period_start) > Day(300)])
        isempty(cand) && continue
        r = cand[argmax([r.period_end for r in cand])]
        return (value = r.value, period_end = r.period_end)
    end
    return nothing
end

"""
    validate(system, locator, ticker; provider=:yahoo, scheme=:auto) -> Vector{OracleRow}

Validate EDGAR.jl's extraction against an independent fundamentals `provider` for one filer, across the
three statements. `system` is `:sec`, `:esef`, `:dart`, `:india`, `:china`, `:hkex` or `:germany`;
`locator` is the CIK (SEC), LEI (ESEF), corp/stock code (DART), NSE ticker (India), CNINFO code (China)
or HKEXnews code (Hong Kong) — or, for the PDF systems (China/HK/Germany), a local report path; and
`ticker` is the provider's symbol (e.g. `"AAPL"`, `"CTY1S.HE"`, `"TCS.NS"`, `"0700.HK"`).

`provider` selects the backend: `:yahoo` (YFinance, global coverage) or `:alphavantage` (US-strong, needs
`ALPHA_VANTAGE_API_KEY`). Returns one [`OracleRow`](@ref) per metric (tagged `:bs`/`:is`/`:cf`): EDGAR's
value, the provider's `reference` value, the `rel_diff`, and whether they `match` within 1%. `scheme` is
reserved for the standardisation-reason registry (see [`report`](@ref)).
"""
function validate(system::Symbol, locator::AbstractString, ticker::AbstractString;
                  provider::Symbol=:yahoo, scheme::Symbol=:none)
    _ensure_ua()
    p = _provider(provider)
    rows = OracleRow[]
    edgar = _edgar_rows(system, locator)
    edgar === nothing && return rows
    funds = provider_fetch(p, ticker)
    for m in ORACLE_METRICS
        e = _edgar_metric(edgar, m, system)
        if e === nothing
            push!(rows, (statement = m.statement, metric = m.name, period_end = nothing,
                         edgar = nothing, reference = nothing, rel_diff = Inf, match = false)); continue
        end
        payload = m.statement === :bs ? funds.bs : m.statement === :is ? funds.is : funds.cf
        a = provider_value(p, payload, provider_concepts(p, m.name), e.period_end)
        rd = (a === nothing) ? Inf : abs(e.value - a) / max(abs(a), 1)
        push!(rows, (statement = m.statement, metric = m.name, period_end = e.period_end,
                     edgar = e.value, reference = a, rel_diff = rd, match = a !== nothing && rd <= ORACLE_TOL))
    end
    return rows
end

const _ORACLE_STMT_LABEL = Dict(:bs => "BalanceSheet", :is => "IncomeStatement", :cf => "CashFlow")

# Reason-carrying registry of (ticker, metric) pairs where EDGAR and a provider legitimately disagree
# because the provider applies a documented (Morningstar-style) standardisation — NOT extraction defects.
# Keyed by `scheme`; `report` flags a registered pair as "◑ documented", prints its reason, and does not
# count it against the result. A pair that unexpectedly starts matching is harmless (prints ✓); one that
# keeps diverging is expected. `scheme = :none` disables the registry (exact matching only); `scheme =
# :auto` selects the provider's `default_scheme` (both Yahoo and AlphaVantage serve Morningstar-style
# standardised fundamentals, so `:morningstar`). Every reason is confirmed live or against the manual.
const SCHEME_REGISTRY = Dict{Symbol,Dict{Tuple{String,String},String}}(
    :morningstar => Dict(
        ("HEIA.AS", "Revenue") =>
            "Yahoo serves revenue NET of the €6.1bn alcohol-excise pass-through (heia:RevenueLessExciseTaxExpense); EDGAR reports gross ifrs-full:Revenue (Δ≈20.6%). Manual §Netherlands.",
        ("CTY1S.HE", "Equity") =>
            "Yahoo StockholdersEquity is total ifrs-full:Equity INCL. hybrid perpetual capital; EDGAR selects ifrs-full:EquityAttributableToOwnersOfParent, which excludes it (NCI nil; Δ≈31.9%).",
        ("MARUTI.NS", "Revenue") =>
            "Yahoo revenue = RevenueFromOperations − excise duty; EDGAR reports gross in-capmkt:RevenueFromOperations (Δ≈1.6%). See india-nse-xbrl-quirks / manual §13.5.",
        ("RELIANCE.NS", "Revenue") =>
            "Yahoo revenue = RevenueFromOperations − excise duty; EDGAR reports gross in-capmkt:RevenueFromOperations (Δ≈1.7%). See india-nse-xbrl-quirks / manual §13.5.",
        ("SIE.DE", "Revenue") =>
            "Yahoo reports continuing-operations revenue (~€74.9bn); EDGAR reports total Umsatzerlöse (€77.8bn, Δ≈3.7%). Manual §Germany.",
        ("VOW3.DE", "NetIncome") =>
            "Yahoo standardised net income (~€16.5bn) differs from net income attributable to VW AG shareholders (€16.0bn, what the metric selects; Δ≈3%). Manual §Germany.",
    ),
    # Stern Stewart EVA standardisation — the "economic" (NOPAT/invested-capital) adjustments to reported
    # GAAP/IFRS figures. Reserved: populated when an EVA-standardised reference is wired in; the registry
    # is scheme-keyed precisely so a second standardisation philosophy slots in without touching `report`.
    :sternstewart => Dict{Tuple{String,String},String}(),
)

# Resolve `scheme = :auto` to the provider's standardisation scheme; pass any other value through verbatim.
_resolve_scheme(scheme::Symbol, p::FundamentalsProvider) = scheme === :auto ? default_scheme(p) : scheme

# The documented reason a (ticker, metric) may diverge under `scheme`, or `nothing`. `:none` → no registry.
function _scheme_reason(scheme::Symbol, ticker, metric)
    scheme === :none && return nothing
    reg = get(SCHEME_REGISTRY, scheme, nothing)
    reg === nothing && return nothing
    return get(reg, (String(ticker), String(metric)), nothing)
end

"""
    report(firms = default_firms(provider); provider=:yahoo, scheme=:auto) -> Bool

Run [`validate`](@ref) over a panel of filers, print each metric's EDGAR-vs-provider comparison grouped by
statement, and return whether there were no *unexpected* mismatches. Metrics the provider doesn't cover are
reported but not counted; documented standardisations in the [`SCHEME_REGISTRY`](@ref) for the resolved
`scheme` are flagged (`◑ documented`), annotated with their reason, and likewise not counted.

`scheme` defaults to `:none` — strict, exact matching where every mismatch counts (so a documented
standardisation gap shows as `✗ MISMATCH`). Pass `scheme = :morningstar` to apply the standardisation
registry (both Yahoo and AlphaVantage serve Morningstar-standardised fundamentals), `:sternstewart` for the
EVA scheme, or `:auto` to use the provider's `default_scheme`.
"""
function report(firms = nothing; provider::Symbol=:yahoo, scheme::Symbol=:none)
    p = _provider(provider)
    firms === nothing && (firms = default_firms(p))
    pname = provider_name(p)
    sch = _resolve_scheme(scheme, p)
    nfail = 0
    for (name, system, locator, ticker, jur) in firms
        println("\n", jur, "  ", name, "  [", system, "]")
        rows = try validate(system, locator, ticker; provider = provider, scheme = scheme) catch e; println("   ✗ ", e); nfail += 1; continue end
        isempty(rows) && (println("   ⏭  no EDGAR data"); continue)
        for r in rows
            tag = _ORACLE_STMT_LABEL[r.statement]
            if r.edgar === nothing
                @printf("   [%-15s] %-12s EDGAR: (none)\n", tag, r.metric)
            elseif r.reference === nothing
                @printf("   [%-15s] %-12s EDGAR %+.6g  @%s   %s: (none)\n", tag, r.metric, r.edgar, r.period_end, pname)
            else
                reason = r.match ? nothing : _scheme_reason(sch, ticker, r.metric)
                r.match || reason !== nothing || (nfail += 1)
                mark = r.match ? "✓" : reason !== nothing ? "◑ documented" : "✗ MISMATCH"
                @printf("   [%-15s] %-12s EDGAR %+.6g   %s %+.6g   Δ%.3f%%  %s\n",
                        tag, r.metric, r.edgar, pname, r.reference, 100r.rel_diff, mark)
                reason !== nothing && println("        └ ", reason)
            end
        end
    end
    @printf("\n%s cross-check (scheme=%s): %d unexpected mismatch(es)\n", pname, sch, nfail)
    return nfail == 0
end
