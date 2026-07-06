# Russia (MOEX / CBR / e-Disclosure, RAS) FilingSystem — the 9th FilingSystem, and the FIRST whose "filing"
# is a STRUCTURED DATASET ROW rather than a fetched document. Russian corporate disclosure has no single
# keyless portal: the canonical primary agency (Interfax's e-disclosure.ru) is behind a ServicePipe
# JavaScript anti-bot gate, so identity and facts are assembled from the doors that ARE open. The MVP is
# route 1 — the RFSD (Russian Financial Statements Database), an open, CC-BY-4.0 firm-level Parquet
# collection of the whole NON-FINANCIAL universe's unconsolidated RAS (РСБУ) statements, keyed by INN.
#
# Because RFSD is a year-partitioned Parquet panel, a "filing" is one (inn, year) row and "fetch" is a
# DuckDB query — not an HTTP document GET. There is no PDF extraction, no XBRL parse and no label vocabulary:
# the 187 numeric OKUD `line_XXXX` codes ARE the taxonomy, so classification (route-1 R3) is a static
# numeric code map (`vocab_ras`). Identity comes from the open, keyless MOEX ISS securities API
# (name/ticker → `emitent_inn`); DuckDB (already a dependency) is the data backend. See
# docs/dev/russia-plan.md and the manual chapter `sys:russia`.
#
# This file is R0 — the SEAM only: the `FilingSystem` type, its credential tag and its HTTP headers, so
# `using EDGAR` loads clean. RFSD discovery (R2, the `RFSDFilings` source: MOEX resolver + DuckDB partition
# query, both point and population modes) and the row → `FactRow` structured-fact path (R1) with `vocab_ras`
# classification (R3) come next; route 2 (CBR bank Forms 101/102) is a separate, later plan.

"""
    Russia <: FilingSystem

Russia's corporate-disclosure system, reached through **route 1 — the RFSD** (Russian Financial Statements
Database): an open, CC-BY-4.0, firm-level **Parquet** panel of the whole **non-financial** universe's
**unconsolidated RAS (РСБУ)** statements, 2011–2024, keyed by the **INN** (taxpayer number). Unlike every
prior [`FilingSystem`](@ref), a Russian "filing" is a **structured dataset row** — one `(inn, year)` — not a
fetched document: discovery resolves a name/ticker to an INN through the keyless **MOEX ISS** API (or takes a
direct INN, or a *population* cohort by sector / region / legal form / ownership), and a filing is read from
the year-partitioned Parquet with **DuckDB**. The 187 numeric OKUD `line_XXXX` codes serve as the taxonomy,
so facts need neither a PDF extractor nor an XBRL parser.

Access is **keyless** — MOEX ISS and the RFSD dataset are both open; only a browser User-Agent is sent.
Identity is `EntityId(:inn, "7707083893")`. Discover with `RFSDFilings` (planned, R2); the financial sector
(banks, insurers) is out of RFSD by law and is a later CBR route.
"""
struct Russia <: FilingSystem end

# Credentials-registry key. Russia needs no API key (MOEX ISS and RFSD are both open), but a tag keeps it
# uniform with the other systems and lets `set_credentials`/`get_credential` work if ever needed.
system_tag(::Russia) = :russia

# A realistic desktop-browser User-Agent. MOEX ISS (iss.moex.com) and the HuggingFace-hosted RFSD Parquet
# both serve fine to a plain browser UA — no key, no cookie, no Referer. An explicit `headers` vector also
# replaces `fetch_url`'s default SEC User-Agent, which is what a non-SEC system wants.
const _RUSSIA_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " *
                   "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

# MOEX ISS host (used from R2): the open, keyless Informational & Statistical Server that resolves a company
# name or ticker to its `secid` / ISIN / `emitent_inn` (the INN that keys RFSD). https is required.
const _MOEX_ISS_BASE = "https://iss.moex.com"

system_headers(::Russia) = ["User-Agent"      => _RUSSIA_UA,
                            "Accept"          => "application/json, text/plain, */*",
                            "Accept-Language" => "en-US,en;q=0.9"]

# ── R1: RFSD structured-row facts ────────────────────────────────────────────────────────────────
#
# A Russian route-1 "filing" is one (inn, year) RFSD row, carried as JSON in `Filing.content` (kind
# `:ras`; produced by the DuckDB fetch path in R2, or read from an offline fixture here). The JSON is
# `{inn, year, okved, …, flags:{…}, lines:{line_XXXX => value}}`. Each non-null OKUD `line_XXXX` cell
# becomes one `Fact`:
#   • RAS/OKUD statements are filed in THOUSANDS of rubles (в тыс. руб.), so values are scaled ×1000 to
#     rubles and `decimals = -3` records the thousand-ruble precision.
#   • The leading digit of the code fixes the statement family and period type — `1xxx` = balance sheet
#     (an INSTANT, as-of 31 Dec); `2/3/4/6xxx` = income / equity / cash-flow / targeted-funds (a
#     DURATION over the reporting year). Some codes are aggregates with a trailing letter (`line_321x`).
# The concept is the raw `ras:line_XXXX` code. `_ras_period` (vocab_ras) gives each fact's period type and
# span — an instant for balance-sheet and equity-balance lines, a duration otherwise, with the equity
# statement's prior-year comparatives stamped at the correct earlier year-ends. Under `classify`,
# `_ras_statement` fills `statement` from the code's OKUD family (1xxx→BalanceSheet, 2xxx→IncomeStatement,
# 3xxx→Equity, 4xxx→CashFlow, 6xxx→TargetedFunds); under `labels`, `ras_label` fills the English label.
function _rfsd_facts(f::Filing; classify::Bool=false, labels::Bool=false)
    doc = JSON3.read(f.content)
    inn = String(doc.inn)
    yr  = Int(doc.year)
    out = Fact[]
    for (k, v) in pairs(doc.lines)
        v === nothing && continue
        code = String(k)
        inst, pstart, pend = _ras_period(code, yr)
        stmt = classify ? _ras_statement(code) : ""
        push!(out, Fact(; concept = "ras:$code", value = Float64(v) * 1000.0, unit = "RUB",
                        cik = inn, accession = f.ref, period_end = pend, period_start = pstart,
                        is_instant = inst, decimals = -3, statement = stmt,
                        statements = isempty(stmt) ? String[] : [stmt],
                        label = labels ? ras_label(code) : ""))
    end
    return [fact_row(fc) for fc in out]
end

# ── R2: the RFSD fetch is a DuckDB query (weakdep) ───────────────────────────────────────────────
#
# `fetch_filing(::Russia, h)` reads one (inn, year) row from the year-partitioned RFSD parquet with
# DuckDB. DuckDB is an OPTIONAL dependency (the `EDGARDuckDBExt` package extension), so the real query
# method — `_rfsd_query(parquet_url, inn, year) -> JSON String` (the `:ras` filing content) — lives in
# that extension and is available once `using DuckDB` has loaded it. This core stub is a catch-all
# fallback (`args...`, strictly less specific than the extension's typed method, so the extension adds
# rather than overwrites — the same weakdep pattern as `to_duckdb`); it explains the need when unloaded.
_rfsd_query(args...) =
    error("fetch_filing(::Russia, …) needs DuckDB.jl to read the RFSD parquet — run `using DuckDB` " *
          "to load the RFSD reader (the EDGARDuckDBExt extension).")

# Weakdep (R2b): a POPULATION `discover` — a cohort selected by RFSD dimension columns (sector, region,
# legal form, ownership) — must scan the parquet to enumerate matching INNs, so unlike the point path
# (MOEX, HTTP-only) it needs DuckDB. `_rfsd_discover(url, dims, predicates, limit) -> Vector{String}` (the
# matching INNs) is the real method in EDGARDuckDBExt; this catch-all stub explains the need when unloaded.
_rfsd_discover(args...) =
    error("population discover(RFSDFilings(); okved=…, region=…, …) needs DuckDB.jl to scan the RFSD " *
          "parquet — run `using DuckDB` to load the RFSD reader (the EDGARDuckDBExt extension).")

# Weakdep (R2c, bulk): the batch fetch — read MANY (inn, year) rows in one scan — and the download-once
# cache (a DuckDB `COPY` of a remote partition to a local parquet). Real methods in EDGARDuckDBExt.
#   `_rfsd_query_many(src, inns, year) -> Dict{String,String}`  (inn => :ras JSON) — one `WHERE inn IN (…)`.
#   `_rfsd_download(remote_url, dest)`                          — COPY the partition to a local file.
_rfsd_query_many(args...) =
    error("batch fetch_filing(::Russia, handles) needs DuckDB.jl — run `using DuckDB` (EDGARDuckDBExt).")
_rfsd_download(args...) =
    error("rfsd_download needs DuckDB.jl to copy the RFSD partition — run `using DuckDB` (EDGARDuckDBExt).")

# ── R4: data-quality flags — exclude author-flagged anomalies by default ─────────────────────────
#
# The RFSD authors manually flag ~436 firms (1,130 firm-years) whose statements are anomalous (e.g. revenue
# many times Gazprom's) and RECOMMEND excluding them (`outlier=1`). So `fetch_filing(::Russia, …)` DROPS
# such rows by default (point → error; batch → skip), overridable with `allow_outliers=true`; population
# `discover` already filters them in SQL. `rfsd_flags` exposes the quality flags off a fetched `:ras` filing.

"""
    rfsd_flags(f::Filing) -> NamedTuple

The RFSD data-quality flags carried by a Russian `:ras` [`Filing`](@ref), each `true` / `false` / `missing`:
`outlier` (author-flagged anomalous — excluded by [`fetch_filing`](@ref) unless `allow_outliers=true`),
`articulated` (statement lines sum to their subtotals), `totals_adjustment` (a wrong stated total was
repaired to the calculated one), `filed`, `eligible`, `imputed` (reconstructed from adjacent years),
`simplified` (abbreviated form), `financial`. The `articulated` and `totals_adjustment` flags are
reliability signals (a filer whose own statements do not reconcile), useful e.g. for credit analysis.
"""
function rfsd_flags(f::Filing)
    f.kind === :ras || throw(ArgumentError("rfsd_flags: not a Russian :ras filing (kind = $(repr(f.kind)))"))
    fl = JSON3.read(f.content).flags
    g(k) = (v = get(fl, k, nothing); v === nothing ? missing : v == 1)
    return (outlier = g(:outlier), articulated = g(:articulated), totals_adjustment = g(:totals_adjustment),
            filed = g(:filed), eligible = g(:eligible), imputed = g(:imputed),
            simplified = g(:simplified), financial = g(:financial))
end

# True iff the :ras JSON content is flagged `outlier` (anomalous) — the fetch-time exclusion predicate.
_rfsd_json_outlier(json::AbstractString) = get(JSON3.read(json).flags, :outlier, nothing) == 1
