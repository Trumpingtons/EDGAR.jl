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
        (f.entity.value, f.ref, f.document, f.url, String(f.kind), Dates.now(), f.content))
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

# ── Document repository (the document-first PDF pipeline) ───────────────────────────────────────
# Loads a StructuredDocument into the repository DB (docs/dev/pdf-repository-schema.md): documents /
# sections / text_blocks / tables / table_cells / figures (+ translations & facts stubs) and the
# referencing views. `bbox` is stored as JSON text (VARCHAR); `"tables"`, `"row"`, `"col"` are quoted
# (reserved-word-safe). SEPARATE DB file from the facts warehouse above (default
# `~/RegulatoryReports/regulatory-reports.duckdb`), so the differently-shaped `documents` table never clashes.
const _REPO_DDL = [
  """CREATE TABLE IF NOT EXISTS documents (doc_id VARCHAR PRIMARY KEY, source_path VARCHAR,
     jurisdiction VARCHAR, filing_system VARCHAR, language VARCHAR, company VARCHAR, report_type VARCHAR,
     fiscal_year INTEGER, currency VARCHAR, framework VARCHAR, n_pages INTEGER, parser VARCHAR,
     parser_version VARCHAR, ocr BOOLEAN, ingested_at TIMESTAMP)""",
  """CREATE TABLE IF NOT EXISTS sections (section_id VARCHAR PRIMARY KEY, doc_id VARCHAR,
     parent_id VARCHAR, level INTEGER, title VARCHAR, lang VARCHAR, ord INTEGER, page_start INTEGER,
     page_end INTEGER, bbox VARCHAR)""",
  """CREATE TABLE IF NOT EXISTS text_blocks (block_id VARCHAR PRIMARY KEY, doc_id VARCHAR,
     section_id VARCHAR, ord INTEGER, kind VARCHAR, text VARCHAR, lang VARCHAR, page INTEGER,
     bbox VARCHAR, char_len INTEGER)""",
  """CREATE TABLE IF NOT EXISTS "tables" (table_id VARCHAR PRIMARY KEY, doc_id VARCHAR,
     section_id VARCHAR, ord INTEGER, kind VARCHAR, statement_type VARCHAR, caption VARCHAR,
     lang VARCHAR, page_start INTEGER, page_end INTEGER, bbox VARCHAR, n_rows INTEGER, n_cols INTEGER,
     csv_path VARCHAR)""",
  """CREATE TABLE IF NOT EXISTS table_cells (table_id VARCHAR, "row" INTEGER, "col" INTEGER,
     rowspan INTEGER, colspan INTEGER, is_header BOOLEAN, text VARCHAR,
     PRIMARY KEY (table_id, "row", "col"))""",
  """CREATE TABLE IF NOT EXISTS figures (figure_id VARCHAR PRIMARY KEY, doc_id VARCHAR,
     section_id VARCHAR, ord INTEGER, caption VARCHAR, page INTEGER, bbox VARCHAR, image_path VARCHAR,
     image_format VARCHAR, width INTEGER, height INTEGER)""",
  """CREATE TABLE IF NOT EXISTS translations (object_type VARCHAR, object_id VARCHAR,
     target_lang VARCHAR, text VARCHAR, source VARCHAR, model VARCHAR, created_at TIMESTAMP,
     PRIMARY KEY (object_type, object_id, target_lang))""",
  """CREATE TABLE IF NOT EXISTS facts (fact_id VARCHAR PRIMARY KEY, doc_id VARCHAR, table_id VARCHAR,
     "row" INTEGER, "col" INTEGER, section_id VARCHAR, statement_type VARCHAR, label VARCHAR,
     concept VARCHAR, standard_concept VARCHAR, period_start DATE, period_end DATE, is_instant BOOLEAN,
     value DOUBLE, unit VARCHAR, scale DOUBLE, sign INTEGER, decimals INTEGER, extractor VARCHAR,
     confidence DOUBLE, bbox VARCHAR)""",
  """CREATE TABLE IF NOT EXISTS toc (doc_id VARCHAR, seq INTEGER, level INTEGER, title VARCHAR,
     page INTEGER, PRIMARY KEY (doc_id, seq))""",
]
const _REPO_VIEWS = [
  """CREATE OR REPLACE VIEW v_cell_context AS
     SELECT c.table_id, c."row", c."col", c.is_header, c.text, t.doc_id, t.section_id,
            t.kind AS table_kind, t.statement_type, t.page_start AS page
     FROM table_cells c JOIN "tables" t USING (table_id)""",
  """CREATE OR REPLACE VIEW v_section_path AS
     WITH RECURSIVE p(section_id, doc_id, path) AS (
       SELECT section_id, doc_id, title FROM sections WHERE parent_id IS NULL
       UNION ALL
       SELECT s.section_id, s.doc_id, p.path || ' > ' || s.title
       FROM sections s JOIN p ON s.parent_id = p.section_id)
     SELECT section_id, doc_id, path FROM p""",
  """CREATE OR REPLACE VIEW v_fact_provenance AS
     SELECT f.fact_id, f.doc_id, f.label, f.value, f.statement_type, f.table_id, f."row", f."col",
            f.section_id, sp.path AS section_path, f.bbox
     FROM facts f LEFT JOIN v_section_path sp USING (section_id)""",
]

_n(x) = x === nothing ? missing : x
_bj(::Nothing) = missing
_bj(b::EDGAR.BBox) = string("{\"page\":", b.page, ",\"x0\":", b.x0, ",\"y0\":", b.y0,
                            ",\"x1\":", b.x1, ",\"y1\":", b.y1, "}")
_csvpath(table_id) = string("tables/", split(table_id, ":")[end], ".csv")

function _ensure_repo(con)
    for ddl in _REPO_DDL
        DBInterface.execute(con, ddl)
    end
    for v in _REPO_VIEWS
        DBInterface.execute(con, v)
    end
end

function _load_doc!(con, sd::EDGAR.StructuredDocument)
    doc = sd.document.doc_id
    DBInterface.execute(con, "BEGIN TRANSACTION")
    try
        DBInterface.execute(con,
            "DELETE FROM table_cells WHERE table_id IN (SELECT table_id FROM \"tables\" WHERE doc_id = ?)", (doc,))
        for t in ("facts", "figures", "\"tables\"", "text_blocks", "sections", "toc", "documents")
            DBInterface.execute(con, "DELETE FROM $t WHERE doc_id = ?", (doc,))
        end
        m = sd.document
        DBInterface.execute(con, "INSERT INTO documents VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (m.doc_id, m.source_path, _n(m.jurisdiction), _n(m.filing_system), _n(m.language),
             _n(m.company), _n(m.report_type), _n(m.fiscal_year), _n(m.currency), _n(m.framework),
             m.n_pages, m.parser, m.parser_version, m.ocr, Dates.now()))
        ss = DBInterface.prepare(con, "INSERT INTO sections VALUES (?,?,?,?,?,?,?,?,?,?)")
        for s in sd.sections
            DBInterface.execute(ss, (s.section_id, doc, _n(s.parent_id), s.level, s.title, s.lang,
                s.ord, s.page_start, s.page_end, _bj(s.bbox)))
        end
        DBInterface.close!(ss)
        tx = DBInterface.prepare(con, "INSERT INTO text_blocks VALUES (?,?,?,?,?,?,?,?,?,?)")
        for t in sd.text_blocks
            DBInterface.execute(tx, (t.block_id, doc, _n(t.section_id), t.ord, t.kind, t.text, t.lang,
                t.page, _bj(t.bbox), t.char_len))
        end
        DBInterface.close!(tx)
        tb = DBInterface.prepare(con, "INSERT INTO \"tables\" VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
        cc = DBInterface.prepare(con, "INSERT INTO table_cells VALUES (?,?,?,?,?,?,?)")
        ncells = 0
        for t in sd.tables
            DBInterface.execute(tb, (t.table_id, doc, _n(t.section_id), t.ord, t.kind,
                _n(t.statement_type), _n(t.caption), t.lang, t.page_start, t.page_end, _bj(t.bbox),
                t.n_rows, t.n_cols, _csvpath(t.table_id)))
            for c in t.cells
                DBInterface.execute(cc, (t.table_id, c.row, c.col, c.rowspan, c.colspan, c.is_header, c.text))
                ncells += 1
            end
        end
        DBInterface.close!(tb); DBInterface.close!(cc)
        fg = DBInterface.prepare(con, "INSERT INTO figures VALUES (?,?,?,?,?,?,?,?,?,?,?)")
        for f in sd.figures
            DBInterface.execute(fg, (f.figure_id, doc, _n(f.section_id), f.ord, _n(f.caption), f.page,
                _bj(f.bbox), _n(f.image_path), _n(f.image_format), _n(f.width), _n(f.height)))
        end
        DBInterface.close!(fg)
        tc = DBInterface.prepare(con, "INSERT INTO toc VALUES (?,?,?,?,?)")
        for (i, e) in enumerate(sd.toc)
            DBInterface.execute(tc, (doc, i, e.level, e.title, e.page))
        end
        DBInterface.close!(tc)
        DBInterface.execute(con, "COMMIT")
        return (sections = length(sd.sections), text_blocks = length(sd.text_blocks),
                tables = length(sd.tables), table_cells = ncells, figures = length(sd.figures),
                toc = length(sd.toc))
    catch e
        DBInterface.execute(con, "ROLLBACK")
        rethrow(e)
    end
end

EDGAR.to_repository(sd::EDGAR.StructuredDocument, con::DuckDB.DB) = (_ensure_repo(con); _load_doc!(con, sd))

function EDGAR.to_repository(sd::EDGAR.StructuredDocument,
        db::AbstractString = joinpath(expanduser("~/RegulatoryReports"), "regulatory-reports.duckdb"))
    mkpath(dirname(db))
    con = DBInterface.connect(DuckDB.DB, db)
    try
        return EDGAR.to_repository(sd, con)
    finally
        DBInterface.close!(con)
    end
end

# Convenience: load straight from a persisted structured.json (no PythonCall needed).
EDGAR.to_repository(path::AbstractString, db::AbstractString) =
    EDGAR.to_repository(EDGAR.read_structured_document(path), db)

# ── Table classification pass (set tables.kind / statement_type) ─────────────────────────────────
# Match each table's caption (falling back to its enclosing section title) against the open TABLE_CLASSES
# registry. A first cut on heading text; numeric-density / largest-table-in-section refinement is a later step.
function EDGAR.classify_tables!(con::DuckDB.DB; doc_id = nothing)
    tsql = "SELECT t.table_id AS table_id, t.doc_id AS doc_id, t.page_start AS page, t.ord AS ord, " *
           "t.caption AS caption, s.title AS title FROM \"tables\" t " *
           "LEFT JOIN sections s ON t.section_id = s.section_id" *
           (doc_id === nothing ? "" : " WHERE t.doc_id = ?")
    trows = DuckDB.Tables.rowtable(doc_id === nothing ? DBInterface.execute(con, tsql) :
                                                        DBInterface.execute(con, tsql, (doc_id,)))
    # heading-ish (short) text blocks, to recover a statement title the page-header may have masked
    bsql = "SELECT doc_id, page, ord, text FROM text_blocks WHERE char_len < 140" *
           (doc_id === nothing ? "" : " AND doc_id = ?")
    brows = DuckDB.Tables.rowtable(doc_id === nothing ? DBInterface.execute(con, bsql) :
                                                        DBInterface.execute(con, bsql, (doc_id,)))
    csql = "SELECT doc_id, page, title FROM toc" * (doc_id === nothing ? "" : " WHERE doc_id = ?")
    crows = DuckDB.Tables.rowtable(doc_id === nothing ? DBInterface.execute(con, csql) :
                                                        DBInterface.execute(con, csql, (doc_id,)))
    byp = Dict{Tuple{String,Int},Vector{Tuple{Int,String}}}()
    for b in brows
        (b.text === missing || b.page === missing) && continue
        push!(get!(byp, (b.doc_id, b.page), Tuple{Int,String}[]), (b.ord, String(b.text)))
    end
    toc = Dict{String,Vector{Tuple{Int,String}}}()         # doc_id -> sorted (page, title)
    for c in crows
        (c.title === missing || c.page === missing) && continue
        push!(get!(toc, c.doc_id, Tuple{Int,String}[]), (c.page, String(c.title)))
    end
    for v in values(toc); sort!(v; by = first); end
    function nearest_toc(d, page)                            # the outline entry covering this page
        best = nothing
        for (p, ttl) in get(toc, d, Tuple{Int,String}[])
            p <= page ? (best = ttl) : break
        end
        return best
    end
    # a table's own leading cells — fund statements carry their title in cell (0,0) rather than a heading
    hsql = "SELECT c.table_id AS table_id, c.text AS text FROM table_cells c JOIN \"tables\" t USING (table_id) " *
           "WHERE c.\"row\" <= 1 AND c.\"col\" = 0" * (doc_id === nothing ? "" : " AND t.doc_id = ?")
    hrows = DuckDB.Tables.rowtable(doc_id === nothing ? DBInterface.execute(con, hsql) :
                                                        DBInterface.execute(con, hsql, (doc_id,)))
    firstcell = Dict{String,Vector{String}}()
    for h in hrows
        h.text === missing && continue
        push!(get!(firstcell, h.table_id, String[]), String(h.text))
    end
    upd = DBInterface.prepare(con, "UPDATE \"tables\" SET kind = ?, statement_type = ? WHERE table_id = ?")
    counts = Dict{String,Int}()
    try
        for t in trows
            cand = String[]
            t.caption === missing || push!(cand, String(t.caption))
            t.title   === missing || push!(cand, String(t.title))
            # the nearest 2 preceding short blocks on the same page (the visual heading)
            blks = get(byp, (t.doc_id, t.page), Tuple{Int,String}[])
            prec = sort([b for b in blks if b[1] < t.ord]; by = first, rev = true)
            for b in first(prec, 2)
                push!(cand, b[2])
            end
            # the PDF-outline entry covering this page (authoritative; immune to page-header noise)
            tt = nearest_toc(t.doc_id, t.page); tt === nothing || push!(cand, tt)
            # the table's own leading cells (fund statements put their title in cell (0,0))
            for x in get(firstcell, t.table_id, String[])
                push!(cand, x)
            end
            st = EDGAR.classify_table_class(join(cand, " | "))
            kind = st === nothing ? "descriptive" : "statement"
            DBInterface.execute(upd, (kind, st === nothing ? missing : st, t.table_id))
            k = st === nothing ? "descriptive" : st
            counts[k] = get(counts, k, 0) + 1
        end
    finally
        DBInterface.close!(upd)
    end
    return counts
end

function EDGAR.classify_tables!(
        db::AbstractString = joinpath(expanduser("~/RegulatoryReports"), "regulatory-reports.duckdb");
        doc_id = nothing)
    con = DBInterface.connect(DuckDB.DB, db)
    try
        return EDGAR.classify_tables!(con; doc_id = doc_id)
    finally
        DBInterface.close!(con)
    end
end

end # module
