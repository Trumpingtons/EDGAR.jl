# save_selection (the unified Export-As menu) + DuckDB extension stub methods.

"""
    to_duckdb(data, db; table="facts") -> Int

Append the XBRL facts in `data` to a DuckDB table, returning the number of rows **newly**
inserted. `data` is a [`Selection`](@ref), a vector of selections, or a fact row table
(the output of [`facts`](@ref)); `db` is a database-file path (created if it does not
exist) or an open `DuckDB.DB` connection.

The table is the canonical fact warehouse — one schema every source maps into (the picker
now, with `source='picker'`; the structured-data API later, filling `form`/`fy`/`fp`/`frame`).
Its primary key is each fact's **semantic identity** `(cik, accession, concept, unit,
period_start, period_end, is_instant, dimensions)` — *not* the document-internal
`context_ref`/`unit_ref`, which are kept only as provenance — and rows are inserted with
`ON CONFLICT DO NOTHING`. So re-importing the same filing is **idempotent** (returning `0`),
and the same fact arriving from two sources collapses to one row. Append filing by filing
to grow the warehouse. Once the facts are in DuckDB, export to Parquet/CSV/SQLite is a single
`COPY … TO` / `ATTACH … (TYPE SQLITE)`; and because a fact table is already a Tables.jl
source, `CSV.write`/`Arrow.write`/`SQLite.load!` also take it directly.

This is a **package extension**: it is available only after `using DuckDB`.

```julia
using DuckDB
to_duckdb(select_section(f), "filings.duckdb")   # append; running it again -> 0 new rows
```
"""
function to_duckdb(args...; kwargs...)
    error("`to_duckdb` requires DuckDB.jl. Run `using DuckDB` to load the EDGAR.jl " *
          "DuckDB extension (`EDGARDuckDBExt`).")
end

"""
    statement_view(db; table="facts", statement=nothing, accession=nothing,
                   consolidated=true, months=nothing, by=:concept) -> Vector{NamedTuple}

Pivot the long fact table in DuckDB `db` (a database-file path or an open `DuckDB.DB`)
into a **wide statement view** — the familiar shape of a financial statement: one row per
`concept`/`label`, one column per reporting period (`period_end`), each cell the normalised
value. The newest period comes first. Because the warehouse may hold many filings, the view
**stitches** a statement across them automatically.

- `statement` — restrict to one financial statement, e.g. `"IncomeStatement"`, `"BalanceSheet"`,
  `"CashFlow"` (requires facts ingested with `classify=true`; see [`statement_map`](@ref)).
- `months` — keep only duration periods of about this many months (e.g. `3` quarterly, `12`
  annual) plus all instants. This is **smart period selection**: it stops the 3-month and
  9-month periods that share an end date from colliding in one column.
- `consolidated=true` (default) shows the face of the statement (no dimensional qualifier);
  `consolidated=false` adds the dimensional breakdowns and a `dimensions` column.
- `accession` restricts to a single filing.
- `by=:standard_concept` groups by the standardized concept (see [`set_standardizer`](@ref))
  for cross-company comparison, instead of the raw `concept`/`label`.

The result is a Tables.jl row table (the period dates are the column names), so
`pretty_table(statement_view(db))` renders the statement and it feeds any Tables.jl sink.

This is a **package extension**: available only after `using DuckDB`.

```julia
using DuckDB, PrettyTables
to_duckdb(select_section(f), "filings.duckdb")     # accumulate facts
pretty_table(statement_view("filings.duckdb"))     # see them as a statement
```
"""
function statement_view(args...; kwargs...)
    error("`statement_view` requires DuckDB.jl. Run `using DuckDB` to load the EDGAR.jl " *
          "DuckDB extension (`EDGARDuckDBExt`).")
end

"""
    archive_filings(cik, db; forms=nothing, startdate=nothing, enddate=nothing,
                    facts=true, classify=false, labels=false, kind=:auto, limit=nothing) -> NamedTuple

Bulk-archive a filer's filings into the DuckDB warehouse `db` (a path): list them with
[`filings_by_cik`](@ref), then for each fetch the document and store it in `documents`
(the lossless iXBRL HTML, Layer 1) and — when `facts=true` — extract its XBRL facts
natively with [`facts(::Filing)`](@ref) into `facts` (tagged `source='filing'`) plus a
filing-level Facts JSON snapshot in `extractions`. One open connection is reused across
the whole run, and every write is idempotent (re-running adds nothing new).

`forms` / `startdate` / `enddate` filter the listing as in [`filings_by_cik`](@ref);
`limit` caps how many filings are processed; `kind` is passed to [`fetch_filing`](@ref).
`classify=true` fills each fact's `statement` (presentation linkbase) and `labels=true` its
`label` (label linkbase), at one extra fetch each per filing.
Returns a summary `(filings, documents, facts)` of how many were processed and how many
rows were newly added. A filing that fails to fetch is skipped.

Requires DuckDB: `using DuckDB` loads this method.

```julia
using DuckDB
archive_filings(104169, "wmt.duckdb"; forms = "10-Q", limit = 4)   # last 4 Walmart 10-Qs
```
"""
function archive_filings(args...; kwargs...)
    error("`archive_filings` requires DuckDB.jl. Run `using DuckDB` to load the EDGAR.jl " *
          "DuckDB extension (`EDGARDuckDBExt`).")
end

# Internal: a filesystem-safe basename for a selection's export files — the accession
# plus a slug of the selector, so several picks from one filing do not collide.
function _selection_slug(sel::Selection)
    s = strip(replace(sel.selector, r"[^A-Za-z0-9]+" => "-"), '-')
    isempty(s) && (s = string(sel.kind))
    length(s) > 48 && (s = s[1:48])
    return string(isempty(sel.accession) ? "selection" : sel.accession, "_", s)
end

"""
    save_selection(sel::Selection; as::Symbol, dir=".", db=nothing) -> String | Int

Export a [`Selection`](@ref) to disk in one of the four formats — the unified "Export As"
menu — returning the path written (or, for `:duckdb`, the number of rows appended). `dir`
is created if needed; file names are `<accession>_<selector-slug>.<ext>`.

- `:ixbrl`    — the lossless captured fragment (`sel.html`) as `…​.ixbrl.html`. View a
  self-contained, image-resolving version with [`open_filing(::Selection)`](@ref).
- `:markdown` — [`markdown`](@ref) (table/prose + provenance) as `…​.md`.
- `:facts`    — [`facts_json`](@ref) (the Layer-2 semantic JSON) as `…​.facts.json`.
- `:duckdb`   — append via `to_duckdb` to `db` (default `<dir>/facts.duckdb`); **requires**
  `using DuckDB`. Returns the number of rows newly inserted.

```julia
sel = select_section(f)
save_selection(sel; as = :markdown, dir = "out")    # -> "out/0000..._div-....md"
save_selection(sel; as = :facts,    dir = "out")    # -> "out/0000..._div-....facts.json"
using DuckDB
save_selection(sel; as = :duckdb,   dir = "out")    # -> 42  (rows appended to out/facts.duckdb)
```
"""
function save_selection(sel::Selection; as::Symbol, dir::AbstractString=".", db=nothing)
    if as === :duckdb
        isdir(dir) || mkpath(dir)
        return to_duckdb(sel, db === nothing ? joinpath(dir, "facts.duckdb") : db)
    end
    ext, content = as === :ixbrl    ? (".ixbrl.html", sel.html) :
                   as === :markdown ? (".md", markdown(sel)) :
                   as === :facts    ? (".facts.json", facts_json(sel)) :
                   throw(ArgumentError("`as` must be :ixbrl, :markdown, :facts or :duckdb, got $(repr(as))"))
    isdir(dir) || mkpath(dir)
    path = joinpath(dir, _selection_slug(sel) * ext)
    write(path, content)
    return path
end
