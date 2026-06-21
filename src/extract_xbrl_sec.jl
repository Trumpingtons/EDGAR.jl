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
# `"lab"` label) from its Archives directory; "" if absent.
function _fetch_linkbase(f::Filing, suffix::AbstractString)
    base = _filing_dir(f.cik, f.accession)
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
`"CoverPage"` — using the **authoritative** source: the filing's own presentation linkbase
(`*_pre.xml`). Concepts that appear only in notes/disclosures are absent. Returns a
`concept => statement` dictionary (empty if the linkbase cannot be fetched). This is what
`facts(f; classify=true)` uses to fill the `statement` column.
"""
statement_map(f::Filing) = _concept_statements(_fetch_linkbase(f, "pre"))

"""
    label_map(f::Filing) -> Dict{String,String}

The filing's concept => human-readable label map, from its **label linkbase** (`*_lab.xml`) — the
authoritative source for how each XBRL concept is presented (e.g.
`"us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax" => "Net sales"`). Prefers the
standard label, falling back to the terse then verbose label; returns an empty map if the linkbase
cannot be fetched. This is what `facts(f; labels=true)` uses to fill the `label` column (the
browser picker reads the label off the rendered row instead).
"""
label_map(f::Filing) = _concept_labels(_fetch_linkbase(f, "lab"))

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
