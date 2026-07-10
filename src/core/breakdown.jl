# Dimensional breakdown — "revenue by segment / product / geography", etc. NO definition linkbase needed:
# the dimensional members are read straight from the instance contexts (`_xbrl_contexts`), and each
# member's human NAME is resolved from the label linkbase (`label_map` carries MEMBER labels too, e.g.
# `aapl:IPhoneMember` -> "iPhone [Member]", not just concept labels). That is the NAMED-member path (SEC,
# IFRS/ESEF, EDINET, DART). Some taxonomies (India) instead use GENERIC members (`…Segment01Member`) with
# the real name in a separate NON-NUMERIC "descriptor" text fact per member (`DescriptionOfReportableSegment`
# = "Retail", tagged with that member) — `_member_name_facts` recovers those, as a fallback name source.

# member => name from non-numeric "descriptor" text facts (`Name…`/`Description…` concepts about a segment/
# dimension member), read straight from the instance and matched to the member on `axis` by shared context.
# Namespace-agnostic; empty for taxonomies (SEC, IFRS) that name their members through the label linkbase
# instead. `facts` is numeric-only, so these text facts are parsed here directly.
function _member_name_facts(content::AbstractString, axis::AbstractString)
    ctxs = _xbrl_contexts(content)
    names = Dict{String,String}()
    for m in eachmatch(r"(?is)<([\w.-]+:(?:Name|Description)Of[A-Za-z]*)\b[^>]*\bcontextRef=\"([^\"]+)\"[^>]*>(.*?)</[\w.-]+:(?:Name|Description)Of[A-Za-z]*>", content)
        concept, ctx = m.captures[1], m.captures[2]
        occursin(r"(?i)segment|dimension|member|class|category", concept) || continue
        c = get(ctxs, ctx, nothing); c === nothing && continue
        mem = get(c.dims, axis, ""); isempty(mem) && continue
        txt = _xbrl_text(m.captures[3]); isempty(txt) && continue
        get!(names, mem, txt)                              # first descriptor wins (they repeat per statement)
    end
    return names
end

"""
    breakdown(f::Filing, concept; axis=nothing, labels=true) -> Vector{NamedTuple}

Break the reported values of `concept` down by the members of a dimensional `axis` — e.g. revenue by
operating segment, by product, or by geography. The members come straight from the filing's own
contexts (no definition linkbase required); each member's human name is resolved from the label
linkbase (which carries member labels). Returns one row per reported (member, period):

- `axis` — the dimension broken down on
- `member` — the member QName (e.g. `aapl:AmericasSegmentMember`)
- `name` — the member's human label (`"Americas Segment"`), or the QName if `labels=false`/unresolved
- `value`, `period_start`, `period_end`, `is_instant`
- `other_dims` — any OTHER axes on the same fact (e.g. a co-occurring consolidation-items axis), so a
  breakdown that is entangled with a second dimension is visible rather than silently double-counted.

`concept` is the concept QName (e.g. `"us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax"`).
When `axis` is omitted it is auto-detected from `concept`'s dimensioned facts — preferring an axis whose
name contains "Segment", else the most-used axis. `labels=false` skips the (possibly networked) label
fetch. `lang` picks the language of the member names for multilingual taxonomies (EDINET, DART): e.g.
`lang="en"` for English rather than the native Japanese/Korean. Newest period first, largest value first.

```julia
f = fetch_filing(320193, "0000320193-25-000079")
breakdown(f, "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax";
          axis = "us-gaap:StatementBusinessSegmentsAxis")     # Americas, Europe, Greater China, Japan, ...
```
"""
function breakdown(f::Filing, concept::AbstractString; axis::Union{AbstractString,Nothing}=nothing,
                   labels::Bool=true, lang::Union{AbstractString,Nothing}=nothing)
    ctxs = _xbrl_contexts(f.content)
    dimsof(r) = (c = get(ctxs, r.context_ref, nothing); c === nothing ? Dict{String,String}() : c.dims)
    cand = [r for r in facts(f) if r.concept == concept]
    isempty(cand) && return NamedTuple[]

    if axis === nothing                                   # auto-detect: prefer a segment axis, else most used
        cnt = Dict{String,Int}()
        for r in cand, a in keys(dimsof(r)); cnt[a] = get(cnt, a, 0) + 1; end
        isempty(cnt) && return NamedTuple[]               # concept present but undimensioned
        seg = [a for a in keys(cnt) if occursin(r"(?i)segment", a)]
        axis = argmax(a -> cnt[a], isempty(seg) ? collect(keys(cnt)) : seg)
    end

    lm    = labels ? label_map(f; lang = lang) : Dict{String,String}()
    descr = labels ? _member_name_facts(f.content, axis) : Dict{String,String}()   # generic-member fallback (India)
    # Resolve a member's name: the label linkbase first (named members — strip the trailing "[…]" domain/
    # member tag, incl.\ the localized "[メンバー]"/"[구성요소]"); then the descriptor text fact (generic
    # members); then, failing both, the member QName itself.
    function name(m)
        l = strip(replace(get(lm, m, ""), r"\s*\[[^\]]*\]\s*$" => ""))
        isempty(l) || return l
        haskey(descr, m) && return descr[m]
        return m
    end
    out = NamedTuple[]
    for r in cand
        d = dimsof(r); haskey(d, axis) || continue
        m = d[axis]
        push!(out, (axis = axis, member = m, name = name(m), value = r.value,
                    period_start = r.period_start, period_end = r.period_end, is_instant = r.is_instant,
                    other_dims = join(sort([k for k in keys(d) if k != axis]), ",")))
    end
    sort!(out; by = r -> (r.period_end, -r.value), rev = true)
    return out
end

"""
    segments(f::Filing, concept; labels=true, lang=nothing) -> Vector{NamedTuple}

`concept` broken down by **operating / reportable segment** — a convenience over [`breakdown`](@ref)
that picks the filing's segment axis for you (an axis whose name contains "Segment"), returning the same
rows. For any OTHER dimension — product, geography, maturity — call [`breakdown`](@ref) with an explicit `axis`.

Dispatches on the filing's format (`f.kind`). Dimensionally-tagged filings (SEC/EDINET/DART/India/…) use
the XBRL path above. **PDF-native filings** (China, Germany, HK, Russia, Generic) and **ESEF** (which
block-tags the segment note, so it carries no dimension) carry no segment cube — there `segments` recovers
the note from the document's *table*: a structure-based locator finds the operating-segment table (a
segment-name header + an external-revenue row, rejecting geography/product/management-view decoys) via a
Docling adapter (PDF) or the HTML table reader (semantic iXBRL); for a PDF the note is located by the `toc`
outline then a text scan, with a built-in reconciliation check (Σ segments = consolidated) arbitrating and
validating. Values are scaled to base units — a drop-in for the dimension path. Returns an empty vector
when no segment table is found (e.g. a filing with no segment disclosure). See `docs/dev/segments-pdf-plan.md`.

```julia
segments(f, "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax")   # revenue by segment
segments(f, "ifrs-full:Revenue"; lang = "en")                                # EDINET/DART, English names
```
"""
function segments(f::Filing, concept::AbstractString; labels::Bool=true,
                  lang::Union{AbstractString,Nothing}=nothing)
    # Dispatch on the filing's format (segments-pdf-plan). PDF-native filings carry no XBRL dimensions —
    # recover the segment note from the document's tables (`_segments_pdf`, Docling). iXBRL/HTML filings
    # try dimensions first; ESEF block-tags the note (no dimension), so fall back to the rendered HTML table.
    f.kind === :pdf && return _segments_pdf(f.content)
    rows = try breakdown(f, concept; axis = nothing, labels = labels, lang = lang) catch; NamedTuple[] end
    (!isempty(rows) && occursin(r"(?i)segment", rows[1].axis)) && return rows    # XBRL segment dimension carried it
    (f.kind in (:ixbrl, :html)) && return _segments_ixbrl(f.content)             # ESEF: block-tagged HTML table
    return NamedTuple[]
end
