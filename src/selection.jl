# The picker transport contract: parse a browser payload into a Selection (jurisdiction-agnostic).


# ── Transport contract (browser → Julia) ───────────────────────────────────
#
# The picker's JS POSTs a JSON payload describing the selected region. Because the
# browser has the whole document DOM (and its <ix:header>), it resolves contexts,
# units and dimensions before sending; Julia only normalises the numeric value
# (value × 10^scale × sign) and shapes the types. Payload (version 1):
#
#   { "version": 1,
#     "provenance": { "cik": "...", "accession": "...", "url": "..." },
#     "selector": "#item8 table", "kind": "table",
#     "text": "ASSETS …", "html": "<table>…</table>",
#     "table": { "header": ["", "2025", "2024"],
#                "rows":   [["Cash","10729","10727"], …] },          // or null
#     "facts": [ { "concept": "us-gaap:CashAndCashEquivalents...",
#                  "label": "Cash and cash equivalents",
#                  "value": 10729, "scale": 6, "sign": "", "decimals": -6,
#                  "unit": "USD", "unitRef": "usd", "contextRef": "c-3",
#                  "periodStart": null, "periodEnd": "2025-04-30",
#                  "isInstant": true, "dimensions": {} }, … ]        // or []
#   }
const SELECTION_SCHEMA_VERSION = 1

# Internal: JSON value (number or comma-formatted string) → Float64.
_tonum(x) = x isa Number ? Float64(x) : parse(Float64, replace(strip(String(x)), "," => ""))

# Internal: build one Fact from a payload fact object, applying scale/sign and
# resolving the (already JS-resolved) period/unit/dimensions into Julia types.
function _parse_fact(fj, cik, accession, source_selector)
    scale = Int(get(fj, :scale, 0))
    sign  = String(get(fj, :sign, ""))
    value = _tonum(fj.value) * 10.0^scale * (sign == "-" ? -1.0 : 1.0)
    ps = get(fj, :periodStart, nothing)
    period_start = (ps === nothing || ps == "") ? nothing : Date(String(ps))
    dec = get(fj, :decimals, nothing)
    decimals = (dec === nothing || dec == "INF") ? nothing : Int(dec)
    dims = Dict{String,String}()
    dj = get(fj, :dimensions, nothing)
    dj === nothing || for (k, v) in pairs(dj); dims[String(k)] = String(v); end
    return Fact(; cik, accession, statement = String(get(fj, :statement, "")),
                concept = String(fj.concept), label = String(get(fj, :label, "")),
                value, unit = String(get(fj, :unit, "")),
                period_start, period_end = Date(String(fj.periodEnd)),
                is_instant = Bool(get(fj, :isInstant, false)), dimensions = dims, decimals,
                context_ref = String(get(fj, :contextRef, "")),
                unit_ref = String(get(fj, :unitRef, "")), source_selector)
end

# Internal: a copy of a Fact with its `statement` replaced (Fact is immutable). Used to apply
# statement classification to picked facts after the fact, mirroring `facts(::Filing; classify)`.
_with_statement(f::Fact, statement::AbstractString) =
    Fact(f.cik, f.accession, String(statement), f.concept, f.label, f.value, f.unit,
         f.period_start, f.period_end, f.is_instant, f.dimensions, f.decimals,
         f.context_ref, f.unit_ref, f.source_selector)

# Internal: fill a picked Selection's facts' `statement` from a concept => statement map (from the
# filing's presentation linkbase). Concepts absent from the map (e.g. note-only) keep their empty
# statement. Returns the Selection unchanged when there is nothing to classify.
function _classify_selection(sel::Selection, statements::AbstractDict)
    (isempty(sel.facts) || isempty(statements)) && return sel
    facts = [haskey(statements, f.concept) ? _with_statement(f, statements[f.concept]) : f
             for f in sel.facts]
    return Selection(sel.cik, sel.accession, sel.url, sel.selector, sel.kind, sel.text,
                     sel.html, sel.table, facts)
end

"""
    parse_selection(payload::AbstractString) -> Selection

Parse a picker transport payload (the JSON the browser POSTs back, schema version
$(SELECTION_SCHEMA_VERSION)) into a [`Selection`](@ref) — resolving its structured
table and normalising its [`Fact`](@ref)s. Throws if the payload's `version` is not
understood. This is the seam between the browser picker and the Julia export layers.
"""
function parse_selection(payload::AbstractString)
    o = JSON3.read(payload)
    get(o, :version, nothing) == SELECTION_SCHEMA_VERSION ||
        throw(ArgumentError("unsupported selection payload version $(get(o, :version, "missing"))"))
    p = o.provenance
    cik = String(p.cik); accession = String(p.accession); url = String(get(p, :url, ""))
    selector = String(get(o, :selector, ""))
    tj = get(o, :table, nothing)
    table = tj === nothing ? nothing :
        (header = String[String(x) for x in get(tj, :header, ())],
         rows = Vector{String}[String[String(c) for c in r] for r in get(tj, :rows, ())])
    facts = Fact[]
    fj = get(o, :facts, nothing)
    fj === nothing || for f in fj; push!(facts, _parse_fact(f, cik, accession, selector)); end
    return Selection(cik, accession, url, selector, Symbol(get(o, :kind, "prose")),
                     String(get(o, :text, "")), String(get(o, :html, "")), table, facts)
end

"""
    open_filing(sel::Selection) -> String

View a region captured with [`select_section`](@ref)/[`select_sections`](@ref) in your
browser — the picked-region counterpart of [`open_filing(::Filing)`](@ref). The captured
HTML (`sel.html`) is wrapped in a minimal page (with a `<base>` so the fragment's relative
images still resolve to the SEC Archives, and a small provenance header naming the filer,
accession and selector), written to a throwaway temporary directory and opened. Returns the
path. This is a quick visual check of what you picked; to keep a copy, use the export layers.

```julia
sel = select_section(f)
open_filing(sel)               # eyeball exactly what was captured
```
"""
# Internal: wrap a Selection's captured HTML in a minimal, self-contained preview
# page — a `<base>` so relative images resolve to the SEC Archives, plus a provenance
# header. Pure (no I/O), so it can be tested without launching a browser.
function _selection_page(sel::Selection)
    dirurl = sel.url[1:something(findlast('/', sel.url), 0)]
    basetag = isempty(dirurl) ? "" : "<base href=\"$dirurl\">"
    prov = string("<p style=\"font:13px system-ui,sans-serif;color:#555;",
                  "border-bottom:1px solid #ddd;padding-bottom:6px;margin:0 0 12px\">",
                  "EDGAR selection &middot; ", sel.kind, " &middot; CIK ", sel.cik,
                  " &middot; ", sel.accession, " &middot; <code>", sel.selector, "</code></p>")
    return string("<!doctype html><html><head><meta charset=\"utf-8\">", basetag,
                  "<title>EDGAR selection &mdash; ", sel.kind, "</title></head><body>",
                  prov, sel.html, "</body></html>")
end

function open_filing(sel::Selection)
    dir = mktempdir(; prefix = "EDGAR_selection_", cleanup = true)
    path = joinpath(dir, "selection.html")
    write(path, _selection_page(sel))
    return _open_in_default_app(path)
end
