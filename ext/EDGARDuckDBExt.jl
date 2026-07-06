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
     csv_path VARCHAR, currency VARCHAR, scale DOUBLE)""",   # currency/scale are table-invariant; facts inherit
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
     note_ref VARCHAR, concept VARCHAR, standard_concept VARCHAR, period_start DATE, period_end DATE,
     is_instant BOOLEAN, fiscal_year INTEGER, period_precision VARCHAR,
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
    # migrations for DBs created before a column existed (idempotent)
    for col in ("fiscal_year INTEGER", "period_precision VARCHAR", "note_ref VARCHAR")
        DBInterface.execute(con, "ALTER TABLE facts ADD COLUMN IF NOT EXISTS $col")
    end
    for col in ("currency VARCHAR", "scale DOUBLE")
        DBInterface.execute(con, "ALTER TABLE \"tables\" ADD COLUMN IF NOT EXISTS $col")
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
        tb = DBInterface.prepare(con, "INSERT INTO \"tables\" (table_id, doc_id, section_id, ord, kind, " *
            "statement_type, caption, lang, page_start, page_end, bbox, n_rows, n_cols, csv_path) " *
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)")   # currency/scale left NULL (detection deferred)
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

# Financial-statements SECTION headings in the bookmark TOC, multilingual (consolidated + parent/company
# accounts). Used to confine primary-statement detection to those page ranges — the structural discriminator
# that separates a real statement from its echo elsewhere (e.g. a German management report's `Ertragslage`).
const _FS_SECTION = r"financial statements|konzernabschluss|jahresabschluss|comptes consolid|comptes annuels|états financiers|bilancio consolidato|bilancio d.esercizio|bilancio separato|estados financ|cuentas anuales|demonstrações financ|财务报表|連結財務諸表|財務諸表|計算書類|재무제표|финансов[ао][яй] отч"i
const _FS_NOTNOTE = r"\bnotes?\b|anhang|附注|注記|주석|примечани"i

# Notes-SECTION headings (the block of notes that follows the primary statements), multilingual. Marks the
# notes boundary: within an FS section the statements come first, then the notes start here.
const _NOTES_SEC = r"notes to the|notes to consolidated|notes forming part|\bnotes to\b|konzernanhang|\banhang\b|note al bilancio|note illustrative|note esplicative|nota integrativa|notes annexes|annexe aux comptes|notas a los|notas explicativas|注記|주석|примечания к|附注"i

# Notes-section boundary page(s) per doc, from the bookmark TOC (sorted). A table at/after the boundary
# within its FS section is a note, not a statement.
function _notes_pages(con, doc_id)
    sql = "SELECT doc_id, title, page FROM toc" *
          (doc_id === nothing ? "" : " WHERE doc_id = ?") * " ORDER BY doc_id, seq"
    rows = DuckDB.Tables.rowtable(doc_id === nothing ? DBInterface.execute(con, sql) :
                                                       DBInterface.execute(con, sql, (doc_id,)))
    out = Dict{String,Vector{Int}}()
    for r in rows
        (r.title === missing || r.page === missing) && continue
        occursin(_NOTES_SEC, String(r.title)) && push!(get!(out, r.doc_id, Int[]), r.page)
    end
    for v in values(out); sort!(v); end
    return out
end

# Page ranges of the financial-statements section(s) per doc, from the bookmark TOC: each FS-matching entry
# spans until the next bookmark at the same-or-higher level. Overlapping/adjacent ranges are merged. Empty
# for docs without bookmarks (→ no confinement, the classifier falls back to caption/heading alone).
function _fs_ranges(con, doc_id)
    sql = "SELECT doc_id, level, title, page FROM toc" *
          (doc_id === nothing ? "" : " WHERE doc_id = ?") * " ORDER BY doc_id, seq"
    rows = DuckDB.Tables.rowtable(doc_id === nothing ? DBInterface.execute(con, sql) :
                                                       DBInterface.execute(con, sql, (doc_id,)))
    bydoc = Dict{String,Vector{Any}}()
    for r in rows; push!(get!(bydoc, r.doc_id, []), r); end
    out = Dict{String,Vector{Tuple{Int,Int}}}()
    for (doc, toc) in bydoc
        rng = Tuple{Int,Int}[]
        for (i, e) in enumerate(toc)
            (e.title === missing || e.page === missing) && continue
            (occursin(_FS_SECTION, String(e.title)) && !occursin(_FS_NOTNOTE, String(e.title))) || continue
            endp = typemax(Int)
            for j in i+1:length(toc)
                (toc[j].page !== missing && toc[j].level <= e.level) && (endp = toc[j].page - 1; break)
            end
            push!(rng, (e.page, endp))
        end
        sort!(rng)
        merged = Tuple{Int,Int}[]
        for r in rng
            (!isempty(merged) && r[1] <= merged[end][2] + 1) ?
                (merged[end] = (merged[end][1], max(merged[end][2], r[2]))) : push!(merged, r)
        end
        isempty(merged) || (out[doc] = merged)
    end
    return out
end

# Per-statement TOC anchors: when a bookmark entry's title names a specific statement ("Bilan consolidé",
# "①連結財政状態計算書", "Statement of Operations"), it anchors that statement TYPE to its page. Returns
# `doc => (page => statement_type)`. Authoritative — used to confirm/assign the type for the table there.
function _toc_anchors(con, doc_id)
    sql = "SELECT doc_id, title, page FROM toc" *
          (doc_id === nothing ? "" : " WHERE doc_id = ?") * " ORDER BY doc_id, seq"
    rows = DuckDB.Tables.rowtable(doc_id === nothing ? DBInterface.execute(con, sql) :
                                                       DBInterface.execute(con, sql, (doc_id,)))
    out = Dict{String,Dict{Int,String}}()
    for r in rows
        (r.title === missing || r.page === missing) && continue
        st = EDGAR.classify_table_class(String(r.title))
        (st === nothing || st == "fund_portfolio") && continue
        get!(out, r.doc_id, Dict{Int,String}())[r.page] = st
    end
    return out
end

# ── Table classification pass (set tables.kind / statement_type) ─────────────────────────────────
# Match each table's caption (falling back to its enclosing section title) against the open TABLE_CLASSES
# registry, confined — when the bookmark TOC marks them — to the financial-statements section(s), and with
# the type overridden by a per-statement TOC anchor on the table's page where one exists.
function EDGAR.classify_tables!(con::DuckDB.DB; doc_id = nothing)
    fsr = _fs_ranges(con, doc_id)
    anchors = _toc_anchors(con, doc_id)
    nbs = _notes_pages(con, doc_id)
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
    found = Dict{String,Set{String}}()          # derivable statement types classified, per doc (for the K check)
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
            # A NOTE table stays DESCRIPTIVE, never a primary statement (it's kept, not removed): its own
            # caption / section title says "Notes to …" or starts with a note number ("24. Lease liabilities",
            # "30. Notes to the cash flow statement"). Primary statements are titled, never numbered, so this
            # only filters notes — and stops them polluting the statement facts (e.g. CF note rows). The note
            # reference per line item is still captured on each fact via `note_ref`.
            rng = get(fsr, t.doc_id, Tuple{Int,Int}[])
            has_fs = !isempty(rng)
            in_fs = has_fs && t.page !== missing && any(r -> r[1] <= t.page <= r[2], rng)
            own = String[String(x) for x in (t.caption, t.title) if x !== missing]
            # "notes to …" is always a note; a leading note-number ("24. Lease liabilities") marks a note ONLY
            # OUTSIDE the FS section — inside it the statements are numbered too (Siemens' "1. Konzern-Gewinn-
            # und Verlustrechnung", "2. Bilanz"), so there we trust the class match instead.
            isnote = any(s -> occursin(r"\bnotes?\s+to\b"i, s) ||
                              (!in_fs && occursin(r"^\s*\d{1,3}\s*[.\)]", s)), own)
            st = isnote ? nothing : EDGAR.classify_table_class(join(cand, " | "))
            # TOC confinement: when the bookmarks mark the FS section(s), a table outside every FS range
            # cannot be a primary statement (excludes management-report / front-half echoes).
            (st !== nothing && has_fs && !in_fs) && (st = nothing)
            # Notes-section boundary: within its FS section the statements come first, then the notes — a
            # table at/after the notes boundary (that starts within the same FS range) is a note, not a
            # statement (catches note tables sitting inside the FS section, after the statements).
            if st !== nothing && in_fs && t.page !== missing
                cr = findfirst(r -> r[1] <= t.page <= r[2], rng)
                cr === nothing || any(nb -> rng[cr][1] <= nb <= t.page, get(nbs, t.doc_id, Int[])) &&
                    (st = nothing)
            end
            # Per-statement TOC anchor: when a bookmark names the statement on this exact page, that type is
            # authoritative — it confirms the type and recovers statements whose caption didn't match.
            if t.page !== missing
                anc = get(get(anchors, t.doc_id, Dict{Int,String}()), t.page, nothing)
                anc === nothing || (st = anc)
            end
            kind = st === nothing ? "descriptive" : something(EDGAR.table_class_kind(st), "statement")
            DBInterface.execute(upd, (kind, st === nothing ? missing : st, t.table_id))
            k = st === nothing ? "descriptive" : st
            counts[k] = get(counts, k, 0) + 1
            st in _DERIVABLE_ST && push!(get!(found, t.doc_id, Set{String}()), st)
        end
    finally
        DBInterface.close!(upd)
    end
    # Expected-K cross-check: the TOC anchors name which statements the filing declares — warn when an
    # anchored derivable statement (BS/IS/CF) got no classified table (a coverage gap to investigate).
    for (doc, anc) in anchors
        exp = Set(v for v in values(anc) if v in _DERIVABLE_ST)
        miss = setdiff(exp, get(found, doc, Set{String}()))
        isempty(miss) ||
            @warn "TOC-declared statement(s) not classified (coverage gap)" doc = doc missing = sort(collect(miss))
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

# ── Facts derivation (statement tables → facts rows) ─────────────────────────────────────────────
# For every classified statement table (kind='statement'), infer the value-column axis with the
# locale-aware core (EDGAR.infer_columns / parse_amount, src/extractors/facts_derive.jl), keyed off the
# document's jurisdiction, then emit one fact per (body label-row × value column). Notes/empty columns are
# excluded. PERIOD dates are resolved precisely (two-pass): pass 1 reads any full period-end date in a
# column header (`parse_period_end`, e.g. "31 March 2023") and builds a per-document year→date map; pass 2
# emits, using that date for year-only columns of the same year and falling back to the calendar year-end
# only when the document offers nothing better. Duration `period_start = end − 1 year + 1 day`. Entity/
# dimension columns (combined funds, "of which") carry no period; their header is recoverable via the
# (table_id, col) provenance. Idempotent per doc: replaces only this extractor's own rows.
const _INSTANT_ST = ("balance_sheet",)

# Resolve ALL period columns of one table together → Dict{col => (period_start, period_end, fiscal_year,
# precision)}. Stay TRUE to the filing — never fabricate a day it didn't state.
#
# Per column, from its OWN header: period_end = the LATEST date (current = T), period_start = the EARLIEST
# (we have both → assign them; order-independent, so an OCR-scrambled range resolves). A single date on a
# duration → start = end − 1 year + 1 day. An instant column never pairs dates. No date but the year is
# stated, or a same-year date exists elsewhere in the report → that year/date. `fiscal_year` is the year the
# header labels (Japanese "2024年度" ending 2025-03-31 → 2024), falling back to the end date's year.
#
# COLUMN-LEVEL repair (for mangled tables): if a column lost its date but the table's period columns carry,
# in total, exactly one distinct date per column, the dates are reassigned to columns by their monotonic
# display order — direction (newest left vs right) read from the columns whose date survived. Conservative:
# fires only when the distinct-date count matches the column count, the direction is known, and the result
# is consistent with every surviving date. A non-monotonic date sequence is logged and left unrepaired.
# True if the period dates are monotonic (single panel) OR a tiling of a repeated monotonic block — a
# side-by-side multi-panel layout, e.g. an account-form balance sheet (Assets | Liabilities+Equity), each
# panel covering the same periods: label,2025,2024,label,2025,2024. Only a sequence that is neither (a date
# genuinely out of order, or panels that disagree) is the anomaly worth warning about.
function _monotone_or_paneled(dates::AbstractVector{Date})
    n = length(dates); n <= 1 && return true
    for L in 1:n
        n % L == 0 || continue
        blk = view(dates, 1:L)
        df = [blk[j+1] - blk[j] for j in 1:L-1]
        (all(>=(Day(0)), df) || all(<=(Day(0)), df)) || continue
        all(dates[k] == blk[(k-1) % L + 1] for k in 1:n) && return true
    end
    return false
end

function _resolve_period_columns(pcols, loc::Symbol, st, docdates::Dict{Int,Date}, table_id)
    is_instant = st in _INSTANT_ST
    cols = sort(collect(pcols); by = c -> c.col)        # left-to-right
    n = length(cols)
    dsets = Vector{Vector{Date}}(undef, n)
    fys   = Vector{Union{Missing,Int}}(undef, n)
    for (i, c) in enumerate(cols)
        ds = EDGAR.period_dates(c.hdr; locale = loc)
        y = tryparse(Int, c.key); fy = (y !== nothing && 1900 <= y <= 2100) ? y : missing
        (isempty(ds) && fy !== missing) && ((d = get(docdates, fy, nothing)) === nothing || (ds = [d]))
        dsets[i] = ds; fys[i] = fy
    end
    ends = Union{Missing,Date}[isempty(dsets[i]) ? missing : maximum(dsets[i]) for i in 1:n]

    # monotonicity + direction from the columns whose end date is known
    known = [(i, ends[i]) for i in 1:n if ends[i] !== missing]
    direction = 0                                        # +1 = dates ascend with col index (newest right)
    if length(known) >= 2
        kd = Date[k[2] for k in known]
        d = [kd[j+1] - kd[j] for j in 1:length(kd)-1]
        nondec = all(>=(Day(0)), d); noninc = all(<=(Day(0)), d)   # global direction (for the repair only)
        direction = (nondec && !noninc) ? 1 : (noninc && !nondec) ? -1 : 0
        _monotone_or_paneled(kd) ||                                # panels & ties are fine; only a reversal warns
            @warn "period dates neither monotonic nor a repeated panel; possible mis-extraction" table=table_id ends=ends
    end

    # column-level repair: dates mangled (a column is dateless) yet exactly one distinct date per column
    pool = sort(unique(reduce(vcat, dsets; init = Date[])))
    if any(e -> e === missing, ends) && direction != 0 && length(pool) == n
        desc = sort(pool; rev = true)                    # newest first
        assign(i) = direction == 1 ? desc[n-i+1] : desc[i]
        if all(ends[i] === missing || ends[i] == assign(i) for i in 1:n)
            ends = Union{Missing,Date}[assign(i) for i in 1:n]
        else
            @warn "column date repair inconsistent with surviving dates; skipped" table=table_id pool=pool
        end
    end

    out = Dict{Int,NTuple{4,Any}}()
    for (i, c) in enumerate(cols)
        pe = ends[i]; fy = fys[i]
        if pe === missing
            out[c.col] = (missing, missing, fy, fy === missing ? missing : "year")
        else
            fy === missing && (fy = Dates.year(pe))
            ps = is_instant ? missing :
                 (length(dsets[i]) >= 2 ? minimum(dsets[i]) : pe - Year(1) + Day(1))
            out[c.col] = (ps, pe, fy, "day")
        end
    end
    return out
end

# The list-shaped statements (`label × period → value`) the deriver can read. The statement of changes in
# equity (`equity_changes`) is deliberately EXCLUDED — it is a MATRIX (movement × equity-component), not a
# list, so it stays classified & kept but is derived separately (dimensionally) later, not here.
const _DERIVABLE_ST = ("balance_sheet", "income_statement", "cash_flow")

function EDGAR.derive_facts!(con::DuckDB.DB; doc_id = nothing)
    _ensure_repo(con)
    inlist = join(("'" * s * "'" for s in _DERIVABLE_ST), ", ")
    tsql = "SELECT t.table_id AS table_id, t.doc_id AS doc_id, t.section_id AS section_id, " *
           "t.statement_type AS statement_type, t.n_rows AS n_rows, t.n_cols AS n_cols, " *
           "d.jurisdiction AS jurisdiction FROM \"tables\" t JOIN documents d USING (doc_id) " *
           "WHERE t.kind = 'statement' AND t.statement_type IN ($inlist)" *
           (doc_id === nothing ? "" : " AND t.doc_id = ?")
    trows = DuckDB.Tables.rowtable(doc_id === nothing ? DBInterface.execute(con, tsql) :
                                                        DBInterface.execute(con, tsql, (doc_id,)))
    isempty(trows) && return (facts = 0, tables = 0)
    nfacts = 0; ntables = 0
    DBInterface.execute(con, "BEGIN TRANSACTION")
    try
        for d in unique(t.doc_id for t in trows)
            DBInterface.execute(con, "DELETE FROM facts WHERE doc_id = ? AND extractor = 'derive_facts'", (d,))
        end
        # Pass 1 — grid + column inference per table; collect each document's year→period-end map from
        # whichever column headers carry a full date (first full date wins for a given year).
        prepared = NamedTuple[]
        docdates = Dict{String,Dict{Int,Date}}()
        for t in trows
            loc = EDGAR.amount_locale(t.jurisdiction === missing ? "" : t.jurisdiction)
            grid = Dict{Tuple{Int,Int},String}()
            cellrows = DuckDB.Tables.rowtable(DBInterface.execute(con,
                "SELECT \"row\" r, \"col\" c, rowspan rs, colspan cs, is_header h, text " *
                "FROM table_cells WHERE table_id = ? AND text IS NOT NULL", (t.table_id,)))
            for cc in cellrows
                grid[(cc.r, cc.c)] = strip(String(cc.text))
            end
            # Expand spanning HEADER cells into the cells they cover (without overwriting a real cell):
            # a colspan'd period header (e.g. Tesco's "24 February 2024" over Notes+£m) otherwise hides its
            # date from the value column beneath it, leaving that column dateless.
            for cc in cellrows
                rs = cc.rs === missing ? 1 : Int(cc.rs)
                cs = cc.cs === missing ? 1 : Int(cc.cs)
                (cc.h === true && (rs > 1 || cs > 1)) || continue
                txt = strip(String(cc.text)); isempty(txt) && continue
                for dr in 0:rs-1, dc in 0:cs-1
                    (dr == 0 && dc == 0) && continue
                    get!(grid, (cc.r + dr, cc.c + dc), txt)
                end
            end
            isempty(grid) && continue
            inf = EDGAR.infer_columns(grid, t.n_rows, t.n_cols; locale = loc)
            valcols = [col for col in inf.columns if col.kind in (:period, :entity, :value, :dimension)]
            isempty(valcols) && continue
            dd = get!(docdates, t.doc_id, Dict{Int,Date}())
            for col in valcols
                col.kind === :period || continue
                d = EDGAR.parse_period_end(col.hdr; locale = loc)
                y = tryparse(Int, col.key)
                (d === nothing || y === nothing) && continue
                get!(dd, y, d)
            end
            notescols = [col.col for col in inf.columns if col.kind === :notes]   # the "Notes" reference column(s)
            push!(prepared, (t = t, grid = grid, data_start = inf.data_start, valcols = valcols,
                             notescols = notescols, loc = loc))
        end
        # Pass 2 — emit one fact per (body label-row × value column), with document-aware period dates.
        ins = DBInterface.prepare(con,
            "INSERT INTO facts (fact_id, doc_id, table_id, \"row\", \"col\", section_id, statement_type, " *
            "label, note_ref, period_start, period_end, is_instant, fiscal_year, period_precision, " *
            "value, extractor, confidence) " *
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
        try
            for pr in prepared
                t = pr.t; ntables += 1
                dd = get(docdates, t.doc_id, Dict{Int,Date}())
                inst = t.statement_type in _INSTANT_ST
                pcols = [c for c in pr.valcols if c.kind === :period]
                colmap = isempty(pcols) ? Dict{Int,NTuple{4,Any}}() :
                         _resolve_period_columns(pcols, pr.loc, t.statement_type, dd, t.table_id)
                for r in pr.data_start:t.n_rows-1
                    lbl = get(pr.grid, (r, 0), "")
                    (!isempty(lbl) && EDGAR.parse_amount(lbl; locale = pr.loc) === nothing) || continue
                    nref = join(filter(!isempty, [strip(get(pr.grid, (r, nc), "")) for nc in pr.notescols]), ", ")
                    for col in pr.valcols
                        p = EDGAR.parse_amount(get(pr.grid, (r, col.col), ""); locale = pr.loc)
                        (p === nothing || p.nil) && continue
                        ps, pe, fy, prec = col.kind === :period ? colmap[col.col] :
                                           (missing, missing, missing, missing)
                        fid = string(t.table_id, ":f", r, "_", col.col)
                        DBInterface.execute(ins, (fid, t.doc_id, t.table_id, r, col.col, _n(t.section_id),
                            t.statement_type, lbl, isempty(nref) ? missing : nref, _n(ps), _n(pe), inst,
                            _n(fy), _n(prec), p.val, "derive_facts", 1.0))
                        nfacts += 1
                    end
                end
            end
        finally
            DBInterface.close!(ins)
        end
        DBInterface.execute(con, "COMMIT")
    catch e
        DBInterface.execute(con, "ROLLBACK")
        rethrow(e)
    end
    return (facts = nfacts, tables = ntables)
end

function EDGAR.derive_facts!(
        db::AbstractString = joinpath(expanduser("~/RegulatoryReports"), "regulatory-reports.duckdb");
        doc_id = nothing)
    con = DBInterface.connect(DuckDB.DB, db)
    try
        return EDGAR.derive_facts!(con; doc_id = doc_id)
    finally
        DBInterface.close!(con)
    end
end

# ── Russia RFSD reader (R2) — the DuckDB half of fetch_filing(::Russia, h) ───────────────────────
#
# Read one (inn, year) row from the year-partitioned RFSD parquet (`url`, a remote HuggingFace file read
# over httpfs, or a local cache path) and serialise it to the JSON shape the core `_rfsd_facts` (R1)
# consumes: `{inn, year, <id cols…>, flags:{…}, lines:{line_XXXX => value}}`. Returns "" if the INN has
# no row in that partition. `httpfs` is installed/loaded on demand so remote URLs work with no download.
const _RFSD_IDCOLS   = ("ogrn", "okved", "okved_section", "okopf", "region")
const _RFSD_FLAGCOLS = ("filed", "eligible", "articulated", "totals_adjustment", "outlier",
                        "simplified", "imputed", "financial")

# Load httpfs for a remote URL; a local parquet path is read directly (no extension).
function _rfsd_httpfs!(con, src::AbstractString)
    if startswith(src, "http")
        DBInterface.execute(con, "INSTALL httpfs")
        DBInterface.execute(con, "LOAD httpfs")
    end
end

# Serialise one RFSD result row to the :ras JSON shape core `_rfsd_facts` consumes:
# `{inn, year, <id cols…>, flags:{…}, lines:{line_XXXX => value}}`.
function _rfsd_row_json(row, year::Integer)
    gv(k) = hasproperty(row, Symbol(k)) ? getproperty(row, Symbol(k)) : missing
    lines = Dict{String,Float64}()
    for k in propertynames(row)
        s = String(k)
        startswith(s, "line_") || continue
        v = getproperty(row, k)
        v === missing && continue
        lines[s] = Float64(v)
    end
    doc = Dict{String,Any}("inn" => string(gv("inn")), "year" => Int(year), "lines" => lines)
    for k in _RFSD_IDCOLS
        v = gv(k); doc[k] = v === missing ? nothing : v
    end
    flags = Dict{String,Any}()
    for k in _RFSD_FLAGCOLS
        v = gv(k); flags[k] = v === missing ? nothing : Float64(v)
    end
    doc["flags"] = flags
    return EDGAR.JSON3.write(doc)
end

function EDGAR._rfsd_query(url::AbstractString, inn::AbstractString, year::Integer)
    con = DBInterface.connect(DuckDB.DB)
    try
        _rfsd_httpfs!(con, url)
        safe_inn = replace(inn, "'" => "''")            # RFSD INNs are digits, but guard anyway
        q = "SELECT * FROM read_parquet('$url') WHERE inn = '$safe_inn' LIMIT 1"
        for r in DBInterface.execute(con, q)
            return _rfsd_row_json(r, year)
        end
        return ""
    finally
        DBInterface.close!(con)
    end
end

# Population discover (R2b): one scan of the year partition enumerates the INNs matching the dimension
# filters (`dims`, column => code, exact match) under the sound-population predicates (`preds`, a NamedTuple
# `(filed, eligible, outlier)`), bounded by `limit`. `dims` keys come from a fixed allow-list (`_RFSD_DIM_KWARGS`)
# so they are safe column identifiers; values are single-quote-escaped.
function EDGAR._rfsd_discover(url::AbstractString, dims::AbstractDict, preds, limit::Integer)
    con = DBInterface.connect(DuckDB.DB)
    try
        if startswith(url, "http")
            DBInterface.execute(con, "INSTALL httpfs")
            DBInterface.execute(con, "LOAD httpfs")
        end
        where = String[]
        for (k, v) in dims
            push!(where, "$k = '$(replace(string(v), "'" => "''"))'")
        end
        preds.filed    && push!(where, "filed = 1")
        preds.eligible && push!(where, "eligible = 1")
        preds.outlier  || push!(where, "(outlier = 0 OR outlier IS NULL)")
        clause = isempty(where) ? "" : "WHERE " * join(where, " AND ")
        q = "SELECT inn FROM read_parquet('$url') $clause LIMIT $(Int(limit))"
        inns = String[]
        for r in DBInterface.execute(con, q)
            r.inn === missing || push!(inns, string(r.inn))
        end
        return inns
    finally
        DBInterface.close!(con)
    end
end

# Batch fetch (R2c): read many INNs in ONE scan (`WHERE inn IN (…)`). Returns inn => :ras JSON for the
# INNs present in the partition (absent ones simply don't appear). One scan for a whole cohort, vs N.
function EDGAR._rfsd_query_many(url::AbstractString, inns::AbstractVector, year::Integer)
    out = Dict{String,String}()
    isempty(inns) && return out
    con = DBInterface.connect(DuckDB.DB)
    try
        _rfsd_httpfs!(con, url)
        inlist = join(("'" * replace(string(s), "'" => "''") * "'" for s in inns), ", ")
        q = "SELECT * FROM read_parquet('$url') WHERE inn IN ($inlist)"
        for r in DBInterface.execute(con, q)
            out[string(r.inn)] = _rfsd_row_json(r, year)
        end
        return out
    finally
        DBInterface.close!(con)
    end
end

# Download-once (R2c): COPY a remote partition to a local parquet via DuckDB — no extra HTTP dependency,
# and httpfs already handles the HuggingFace redirect. The local file is then read directly (no httpfs).
function EDGAR._rfsd_download(remote_url::AbstractString, dest::AbstractString)
    con = DBInterface.connect(DuckDB.DB)
    try
        _rfsd_httpfs!(con, remote_url)
        safe_dest = replace(dest, "'" => "''")
        DBInterface.execute(con,
            "COPY (SELECT * FROM read_parquet('$remote_url')) TO '$safe_dest' (FORMAT PARQUET)")
        return dest
    finally
        DBInterface.close!(con)
    end
end

# CBR bank directory (route 2, C1): read the downloaded UniDbQuery XLSX (a LOCAL path) with DuckDB read_xlsx
# into (regnum, name, ogrn, status) rows — the regnum resolver for CBRBankFilings discovery.
function EDGAR._cbr_directory_rows(path::AbstractString)
    con = DBInterface.connect(DuckDB.DB)
    try
        DBInterface.execute(con, "INSTALL excel")
        DBInterface.execute(con, "LOAD excel")
        safe = replace(path, "'" => "''")
        out = @NamedTuple{regnum::String, name::String, ogrn::String, status::String}[]
        for r in DBInterface.execute(con,
                "SELECT cregnum, bnk_name, ogrn, lic_status FROM read_xlsx('$safe', header=true)")
            r.cregnum === missing && continue
            push!(out, (regnum = string(Int(r.cregnum)),
                        name   = r.bnk_name === missing ? "" : String(r.bnk_name),
                        ogrn   = r.ogrn === missing ? "" : string(Int(r.ogrn)),
                        status = r.lic_status === missing ? "" : String(r.lic_status)))
        end
        return out
    finally
        DBInterface.close!(con)
    end
end

end # module
