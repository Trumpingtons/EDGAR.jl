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
using EDGAR: BBox, DocSection, TextBlock, TableCell, DocTable, DocFigure, DocMeta, StructuredDocument, TocEntry

const _NONE = pybuiltins.None
_optstr(x) = pyis(x, _NONE) ? nothing : (s = strip(pyconvert(String, x)); isempty(s) ? nothing : String(s))
_optstr(::Nothing) = nothing

# bbox: docling is BOTTOMLEFT (y from page bottom); convert to TOP-LEFT (y from top) using page height.
function _bbox(prov, pageH::Dict{Int,Float64})
    try
        pyconvert(Int, pybuiltins.len(prov)) == 0 && return nothing
        p0 = prov[0]
        page = pyconvert(Int, p0.page_no)
        bb = p0.bbox
        l = pyconvert(Float64, bb.l); t = pyconvert(Float64, bb.t)
        r = pyconvert(Float64, bb.r); b = pyconvert(Float64, bb.b)
        H = get(pageH, page, 0.0)
        return H > 0 ? BBox(page, l, H - t, r, H - b) : BBox(page, l, t, r, b)
    catch
        return nothing   # HTML / no page coordinates
    end
end

# Self-emitted progress. Docling's convert() is a single silent blocking call that emits no intermediate
# signal AND starves a background printer thread (so a live ticking bar is impractical here). Instead we
# print a reliable, zero-dep FORECAST up front (page count × ~2 s/page measured) and the ACTUAL time on
# completion — which is what removes the "long silent wait" surprise. `npages<=0` (e.g. HTML) → no ETA.
function _docling_progress(run, npages::Integer, name; per_page = 2.0)
    if npages > 0
        est = round(Int, npages * per_page)
        println("  ", name, ": ", npages, " pages — est ~", est, "s (~", round(Int, 60 / per_page),
                " pages/min). Docling runs silently; please wait…")
    else
        println("  ", name, ": converting (page count unknown)…")
    end
    flush(stdout)
    t0 = time()
    r = run()
    println("  ", name, ": done in ", round(Int, time() - t0), "s")
    flush(stdout)
    return r
end

# Jurisdictions whose PDFs carry a garbled-but-present (CID) text layer that Docling's
# "OCR only where text is MISSING" heuristic mis-trusts — so full-page OCR must be FORCED. Japan/EDINET
# is the documented case (see pdf-extractor-plan); add others here as they're found.
_force_ocr_default(jurisdiction, language) =
    uppercase(strip(String(something(jurisdiction, "")))) == "JP" ||
    lowercase(strip(String(something(language, "")))) in ("ja", "jp", "japanese")

function EDGAR.structured_document(path::AbstractString;
        pages::Union{Nothing,Tuple{Integer,Integer}} = nothing, ocr::Bool = false,
        force_ocr::Union{Nothing,Bool} = nothing,
        doc_id::AbstractString = first(splitext(basename(path))),
        jurisdiction = nothing, language = nothing, company = nothing,
        report_type = nothing, fiscal_year = nothing, currency = nothing, framework = nothing,
        with_images::Bool = true, progress::Bool = false)

    isfile(path) || throw(ArgumentError("file not found: $(repr(path))"))
    language === nothing || EDGAR._validate_presentation_lang(language; context = "structured_document")
    bm  = pyimport("docling.datamodel.base_models")
    po  = pyimport("docling.datamodel.pipeline_options")
    dc  = pyimport("docling.document_converter")
    ilm = pyimport("importlib.metadata")
    io  = pyimport("io")

    ishtml = lowercase(last(splitext(path))) in (".htm", ".html")
    if ishtml
        # HTML input (e.g. a SEC N-CSR): Docling's HTML pipeline. `pages`/`ocr` do not apply, and the
        # document has no page coordinates, so bbox/page come through empty (handled below).
        conv = dc.DocumentConverter(allowed_formats = pylist([bm.InputFormat.HTML]))
        runconv = () -> conv.convert(path)
        npages = 0
    else
        # Force full-page OCR when asked, or by default for jurisdictions with a garbled CID text layer
        # (Japan/EDINET). Forcing implies OCR on. NOTE: full-page OCR adds real per-page compute — it is
        # NOT free; selective OCR was fast only because it skipped most pages.
        fforce = force_ocr === nothing ? _force_ocr_default(jurisdiction, language) : force_ocr
        opts = po.PdfPipelineOptions()
        opts.do_ocr = ocr || fforce
        fforce && (opts.ocr_options.force_full_page_ocr = true)
        opts.do_table_structure = true
        if with_images
            opts.generate_picture_images = true
            opts.images_scale = 2.0
        end
        fo = pydict(); fo[bm.InputFormat.PDF] = dc.PdfFormatOption(pipeline_options = opts)
        conv = dc.DocumentConverter(format_options = fo)
        runconv = pages === nothing ? (() -> conv.convert(path)) : (() -> conv.convert(path; page_range = pages))
        npages = pages === nothing ?
            (try pyconvert(Int, pybuiltins.len(pyimport("pypdfium2").PdfDocument(path))) catch; 0 end) :
            (Int(pages[2]) - Int(pages[1]) + 1)
    end
    if progress
        # load the models first (the noisy, one-time part) so the forecast prints right as the
        # genuinely-silent page processing begins — not before model loading.
        conv.initialize_pipeline(ishtml ? bm.InputFormat.HTML : bm.InputFormat.PDF)
        res = _docling_progress(runconv, npages, basename(path))
    else
        res = runconv()
    end
    doc = res.document

    npages = try pyconvert(Int, doc.num_pages()) catch; 0 end
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
    figbytes = Dict{String,Vector{UInt8}}()      # figure_id -> PNG bytes (when with_images)
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
            n = length(figures) + 1
            fid = string(doc_id, ":fig", n)
            ipath = nothing; ifmt = nothing; iw = nothing; ih = nothing
            if with_images
                try
                    img = item.get_image(doc)
                    if !pyis(img, _NONE)
                        buf = io.BytesIO(); img.save(buf, "PNG")
                        figbytes[fid] = pyconvert(Vector{UInt8}, buf.getvalue())
                        ipath = string("figures/fig", n, ".png"); ifmt = "png"
                        iw = pyconvert(Int, img.width); ih = pyconvert(Int, img.height)
                    end
                catch
                end
            end
            push!(figures, DocFigure(fid, cursec(), ord, _optstr(item.caption_text(doc)),
                  bx === nothing ? 0 : bx.page, bx, ipath, ifmt, iw, ih))
        end
    end

    meta = DocMeta(String(doc_id), abspath(path), _optstr(jurisdiction), nothing, _optstr(language),
        _optstr(company), _optstr(report_type),
        fiscal_year === nothing ? nothing : Int(fiscal_year),
        _optstr(currency), _optstr(framework), npages, "docling", pver, ocr)

    # PDF outline / bookmarks — an authoritative heading+page source (immune to page-header noise),
    # read with pypdfium2 (same venv). Empty for HTML or PDFs without an outline.
    toc = TocEntry[]
    if !ishtml
        try
            pdoc = pyimport("pypdfium2").PdfDocument(path)
            for it in pdoc.get_toc()
                pyis(it.title, _NONE) && continue
                lvl = try pyconvert(Int, it.level) catch; 0 end
                pg  = try (pi = it.page_index; pyis(pi, _NONE) ? 0 : pyconvert(Int, pi) + 1) catch; 0 end
                push!(toc, TocEntry(pyconvert(String, it.title), lvl, pg))
            end
            pdoc.close()
        catch
        end
    end

    return StructuredDocument("1.0", meta, sections, texts, tables, figures, toc, figbytes)
end

end # module
