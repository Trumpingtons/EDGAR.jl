# W2 — Julia-native XBRL fact extraction from a fetched Filing, with no browser. This is the
# bulk, non-interactive path: it mirrors the picker's (validated) JS — build the context and
# unit maps, then resolve every numeric fact — using regex over the document source. Two shapes:
#   :ixbrl / :html — inline XBRL: facts are <ix:nonFraction> in the rendered .htm
#   :xbrl          — a classic XBRL instance (.xml): facts are concept-named elements
# Element prefixes (xbrli:/ix:/xbrldi:) are matched loosely so a non-standard prefix still works.

# Strip tags AND HTML entities, then collapse whitespace -> the text value of an element. The
# entity strip matters: a nil cell is often `&#8212;` (em dash) or `&#160;` (nbsp); without it,
# cleaning the *raw* source to digits would leak the entity's number (`&#8212;` -> `8212`). The
# browser path is immune (DOM `textContent` already decodes), but this regex extractor is not.
_xbrl_text(s) = strip(replace(replace(replace(s, r"(?is)<[^>]*>" => " "), r"&#?\w+;" => " "), r"\s+" => " "))

# Clean a displayed number to a parseable string + a negative flag (parentheses = negative),
# mirroring the picker's factNumber.
function _xbrl_number(valtext::AbstractString, signattr::AbstractString)
    t = _xbrl_text(valtext)
    neg = signattr == "-"
    if startswith(t, "(") && endswith(t, ")")
        neg = true
        t = t[nextind(t, firstindex(t)):prevind(t, lastindex(t))]
    end
    startswith(t, "-") && (neg = !neg)   # classic instances carry the sign in the value text, not a `sign` attribute
    return (replace(t, r"[^0-9.]" => ""), neg)
end

# English number words -> their numeric value, for the iXBRL `ixt-sec:numwordsen` transform
# (a fact written in words, e.g. `No` par value, `Forty-two`). `no`/`none`/`nil`/`null` are the
# common dei case (a zero shown as a word). Cardinal scales compose the usual way.
const _NUMWORDS = Dict{String,Int}(
    "zero" => 0, "no" => 0, "none" => 0, "nil" => 0, "null" => 0,
    "one" => 1, "two" => 2, "three" => 3, "four" => 4, "five" => 5, "six" => 6, "seven" => 7,
    "eight" => 8, "nine" => 9, "ten" => 10, "eleven" => 11, "twelve" => 12, "thirteen" => 13,
    "fourteen" => 14, "fifteen" => 15, "sixteen" => 16, "seventeen" => 17, "eighteen" => 18,
    "nineteen" => 19, "twenty" => 20, "thirty" => 30, "forty" => 40, "fifty" => 50,
    "sixty" => 60, "seventy" => 70, "eighty" => 80, "ninety" => 90)
const _NUMSCALES = Dict{String,Int}("thousand" => 1000, "million" => 1_000_000,
    "billion" => 1_000_000_000, "trillion" => 1_000_000_000_000)

# Parse a spelled-out English cardinal into its digit string, or `nothing` if the phrase contains
# a word that is not a number word (so a non-numeric `numwordsen` value is dropped, not mis-read).
function _numwordsen(s::AbstractString)
    total = 0; group = 0; seen = false
    for w in split(lowercase(replace(s, r"[-,]" => " ")))
        w == "and" && continue
        if haskey(_NUMWORDS, w)
            group += _NUMWORDS[w]; seen = true
        elseif w == "hundred"
            group = max(group, 1) * 100; seen = true
        elseif haskey(_NUMSCALES, w)
            total += max(group, 1) * _NUMSCALES[w]; group = 0; seen = true
        else
            return nothing
        end
    end
    return seen ? string(total + group) : nothing
end

# Parse a start-tag's attribute string into a Dict (attribute names are case-sensitive as written).
function _attrs(s::AbstractString)
    d = Dict{String,String}()
    for m in eachmatch(r"([A-Za-z_][\w:.-]*)\s*=\s*\"([^\"]*)\"", s)
        d[m.captures[1]] = m.captures[2]
    end
    return d
end

# The local name of a measure (drop the iso4217:/xbrli: prefix): iso4217:USD -> USD.
_measure_local(s) = (i = findlast(':', s); i === nothing ? s : s[nextind(s, i):end])

# contexts: id -> (instant, start, stop, dims). One of instant or (start,stop) is set.
function _xbrl_contexts(content::AbstractString)
    ctxs = Dict{String,@NamedTuple{instant::Union{Nothing,String}, start::Union{Nothing,String},
                                   stop::Union{Nothing,String}, dims::Dict{String,String}}}()
    for m in eachmatch(r"(?is)<(?:\w+:)?context\b([^>]*)>(.*?)</(?:\w+:)?context>", content)
        id = get(_attrs(m.captures[1]), "id", "")
        isempty(id) && continue
        body = m.captures[2]
        inst = match(r"(?is)<(?:\w+:)?instant>\s*([^<\s]+)\s*</(?:\w+:)?instant>", body)
        sd = match(r"(?is)<(?:\w+:)?startDate>\s*([^<\s]+)\s*</(?:\w+:)?startDate>", body)
        ed = match(r"(?is)<(?:\w+:)?endDate>\s*([^<\s]+)\s*</(?:\w+:)?endDate>", body)
        dims = Dict{String,String}()
        for d in eachmatch(r"(?is)<(?:\w+:)?explicitMember\b[^>]*\bdimension=\"([^\"]+)\"[^>]*>\s*([^<]+?)\s*</(?:\w+:)?explicitMember>", body)
            dims[d.captures[1]] = strip(d.captures[2])
        end
        ctxs[id] = (instant = inst === nothing ? nothing : inst.captures[1],
                    start = sd === nothing ? nothing : sd.captures[1],
                    stop = ed === nothing ? nothing : ed.captures[1], dims = dims)
    end
    return ctxs
end

# units: id -> "USD" / "shares" / "USD/shares".
function _xbrl_units(content::AbstractString)
    units = Dict{String,String}()
    measure(block) = (m = match(r"(?is)<(?:\w+:)?measure>\s*([^<]+?)\s*</(?:\w+:)?measure>", block);
                      m === nothing ? "" : _measure_local(strip(m.captures[1])))
    for m in eachmatch(r"(?is)<(?:\w+:)?unit\b([^>]*)>(.*?)</(?:\w+:)?unit>", content)
        id = get(_attrs(m.captures[1]), "id", "")
        isempty(id) && continue
        div = match(r"(?is)<(?:\w+:)?divide>(.*?)</(?:\w+:)?divide>", m.captures[2])
        if div === nothing
            units[id] = measure(m.captures[2])
        else
            num = match(r"(?is)<(?:\w+:)?unitNumerator>(.*?)</(?:\w+:)?unitNumerator>", div.captures[1])
            den = match(r"(?is)<(?:\w+:)?unitDenominator>(.*?)</(?:\w+:)?unitDenominator>", div.captures[1])
            units[id] = (num === nothing ? "" : measure(num.captures[1])) * "/" *
                        (den === nothing ? "" : measure(den.captures[1]))
        end
    end
    return units
end

# Resolve one fact's parts against the maps into a Fact, or `nothing` if it cannot be resolved
# (unknown/incomplete context, non-numeric value).
function _assemble_fact(cik, accession, concept, valtext, signattr, scaleattr, decimalsattr,
                        ctxRef, unitRef, ctxs, units, statement, label)
    ctx = get(ctxs, ctxRef, nothing)
    ctx === nothing && return nothing
    isinstant = ctx.instant !== nothing
    pend = isinstant ? ctx.instant : ctx.stop
    pend === nothing && return nothing
    pe = tryparse(Date, pend)
    pe === nothing && return nothing
    numstr, neg = _xbrl_number(valtext, signattr)
    isempty(numstr) && return nothing
    num = tryparse(Float64, numstr)
    num === nothing && return nothing
    scale = something(tryparse(Int, scaleattr), 0)
    dec = (decimalsattr == "" || uppercase(decimalsattr) == "INF") ? nothing : tryparse(Int, decimalsattr)
    return Fact(; cik, accession, concept, statement, label,
                value = num * 10.0^scale * (neg ? -1.0 : 1.0),
                unit = get(units, unitRef, ""),
                period_start = isinstant ? nothing : (ctx.start === nothing ? nothing : tryparse(Date, ctx.start)),
                period_end = pe, is_instant = isinstant, dimensions = ctx.dims, decimals = dec,
                context_ref = ctxRef, unit_ref = unitRef)
end

# The displayed value text to clean, honouring the iXBRL `format` transform: `ixt:fixed-zero`/
# `zerodash` means a fact shown as a dash is the value **zero**, and `ixt-sec:numwordsen` means it
# is a spelled-out number (`Forty-two`, `No`). A `numwordsen` value that is not a number phrase
# yields `""` (dropped, not mis-read). Other `ixt:*` transforms (num-dot-decimal, …) are handled
# by the later digit cleanup.
function _ix_valtext(fmt::AbstractString, raw::AbstractString)
    f = lowercase(fmt)
    occursin("zero", f) && return "0"
    occursin("numwords", f) && return something(_numwordsen(_xbrl_text(raw)), "")
    return raw
end

# Inline-XBRL facts: every <ix:nonFraction> (numeric). Non-numeric <ix:nonNumeric> are text,
# skipped.
function _ixbrl_facts(content, cik, accession, ctxs, units, statements, labels)
    out = Fact[]
    for m in eachmatch(r"(?is)<ix:nonFraction\b([^>]*)>(.*?)</ix:nonFraction>", content)
        a = _attrs(m.captures[1])
        concept = get(a, "name", "")
        isempty(concept) && continue
        f = _assemble_fact(cik, accession, concept, _ix_valtext(get(a, "format", ""), m.captures[2]),
                           get(a, "sign", ""), get(a, "scale", "0"), get(a, "decimals", ""),
                           get(a, "contextRef", ""), get(a, "unitRef", ""), ctxs, units,
                           get(statements, concept, ""), get(labels, concept, ""))
        f === nothing || push!(out, f)
    end
    return out
end

# Classic XBRL instance: numeric facts are concept-named elements carrying a unitRef.
function _classic_facts(content, cik, accession, ctxs, units, statements, labels)
    out = Fact[]
    # Content of a numeric fact is a plain number (no nested tags), so `[^<]*` keeps this linear — a
    # lazy `.*?` with the `</\1>` backreference catastrophically backtracks and trips PCRE's match
    # limit on large instances (10k+ facts, 10-50 MB). Text-block elements (with nested HTML) don't
    # match `[^<]*</\1>` and are skipped — which is correct, they are not numeric facts anyway.
    for m in eachmatch(r"(?is)<([\w-]+:[\w.-]+)\b([^>]*\bcontextRef=\"[^\"]+\"[^>]*)>([^<]*)</\1>", content)
        tag = m.captures[1]
        startswith(lowercase(tag), "xbrli:") && continue   # structural, not a fact
        a = _attrs(m.captures[2])
        haskey(a, "unitRef") || continue                   # numeric facts only
        f = _assemble_fact(cik, accession, tag, m.captures[3], get(a, "sign", ""),
                           get(a, "scale", "0"), get(a, "decimals", ""),
                           a["contextRef"], a["unitRef"], ctxs, units,
                           get(statements, tag, ""), get(labels, tag, ""))
        f === nothing || push!(out, f)
    end
    return out
end

# Internal: extract every numeric XBRL fact from a filing's document. `statements` maps each
# concept to its statement (presentation linkbase); `labels` maps each concept to its human label
# (label linkbase); both empty for no classification / no labels.
# Parse one document's facts (inline iXBRL or a classic `.xml` instance) given its `kind`.
function _facts_of(content, kind::Symbol, cik, accession, statements, labels)
    ctxs = _xbrl_contexts(content)
    units = _xbrl_units(content)
    return kind === :xbrl ? _classic_facts(content, cik, accession, ctxs, units, statements, labels) :
                            _ixbrl_facts(content, cik, accession, ctxs, units, statements, labels)
end

function _extract_facts(f::Filing; statements::AbstractDict=Dict{String,String}(),
                        labels::AbstractDict=Dict{String,String}())
    inline = _facts_of(f.content, f.kind, f.cik, f.accession, statements, labels)
    # Prefer the SEC's complete *extracted* instance (`<doc>_htm.xml`) when it yields strictly more
    # facts — for a foreign/40-F/20-F or multi-part filing the primary inline document is only a
    # cover/wrapper, so the extracted instance is far richer. Guarded three ways so it never regresses
    # a filing whose inline document is already complete: URL-gated to real SEC archives (in-memory
    # fixtures stay offline-testable), only adopted on a strictly larger fact count, and any
    # fetch/parse failure falls back to the inline result.
    (f.kind === :xbrl || !startswith(f.url, "https://www.sec.gov/Archives/")) && return inline
    try
        base = _filing_dir(f.cik, f.accession)
        body = fetch_url(base * "/" * _xbrl_instance(base))
        body === nothing && return inline
        instance = _facts_of(String(body), :xbrl, f.cik, f.accession, statements, labels)
        return length(instance) > length(inline) ? instance : inline
    catch
        return inline
    end
end

# Internal: a whole filing as a Selection (kind `:filing`, no DOM selector) — the unit the
# export layers already understand, so `facts`/`facts_json`/`to_duckdb` work unchanged.
_filing_selection(f::Filing, fcts) =
    Selection(; cik = f.cik, accession = f.accession, url = f.url, selector = "",
              kind = :filing, facts = fcts)

# ── Statement classification from the presentation linkbase (W5) ─────────────
# The authoritative grouping of concepts into financial statements is the filing's own
# presentation linkbase (`*_pre.xml`): each extended-link role is a section. We classify each role
# from BOTH its name and the concepts it contains (see `_classify_role` in classify.jl), then map
# every concept it holds to that statement. Passing the concepts (not just the role name) is what
# makes it robust to bank/IFRS naming and opaque role URIs.

# Parse a presentation-linkbase XML into a concept => statement map.
function _concept_statements(pre_xml::AbstractString)
    cmap = Dict{String,String}()
    for m in eachmatch(r"(?is)<(?:link:)?presentationLink\b[^>]*\brole=\"([^\"]+)\"[^>]*>(.*?)</(?:link:)?presentationLink>", pre_xml)
        concepts = String[replace(String(loc.captures[1]), "_" => ":"; count = 1)
                          for loc in eachmatch(r"xlink:href=\"[^\"#]*#([^\"]+)\"", m.captures[2])]
        stmt = _classify_role(m.captures[1], concepts)
        isempty(stmt) && continue
        for c in concepts
            if !haskey(cmap, c) ||
               findfirst(==(stmt), _STATEMENT_PRIORITY) < findfirst(==(cmap[c]), _STATEMENT_PRIORITY)
                cmap[c] = stmt
            end
        end
    end
    return cmap
end

# ── Label linkbase (native human labels) ─────────────────────────────────────
# The picker captures a fact's label from the rendered DOM row; the browser-less native path has
# no DOM, so it reads the filing's **label linkbase** (`*_lab.xml`) — the authoritative
# concept => human-label map. A label resource is tied to its concept by a `loc` (label -> concept)
# and a `labelArc` (loc-label -> resource-label); each `label` element carries the text and a role.
# We keep the standard label, falling back to terse then verbose, and ignore non-display roles
# (documentation, period-start/end, …).

const _LABEL_ROLES = ["http://www.xbrl.org/2003/role/label",
                      "http://www.xbrl.org/2003/role/terseLabel",
                      "http://www.xbrl.org/2003/role/verboseLabel"]

# Parse a label-linkbase XML into a concept => label map (best available role per concept).
function _concept_labels(lab_xml::AbstractString)
    locmap = Dict{String,String}()                         # loc label -> concept
    for loc in eachmatch(r"(?is)<(?:link:)?loc\b([^>]*)>", lab_xml)
        a = _attrs(loc.captures[1])
        href = get(a, "xlink:href", ""); label = get(a, "xlink:label", "")
        (isempty(href) || isempty(label)) && continue
        i = findlast('#', href)
        i === nothing && continue
        locmap[label] = replace(href[nextind(href, i):end], "_" => ":"; count = 1)
    end
    arcs = Dict{String,String}()                            # label-resource label -> concept
    for arc in eachmatch(r"(?is)<(?:link:)?labelArc\b([^>]*)>", lab_xml)
        a = _attrs(arc.captures[1])
        concept = get(locmap, get(a, "xlink:from", ""), "")
        to = get(a, "xlink:to", "")
        (isempty(concept) || isempty(to)) && continue
        arcs[to] = concept
    end
    cmap = Dict{String,String}(); best = Dict{String,Int}()
    for m in eachmatch(r"(?is)<(?:link:)?label\b([^>]*)>(.*?)</(?:link:)?label>", lab_xml)
        a = _attrs(m.captures[1])
        concept = get(arcs, get(a, "xlink:label", ""), "")
        isempty(concept) && continue
        rank = findfirst(==(get(a, "xlink:role", _LABEL_ROLES[1])), _LABEL_ROLES)
        rank === nothing && continue                        # not a display role
        if !haskey(best, concept) || rank < best[concept]
            text = _xbrl_text(m.captures[2])
            isempty(text) || (cmap[concept] = text; best[concept] = rank)
        end
    end
    return cmap
end

# ── Calculation linkbase (W7) ────────────────────────────────────────────────
# The `*_cal.xml` gives the statement's arithmetic: each calculationArc says a child concept
# rolls up into a parent with a signed weight (+1 added, -1 subtracted). The arc's from/to are
# locator labels; the loc elements map those labels back to concepts. Note we do NOT use the
# weights to rewrite stored fact values — those are XBRL-canonical and validated against the SEC
# API — the weight is exposed as the contribution sign / for summation checks.
function _calculations(cal_xml::AbstractString)
    rows = @NamedTuple{statement::String, parent::String, child::String, weight::Float64}[]
    for link in eachmatch(r"(?is)<(?:link:)?calculationLink\b([^>]*)>(.*?)</(?:link:)?calculationLink>", cal_xml)
        stmt = _classify_role(get(_attrs(link.captures[1]), "xlink:role", ""))
        body = link.captures[2]
        locmap = Dict{String,String}()
        for loc in eachmatch(r"(?is)<(?:link:)?loc\b([^>]*)>", body)
            a = _attrs(loc.captures[1])
            href = get(a, "xlink:href", ""); label = get(a, "xlink:label", "")
            (isempty(href) || isempty(label)) && continue
            i = findlast('#', href)
            i === nothing && continue
            locmap[label] = replace(href[nextind(href, i):end], "_" => ":"; count = 1)
        end
        for arc in eachmatch(r"(?is)<(?:link:)?calculationArc\b([^>]*)>", body)
            a = _attrs(arc.captures[1])
            parent = get(locmap, get(a, "xlink:from", ""), "")
            child = get(locmap, get(a, "xlink:to", ""), "")
            (isempty(parent) || isempty(child)) && continue
            push!(rows, (statement = stmt, parent = parent, child = child,
                         weight = something(tryparse(Float64, get(a, "weight", "")), 1.0)))
        end
    end
    return rows
end

"""
    facts(f::Filing; classify=false, labels=false) -> Vector{FactRow}

Extract **every** numeric XBRL fact from a fetched [`Filing`](@ref) — no browser — as the same
Tables.jl row table that [`facts(::Selection)`](@ref) returns. This is the bulk, non-interactive
counterpart of the picker: it reads the inline XBRL (`<ix:nonFraction>`) of an `:ixbrl`/`:html`
filing, or the classic `.xml` instance of an `:xbrl` filing, resolving each fact against the
document's contexts and units. Facts are de-duplicated on the semantic key; `source_selector` is
empty (the facts come from the whole filing, not a picked region).

With `classify=true`, each fact's `statement` is filled from the filing's presentation linkbase
(see [`statement_map`](@ref)). With `labels=true`, each fact's `label` is filled from the filing's
label linkbase (see [`label_map`](@ref)); the picker fills this from the rendered row instead. Each
flag costs one extra linkbase fetch.

```julia
f = fetch_filing(104169, "0000104169-26-000102")
facts(f)                                  # all the 10-Q's facts as a row table
facts(f; classify = true, labels = true)  # …with the `statement` and `label` columns filled
```
"""
facts(f::Filing; classify::Bool=false, labels::Bool=false) =
    facts(_filing_selection(f, _extract_facts(f;
        statements = classify ? statement_map(f) : Dict{String,String}(),
        labels = labels ? label_map(f) : Dict{String,String}())))

"""
    facts_json(f::Filing; pretty=true, classify=false, labels=false) -> String

The whole filing's facts as a Facts JSON document (see [`facts_json(::Selection)`](@ref)),
extracted natively (no browser). `classify=true` fills each fact's `statement` from the
presentation linkbase; `labels=true` fills each fact's `label` from the label linkbase. Round-trips
via [`read_facts_json`](@ref).
"""
facts_json(f::Filing; pretty::Bool=true, classify::Bool=false, labels::Bool=false) =
    facts_json(_filing_selection(f, _extract_facts(f;
        statements = classify ? statement_map(f) : Dict{String,String}(),
        labels = labels ? label_map(f) : Dict{String,String}())); pretty)
