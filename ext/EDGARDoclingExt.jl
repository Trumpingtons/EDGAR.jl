# Package extension: the Docling (Tier-2, document-AI) PDF parser, reached via PythonCall.
# Loaded automatically when both EDGAR and PythonCall are in the session — keeping Python an OPTIONAL
# dependency (the core package never loads it; Pollis/Electron stays Python-free). It implements
# `EDGAR.structured_document`, driving Docling in-process and mapping its DoclingDocument onto EDGAR's
# `StructuredDocument` (sections / text_blocks / tables+cells / figures + metadata, with page+bbox).
#
# Environment: PythonCall must point at the Tier-2 venv (Docling + MinerU installed). Set BEFORE the
# first `using PythonCall`:
#   ENV["JULIA_CONDAPKG_BACKEND"] = "Null"
#   ENV["JULIA_PYTHONCALL_EXE"]   = expanduser("~/EDGAR-tools/tier2-venv/bin/python")
module EDGARDoclingExt

using EDGAR
using PythonCall
using EDGAR: BBox, DocSection, TextBlock, TableCell, DocTable, DocFigure, DocMeta, StructuredDocument

const _NONE = pybuiltins.None
_optstr(x) = pyis(x, _NONE) ? nothing : (s = strip(pyconvert(String, x)); isempty(s) ? nothing : String(s))
_optstr(::Nothing) = nothing

# bbox: docling is BOTTOMLEFT (y from page bottom); convert to TOP-LEFT (y from top) using page height.
function _bbox(prov, pageH::Dict{Int,Float64})
    pyconvert(Int, pybuiltins.len(prov)) == 0 && return nothing
    p0 = prov[0]
    page = pyconvert(Int, p0.page_no)
    bb = p0.bbox
    l = pyconvert(Float64, bb.l); t = pyconvert(Float64, bb.t)
    r = pyconvert(Float64, bb.r); b = pyconvert(Float64, bb.b)
    H = get(pageH, page, 0.0)
    return H > 0 ? BBox(page, l, H - t, r, H - b) : BBox(page, l, t, r, b)
end

function EDGAR.structured_document(path::AbstractString;
        pages::Union{Nothing,Tuple{Integer,Integer}} = nothing, ocr::Bool = false,
        doc_id::AbstractString = first(splitext(basename(path))),
        jurisdiction = nothing, language = nothing, company = nothing,
        report_type = nothing, fiscal_year = nothing, currency = nothing, framework = nothing)

    isfile(path) || throw(ArgumentError("PDF not found: $(repr(path))"))
    bm  = pyimport("docling.datamodel.base_models")
    po  = pyimport("docling.datamodel.pipeline_options")
    dc  = pyimport("docling.document_converter")
    ilm = pyimport("importlib.metadata")

    opts = po.PdfPipelineOptions()
    opts.do_ocr = ocr
    opts.do_table_structure = true
    fo = pydict(); fo[bm.InputFormat.PDF] = dc.PdfFormatOption(pipeline_options = opts)
    conv = dc.DocumentConverter(format_options = fo)
    res  = pages === nothing ? conv.convert(path) : conv.convert(path; page_range = pages)
    doc  = res.document

    npages = pyconvert(Int, doc.num_pages())
    pver   = pyconvert(String, ilm.version("docling"))
    lang   = language === nothing ? "und" : String(language)

    pageH = Dict{Int,Float64}()
    try
        for kv in doc.pages.items()
            pageH[pyconvert(Int, kv[0])] = pyconvert(Float64, kv[1].size.height)
        end
    catch
    end

    sections = DocSection[]; texts = TextBlock[]; tables = DocTable[]; figures = DocFigure[]
    secstack = Tuple{Int,String}[]               # (level, section_id)
    ord = 0
    cursec() = isempty(secstack) ? nothing : secstack[end][2]

    for pair in doc.iterate_items()
        item = pair[0]
        cls  = pyconvert(String, item.__class__.__name__)
        ord += 1
        if cls == "SectionHeaderItem"
            lvl = pyconvert(Int, item.level)
            bx  = _bbox(item.prov, pageH)
            while !isempty(secstack) && secstack[end][1] >= lvl
                pop!(secstack)
            end
            parent = cursec()
            sid = string(doc_id, ":s", length(sections) + 1)
            pg = bx === nothing ? 0 : bx.page
            push!(sections, DocSection(sid, parent, lvl, pyconvert(String, item.text), lang, ord, pg, pg, bx))
            push!(secstack, (lvl, sid))
        elseif cls == "TextItem" || cls == "ListItem"
            label = pyconvert(String, item.label.value)
            (label == "page_header" || label == "page_footer") && continue
            bx  = _bbox(item.prov, pageH)
            txt = pyconvert(String, item.text)
            kind = cls == "ListItem" ? "list_item" :
                   (label == "caption" || label == "footnote") ? label : "paragraph"
            push!(texts, TextBlock(string(doc_id, ":t", length(texts) + 1), cursec(), ord, kind,
                  txt, lang, bx === nothing ? 0 : bx.page, bx, length(txt)))
        elseif cls == "TableItem"
            bx = _bbox(item.prov, pageH)
            nr = pyconvert(Int, item.data.num_rows); nc = pyconvert(Int, item.data.num_cols)
            cells = TableCell[]
            for cell in item.data.table_cells
                r0 = pyconvert(Int, cell.start_row_offset_idx); r1 = pyconvert(Int, cell.end_row_offset_idx)
                c0 = pyconvert(Int, cell.start_col_offset_idx); c1 = pyconvert(Int, cell.end_col_offset_idx)
                ishdr = pyconvert(Bool, cell.column_header) || pyconvert(Bool, cell.row_header)
                push!(cells, TableCell(r0, c0, max(1, r1 - r0), max(1, c1 - c0), ishdr,
                      pyconvert(String, cell.text)))
            end
            pg = bx === nothing ? 0 : bx.page
            push!(tables, DocTable(string(doc_id, ":tbl", length(tables) + 1), cursec(), ord,
                  "unknown", nothing, _optstr(item.caption_text(doc)), lang, pg, pg, bx, nr, nc, cells))
        elseif cls == "PictureItem"
            bx = _bbox(item.prov, pageH)
            push!(figures, DocFigure(string(doc_id, ":fig", length(figures) + 1), cursec(), ord,
                  _optstr(item.caption_text(doc)), bx === nothing ? 0 : bx.page, bx,
                  nothing, nothing, nothing, nothing))
        end
    end

    meta = DocMeta(String(doc_id), abspath(path), _optstr(jurisdiction), nothing, _optstr(language),
        _optstr(company), _optstr(report_type),
        fiscal_year === nothing ? nothing : Int(fiscal_year),
        _optstr(currency), _optstr(framework), npages, "docling", pver, ocr)

    return StructuredDocument("1.0", meta, sections, texts, tables, figures)
end

end # module
