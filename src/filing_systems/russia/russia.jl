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
# Statement/label classification (the OKUD code → concept map, `vocab_ras`) is R3; here `statement` and
# `label` stay empty and the concept is the raw `ras:line_XXXX` code. `classify`/`labels` are accepted
# for signature parity with the XBRL/PDF paths and are no-ops until R3.

# "line_1XXX" (a balance-sheet line) is an instant; every other family is a duration.
_ras_is_instant(code::AbstractString) = ncodeunits(code) ≥ 6 && codeunit(code, 6) == UInt8('1')

function _rfsd_facts(f::Filing; classify::Bool=false, labels::Bool=false)
    doc    = JSON3.read(f.content)
    inn    = String(doc.inn)
    yr     = Int(doc.year)
    pend   = Date(yr, 12, 31)
    pstart = Date(yr, 1, 1)
    out    = Fact[]
    for (k, v) in pairs(doc.lines)
        v === nothing && continue
        code = String(k)
        inst = _ras_is_instant(code)
        push!(out, Fact(; concept = "ras:$code", value = Float64(v) * 1000.0, unit = "RUB",
                        cik = inn, accession = f.ref, period_end = pend,
                        period_start = inst ? nothing : pstart, is_instant = inst, decimals = -3))
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
