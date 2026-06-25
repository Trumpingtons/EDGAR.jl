# facts(::Selection): assemble captured facts into the Tables.jl row table (jurisdiction-agnostic).

"""
    facts(sel::Selection) -> Vector{FactRow}
    facts(sels::AbstractVector{<:Selection}) -> Vector{FactRow}

Assemble the resolved XBRL facts captured in `sel` (or several selections) into a
[Tables.jl](https://github.com/JuliaData/Tables.jl) *row table* — the hardened fact
schema: `cik`, `accession`, `statement`, `concept`, `label`, normalised `value`, `unit`,
`period_start`/`period_end`, `is_instant`, `dimensions` (JSON), `decimals`, the raw
`context_ref`/`unit_ref`, and `source_selector`. Values are already normalised
(`displayed × 10^scale × sign`, in [`parse_selection`](@ref)).

Rows are de-duplicated on the natural key `(accession, concept, context_ref, unit_ref)` —
one fact per concept × context × unit — so picking the same region twice, or combining
overlapping selections, does not double-count. A prose-only selection yields an **empty**
table (no error). Being a `Vector` of `NamedTuple`s, the result is a Tables.jl source —
render it with `PrettyTables`, or feed it to `CSV`, `Arrow`, `DataFrames`, a database, ….

```julia
sel = select_section(f)            # pick the income statement
using PrettyTables
pretty_table(facts(sel))           # the normalised facts as a table
```
"""
function facts(sels::AbstractVector{<:Selection})
    rows = FactRow[]
    seen = Set{NTuple{4,String}}()
    for sel in sels, f in sel.facts
        key = (f.accession, f.concept, f.context_ref, f.unit_ref)
        key in seen && continue
        push!(seen, key)
        push!(rows, fact_row(f))
    end
    return rows
end
facts(sel::Selection) = facts([sel])
