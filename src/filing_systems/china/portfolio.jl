# China fund portfolio (§8 投资组合报告) — the holdings disclosure a public fund/ETF/LOF carries in its annual
# report, the CNINFO analogue of an SEC N-PORT. Extracted from the §8 tables via Docling (Tier-2), separate
# from the CAS financial-statement path (filing_systems/china/cas.jl): a portfolio is a list of positions and
# exposure summaries, not classified statement facts. See docs/dev/china-plan.md.

# One position: a security held by the fund, its size and its weight in the fund's net asset value.
struct FundHolding
    category::String                 # "stock" | "bond" | "abs" | "metal" | "warrant"
    code::String                     # exchange code (601899); may carry a market suffix
    name::String                     # 紫金矿业
    quantity::Union{Float64,Nothing} # 数量 (shares/张); nothing when the schedule omits it
    fair_value::Float64              # 公允价值 (CNY)
    pct_nav::Float64                 # 占基金资产净值比例 (%)
end

# 8.1 期末基金资产组合情况: the fund's assets split by class (equity / fixed income / cash …).
struct FundAssetClass
    item::String                     # 权益投资 / 其中：股票 / 银行存款和结算备付金合计 …
    amount::Float64                  # CNY
    pct_total_assets::Float64        # 占基金总资产的比例 (%)
end

# 8.2 报告期末按行业分类的股票投资组合: equity exposure by CSRC industry sector.
struct FundIndustryExposure
    sector_code::String              # A … S (CSRC 行业代码)
    sector::String                   # 采矿业 / 制造业 …
    fair_value::Float64              # CNY
    pct_nav::Float64                 # 占基金资产净值比例 (%)
end

# The whole §8 report: the position list plus the two exposure summaries.
struct FundPortfolio
    asset_composition::Vector{FundAssetClass}
    industry::Vector{FundIndustryExposure}
    holdings::Vector{FundHolding}
end

# §8 page range from the PDF outline: the 投资组合报告 bookmark up to the next section (§9 基金份额 / holders /
# NAV performance). Returns (lo,hi) or nothing (no outline → caller cannot locate the section).
function _fund_portfolio_pages(doc)
    haskey(doc, :outline) || return nothing
    ol = doc.outline
    (ol === nothing || isempty(ol)) && return nothing
    npg = length(doc.pages)
    lo = nothing; hi = nothing
    for e in ol
        p = get(e, :page, nothing); p === nothing && continue
        t = _cas_norm(String(get(e, :title, "")))
        occursin("投资组合报告", t) && lo === nothing && (lo = Int(p))
        if lo !== nothing && hi === nothing && Int(p) > lo &&
           (occursin("基金份额", t) || occursin("持有人", t) || occursin("净值表现", t) || occursin("开放式基金", t))
            hi = Int(p)
        end
    end
    lo === nothing && return nothing
    return (lo, hi === nothing ? min(lo + 10, npg) : hi)
end

# Parse a portfolio-cell number: thousands-comma / decimal, "-" and blanks → nothing (a not-held line).
_port_num(s) = (p = parse_amount(strip(String(s)); locale = :en); (p === nothing || p.nil) ? nothing : p.val)

# A securities code cell: 5–6 digits, optionally a market/board letter suffix (e.g. Hong-Kong-connect).
_port_iscode(s) = occursin(r"^\d{5,6}[A-Za-z]{0,2}$", strip(String(s)))

# Holdings category from a header/title string (which security schedule this is).
function _port_holding_cat(s)
    occursin("资产支持证券", s) && return "abs"
    occursin("债券", s)         && return "bond"
    occursin("贵金属", s)       && return "metal"
    occursin("权证", s)         && return "warrant"
    occursin("股票", s)         && return "stock"
    return nothing
end

# Build a (row,col)->text grid and the column count for a Docling table.
function _port_grid(tbl)
    grid = Dict{Tuple{Int,Int},String}()
    mc = 0
    for c in tbl.cells
        grid[(c.row, c.col)] = strip(c.text); mc = max(mc, c.col)
    end
    return grid, mc
end

# Assemble the §8 portfolio from a parsed StructuredDocument. Tables are classified STRUCTURALLY (column shape
# and cell patterns) so multi-page continuations — which Docling emits without a repeated title — are handled:
#   • holdings detail  = ≥6 columns whose rows are [序号, code, name, 数量, 公允价值, 占净值比例] (all three
#     numerics present); the trailing "重大变动" trading tables are 5-column (金额, no 数量) and so excluded,
#     and the 流通受限 note table has a text last column and so excluded.
#   • industry         = a 4-column table whose first column is single CSRC sector letters (A…S).
#   • asset composition= the 4-column 8.1 table (占基金总资产 header).
# A holdings continuation inherits the category of the schedule it continues (`curcat`).
function _fund_portfolio(sd)::FundPortfolio
    sectitle = Dict(s.section_id => s.title for s in sd.sections)
    assets = FundAssetClass[]
    industry = Dict{String,FundIndustryExposure}()   # keyed by sector, summed across sub-portfolios
    holdings = FundHolding[]
    curcat = "stock"
    for tbl in sd.tables
        grid, mc = _port_grid(tbl)
        nr = tbl.n_rows
        title = _cas_norm(string(something(tbl.caption, ""), " ", get(sectitle, something(tbl.section_id, ""), "")))
        rows(colpred) = count(r -> colpred(get(grid, (r, 0), ""), get(grid, (r, 1), "")), 0:nr-1)

        # 8.1 asset composition: 4 cols with a [序号, 项目, 金额, 占基金总资产] header. Detected on the HEADER
        # ROW, not the title — a fund may caption the table with only a unit note ("金额单位：人民币元") and
        # section it under the bare "投资组合报告" heading.
        if occursin("基金资产组合情况", title) ||
           (mc >= 3 && any(r -> occursin("项目", get(grid, (r, 1), "")) && occursin("金额", get(grid, (r, 2), "")), 0:min(1, nr-1)))
            for r in 0:nr-1
                item = get(grid, (r, 1), "")
                (isempty(item) || occursin("项目", item)) && continue
                amt = _port_num(get(grid, (r, 2), "")); amt === nothing && continue
                pct = _port_num(get(grid, (r, 3), ""))
                push!(assets, FundAssetClass(replace(item, r"\s" => ""), amt, pct === nothing ? 0.0 : pct))
            end
            continue
        end

        # industry exposure: first column is single CSRC sector letters.
        if mc >= 3 && rows((c0, _) -> occursin(r"^[A-Z]$", c0)) >= 3
            for r in 0:nr-1
                sc = get(grid, (r, 0), "")
                occursin(r"^[A-Z]$", sc) || continue
                fv = _port_num(get(grid, (r, 2), "")); fv === nothing && continue   # skip not-held ("-")
                pct = _port_num(get(grid, (r, 3), ""))
                sec = replace(get(grid, (r, 1), ""), r"\s" => "")
                prev = get(industry, sec, nothing)
                industry[sec] = prev === nothing ?
                    FundIndustryExposure(sc, sec, fv, pct === nothing ? 0.0 : pct) :
                    FundIndustryExposure(sc, sec, prev.fair_value + fv, prev.pct_nav + (pct === nothing ? 0.0 : pct))
            end
            continue
        end

        # holdings detail: ≥6 cols, rows [序号, code, name, 数量, 公允价值, 占净值比例] with all numerics present.
        ishold = mc >= 5 && rows((_, c1) -> _port_iscode(c1)) >= 1
        if ishold
            hdr = _port_holding_cat(title)
            hdr === nothing || (curcat = hdr)
            for r in 0:nr-1
                code = get(grid, (r, 1), "")
                _port_iscode(code) || continue
                fv = _port_num(get(grid, (r, 4), "")); fv === nothing && continue
                pct = _port_num(get(grid, (r, 5), "")); pct === nothing && continue   # excludes 流通受限 (text col-5)
                qty = _port_num(get(grid, (r, 3), ""))
                name = replace(get(grid, (r, 2), ""), r"\s" => "")
                push!(holdings, FundHolding(curcat, code, name, qty, fv, pct))
            end
            continue
        end
    end
    return FundPortfolio(assets, collect(values(industry)), holdings)
end

"""
    extract_fund_portfolio(path) -> FundPortfolio

Extract a Chinese public fund's §8 portfolio report (投资组合报告) from its annual-report PDF: the position
list (`holdings`) plus the asset-composition (`asset_composition`) and by-industry (`industry`) summaries.
The §8 section is located from the PDF outline and parsed with Docling; see [`FundPortfolio`](@ref). This is
the holdings analogue of the CAS statement path ([`extract_cas_pdf`](@ref)) and applies to the fund format
(ETF/LOF/open-end); a REIT rides the corporate statement path instead.

Coverage note: the disclosure itself is uneven by security type — the equity schedule (8.3) lists ALL stock
positions, whereas bonds, ABS, precious metals and warrants are disclosed only as the TOP FIVE by fair value
(8.6–8.9). So for a bond fund `holdings` is the top-5 bonds, not the full book; use `asset_composition` for
the fund-wide fixed-income total.
"""
function extract_fund_portfolio(path::AbstractString)
    doc = _pdf_words(path)
    rng = _fund_portfolio_pages(doc)
    rng === nothing && throw(ArgumentError("no §8 投资组合报告 outline found in $(repr(basename(path)))"))
    sd = structured_document(path; pages = rng, jurisdiction = "CN", language = "zh")
    return _fund_portfolio(sd)
end
