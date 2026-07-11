# toc.jl — the table of contents / document outline: the STRUCTURE layer, parallel to facts() (numbers) and
# narratives() (prose). One source-agnostic row table across formats — a PDF's bookmark outline, an HTML/iXBRL
# document's heading hierarchy, or an XBRL filing's presentation-linkbase statement roles. Rows are in document
# order; `level` encodes the hierarchy (rebuild a tree from it); `source` says which producer emitted them.

struct TocNode
    cik::String
    accession::String
    source::Symbol            # :pdf | :html | :ixbrl | :xbrl
    ord::Int                  # document order (1-based)
    level::Int                # nesting depth (0 = top level)
    title::String
    page::Union{Nothing,Int}  # PDF page (nothing for HTML/XBRL)
    anchor::String            # HTML element id / iXBRL anchor / XBRL role — for back-linking ("" if none)
    kind::String              # "" | "statement" | … (semantic tag; "" unless a producer sets it)
end

function TocNode(; cik::AbstractString = "", accession::AbstractString = "", source::Symbol = :pdf,
                 ord::Integer = 0, level::Integer = 0, title::AbstractString = "",
                 page::Union{Nothing,Integer} = nothing, anchor::AbstractString = "", kind::AbstractString = "")
    TocNode(String(cik), String(accession), source, Int(ord), Int(level), String(title),
            page === nothing ? nothing : Int(page), String(anchor), String(kind))
end

Base.show(io::IO, n::TocNode) = print(io, "TocNode(", repr(n.title), " L", n.level, " [", n.source, "]",
    n.page === nothing ? "" : " p$(n.page)", ")")

# Internal: one entry as a Tables.jl row (a NamedTuple) — the column schema and order for storage/export.
toc_row(n::TocNode) = (cik = n.cik, accession = n.accession, source = String(n.source), ord = n.ord,
                       level = n.level, title = n.title, page = n.page, anchor = n.anchor, kind = n.kind)

# The row-table element type, so an empty table (a document with no outline) is still concretely typed.
const TocRow = @NamedTuple{cik::String, accession::String, source::String, ord::Int, level::Int,
                           title::String, page::Union{Nothing,Int}, anchor::String, kind::String}

_toc_table(v::AbstractVector{TocNode}) = TocRow[toc_row(n) for n in v]

"""
    toc(x) -> Tables.jl row table of `TocRow`

The **table of contents** / outline of a document — the STRUCTURE layer, parallel to [`facts`](@ref) (numbers)
and [`narratives`](@ref) (prose). `x` may be a [`Filing`](@ref), a `StructuredDocument`, or a PDF path. Rows are
in document order; `level` encodes the hierarchy (0 = top level), so a tree is reconstructable. `source` is
`:pdf` (the bookmark outline), `:html` / `:ixbrl` (the heading hierarchy) or `:xbrl` (presentation-linkbase
statement roles). `page` is set for PDF, `anchor` for HTML/XBRL (an element id / role — for back-linking).
Faithful to the source: a PDF with only two coarse bookmarks yields two rows.

```julia
toc(fetch_filing(first(discover(HKEXFilings(); code = "02388"))))   # BOC Hong Kong: the AR outline
toc("annual_report.pdf")                                            # straight from a PDF path (no Docling)
```
"""
function toc end

# ── PDF: the bookmark outline (cheap — the Node/pdf.js pass, NO Docling) ──────
function _toc_pdf(path::AbstractString; cik = "", accession = "")
    doc = _pdf_words(path)
    out = TocNode[]
    (haskey(doc, :outline) && doc.outline !== nothing) || return _toc_table(out)
    for (i, e) in enumerate(doc.outline)
        t = strip(String(get(e, :title, ""))); isempty(t) && continue
        p = get(e, :page, nothing)
        push!(out, TocNode(; cik, accession, source = :pdf, ord = i, level = Int(get(e, :level, 0)),
              title = t, page = p === nothing ? nothing : Int(p)))
    end
    _toc_table(out)
end

toc(path::AbstractString) = _toc_pdf(path)                 # a PDF path

# ── StructuredDocument: its bookmark outline (sd.toc), else its parsed section tree ──
function toc(sd::StructuredDocument)
    acc = sd.document.doc_id
    out = TocNode[]
    if !isempty(sd.toc)
        for (i, e) in enumerate(sd.toc)
            isempty(strip(e.title)) && continue
            push!(out, TocNode(; accession = acc, source = :pdf, ord = i, level = e.level,
                  title = e.title, page = e.page))
        end
    else                                                   # no bookmarks — fall back to the parsed section tree
        for (i, s) in enumerate(sd.sections)
            isempty(strip(s.title)) && continue
            push!(out, TocNode(; accession = acc, source = :pdf, ord = i, level = s.level,
                  title = s.title, page = s.page_start, anchor = s.section_id))
        end
    end
    _toc_table(out)
end

# ── HTML / iXBRL: the heading hierarchy (h1…h6), anchored by element id, in document order ──
function _toc_html(html::AbstractString; cik = "", accession = "", source::Symbol = :html)
    out = TocNode[]
    body = (!occursin('<', html) && isfile(html)) ? read(html, String) : String(html)
    isempty(strip(body)) && return _toc_table(out)
    doc = try EzXML.parsehtml(body) catch; return _toc_table(out) end
    ord = Ref(0)
    function visit(n)
        if EzXML.iselement(n)
            m = match(r"^h([1-6])$", lowercase(EzXML.nodename(n)))
            if m !== nothing
                t = strip(EzXML.nodecontent(n))
                if !isempty(t)
                    ord[] += 1
                    id = EzXML.haskey(n, "id") ? n["id"] : ""
                    push!(out, TocNode(; cik, accession, source, ord = ord[],
                          level = parse(Int, m.captures[1]) - 1, title = t, anchor = id))
                end
            end
        end
        for c in EzXML.eachnode(n); visit(c); end
    end
    visit(EzXML.root(doc))
    _toc_table(out)
end

# ── XBRL / iXBRL: the presentation-linkbase statement roles — the filing's "contents" ──
const _TOC_STMT_ORDER = ["CoverPage", "BalanceSheet", "IncomeStatement", "ComprehensiveIncome", "Equity", "CashFlow"]

function _toc_xbrl(f::Filing; cik = "", accession = "")
    sm = try statement_map(f) catch; Dict{String,String}() end
    present = unique(collect(values(sm)))
    ordered = vcat([s for s in _TOC_STMT_ORDER if s in present],   # canonical statement order first,
                   [s for s in present if !(s in _TOC_STMT_ORDER)]) # then anything else the linkbase names
    _toc_table([TocNode(; cik, accession, source = f.kind, ord = i, level = 0, title = s, kind = "statement")
                for (i, s) in enumerate(ordered)])
end

# ── Filing dispatch: pick the producer by format ──
function toc(f::Filing)
    cik = f.entity.scheme === :cik ? f.entity.value : ""
    acc = f.ref
    if f.kind === :pdf
        (!isempty(f.content) && isfile(f.content)) ||
            throw(ArgumentError("toc(::Filing) for a :pdf filing needs the PDF path in `f.content`; this " *
                  "filing carries none. Use `toc(path)` with the downloaded PDF."))
        return _toc_pdf(f.content; cik, accession = acc)
    end
    if f.kind === :xbrl || f.kind === :ixbrl
        t = _toc_xbrl(f; cik, accession = acc)
        # An iXBRL instance is also HTML: when the presentation-linkbase outline is empty (a bare instance
        # with no reachable linkbase — e.g. a Generic-opened ESEF/DCCA report), lift its own HTML headings.
        (f.kind === :ixbrl && isempty(t)) && return _toc_html(f.content; cik, accession = acc, source = :ixbrl)
        return t
    end
    f.kind === :html && return _toc_html(f.content; cik, accession = acc, source = :html)
    throw(ArgumentError("toc(::Filing): unsupported filing kind $(repr(f.kind))"))
end
