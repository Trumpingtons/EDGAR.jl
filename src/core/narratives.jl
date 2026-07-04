# narratives() — the presentation/text layer, parallel to facts() (numeric). A `Narrative` is prose's
# `Fact`: one narrative section harvested from a filing, whatever the source — an XBRL/iXBRL text-block,
# an ingested PDF section, or a SEC HTML Item. `narratives(f)` returns a Tables.jl row table of these, so
# downstream (search, export, LLM) is source-agnostic. See docs/dev/narratives-plan.md.
#
# N0: the type + row schema + the empty generic. Producers (N1 XBRL/iXBRL, N3 PDF, N4 HTML) add methods.

"""
    Narrative

One narrative section extracted from a filing — the text-layer counterpart of [`Fact`](@ref). Its content
is the prose (`text`); its identity/provenance depend on where it came from (`source`):

- `cik`, `accession` — the filer and filing (provenance).
- `source` — `:xbrl` / `:ixbrl` (a tagged text-block fact), `:pdf` (an ingested-PDF section) or `:html`
  (a SEC Item/Part section).
- `concept` — the XBRL text-block concept, namespaced (`"jpcrp_cor:BusinessRisksTextBlock"`); `""` for a
  PDF/HTML section (which has no concept).
- `section_title` — the section's own name, verbatim in its native language: the EDINET **verbose** label /
  the SEC Item title / the PDF heading (falls back to the concept local-name if unlabeled — never `""`).
- `canonical_title` — the **normalized** section name (the `standard_concept` analogue for prose). Defaults
  to `section_title`; a later `classify` pass can canonicalise/translate it (English, Mandarin, …). Never `""`.
- `tags` — a multi-valued, cross-filer **thematic** classification (`["climate", "supply-chain"]`): the axis
  along which narratives from *different* filers are grouped by theme. Empty for now — reserved for a later
  (AI or manual) tagging pass. Multiple axes encode as namespaced tags (`"theme:climate"`, `"risk:fx"`).
- `text` — the content, HTML-stripped to plain text.
- `lang` — the ISO-639 content language as a **`Symbol`** (`:zh` / `:ja` / `:ko` / `:en`; `Symbol("")` if
  unknown), matching the `Symbol` convention of the other tag-like fields on this row (`source`, and a
  filing's `kind`). The value comes from the source's own tag when meaningful, else a script guess
  (`_guess_lang`); an undetermined tag (`"und"`) is treated as unknown and re-guessed. It serialises to a
  plain `String` in the storage row (see `narrative_row`), exactly as `source` does.
- `char_len` — `length(text)` (set automatically).
- `period_end` — the XBRL context period end; `nothing` for PDF/HTML.
- `dimensions` — axis ⇒ member qualifiers (XBRL only); empty otherwise.
- `context_ref` — the raw XBRL context reference (provenance); `""` otherwise.
- `page` — the PDF page (provenance); `nothing` otherwise.
- `block_id` — the PDF/HTML block/section id (provenance); `""` otherwise.

`Narrative`s flow to disk as a Tables.jl row table (see the internal `narrative_row` for the exact column
schema). Build one with the keyword constructor; `char_len` is derived from `text`.
"""
struct Narrative
    cik::String
    accession::String
    source::Symbol
    concept::String
    section_title::String
    canonical_title::String
    tags::Vector{String}
    text::String
    lang::Symbol
    char_len::Int
    period_end::Union{Nothing,Date}
    dimensions::Dict{String,String}
    context_ref::String
    page::Union{Nothing,Int}
    block_id::String
end

# Keyword constructor — `char_len` is derived from `text`, so callers never set it by hand.
function Narrative(; cik::AbstractString = "", accession::AbstractString = "", source::Symbol = :xbrl,
                   concept::AbstractString = "", section_title::AbstractString = "",
                   canonical_title::Union{Nothing,AbstractString} = nothing,
                   tags::AbstractVector{<:AbstractString} = String[],
                   text::AbstractString = "", lang::Union{Symbol,AbstractString} = Symbol(""),
                   period_end::Union{Nothing,Date} = nothing,
                   dimensions::AbstractDict = Dict{String,String}(), context_ref::AbstractString = "",
                   page::Union{Nothing,Int} = nothing, block_id::AbstractString = "")
    ct = canonical_title === nothing ? section_title : canonical_title   # defaults to the section title
    Narrative(cik, accession, source, concept, section_title, ct, Vector{String}(tags), text, Symbol(lang),
              length(text), period_end, Dict{String,String}(dimensions), context_ref, page, block_id)
end

Base.show(io::IO, n::Narrative) = print(io, "Narrative(",
    isempty(n.concept) ? repr(n.section_title) : n.concept, " [", n.source, "] ", n.char_len, " chars)")

# Internal: one narrative as a Tables.jl row (a NamedTuple) — the exact column schema and order for
# storage/export. `dimensions` is serialised to a JSON string, mirroring `fact_row`.
narrative_row(n::Narrative) =
    (cik = n.cik, accession = n.accession, source = String(n.source), concept = n.concept,
     section_title = n.section_title, canonical_title = n.canonical_title, tags = JSON3.write(n.tags),
     text = n.text, lang = String(n.lang), char_len = n.char_len, period_end = n.period_end,
     dimensions = JSON3.write(n.dimensions), context_ref = n.context_ref, page = n.page, block_id = n.block_id)

# The narrative row-table schema: the element type of the Tables.jl row table `narratives` returns, so an
# empty table (a filing with no narrative sections) is still concretely typed. Mirrors `narrative_row`.
const NarrativeRow = @NamedTuple{cik::String, accession::String, source::String, concept::String,
    section_title::String, canonical_title::String, tags::String, text::String, lang::String,
    char_len::Int, period_end::Union{Nothing,Date}, dimensions::String, context_ref::String,
    page::Union{Nothing,Int}, block_id::String}

# Build the row table from a vector of `Narrative`s (concretely typed even when empty).
_narrative_table(ns::AbstractVector{Narrative}) = NarrativeRow[narrative_row(n) for n in ns]

"""
    narratives(f::Filing; ...) -> Tables.jl row table of `Narrative`

The narrative/text sections of a filing — the prose counterpart of [`facts`](@ref). Harvests XBRL/iXBRL
text-blocks, ingested-PDF sections, or SEC HTML Item sections into one source-agnostic row table (see
[`Narrative`](@ref)). Producers are added per source; methods below.
"""
function narratives end

# ── N1: XBRL / iXBRL text-block producers ────────────────────────────────────
# Generalises `_dei_fact` (filing_systems/sec/auditor.jl): instead of one named DEI concept, harvest EVERY
# text-block, reusing its `ix:nonNumeric` / classic patterns and `_dei_clean` (tag-strip + entity-decode).
#
# A narrative section is a text-block fact: an XBRL concept whose local name ends in "TextBlock" (EDINET
# jpcrp/jpigp/jppfs, SEC us-gaap, …). General across jurisdictions — no per-system table needed for the
# predicate (the EDINET concept table's `type` can refine it later).
# A text-block concept, across taxonomy conventions: EDINET/SEC/us-gaap end the local name in "TextBlock";
# IFRS/ESEF (ifrs-full) end it in "Explanatory" (e.g. DisclosureOfSignificantAccountingPoliciesExplanatory).
_is_narrative_concept(c::AbstractString) = endswith(c, "TextBlock") || endswith(c, "Explanatory")

# The section title: the concept's label if the taxonomy provides one, else the concept local-name (part
# after the ':') so a filer-extension text-block is still named, never blank.
_narr_title(concept, labels) =
    (t = get(labels, concept, ""); isempty(t) ? String(last(split(concept, ':'))) : t)

# Text-block cleaner. Unlike `_dei_clean` (strip-then-decode, for plain DEI strings), a text-block stores
# ESCAPED html (`&lt;p&gt;…`), so we must DECODE entities FIRST (turning `&lt;p&gt;` into `<p>`) and strip
# tags AFTER — else the markup decodes into visible text. Yields the clean prose the CSV oracle carries.
const _NARR_ENTITIES = Dict("amp" => "&", "lt" => "<", "gt" => ">", "quot" => "\"", "apos" => "'", "nbsp" => " ")
function _decode_entities(s::AbstractString)
    replace(s, r"&(#x?[0-9a-fA-F]+|\w+);" => function (e)
        nm = e[2:end-1]
        if startswith(nm, "#x") || startswith(nm, "#X")
            c = tryparse(Int, nm[3:end]; base = 16); return (c === nothing || c > 0x10FFFF) ? e : string(Char(c))
        elseif startswith(nm, "#")
            c = tryparse(Int, nm[2:end]); return (c === nothing || c > 0x10FFFF) ? e : string(Char(c))
        end
        return get(_NARR_ENTITIES, nm, e)
    end)
end
function _textblock_clean(s::AbstractString)
    notags = replace(_decode_entities(s), r"(?is)<[^>]*>" => " ")   # decode FIRST, then strip tags
    return strip(replace(notags, r"\s+" => " "))
end

# Cheap script guess for the content language, distinguishing the CJK scripts: Japanese kana ⇒ ja; else
# Hangul ⇒ ko (DART); else Han-only ⇒ zh (CNINFO — Chinese has no kana). A caller-supplied section language
# takes precedence (see `narratives(::StructuredDocument)`); this is the fallback when none is set.
# Match EXPLICIT kana/hangul/ideograph codepoint ranges, NOT \p{Hiragana}/\p{Katakana}/\p{Hangul}: PCRE
# resolves those script classes via Script_Extensions, so the shared CJK punctuation 、。(U+3001/3002, used in
# Chinese too) counts as Katakana AND Hangul — which would flag every Chinese sentence as Japanese. The kana
# (U+3041–, U+30A1–) and Hangul-syllable (U+AC00–) blocks sit ABOVE the U+3000–303F punctuation block, so
# explicit ranges see only real script letters. Order matters: Japanese has kana, Chinese has neither.
_guess_lang(s::AbstractString) =
    occursin(r"[ぁ-ゖァ-ヺー]", s) ? :ja :   # hiragana / katakana letters
    occursin(r"[가-힣]", s)                    ? :ko :   # hangul syllables
    occursin(r"[一-鿿㐀-䶿]", s)        ? :zh :   # CJK ideographs
    :en

# A context's period end + dimensions, from `_xbrl_contexts`' parsed contexts.
function _narr_ctx(ctxs, ref::AbstractString)
    ctx = get(ctxs, ref, nothing)
    ctx === nothing && return (nothing, Dict{String,String}())
    pend = ctx.instant !== nothing ? ctx.instant : ctx.stop
    return (pend === nothing ? nothing : tryparse(Date, pend), ctx.dims)
end

# Classic instance: text-block elements carry ESCAPED html (no literal '<'), no `unitRef`. Deduped by
# (concept, context) — a filer tags the same block in several places (cf. the CSV-oracle duplicate rows).
function _classic_narratives(content, cik, accession, ctxs, labels)
    out = Narrative[]; seen = Set{Tuple{String,String}}()
    for m in eachmatch(r"(?is)<([\w-]+:[\w.-]*TextBlock)\b([^>]*)>([^<]*)</\1>", content)
        concept = String(m.captures[1]); a = _attrs(m.captures[2]); ref = get(a, "contextRef", "")
        (isempty(ref) || (concept, ref) in seen) && continue
        push!(seen, (concept, ref))
        text = _textblock_clean(m.captures[3]); isempty(text) && continue
        pe, dims = _narr_ctx(ctxs, ref)
        push!(out, Narrative(; cik, accession, source = :xbrl, concept, section_title = _narr_title(concept, labels),
                             text, lang = _guess_lang(text), period_end = pe, dimensions = dims, context_ref = ref))
    end
    return out
end

# Inline iXBRL: text-block facts are `<ix:nonNumeric name="…TextBlock" …>…</ix:nonNumeric>` (content may
# carry rendered markup, which `_dei_clean` strips). NOTE: split-across-`ix:continuation` blocks capture
# only the head for now — EDINET ships a classic instance (preferred), so this path is the inline fallback.
function _ixbrl_narratives(content, cik, accession, ctxs, labels)
    out = Narrative[]; seen = Set{Tuple{String,String}}()
    for m in eachmatch(r"(?is)<ix:nonNumeric\b([^>]*)>(.*?)</ix:nonNumeric>", content)
        a = _attrs(m.captures[1]); concept = get(a, "name", "")
        _is_narrative_concept(concept) || continue
        ref = get(a, "contextRef", ""); (isempty(ref) || (concept, ref) in seen) && continue
        push!(seen, (concept, ref))
        text = _textblock_clean(m.captures[2]); isempty(text) && continue
        pe, dims = _narr_ctx(ctxs, ref)
        push!(out, Narrative(; cik, accession, source = :ixbrl, concept, section_title = _narr_title(concept, labels),
                             text, lang = _guess_lang(text), period_end = pe, dimensions = dims, context_ref = ref))
    end
    return out
end

# Extract every text-block narrative from a filing (mirrors `_extract_facts`' kind dispatch).
function _extract_narratives(f::Filing; labels::AbstractDict = Dict{String,String}())
    ctxs = _xbrl_contexts(f.content)
    cik, acc = f.entity.value, f.ref
    return f.kind === :xbrl ? _classic_narratives(f.content, cik, acc, ctxs, labels) :
                              _ixbrl_narratives(f.content, cik, acc, ctxs, labels)
end

function narratives(f::Filing; classify::Bool = false, labels::Bool = true,
                    lang::Union{AbstractString,Nothing} = nothing)
    # `classify` is reserved for populating each narrative's `canonical_title` (the normalised title — the
    # prose analogue of `facts`' statement classification); a no-op until that mapping lands.
    classify
    if f.kind === :pdf
        (!isempty(f.content) && isfile(f.content)) || throw(ArgumentError(
            "narratives(::Filing) for a :pdf filing needs the PDF source path in `f.content`; or call " *
            "narratives(structured_document(path)) / narratives(read_structured_document(json.path))."))
        return narratives(structured_document(f.content))
    end
    f.system isa SEC && return _sec_narratives(f)          # N4: SEC Item/Part sections
    labdict = labels ? (try label_map(f; lang) catch; Dict{String,String}() end) : Dict{String,String}()
    return _narrative_table(_extract_narratives(f; labels = labdict))
end

# ── N4: SEC HTML producer — Item/Part sections → Narrative rows (source :html) ─
# Wraps `sections(f; form)` (the SEC Item/Part detector). Each Item is a narrative: `section_title` = the
# Item title, `text` = its extracted prose, `block_id` = the item id (e.g. "Item 1A"). No XBRL concept.
# Strip SEC running page-footers that leak into section text, e.g. "Apple Inc. | 2025 Form 10-K | 3".
# General across filers/forms: "<company> | <year> Form 10-{K,Q} | <page>" (not company-hardcoded).
function _strip_running_footer(t::AbstractString)
    t = replace(t, r"\n?[^\n|]{0,80}\|\s*\d{4}\s+Form\s+10-[KQ]\b[^\n|]*\|\s*\d+\s*"i => "\n")
    return strip(replace(t, r"\n{3,}" => "\n\n"))
end

function _sec_narratives(f::Filing; form::AbstractString = "10-K")
    out = Narrative[]
    for s in sections(f; form)
        t = _strip_running_footer(s.text); isempty(t) && continue
        push!(out, Narrative(; accession = f.ref, source = :html, section_title = s.title,
                             text = String(t), lang = _guess_lang(t), block_id = s.item))
    end
    return _narrative_table(out)
end

# ── N3: PDF producer — a StructuredDocument's sections → Narrative rows ────────
# One Narrative per document section: its text-blocks concatenated in reading order. `concept`/`context_ref`
# are empty (a PDF section has no XBRL identity); provenance is `page` + `block_id` (= section id). Works on
# ANY StructuredDocument — freshly parsed (`structured_document`, needs Docling) or reloaded
# (`read_structured_document`), so it is testable without the Docling stack.
function narratives(sd::StructuredDocument)
    bysec = Dict{String,Vector{TextBlock}}()
    for b in sd.text_blocks
        push!(get!(bysec, something(b.section_id, ""), TextBlock[]), b)
    end
    secmap = Dict(s.section_id => s for s in sd.sections)
    acc = sd.document.doc_id
    # sections in document order, then any block-groups with no matching DocSection (never drop text)
    order = vcat([s.section_id for s in sd.sections], [sid for sid in keys(bysec) if !haskey(secmap, sid)])
    out = Narrative[]
    for sid in order
        blocks = get(bysec, sid, TextBlock[]); isempty(blocks) && continue
        sort!(blocks; by = b -> b.ord)
        text = strip(join((b.text for b in blocks), "\n")); isempty(text) && continue
        s = get(secmap, sid, nothing)
        title = (s !== nothing && !isempty(s.title)) ? s.title : (isempty(sid) ? "(untitled)" : sid)
        # DocSection lang wins when meaningful; an empty or "und" (undetermined) Docling tag → guess by script.
        lg    = (s !== nothing && !isempty(s.lang) && s.lang != "und") ? Symbol(s.lang) : _guess_lang(text)
        page  = s !== nothing ? s.page_start : minimum(b.page for b in blocks)
        push!(out, Narrative(; accession = acc, source = :pdf, section_title = title, text = String(text),
                             lang = lg, page = page, block_id = sid))
        delete!(bysec, sid)                       # guard against a section id repeating in `order`
    end
    return _narrative_table(out)
end
