# StructuredDocument — the document-first substrate for PDF reports (see
# docs/dev/pdf-repository-schema.md). Pure-Julia, dependency-light: the TYPES, JSON serialisation,
# a Markdown render, and the filesystem persistence live here; the actual PDF→StructuredDocument
# extraction is provided by the PythonCall package extension (ext/EDGARDoclingExt.jl), so the core
# package never depends on Python. `structured_document(pdf)` is the entry point — it errors with
# guidance until `using PythonCall` loads the extension (mirrors the DuckDB `to_duckdb` pattern).
#
# One report → one StructuredDocument → {sections, text_blocks, tables, figures} + metadata, each
# element carrying page+bbox provenance and a global reading-order `ord`. Original language is stored
# verbatim; translation is a separate (later) layer. Facts are NOT here — they are a later derivation.

using OrderedCollections: OrderedDict

# Bounding box in PDF points, TOP-LEFT origin (y = distance from page top), matching pdf_words.mjs.
struct BBox
    page::Int
    x0::Float64
    y0::Float64
    x1::Float64
    y1::Float64
end

struct DocSection
    section_id::String
    parent_id::Union{String,Nothing}
    level::Int
    title::String
    lang::String
    ord::Int
    page_start::Int
    page_end::Int
    bbox::Union{BBox,Nothing}
end

struct TextBlock
    block_id::String
    section_id::Union{String,Nothing}
    ord::Int
    kind::String                    # paragraph | list_item | caption | footnote
    text::String
    lang::String
    page::Int
    bbox::Union{BBox,Nothing}
    char_len::Int
end

struct TableCell
    row::Int
    col::Int
    rowspan::Int
    colspan::Int
    is_header::Bool
    text::String
end

struct DocTable
    table_id::String
    section_id::Union{String,Nothing}
    ord::Int
    kind::String                    # statement | descriptive | unknown   (semantic layer sets this)
    statement_type::Union{String,Nothing}
    caption::Union{String,Nothing}
    lang::String
    page_start::Int
    page_end::Int
    bbox::Union{BBox,Nothing}
    n_rows::Int
    n_cols::Int
    cells::Vector{TableCell}
end

struct DocFigure
    figure_id::String
    section_id::Union{String,Nothing}
    ord::Int
    caption::Union{String,Nothing}
    page::Int
    bbox::Union{BBox,Nothing}
    image_path::Union{String,Nothing}
    image_format::Union{String,Nothing}
    width::Union{Int,Nothing}
    height::Union{Int,Nothing}
end

struct DocMeta
    doc_id::String
    source_path::String
    jurisdiction::Union{String,Nothing}
    filing_system::Union{String,Nothing}
    language::Union{String,Nothing}
    company::Union{String,Nothing}
    report_type::Union{String,Nothing}
    fiscal_year::Union{Int,Nothing}
    currency::Union{String,Nothing}
    framework::Union{String,Nothing}
    n_pages::Int
    parser::String
    parser_version::String
    ocr::Bool
end

struct TocEntry          # an entry from the PDF outline/bookmarks — authoritative heading + page
    title::String
    level::Int
    page::Int
end

struct StructuredDocument
    schema_version::String
    document::DocMeta
    sections::Vector{DocSection}
    text_blocks::Vector{TextBlock}
    tables::Vector{DocTable}
    figures::Vector{DocFigure}
    toc::Vector{TocEntry}
end

Base.show(io::IO, sd::StructuredDocument) = print(io,
    "StructuredDocument(", sd.document.doc_id, ": ", length(sd.sections), " sections, ",
    length(sd.text_blocks), " text, ", length(sd.tables), " tables, ", length(sd.figures), " figures)")

"""
    structured_document(pdf_path; pages=nothing, ocr=false, doc_id=..., jurisdiction=nothing,
                        language=nothing, company=nothing, report_type=nothing,
                        fiscal_year=nothing, currency=nothing, framework=nothing) -> StructuredDocument

Parse a born-digital PDF into a [`StructuredDocument`](@ref) — sections, text blocks, tables (with cells)
and figures, each with page+bbox provenance. The main (document-AI) path; requires the Tier-2 Python stack
(Docling) reached via PythonCall. **Available only after `using PythonCall`** (package extension).

`pages` is an optional 1-based `(first, last)` range; `ocr` turns on OCR (needed only for broken text
layers, e.g. Japanese EDINET). The jurisdiction/language/etc. keywords seed metadata the per-jurisdiction
profile would otherwise fill. See `docs/dev/pdf-repository-schema.md`.
"""
function structured_document(args...; kwargs...)
    error("`structured_document` requires the Docling Tier-2 stack via PythonCall.jl. Run `using " *
          "PythonCall` (with the tier-2 venv on `JULIA_PYTHONCALL_EXE`) to load the EDGAR.jl Docling " *
          "extension. See docs/dev/pdf-extractor-plan.md.")
end

# --- JSON serialisation (OrderedDict → JSON3; no StructTypes dependency) -------------------------
_jd(::Nothing) = nothing
_jd(b::BBox) = OrderedDict("page" => b.page, "x0" => b.x0, "y0" => b.y0, "x1" => b.x1, "y1" => b.y1)
_jd(s::DocSection) = OrderedDict("section_id" => s.section_id, "parent_id" => s.parent_id,
    "level" => s.level, "title" => s.title, "lang" => s.lang, "ord" => s.ord,
    "page_start" => s.page_start, "page_end" => s.page_end, "bbox" => _jd(s.bbox))
_jd(t::TextBlock) = OrderedDict("block_id" => t.block_id, "section_id" => t.section_id, "ord" => t.ord,
    "kind" => t.kind, "text" => t.text, "lang" => t.lang, "page" => t.page, "bbox" => _jd(t.bbox),
    "char_len" => t.char_len)
_jd(c::TableCell) = OrderedDict("row" => c.row, "col" => c.col, "rowspan" => c.rowspan,
    "colspan" => c.colspan, "is_header" => c.is_header, "text" => c.text)
_jd(t::DocTable) = OrderedDict("table_id" => t.table_id, "section_id" => t.section_id, "ord" => t.ord,
    "kind" => t.kind, "statement_type" => t.statement_type, "caption" => t.caption, "lang" => t.lang,
    "page_start" => t.page_start, "page_end" => t.page_end, "bbox" => _jd(t.bbox),
    "n_rows" => t.n_rows, "n_cols" => t.n_cols, "cells" => [_jd(c) for c in t.cells])
_jd(f::DocFigure) = OrderedDict("figure_id" => f.figure_id, "section_id" => f.section_id, "ord" => f.ord,
    "caption" => f.caption, "page" => f.page, "bbox" => _jd(f.bbox), "image_path" => f.image_path,
    "image_format" => f.image_format, "width" => f.width, "height" => f.height)
_jd(m::DocMeta) = OrderedDict("doc_id" => m.doc_id, "source_path" => m.source_path,
    "jurisdiction" => m.jurisdiction, "filing_system" => m.filing_system, "language" => m.language,
    "company" => m.company, "report_type" => m.report_type, "fiscal_year" => m.fiscal_year,
    "currency" => m.currency, "framework" => m.framework, "n_pages" => m.n_pages,
    "parser" => m.parser, "parser_version" => m.parser_version, "ocr" => m.ocr)
_jd(e::TocEntry) = OrderedDict("title" => e.title, "level" => e.level, "page" => e.page)
_jd(sd::StructuredDocument) = OrderedDict("schema_version" => sd.schema_version,
    "document" => _jd(sd.document), "sections" => [_jd(s) for s in sd.sections],
    "text_blocks" => [_jd(t) for t in sd.text_blocks], "tables" => [_jd(t) for t in sd.tables],
    "figures" => [_jd(f) for f in sd.figures], "toc" => [_jd(e) for e in sd.toc])

# --- Markdown render (Python-free; headings, prose, pipe tables in reading order) ----------------
function _md_table(t::DocTable)
    grid = fill("", t.n_rows, t.n_cols)
    for c in t.cells
        (1 <= c.row + 1 <= t.n_rows && 1 <= c.col + 1 <= t.n_cols) || continue
        grid[c.row+1, c.col+1] = replace(strip(c.text), "\n" => " ", "|" => "\\|")
    end
    io = IOBuffer()
    for r in 1:t.n_rows
        println(io, "| ", join(@view(grid[r, :]), " | "), " |")
        r == 1 && println(io, "|", repeat(" --- |", t.n_cols))
    end
    return String(take!(io))
end

"""
    markdown(sd::StructuredDocument) -> String

Render a [`StructuredDocument`](@ref) as Markdown (headings, paragraphs, pipe tables) in reading order —
the human/RAG view of the document family.
"""
function markdown(sd::StructuredDocument)
    items = vcat([(s.ord, :section, s) for s in sd.sections],
                 [(t.ord, :text, t) for t in sd.text_blocks],
                 [(t.ord, :table, t) for t in sd.tables],
                 [(f.ord, :figure, f) for f in sd.figures])
    sort!(items; by = first)
    io = IOBuffer()
    for (_, kind, el) in items
        if kind === :section
            println(io, "\n", repeat("#", min(el.level, 6)), " ", el.title, "\n")
        elseif kind === :text
            println(io, el.text, "\n")
        elseif kind === :table
            el.caption === nothing || println(io, "*", el.caption, "*\n")
            println(io, _md_table(el))
        elseif kind === :figure
            cap = el.caption === nothing ? "figure" : el.caption
            println(io, "![", cap, "](", something(el.image_path, ""), ")\n")
        end
    end
    return String(take!(io))
end

# --- Filesystem persistence (per-doc derived folder; see schema doc §1) --------------------------
function _csv_field(s)
    s = replace(String(s), "\r" => " ", "\n" => " ")
    (occursin(',', s) || occursin('"', s)) ? string('"', replace(s, '"' => "\"\""), '"') : s
end
function _write_table_csv(t::DocTable, path)
    grid = fill("", t.n_rows, t.n_cols)
    for c in t.cells
        (1 <= c.row + 1 <= t.n_rows && 1 <= c.col + 1 <= t.n_cols) || continue
        grid[c.row+1, c.col+1] = c.text
    end
    open(path, "w") do io
        for r in 1:t.n_rows
            println(io, join((_csv_field(grid[r, c]) for c in 1:t.n_cols), ","))
        end
    end
end

"""
    persist_document(sd::StructuredDocument; root="~/RegulatoryReports") -> String

Write the document family to the filesystem under `root/derived/<doc_id>/`: `structured.json` (canonical),
`document.md` (render), and `tables/<id>.csv` per table. Returns the derived-folder path. The repository
DuckDB load is a separate step. (`figures/` are written by the extractor when image bytes are captured.)
"""
function persist_document(sd::StructuredDocument; root::AbstractString = "~/RegulatoryReports")
    dir = joinpath(expanduser(root), "derived", sd.document.doc_id)
    mkpath(dir)
    open(io -> JSON3.write(io, _jd(sd)), joinpath(dir, "structured.json"), "w")
    write(joinpath(dir, "document.md"), markdown(sd))
    if !isempty(sd.tables)
        mkpath(joinpath(dir, "tables"))
        for t in sd.tables
            _write_table_csv(t, joinpath(dir, "tables", string(split(t.table_id, ":")[end], ".csv")))
        end
    end
    return dir
end

write_structured_document(sd::StructuredDocument, path::AbstractString) =
    open(io -> JSON3.write(io, _jd(sd)), path, "w")

# --- read back a StructuredDocument from its canonical JSON (round-trip) --------------------------
_rs(x) = x === nothing ? nothing : String(x)
_ri(x) = x === nothing ? nothing : Int(x)
_rbb(b) = b === nothing ? nothing : BBox(Int(b.page), Float64(b.x0), Float64(b.y0), Float64(b.x1), Float64(b.y1))

"""
    read_structured_document(path) -> StructuredDocument

Reconstruct a [`StructuredDocument`](@ref) from a `structured.json` written by [`persist_document`](@ref) /
[`write_structured_document`](@ref). Lets the repository loader (`to_repository`) run from persisted JSON
without re-parsing the PDF (no PythonCall needed).
"""
function read_structured_document(path::AbstractString)
    j = JSON3.read(read(path, String))
    d = j.document
    meta = DocMeta(String(d.doc_id), String(d.source_path), _rs(d.jurisdiction), _rs(d.filing_system),
        _rs(d.language), _rs(d.company), _rs(d.report_type), _ri(d.fiscal_year), _rs(d.currency),
        _rs(d.framework), Int(d.n_pages), String(d.parser), String(d.parser_version), Bool(d.ocr))
    sections = [DocSection(String(s.section_id), _rs(s.parent_id), Int(s.level), String(s.title),
        String(s.lang), Int(s.ord), Int(s.page_start), Int(s.page_end), _rbb(s.bbox)) for s in j.sections]
    texts = [TextBlock(String(t.block_id), _rs(t.section_id), Int(t.ord), String(t.kind), String(t.text),
        String(t.lang), Int(t.page), _rbb(t.bbox), Int(t.char_len)) for t in j.text_blocks]
    tables = [DocTable(String(t.table_id), _rs(t.section_id), Int(t.ord), String(t.kind),
        _rs(t.statement_type), _rs(t.caption), String(t.lang), Int(t.page_start), Int(t.page_end),
        _rbb(t.bbox), Int(t.n_rows), Int(t.n_cols),
        [TableCell(Int(c.row), Int(c.col), Int(c.rowspan), Int(c.colspan), Bool(c.is_header),
            String(c.text)) for c in t.cells]) for t in j.tables]
    figures = [DocFigure(String(f.figure_id), _rs(f.section_id), Int(f.ord), _rs(f.caption), Int(f.page),
        _rbb(f.bbox), _rs(f.image_path), _rs(f.image_format), _ri(f.width), _ri(f.height)) for f in j.figures]
    jt = get(j, :toc, nothing)
    toc = jt === nothing ? TocEntry[] : [TocEntry(String(e.title), Int(e.level), Int(e.page)) for e in jt]
    return StructuredDocument(String(j.schema_version), meta, sections, texts, tables, figures, toc)
end

"""
    to_repository(sd_or_path, db="~/RegulatoryReports/regulatory-reports.duckdb") -> NamedTuple

Load a [`StructuredDocument`](@ref) (or a `structured.json` path) into the DuckDB document repository —
`documents`/`sections`/`text_blocks`/`tables`/`table_cells`/`figures` plus the referencing views (see
`docs/dev/pdf-repository-schema.md`). Idempotent per `doc_id` (re-loading replaces the document's rows).
Returns row counts. **Available only after `using DuckDB`** (package extension).
"""
function to_repository(args...; kwargs...)
    error("`to_repository` requires DuckDB.jl. Run `using DuckDB` to load the EDGAR.jl repository loader.")
end

"""
    classify_tables!(db; doc_id=nothing) -> Dict{String,Int}

Tag every repository table by class: set `tables.kind` (`"statement"`/`"descriptive"`) and
`tables.statement_type` (e.g. `"balance_sheet"`) by matching each table's caption or enclosing section
title against [`TABLE_CLASSES`](@ref) (via [`classify_table_class`](@ref)). Optionally restrict to one
`doc_id`. Returns counts per class. **Available only after `using DuckDB`** (package extension).
"""
function classify_tables!(args...; kwargs...)
    error("`classify_tables!` requires DuckDB.jl. Run `using DuckDB` to load the EDGAR.jl repository loader.")
end
