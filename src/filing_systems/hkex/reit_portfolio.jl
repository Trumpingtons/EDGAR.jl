# HK REIT property-portfolio composition — the REIT analogue of `extract_fund_portfolio` (China/India funds). A
# REIT does not list every property; its annual report summarises the portfolio by property TYPE / SEGMENT (Link
# REIT: Destination / Community / Neighbourhood) each with a valuation. That valuation composition maps onto the
# SAME `FundPortfolio` type the fund path returns — `asset_composition::Vector{FundAssetClass}` with `item` the
# segment, `amount` its valuation and `pct_total_assets` its share of the portfolio — so funds and REITs share
# one portfolio API. (Per-property holdings and occupancy are a later extension; `FundAssetClass` has 3 fields.)

# Locate the portfolio pages from the PDF outline (bookmarks mentioning "portfolio"); the schedule lives in the
# business review, not the financial statements.
function _reit_portfolio_pages(doc; window::Int = 14)
    (haskey(doc, :outline) && doc.outline !== nothing) || return nothing
    ps = Int[]
    for e in doc.outline
        p = get(e, :page, nothing); p === nothing && continue
        occursin(r"(?i)portfolio", String(get(e, :title, ""))) && push!(ps, Int(p))
    end
    isempty(ps) && return nothing
    return (minimum(ps), min(minimum(ps) + window, length(doc.pages)))
end

# The portfolio-summary table → segment valuations. Found by a header that names both "valuation" and the
# "no. of properties" count; columns are identified by their (colspan-expanded) header text.
function _reit_portfolio_from_sd(sd)
    for tbl in sd.tables
        htxt = lowercase(join([strip(c.text) for c in tbl.cells if c.row <= 2], " "))
        (occursin("valuation", htxt) && occursin(r"no\.?\s*of\s*propert", htxt)) || continue
        pf = _reit_parse_table(tbl)
        pf === nothing || return pf
    end
    return nothing
end

function _reit_parse_table(tbl)
    nr, nc = tbl.n_rows, tbl.n_cols
    grid = Dict{Tuple{Int,Int},String}(); hdr = Dict{Int,String}()
    for c in tbl.cells
        grid[(c.row, c.col)] = strip(c.text)
        c.row <= 2 || continue                                  # colspan-expanded header, per column
        for cc in c.col:(c.col + max(c.colspan, 1) - 1)
            hdr[cc] = strip(string(get(hdr, cc, ""), " ", strip(c.text)))
        end
    end
    valcol = nothing
    for cc in 0:nc-1; occursin("valuation", lowercase(get(hdr, cc, ""))) && (valcol = cc; break); end
    valcol === nothing && return nothing
    scale = occursin(r"(?i)'m\b|million", lowercase(get(hdr, valcol, ""))) ? 1e6 :
            occursin(r"(?i)'000|thousand", lowercase(get(hdr, valcol, ""))) ? 1e3 : 1.0
    segs = FundAssetClass[]; total = nothing
    for r in 0:nr-1
        seg = strip(replace(get(grid, (r, 0), ""), r"\s*\(\d+\)\s*$" => ""))   # drop a trailing note marker
        occursin(r"[A-Za-z]", seg) || continue                 # a segment row has a word label in column 0
        v = parse_amount(get(grid, (r, valcol), ""); locale = :en)
        (v === nothing || v.nil) && continue
        amt = v.val * scale
        if occursin(r"(?i)^(total|overall)\b", seg)            # the total row sets the denominator, not a segment
            total = amt
        else
            push!(segs, FundAssetClass(seg, amt, 0.0))
        end
    end
    isempty(segs) && return nothing
    total === nothing && (total = sum(s.amount for s in segs))
    comp = [FundAssetClass(s.item, s.amount, total > 0 ? round(100 * s.amount / total, digits = 1) : 0.0) for s in segs]
    return FundPortfolio(comp, FundIndustryExposure[], FundHolding[])
end

"""
    extract_reit_portfolio(path) -> FundPortfolio

Extract a Hong Kong REIT's property-portfolio composition from its annual-report PDF — the segment/type
breakdown (Link REIT: Destination / Community / Neighbourhood), each with its property valuation and share of
the portfolio, returned in the same [`FundPortfolio`](@ref) `asset_composition` the fund path uses. The REIT
analogue of [`extract_fund_portfolio`](@ref); the portfolio schedule is located from the report outline.

```julia
pf = extract_reit_portfolio("HK-LinkREIT-SEHK-AR.pdf")
pf.asset_composition   # FundAssetClass(segment, valuation, % of portfolio)
```
"""
function extract_reit_portfolio(path::AbstractString)
    doc = _pdf_words(path)
    rng = _reit_portfolio_pages(doc)
    rng === nothing && throw(ArgumentError("no property-portfolio schedule found in $(repr(basename(path)))"))
    sd = structured_document(path; pages = rng, jurisdiction = "HK", language = "en")
    pf = _reit_portfolio_from_sd(sd)
    pf === nothing && throw(ArgumentError("could not parse the property-portfolio table in $(repr(basename(path)))"))
    return pf
end

extract_reit_portfolio(sd::StructuredDocument) = _reit_portfolio_from_sd(sd)
