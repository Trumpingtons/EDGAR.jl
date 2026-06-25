# Presentation layer (Step 2.2/2.3): render a `Selection` as Markdown — a structured
# table as a Markdown table, prose as text, each under a provenance header for citation.
# The browser sends a *faithful* grid (Step 2.1), padded with the many empty spacer
# rows/columns and lone `$` columns SEC iXBRL tables use for indentation and currency
# alignment; the cleanup (pruning those, picking the header row) lives here, not in the
# capture, so the capture stays honest and the presentation logic is testable in Julia.

# Internal: escape a cell for a Markdown table — collapse internal whitespace and
# escape the column separator so a stray `|` cannot break the row.
_md_cell(s::AbstractString) = replace(replace(strip(s), r"\s+" => " "), "|" => "\\|")

# Internal: a cell that carries no real content — empty, or a lone currency marker
# (its own spacer column in SEC tables).
_blankish(s::AbstractString) = isempty(strip(s)) || strip(s) == "\$"

# Internal: prune a faithful grid to its meaningful cells. SEC tables put the `$`
# marker in its own column only on some rows (the first of a section, totals, per-share
# lines), which shifts the value into a different column row to row — so dropping whole
# columns cannot realign it. Instead drop the blank-ish cells (empty / lone `$`) within
# each row and left-pack: the label leads and the values follow, so the columns line up
# again. Empty rows are dropped and the result padded back to a rectangle.
function _prune_grid(grid::Vector{Vector{String}})
    isempty(grid) && return grid
    rows = [String[c for c in r if !_blankish(c)] for r in grid]
    rows = [r for r in rows if !isempty(r)]
    isempty(rows) && return rows
    width = maximum(length, rows)
    return [vcat(r, fill("", width - length(r))) for r in rows]
end

# Internal: render a (header, rows) selection table as a GitHub-flavoured Markdown
# table. The faithful grid is pruned, then its first surviving row becomes the header
# (Markdown requires one); header detection is intentionally simple — the first
# non-empty row — which suits the period-label row of a financial statement.
function _table_md(t)::String
    grid = isempty(t.header) ? t.rows : vcat([t.header], t.rows)
    grid = _prune_grid(grid)
    isempty(grid) && return ""
    ncol = length(grid[1])
    row(r) = "| " * join((_md_cell(get(r, j, "")) for j in 1:ncol), " | ") * " |"
    lines = String[row(grid[1]), "| " * join(fill("---", ncol), " | ") * " |"]
    for r in grid[2:end]
        push!(lines, row(r))
    end
    return join(lines, "\n")
end

# Internal: render prose as Markdown — trim and normalise blank-line runs to single
# paragraph breaks. The browser's `innerText` already separates block elements with
# newlines, so the paragraph structure is preserved.
_prose_md(text::AbstractString) = replace(strip(text), r"\n[ \t]*\n[ \t\n]*" => "\n\n")

# Internal: a Markdown blockquote header recording where the selection came from, so
# the rendered output can be cited (RAG). Uses what the `Selection` carries — the
# report date is not yet part of the selection contract, so it is omitted for now.
function _provenance_md(sel::Selection)::String
    return string("> Source: SEC EDGAR — CIK ", sel.cik, ", accession ", sel.accession,
                  " (", sel.kind, ")\n",
                  "> URL: ", sel.url, "\n",
                  "> Selector: `", sel.selector, "`")
end

"""
    markdown(sel::Selection; provenance=true) -> String

Render a [`Selection`](@ref) as Markdown: a structured table (`sel.table`) becomes a
GitHub-flavoured Markdown table, and prose becomes text. The faithful capture grid is
cleaned up here — the empty spacer columns, lone `\$` columns and blank rows that SEC
iXBRL tables are padded with are dropped, and the first surviving row is used as the
header. With `provenance=true` (the default) a citation header (CIK, accession, source
URL, selector) is prepended as a Markdown blockquote, so the output is self-describing
for retrieval/RAG; pass `provenance=false` for just the body.

```julia
sel = select_section(f)        # pick the income statement
print(markdown(sel))           # a Markdown table under a provenance header
```
"""
function markdown(sel::Selection; provenance::Bool=true)
    body = sel.table === nothing ? _prose_md(sel.text) : _table_md(sel.table)
    provenance || return body
    head = _provenance_md(sel)
    return isempty(body) ? head : string(head, "\n\n", body)
end

# ── Facts JSON (Step 2.x/5: the Layer-2 semantic export) ────────────────────
# The resolved facts as a portable JSON document: a provenance header plus the facts
# with *normalised* values (number, not display text). Date fields are ISO strings;
# `cik`/`accession`/`url` live once at the top, the rest per fact. It is the convenient
# working representation of the iXBRL semantics — clean for LLM/RAG, cheap to re-query,
# and a common shape across modern iXBRL, old classic XBRL, and extracted fragments.

# Internal: one Fact as the JSON object (the top-level cik/accession are not repeated).
_fact_json(f::Fact) = (; concept = f.concept, standard_concept = standardize(f.concept),
    label = f.label, value = f.value, unit = f.unit, statement = f.statement, statements = f.statements,
    period_start = f.period_start === nothing ? nothing : string(f.period_start),
    period_end = string(f.period_end), is_instant = f.is_instant,
    dimensions = f.dimensions, decimals = f.decimals,
    context_ref = f.context_ref, unit_ref = f.unit_ref, source_selector = f.source_selector)

"""
    facts_json(sel::Selection; pretty=true) -> String

Serialise the XBRL facts captured in `sel` to a portable **Facts JSON** document — the
Layer-2 semantic export. The document is a provenance header (`cik`, `accession`, `url`,
`selector`, `kind`) plus a `facts` array; each fact carries its `concept`, `label`,
**normalised** `value`, `unit`, resolved period (`period_start`/`period_end`,
`is_instant`), `dimensions`, `decimals`, and the raw `context_ref`/`unit_ref` and
`source_selector` for traceability. Round-trips via [`read_facts_json`](@ref), which reads
it back into a `Selection` (so it flows on to [`facts`](@ref) / `to_duckdb`). Prose-only
selections produce a document with an empty `facts` array.

```julia
sel = select_section(f)                 # pick the income statement
write("wmt_income.facts.json", facts_json(sel))
```
"""
function facts_json(sel::Selection; pretty::Bool=true)
    doc = (; version = 1, cik = sel.cik, accession = sel.accession, url = sel.url,
           selector = sel.selector, kind = String(sel.kind),
           facts = [_fact_json(f) for f in sel.facts])
    return pretty ? sprint(io -> JSON3.pretty(io, doc)) : JSON3.write(doc)
end

"""
    read_facts_json(source) -> Selection

Read a **Facts JSON** document (written by [`facts_json`](@ref)) back into a
[`Selection`](@ref), reconstructing its [`Fact`](@ref)s — the inverse of `facts_json`.
`source` is a file path or a JSON string. The returned selection carries the facts (and
provenance) but not the original HTML/text, so it is the working semantic representation:
feed it to [`facts`](@ref) for a row table, or `to_duckdb` to load into a warehouse. This
is also how **old classic-XBRL** filings (no rendered HTML) enter the same pipeline.

```julia
sel = read_facts_json("wmt_income.facts.json")
using DuckDB
to_duckdb(sel, "filings.duckdb")        # ingest the saved facts
```
"""
function read_facts_json(source::AbstractString)
    # A JSON document starts with `{`/`[`; anything else is treated as a file path.
    # (Avoid `isfile` on the content itself — a long JSON string overruns the path limit.)
    s = lstrip(source)
    o = JSON3.read((startswith(s, '{') || startswith(s, '[')) ? source : read(source, String))
    cik = String(o.cik); accession = String(o.accession)
    selector = String(get(o, :selector, ""))
    facts = Fact[]
    for fj in get(o, :facts, ())
        dj = get(fj, :dimensions, nothing)
        dims = Dict{String,String}()
        dj === nothing || for (k, v) in pairs(dj); dims[String(k)] = String(v); end
        ps = get(fj, :period_start, nothing)
        dec = get(fj, :decimals, nothing)
        push!(facts, Fact(; cik, accession,
            concept = String(fj.concept), label = String(get(fj, :label, "")),
            value = Float64(fj.value), unit = String(get(fj, :unit, "")),
            statement = String(get(fj, :statement, "")),
            statements = String[String(x) for x in get(fj, :statements, String[])],
            period_start = (ps === nothing || ps == "") ? nothing : Date(String(ps)),
            period_end = Date(String(fj.period_end)),
            is_instant = Bool(get(fj, :is_instant, false)), dimensions = dims,
            decimals = dec === nothing ? nothing : Int(dec),
            context_ref = String(get(fj, :context_ref, "")),
            unit_ref = String(get(fj, :unit_ref, "")),
            source_selector = String(get(fj, :source_selector, selector))))
    end
    return Selection(; cik, accession, url = String(get(o, :url, "")), selector,
                     kind = Symbol(get(o, :kind, "table")), facts)
end
