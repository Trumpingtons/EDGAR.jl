# Core data types (jurisdiction-agnostic): Filing, Fact, Selection and the row schemas.

"""
    Filing

A single filing document fetched into memory by [`fetch_filing`](@ref): its
`content` (a `String`) plus `cik` (10-digit), `accession`, `document` (the
filename), source `url`, and `kind` — `:ixbrl` (inline-XBRL HTML), `:xbrl` (a
classic XBRL instance), or `:html` (a filing with no XBRL). Persist it with
[`save_filing`](@ref).
"""
struct Filing
    cik::String
    accession::String
    document::String
    url::String
    kind::Symbol
    content::String
end

Base.show(io::IO, f::Filing) =
    print(io, "Filing(", repr(f.kind), ", ", repr(f.document), ", ", length(f.content), " bytes)")

# ── Interactive selection ──────────────────────────────────────────────────
#
# The picker (see `select_section`) lets a user click a region in a rendered
# filing; that region comes back as a `Selection`, the unit every export layer
# (Markdown, facts, …) operates on. The type is defined here as a stable contract
# ahead of the machinery that produces it.
"""
    Fact

One numeric XBRL fact extracted from a tagged region of a filing — the atom of the
analytical (Layer 2/3) output. Values are stored **normalised** (the displayed
number with `scale` and `sign` already applied), and the context/unit references are
**resolved** so a row is self-describing, while the raw refs are kept for provenance.

Fields:

- `cik`, `accession` — the filer and filing (provenance/identity).
- `statement` — which statement/section the fact sits in (e.g. `"BalanceSheet"`), or
  `""` if not classified.
- `concept` — the XBRL concept, namespaced (`"us-gaap:Assets"`, or an issuer extension).
- `label` — the human-readable label as presented.
- `value` — the **normalised** numeric value (`displayed × 10^scale × sign`).
- `unit` — the resolved unit (`"USD"`, `"shares"`, `"USD/shares"`, `"pure"`).
- `period_start` — the start of a duration; `nothing` for an instant.
- `period_end` — the period end (instants) or duration end.
- `is_instant` — `true` for a point-in-time fact (balance-sheet items), `false` for a
  flow (income-statement / cash-flow items).
- `dimensions` — axis ⇒ member qualifiers (segment, geography, …); empty when none.
- `decimals` — reported precision; `nothing` for `INF` / unspecified.
- `context_ref`, `unit_ref` — the raw iXBRL references (provenance/debug).
- `source_selector` — the DOM region ([`Selection`](@ref)) the fact came from.

Only **numeric** facts are represented here; non-numeric tags (text/date) belong to
the presentation/text layer. `Fact`s flow to disk as a Tables.jl row table (see the
internal `fact_row` for the exact column schema and the dedup key). Build one with the
keyword constructor.
"""
struct Fact
    cik::String
    accession::String
    statement::String
    concept::String
    label::String
    value::Float64
    unit::String
    period_start::Union{Date,Nothing}
    period_end::Date
    is_instant::Bool
    dimensions::Dict{String,String}
    decimals::Union{Int,Nothing}
    context_ref::String
    unit_ref::String
    source_selector::String
    # ALL the statement sections this fact's concept belongs to (a concept can be multi-homed, e.g.
    # StockholdersEquity ∈ BalanceSheet + Equity), priority-sorted so `statement` == first. Empty
    # unless classified. The primary `statement` field is kept for back-compatible filtering/grouping.
    statements::Vector{String}
end

# Keyword constructor — the positional form has 16 fields; this keeps construction
# (in Phase 3 and in tests) readable, with sensible defaults for the optional ones.
function Fact(; concept, value, period_end, is_instant, unit="",
              cik="", accession="", statement="", label="",
              period_start=nothing, dimensions=Dict{String,String}(), decimals=nothing,
              context_ref="", unit_ref="", source_selector="", statements=String[])
    return Fact(cik, accession, statement, concept, label, Float64(value), unit,
                period_start, period_end, is_instant, dimensions, decimals,
                context_ref, unit_ref, source_selector, statements)
end

Base.show(io::IO, f::Fact) =
    print(io, "Fact(", f.concept, " = ", f.value, " ", f.unit,
          " @ ", f.is_instant ? f.period_end : "$(f.period_start)..$(f.period_end)", ")")

# Internal: one fact as a Tables.jl row (a NamedTuple) — the exact column schema and
# order written to disk. `dimensions` is serialised to a JSON string for storage. The
# warehouse dedup key is (accession, concept, context_ref, unit_ref) — i.e. one fact
# per concept × context × unit within a filing — so re-importing a filing is a no-op.
fact_row(f::Fact) =
    (cik = f.cik, accession = f.accession, statement = f.statement,
     statements = JSON3.write(f.statements), concept = f.concept,
     standard_concept = standardize(f.concept), label = f.label, value = f.value, unit = f.unit,
     period_start = f.period_start, period_end = f.period_end, is_instant = f.is_instant,
     dimensions = JSON3.write(f.dimensions), decimals = f.decimals,
     context_ref = f.context_ref, unit_ref = f.unit_ref, source_selector = f.source_selector)

# The fact row-table schema: the element type of the Tables.jl row table that `facts`
# returns. It mirrors `fact_row` exactly, so an empty table (from a prose-only
# selection) is still concretely typed rather than a `Vector{Any}`. `standard_concept`
# is the cross-company mapping (W4), `nothing` when the concept is unmapped. `statement` is the
# primary section; `statements` is the JSON array of every section the concept belongs to (multi-homed).
const FactRow = @NamedTuple{cik::String, accession::String, statement::String, statements::String,
    concept::String, standard_concept::Union{Nothing,String}, label::String, value::Float64,
    unit::String, period_start::Union{Nothing,Date}, period_end::Date, is_instant::Bool,
    dimensions::String, decimals::Union{Nothing,Int}, context_ref::String,
    unit_ref::String, source_selector::String}

# A structured table captured from a selection: a header row and the body rows, each a
# vector of cell strings (the browser resolves colspan/rowspan before sending).
const SelectionTable = @NamedTuple{header::Vector{String}, rows::Vector{Vector{String}}}

"""
    Selection

A region a user picked from a rendered filing via [`select_section`](@ref) — the
unit the export layers operate on. It carries enough provenance to trace any
downstream artifact (a Markdown chunk, a fact row) back to the exact filing and DOM
region it came from:

- `cik` — the filer's 10-digit, zero-padded Central Index Key.
- `accession` — the filing's dashed accession number.
- `url` — the source document URL the region was picked from.
- `selector` — a CSS selector locating the region within the document, so the same
  pick can be re-applied to a later filing of the same form.
- `kind` — `:table`, `:prose`, or `:mixed`: what the region holds, which decides the
  export layers that apply (a table yields facts/rows; prose yields text only).
- `text` — the region's plain text (its `innerText`).
- `html` — the region's raw `outerHTML` (the lossless fragment).
- `table` — the structured table (`header` + `rows`) when the region is/contains one,
  else `nothing` (drives the Markdown table export).
- `facts` — the resolved numeric [`Fact`](@ref)s in the region (empty for prose).

`Selection`s are produced by [`select_section`](@ref); you rarely build one by hand
outside of tests (use the keyword constructor there).
"""
struct Selection
    cik::String
    accession::String
    url::String
    selector::String
    kind::Symbol
    text::String
    html::String
    table::Union{Nothing,SelectionTable}
    facts::Vector{Fact}
end

Selection(; cik="", accession="", url="", selector="", kind::Symbol=:prose, text="",
          html="", table=nothing, facts=Fact[]) =
    Selection(cik, accession, url, selector, kind, text, html, table, facts)

Base.show(io::IO, s::Selection) =
    print(io, "Selection(", repr(s.kind), ", ", repr(s.selector), ", ",
          length(s.text), " chars, ", length(s.facts), " facts)")
