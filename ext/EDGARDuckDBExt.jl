# Package extension (Step 4.1): the DuckDB sink for EDGAR.jl facts. Loaded automatically
# when both EDGAR and DuckDB are in the session. Keeps DuckDB an optional dependency — the
# core package never loads it — while `EDGAR.to_duckdb` gains its real methods here.
#
# A `.duckdb` file becomes a small fact warehouse: the table is created on first use with
# a primary key on the natural fact key, and rows are appended with ON CONFLICT DO NOTHING,
# so re-importing a filing is idempotent. Export onward (Parquet/CSV/SQLite) is then native
# DuckDB (`COPY … TO`, `ATTACH … (TYPE SQLITE)`), so no extra sinks are needed.
module EDGARDuckDBExt

using EDGAR
using DuckDB
using DuckDB: DBInterface
using Dates

# Normalise the input to a fact row table (a Selection / many selections / rows already).
_rows(sel::EDGAR.Selection) = EDGAR.facts(sel)
_rows(sels::AbstractVector{<:EDGAR.Selection}) = EDGAR.facts(sels)
_rows(rows::AbstractVector{<:NamedTuple}) = rows

# The fact table DDL — the warehouse schema, matching EDGAR's FactRow. The primary key is
# the natural fact key, so ON CONFLICT DO NOTHING makes appends idempotent.
# The warehouse schema: ONE canonical facts table that every source maps into — the
# picker (`source='picker'`, with `context_ref`/`source_selector` provenance) and, later,
# the structured-data API (`company_facts`/`frames`, filling `form`/`fy`/`fp`/`frame`).
# Columns absent for a given source are NULL. `fact_key` is the source-agnostic identity
# (see `_fact_key`) and the primary key, so the same fact from two sources is one row.
function _ddl(table::AbstractString)
    return """
    CREATE TABLE IF NOT EXISTS $table (
      fact_key VARCHAR PRIMARY KEY,
      source VARCHAR,
      cik VARCHAR, accession VARCHAR, form VARCHAR, fy INTEGER, fp VARCHAR,
      statement VARCHAR, statements VARCHAR, concept VARCHAR, standard_concept VARCHAR, label VARCHAR,
      value DOUBLE, unit VARCHAR, period_start DATE, period_end DATE, is_instant BOOLEAN,
      dimensions VARCHAR, decimals INTEGER, frame VARCHAR,
      context_ref VARCHAR, unit_ref VARCHAR, source_selector VARCHAR
    )"""
end

# The source-agnostic identity of a fact: entity + filing + concept + unit + period +
# dimensions. The document-internal refs (`context_ref`/`unit_ref`) and the `source` are
# deliberately excluded, so the *same* fact picked from a rendered statement and loaded
# from the API dedups to a single warehouse row.
function _fact_key(r)
    ps = r.period_start === nothing ? "" : string(r.period_start)
    return join((r.cik, r.accession, r.concept, r.unit, ps, string(r.period_end),
                 string(r.is_instant), r.dimensions), "|")
end

_count(con, table) = first(DBInterface.execute(con, "SELECT count(*) AS n FROM $table")).n

# Reject anything but a plain SQL identifier for the table name (it is interpolated).
function _check_table(table::AbstractString)
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", table) ||
        throw(ArgumentError("table must be a simple identifier, got $(repr(table))"))
    return table
end

const _COLS = "fact_key, source, cik, accession, form, fy, fp, statement, statements, concept, " *
              "standard_concept, label, value, unit, period_start, period_end, is_instant, " *
              "dimensions, decimals, frame, context_ref, unit_ref, source_selector"

function _append!(con, table::AbstractString, rows; source::AbstractString="picker")
    _check_table(table)
    DBInterface.execute(con, _ddl(table))
    before = _count(con, table)
    stmt = DBInterface.prepare(con, "INSERT INTO $table ($_COLS) VALUES (" *
        join(fill("?", 23), ",") * ") ON CONFLICT DO NOTHING")
    try
        for r in rows
            DBInterface.execute(stmt, (_fact_key(r), source, r.cik, r.accession,
                missing, missing, missing,                 # form, fy, fp — API-only (NULL here)
                r.statement, get(r, :statements, "[]"), r.concept, something(r.standard_concept, missing),
                r.label, r.value, r.unit,
                something(r.period_start, missing), r.period_end, r.is_instant,
                r.dimensions, something(r.decimals, missing), missing,   # frame — API-only
                r.context_ref, r.unit_ref, r.source_selector))
        end
    finally
        DBInterface.close!(stmt)
    end
    return Int(_count(con, table) - before)
end

# ── Warehouse meta + the documents / extractions tables (W1) ────────────────
# One `.duckdb` holds all three layers, joinable by accession: `documents` (lossless iXBRL
# HTML), `extractions` (the Facts JSON snapshot of each pick), and `facts` (the rows).
const SCHEMA_VERSION = 3

function _ensure_meta(con)
    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS edgar_meta (key VARCHAR PRIMARY KEY, value VARCHAR)")
    DBInterface.execute(con, "INSERT INTO edgar_meta VALUES ('schema_version', '$SCHEMA_VERSION') ON CONFLICT DO NOTHING")
    return
end

const _DOCS_DDL = """
CREATE TABLE IF NOT EXISTS documents (
  cik VARCHAR, accession VARCHAR, document VARCHAR, url VARCHAR, kind VARCHAR,
  fetched_at TIMESTAMP, content VARCHAR,
  PRIMARY KEY (accession, document)
)"""

const _EXTR_DDL = """
CREATE TABLE IF NOT EXISTS extractions (
  cik VARCHAR, accession VARCHAR, selector VARCHAR, kind VARCHAR,
  created_at TIMESTAMP, facts_json VARCHAR,
  PRIMARY KEY (accession, selector)
)"""

# The selections behind a to_duckdb input (a Selection / many / none), whose Facts JSON
# snapshot is archived in `extractions` alongside the fact rows.
_selections(sel::EDGAR.Selection) = (sel,)
_selections(sels::AbstractVector{<:EDGAR.Selection}) = sels
_selections(::Any) = ()

# Archive each selection's Facts JSON (Layer 2) into `extractions`; picks without provenance
# (no accession) are skipped.
function _record_extractions!(con, sels)
    isempty(sels) && return
    DBInterface.execute(con, _EXTR_DDL)
    stmt = DBInterface.prepare(con, "INSERT INTO extractions VALUES (?,?,?,?,?,?) ON CONFLICT DO NOTHING")
    try
        for s in sels
            isempty(s.accession) && continue
            DBInterface.execute(stmt, (s.cik, s.accession, s.selector, String(s.kind),
                Dates.now(), EDGAR.facts_json(s)))
        end
    finally
        DBInterface.close!(stmt)
    end
    return
end

# Store a fetched Filing's lossless iXBRL/HTML document (Layer 1) in `documents`.
function _store_document!(con, f::EDGAR.Filing)
    DBInterface.execute(con, _DOCS_DDL)
    before = _count(con, "documents")
    DBInterface.execute(con, "INSERT INTO documents VALUES (?,?,?,?,?,?,?) ON CONFLICT DO NOTHING",
        (f.cik, f.accession, f.document, f.url, String(f.kind), Dates.now(), f.content))
    return Int(_count(con, "documents") - before)
end

# Append facts (a Selection / many / a row table) to the warehouse. For Selections, the Facts
# JSON snapshot is also archived in `extractions`. Returns the number of fact rows newly added.
function EDGAR.to_duckdb(data, con::DuckDB.DB; table::AbstractString="facts")
    _ensure_meta(con)
    _record_extractions!(con, _selections(data))
    return _append!(con, table, _rows(data))
end

function EDGAR.to_duckdb(data, path::AbstractString; table::AbstractString="facts")
    con = DBInterface.connect(DuckDB.DB, path)
    try
        return EDGAR.to_duckdb(data, con; table)
    finally
        DBInterface.close!(con)
    end
end

# Archive one filing: its document (Layer 1) and, when `with_facts`, its natively-extracted
# facts (tagged source='filing', W2) plus a filing-level Facts JSON snapshot in `extractions`.
# Returns (documents_added, facts_added).
function _archive_filing!(con, f::EDGAR.Filing, with_facts::Bool, classify::Bool, labels::Bool)
    nd = _store_document!(con, f)
    nf = 0
    if with_facts
        sel = EDGAR._filing_selection(f, EDGAR._extract_facts(f;
            statements = classify ? EDGAR.statement_map(f) : Dict{String,String}(),
            labels = labels ? EDGAR.label_map(f) : Dict{String,String}()))
        nf = _append!(con, "facts", EDGAR.facts(sel); source = "filing")
        _record_extractions!(con, (sel,))
    end
    return (nd, nf)
end

# Store a Filing's lossless document in `documents`. With `facts=true`, also extract and store
# its facts (source='filing') and a filing-level extraction; `classify=true` fills the
# `statement` column from the presentation linkbase, `labels=true` the `label` column from the
# label linkbase. Returns the documents added (0/1).
function EDGAR.to_duckdb(f::EDGAR.Filing, con::DuckDB.DB; table::AbstractString="documents",
                         facts::Bool=false, classify::Bool=false, labels::Bool=false)
    _ensure_meta(con)
    nd, _ = _archive_filing!(con, f, facts, classify, labels)
    return nd
end

function EDGAR.to_duckdb(f::EDGAR.Filing, path::AbstractString; table::AbstractString="documents",
                         facts::Bool=false, classify::Bool=false, labels::Bool=false)
    con = DBInterface.connect(DuckDB.DB, path)
    try
        return EDGAR.to_duckdb(f, con; facts, classify, labels)
    finally
        DBInterface.close!(con)
    end
end

# Bulk (W3): list a filer's filings, fetch each, and archive into the warehouse — one open
# connection reused across the run. Returns (filings, documents, facts). Failed fetches skip.
function EDGAR.archive_filings(cik, path::AbstractString; forms=nothing, startdate=nothing,
        enddate=nothing, facts::Bool=true, classify::Bool=false, labels::Bool=false,
        kind::Symbol=:auto, limit::Union{Nothing,Integer}=nothing)
    listing = EDGAR.filings_by_cik(cik; forms, startdate, enddate)
    limit === nothing || (listing = listing[1:min(Int(limit), length(listing))])
    con = DBInterface.connect(DuckDB.DB, path)
    nfil = 0; nd = 0; nf = 0
    try
        _ensure_meta(con)
        for row in listing
            local f
            try
                f = EDGAR.fetch_filing(cik, row.accession; kind)
            catch
                continue
            end
            d, ff = _archive_filing!(con, f, facts, classify, labels)
            nfil += 1; nd += d; nf += ff
        end
    finally
        DBInterface.close!(con)
    end
    return (filings = nfil, documents = nd, facts = nf)
end

# ── Pivot / statement view (Step 4.3) ───────────────────────────────────────
# Long fact rows -> a wide statement: rows per concept/label, a column per period_end.
# DuckDB's PIVOT statement cannot be prepared (its schema is dynamic) and DBInterface
# prepares every query, so we pivot by conditional aggregation instead — query the
# distinct periods, then build one `first(value) FILTER (WHERE period_end = …)` column per
# period. This is an ordinary preparable SELECT and is also clearer about the column order.

# A single-quoted SQL literal (the only values interpolated are dates from the DB and a
# validated accession, but quote-double defensively all the same).
_lit(s) = "'" * replace(string(s), "'" => "''") * "'"

function _statement_view(con, table, statement, accession, consolidated, months, by)
    _check_table(table)
    by in (:concept, :standard_concept) ||
        throw(ArgumentError("`by` must be :concept or :standard_concept, got $(repr(by))"))
    conds = String["true"]
    consolidated && push!(conds, "dimensions = '{}'")
    if accession !== nothing
        occursin(r"^[0-9A-Za-z-]+$", accession) ||
            throw(ArgumentError("invalid accession: $(repr(accession))"))
        push!(conds, "accession = $(_lit(accession))")
    end
    # Membership-aware: a fact belongs to `statement` if it is in the fact's full `statements` set
    # (multi-homed concepts), not only its primary `statement` — so e.g. the Equity view includes the
    # StockholdersEquity totals that are primarily tagged BalanceSheet. The OR keeps facts whose
    # `statements` is empty but whose primary matches (e.g. rows loaded without multi-classification).
    statement === nothing || push!(conds,
        "(statement = $(_lit(statement)) OR statements LIKE $(_lit("%\"" * statement * "\"%")))")
    # Smart period selection (W6): keep instants (no duration), and durations of ~`months`
    # months — so the 3-month and 9-month periods that share an end date do not collide in
    # one period_end column, and a consistent quarterly/annual view stitches across filings.
    months === nothing ||
        push!(conds, "(is_instant OR round(date_diff('day', period_start, period_end) / 30.44) = $(Int(months)))")
    by === :standard_concept && push!(conds, "standard_concept IS NOT NULL")
    where = join(conds, " AND ")
    keys = by === :standard_concept ? "standard_concept" :
           consolidated ? "concept, label" : "concept, label, dimensions"
    periods = [string(r.period_end) for r in
               DBInterface.execute(con, "SELECT DISTINCT period_end FROM $table WHERE $where ORDER BY period_end DESC")]
    if isempty(periods)
        return DuckDB.Tables.rowtable(DBInterface.execute(con, "SELECT $keys FROM $table WHERE false"))
    end
    # arg_max(value, accession): when a period is reported by several filings, take the value
    # from the latest-filed one (accessions sort chronologically) — deterministic, restatement-aware.
    cols = join(["arg_max(value, accession) FILTER (WHERE period_end = DATE $(_lit(p))) AS \"$p\"" for p in periods], ", ")
    sql = "SELECT $keys, $cols FROM $table WHERE $where GROUP BY $keys ORDER BY $keys"
    return DuckDB.Tables.rowtable(DBInterface.execute(con, sql))
end

EDGAR.statement_view(con::DuckDB.DB; table::AbstractString="facts", statement=nothing,
                     accession=nothing, consolidated::Bool=true, months=nothing, by::Symbol=:concept) =
    _statement_view(con, table, statement, accession, consolidated, months, by)

function EDGAR.statement_view(path::AbstractString; table::AbstractString="facts", statement=nothing,
                              accession=nothing, consolidated::Bool=true, months=nothing, by::Symbol=:concept)
    con = DBInterface.connect(DuckDB.DB, path)
    try
        return _statement_view(con, table, statement, accession, consolidated, months, by)
    finally
        DBInterface.close!(con)
    end
end

end # module
