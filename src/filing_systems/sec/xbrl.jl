# SEC-specific XBRL access (jurisdiction layer). The XBRL *parsing* in extract_xbrl.jl is
# standard-agnostic — it works on any iXBRL/XBRL document (validated against ESEF/IFRS filings,
# not just SEC us-gaap). What is SEC-specific is *locating* a filing's linkbases: on EDGAR they
# live as sibling files in the filing's Archives directory, discovered via its `index.json`. These
# wrappers fetch the relevant linkbase and hand the bytes to the (common) parsers in
# extract_xbrl.jl, giving the `Filing`-level enrichment API (`statement_map`, `label_map`,
# `calculations`).
#
# Other jurisdictions (e.g. ESEF, where the linkbases are bundled in the filing's report-package
# zip) would supply their own equivalent of `_fetch_linkbase`; see the refactor plan.

# Fetch a filing's XBRL linkbase by suffix (`"pre"` presentation, `"cal"` calculation,
# `"lab"` label) as a loose `_<suffix>.xml` file in the filing's Archives directory; "" if absent.
# Note: inline-only filers often ship no loose linkbases at all — classification then falls back
# to FilingSummary.xml + the R-files (see `_filing_summary_statements`). The SEC method of the
# per-system linkbase fetcher (generic dispatch declared in core/filing_system.jl); other systems
# (e.g. ESEF, which bundles linkbases in the report-package zip) supply their own `::ESEF` method.
function _fetch_linkbase(::SEC, f::Filing, suffix::AbstractString)
    base = _filing_dir(f)
    names = try
        [String(it.name) for it in _get_json("$base/index.json").directory.item]
    catch
        return ""
    end
    i = findfirst(n -> endswith(lowercase(n), "_$suffix.xml"), names)
    i === nothing && return ""
    body = fetch_url("$base/$(names[i])")
    return body === nothing ? "" : String(body)
end

"""
    statement_map(f::Filing) -> Dict{String,String}

Classify the filing's concepts into the financial statement each belongs to —
`"IncomeStatement"`, `"BalanceSheet"`, `"CashFlow"`, `"Equity"`, `"ComprehensiveIncome"` or
`"CoverPage"`. The **authoritative** source is the filing's own presentation linkbase
(`*_pre.xml`); when that is absent — as for inline-only filers that ship no loose linkbase —
it falls back to the SEC-generated `FilingSummary.xml` plus the rendered statement R-files,
which is present for every XBRL filing. Concepts that appear only in notes/disclosures are
absent. Returns a `concept => statement` dictionary (empty only if **both** sources fail).
This is what `facts(f; classify=true)` uses to fill the `statement` column.
"""
# concept => EVERY statement section it belongs to (priority-sorted, primary first) — a concept is
# often multi-homed (StockholdersEquity ∈ BalanceSheet + Equity). Linkbase first, FilingSummary fallback.
function statement_map_multi(f::Filing)
    m = _concept_statements(_fetch_linkbase(f, "pre"))     # authoritative: presentation linkbase
    isempty(m) && (m = _filing_summary_statements(f))      # universal fallback: FilingSummary + R-files
    isempty(m) && @warn "No statement classification for $(f.ref): no presentation " *
        "linkbase and no usable FilingSummary.xml — facts will be left unclassified (`statement` empty)."
    return m
end

statement_map(f::Filing) = Dict{String,String}(c => first(v) for (c, v) in statement_map_multi(f))

# Concepts the filing presents with a NEGATED label in their face-statement role (see
# `_concept_negations`) — their sign is flipped so `facts(f; classify=true)` matches the rendered
# statement. Empty for filers with no presentation linkbase (FilingSummary fallback carries no labels).
statement_negations(f::Filing) = _concept_negations(_fetch_linkbase(f, "pre"))

# SEC convenience over the jurisdiction-agnostic `reconstruct_from_notes(pre_xml, rows, statement)`
# (extract_xbrl.jl): fetch this filing's presentation linkbase and facts, then reconstruct. Mirrors how
# `statement_map` wraps `_concept_statements`.
reconstruct_from_notes(f::Filing, statement::AbstractString) =
    reconstruct_from_notes(_fetch_linkbase(f, "pre"), facts(f), statement)

# ── FilingSummary fallback (statement classification without a presentation linkbase) ─────────
# Inline-only filers ship no loose linkbases (and their `*-xbrl.zip` carries none either), so the
# `*_pre.xml` path yields nothing for them. But every XBRL filing carries an SEC-generated
# `FilingSummary.xml` that lists each statement as a <Report> with a role, a human <ShortName>,
# and an <HtmlFileName> R-file (the rendered statement). Each R-file encodes its line items'
# concepts as `defref_<ns>_<Local>` tokens, so we classify each face-statement report from its
# role/name and read its R-file's concepts. Universal; used only as a fallback (1 FilingSummary
# fetch + 1 fetch per face statement) since it is coarser than the authoritative linkbase.

# A `defref_us-gaap_Assets` token -> the namespaced concept `"us-gaap:Assets"` (namespace = up to
# the first underscore, local name follows).
function _defref_concept(token::AbstractString)
    s = replace(token, r"^defref_" => "")
    i = findfirst('_', s)
    return i === nothing ? s : s[1:prevind(s, i)] * ":" * s[nextind(s, i):end]
end

# Every distinct concept referenced in a rendered statement R-file (pure; offline-testable).
_rfile_concepts(html::AbstractString) =
    unique(_defref_concept(m.match) for m in eachmatch(r"defref_[A-Za-z0-9_-]+", html))

# A FilingSummary <Report>'s `<LongName>` follows the grammar "<sortcode> - <Category> - <Title>";
# the category ("Statement"/"Disclosure"/…) authoritatively separates face statements from
# notes/details. Returns the lowercased category, or "" when no LongName is present.
_longname_category(block::AbstractString) =
    (m = match(r"(?is)<LongName>\s*[^-<]*-\s*([^-<]+?)\s*-", block); m === nothing ? "" : lowercase(strip(m.captures[1])))

# Parse FilingSummary.xml into the face-statement reports `(statement, r-file)`: each <Report> whose
# role/name classifies to a face statement. Notes/details drop out through `_classify_role`'s scorer —
# the LongName category (Disclosure/Schedule/…) and any fragment term in the role/name both score as
# disqualifying — so a generically-named detail (e.g. MSFT's "…Comprehensive Income Statements
# (Detail)", whose role still embeds "incomestatement") is not mistaken for a statement. Pure, offline.
function _filing_summary_reports(fs_xml::AbstractString)
    out = @NamedTuple{statement::String, file::String}[]
    for m in eachmatch(r"(?is)<Report\b[^>]*>(.*?)</Report>", fs_xml)
        b = m.captures[1]
        fm = match(r"(?is)<HtmlFileName>\s*(R\d+\.htm)\s*</HtmlFileName>", b)
        fm === nothing && continue
        cat = _longname_category(b)
        rm = match(r"(?is)<Role>(.*?)</Role>", b)
        nm = match(r"(?is)<ShortName>(.*?)</ShortName>", b)
        stmt = rm === nothing ? "" : _classify_role(strip(rm.captures[1]); category = cat)
        isempty(stmt) && nm !== nothing && (stmt = _classify_role(strip(nm.captures[1]); category = cat))
        isempty(stmt) || push!(out, (statement = stmt, file = String(strip(fm.captures[1]))))
    end
    return out
end

# Build concept => Vector{statement} (every section it appears in, priority-sorted) from
# FilingSummary.xml + the R-files it points to.
function _filing_summary_statements(f::Filing)
    base = _filing_dir(f)
    fs = fetch_url("$base/FilingSummary.xml")
    fs === nothing && return Dict{String,Vector{String}}()
    cmap = Dict{String,Vector{String}}()
    for r in _filing_summary_reports(String(fs))
        body = fetch_url("$base/$(r.file)")
        body === nothing && continue
        for c in _rfile_concepts(String(body))
            v = get!(cmap, c, String[])
            r.statement in v || push!(v, r.statement)
        end
    end
    return _add_intrinsic_statements!(cmap)
end

"""
    label_map(f::Filing) -> Dict{String,String}

The filing's concept => human-readable label map, from its **label linkbase** (`*_lab.xml`) — the
authoritative source for how each XBRL concept is presented (e.g.
`"us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax" => "Net sales"`). Prefers the
standard label, falling back to the terse then verbose label; returns an empty map if the linkbase
cannot be fetched. This is what `facts(f; labels=true)` uses to fill the `label` column (the
browser picker reads the label off the rendered row instead).
"""
function label_map(f::Filing)
    m = _concept_labels(_fetch_linkbase(f, "lab"))
    isempty(m) && @warn "No native labels for $(f.ref): the label linkbase was missing " *
        "(not loose and not in `<accession>-xbrl.zip`) — `label` will be empty."
    return m
end

"""
    calculations(f::Filing) -> Vector{NamedTuple}

The filing's **calculation relationships** from its calculation linkbase (`*_cal.xml`) — the
arithmetic of each statement: which concepts sum into which, with what sign. Returns a Tables.jl
row table of `(statement, parent, child, weight)`, where `weight` is `+1.0` (added to the parent)
or `-1.0` (subtracted) and `statement` is the classified role (see [`statement_map`](@ref)).

This is the authoritative source for *how* line items roll up — use it to validate that children
sum to their parent, or to understand a line's contribution sign. It does **not** rewrite the
stored fact values: those are XBRL-canonical and already validated against the SEC API; the weight
is the contribution sign *in the context of a parent*, which is statement- and parent-specific.

```julia
f = fetch_filing(104169, "0000104169-26-000102")
using PrettyTables
pretty_table(calculations(f))     # e.g. OperatingIncomeLoss = Revenues(+1) - CostOfRevenue(-1) - SGA(-1)
```
"""
calculations(f::Filing) = _calculations(_fetch_linkbase(f, "cal"))
