# CAS (Chinese Accounting Standards / 企业会计准则) classification vocabulary — the LABEL-driven analogue of
# the by-namespace national vocabularies (vocab_indas / vocab_jpgaap …). China is PDF-native: a statement
# line carries a Chinese label, not a namespaced concept, so classification keys on the label text. This
# table maps the standard general-industry CAS statement labels to a canonical concept + statement + period
# type; the China PDF extractor (filing_systems/china/cas.jl) looks each row's clustered label up here. See
# docs/dev/china-plan.md (C3). Bank/insurer financial-institution formats are a later addition.

# One classified CAS line: the canonical concept, which primary statement it sits in, and whether it is an
# instant (balance-sheet) or a duration (income / cash-flow) fact.
const _CASConcept = @NamedTuple{concept::String, statement::String, instant::Bool}

# Normalise a label for lookup: NFKC-fold (maps the KANGXI RADICALS some PDFs use — ⾦→金, ⾏→行, ⼊→入 —
# to the CJK ideographs, and full-width forms to ASCII), then drop spaces. Without NFKC a bank whose PDF
# emits 现⾦/归属于本⾏股东… would never match the 现金/归属于本行… vocabulary keys.
_cas_norm(s::AbstractString) = replace(Base.Unicode.normalize(String(s), :NFKC), r"[\s　]" => "")

# Strip the leading enumerators CAS statements prefix line items with, so "一、营业总收入", "其中：营业收入"
# and "（一）基本每股收益" collapse onto the bare label key. Applied after `_cas_norm`.
function _cas_labelkey(s::AbstractString)
    t = _cas_norm(s)
    t = replace(t, r"^[（(]?[一二三四五六七八九十]+[)）]?[、.．,]" => "")   # 一、  （二）  三.
    t = replace(t, r"^[（(]?\d+[)）]?[、.．]" => "")                         # 1.  (2)  3、
    t = replace(t, r"^(其中|加|减|其他)[:：]" => "")                        # 其中：  加：  减：
    t = replace(t, r"^[（(]?按[^）)]*分类[）)]?" => "")                     # "(按所有权归属分类)" IS section divider
    t = replace(t, r"\(或[^()]*\)" => "")                                  # "(或股东权益)" / "(或股本)" clarifier
    t = replace(t, r"\([^()]*填列[^()]*\)$" => "")                         # trailing "(净亏损以'－'号填列)" sign note
    # CF net-flow lines vary the middle by sign (投资活动【产生的|使用的|(使用)/产生的】现金流量净额) and Docling
    # sometimes MERGES the outflow-subtotal label in front of the net-flow one; canonicalise to the net-flow
    # concept (a net-flow line's identity IS the net flow), discarding any merged prefix/suffix.
    m = match(r"(经营|投资|筹资)活动[^现]*现金流量净额", t)
    m === nothing || (t = string(m.captures[1], "活动产生的现金流量净额"))
    return t
end

# The anchor table. Keys are normalised Chinese labels; several presentation variants map to one concept
# (e.g. 所有者权益合计 / 股东权益合计). Concepts are namespaced `cas:` so they are self-identifying in the
# `concept` column while the human label stays Chinese.
const CAS_CONCEPTS = Dict{String,_CASConcept}(
    # ── Balance sheet (资产负债表) — instant ──────────────────────────────────────────────────────
    "货币资金"                     => (concept="cas:CashAndBankBalances",        statement="BalanceSheet", instant=true),
    "应收账款"                     => (concept="cas:AccountsReceivable",         statement="BalanceSheet", instant=true),
    "存货"                         => (concept="cas:Inventories",                statement="BalanceSheet", instant=true),
    "流动资产合计"                 => (concept="cas:CurrentAssets",              statement="BalanceSheet", instant=true),
    "固定资产"                     => (concept="cas:PropertyPlantAndEquipment",  statement="BalanceSheet", instant=true),
    "非流动资产合计"               => (concept="cas:NoncurrentAssets",           statement="BalanceSheet", instant=true),
    "资产总计"                     => (concept="cas:Assets",                     statement="BalanceSheet", instant=true),
    "资产合计"                     => (concept="cas:Assets",                     statement="BalanceSheet", instant=true),  # banks/insurers
    "负债及股东权益合计"           => (concept="cas:LiabilitiesAndEquity",       statement="BalanceSheet", instant=true),  # banks/insurers
    "负债和股东权益合计"           => (concept="cas:LiabilitiesAndEquity",       statement="BalanceSheet", instant=true),
    "流动负债合计"                 => (concept="cas:CurrentLiabilities",         statement="BalanceSheet", instant=true),
    "非流动负债合计"               => (concept="cas:NoncurrentLiabilities",      statement="BalanceSheet", instant=true),
    "负债合计"                     => (concept="cas:Liabilities",                statement="BalanceSheet", instant=true),
    "股本"                         => (concept="cas:ShareCapital",               statement="BalanceSheet", instant=true),
    "实收资本"                     => (concept="cas:ShareCapital",               statement="BalanceSheet", instant=true),
    "未分配利润"                   => (concept="cas:RetainedEarnings",           statement="BalanceSheet", instant=true),
    "归属于母公司所有者权益合计"   => (concept="cas:EquityAttributableToParent", statement="BalanceSheet", instant=true),
    "归属于母公司股东权益合计"     => (concept="cas:EquityAttributableToParent", statement="BalanceSheet", instant=true),
    "归属于本行股东权益合计"       => (concept="cas:EquityAttributableToParent", statement="BalanceSheet", instant=true),  # banks (本行)
    "归属于本公司股东权益合计"     => (concept="cas:EquityAttributableToParent", statement="BalanceSheet", instant=true),
    "少数股东权益"                 => (concept="cas:NoncontrollingInterests",    statement="BalanceSheet", instant=true),
    "所有者权益合计"               => (concept="cas:Equity",                     statement="BalanceSheet", instant=true),
    "股东权益合计"                 => (concept="cas:Equity",                     statement="BalanceSheet", instant=true),
    "所有者权益(或股东权益)合计"   => (concept="cas:Equity",                     statement="BalanceSheet", instant=true),
    "负债和所有者权益总计"         => (concept="cas:LiabilitiesAndEquity",       statement="BalanceSheet", instant=true),
    "负债和股东权益总计"           => (concept="cas:LiabilitiesAndEquity",       statement="BalanceSheet", instant=true),
    # ── Income statement (利润表) — duration ─────────────────────────────────────────────────────
    "营业总收入"                   => (concept="cas:TotalRevenue",               statement="IncomeStatement", instant=false),
    "营业收入"                     => (concept="cas:Revenue",                    statement="IncomeStatement", instant=false),
    "营业收入合计"                 => (concept="cas:Revenue",                    statement="IncomeStatement", instant=false),  # banks: total operating income
    "营业总成本"                   => (concept="cas:TotalOperatingCost",         statement="IncomeStatement", instant=false),
    "营业成本"                     => (concept="cas:CostOfSales",                statement="IncomeStatement", instant=false),
    "营业利润"                     => (concept="cas:OperatingProfit",            statement="IncomeStatement", instant=false),
    "利润总额"                     => (concept="cas:ProfitBeforeTax",            statement="IncomeStatement", instant=false),
    "净利润"                       => (concept="cas:ProfitLoss",                 statement="IncomeStatement", instant=false),
    "归属于母公司所有者的净利润"   => (concept="cas:ProfitAttributableToParent", statement="IncomeStatement", instant=false),
    "归属于母公司股东的净利润"     => (concept="cas:ProfitAttributableToParent", statement="IncomeStatement", instant=false),
    "归属于本行股东的净利润"       => (concept="cas:ProfitAttributableToParent", statement="IncomeStatement", instant=false),  # banks (本行)
    "本行股东的净利润"             => (concept="cas:ProfitAttributableToParent", statement="IncomeStatement", instant=false),
    "归属于本公司股东的净利润"     => (concept="cas:ProfitAttributableToParent", statement="IncomeStatement", instant=false),
    "利息净收入"                   => (concept="cas:NetInterestIncome",          statement="IncomeStatement", instant=false),  # banks
    "净利息收入"                   => (concept="cas:NetInterestIncome",          statement="IncomeStatement", instant=false),
    "手续费及佣金净收入"           => (concept="cas:NetFeeAndCommissionIncome",  statement="IncomeStatement", instant=false),
    "净手续费及佣金收入"           => (concept="cas:NetFeeAndCommissionIncome",  statement="IncomeStatement", instant=false),
    "已赚保费"                     => (concept="cas:NetEarnedPremiums",          statement="IncomeStatement", instant=false),  # insurers
    "少数股东损益"                 => (concept="cas:MinorityInterestIncome",     statement="IncomeStatement", instant=false),
    "基本每股收益"                 => (concept="cas:BasicEarningsPerShare",      statement="IncomeStatement", instant=false),
    # ── Cash-flow statement (现金流量表) — duration ──────────────────────────────────────────────
    "经营活动产生的现金流量净额"   => (concept="cas:NetCashFlowsFromOperating",  statement="CashFlow", instant=false),
    "投资活动产生的现金流量净额"   => (concept="cas:NetCashFlowsFromInvesting",  statement="CashFlow", instant=false),
    "筹资活动产生的现金流量净额"   => (concept="cas:NetCashFlowsFromFinancing",  statement="CashFlow", instant=false),
    "汇率变动对现金及现金等价物的影响" => (concept="cas:EffectOfExchangeRateOnCash", statement="CashFlow", instant=false),
    "现金及现金等价物净增加额"     => (concept="cas:NetIncreaseInCash",          statement="CashFlow", instant=false),
    "期初现金及现金等价物余额"     => (concept="cas:CashAtBeginningOfPeriod",    statement="CashFlow", instant=false),
    "期末现金及现金等价物余额"     => (concept="cas:CashAtEndOfPeriod",          statement="CashFlow", instant=false),
)

"""
    cas_concept(label) -> Union{Nothing, NamedTuple{(:concept,:statement,:instant)}}

Classify a Chinese CAS statement label (as clustered from a PDF row) to its canonical concept, primary
statement and period type, or `nothing` if it is not a recognised anchor. Presentation whitespace and the
optional "（或股东权益）"-type qualifiers are normalised away. General-industry format; see [`CAS_CONCEPTS`](@ref).
"""
function cas_concept(label::AbstractString)
    v = get(CAS_CONCEPTS, _cas_norm(label), nothing)
    v === nothing || return v
    return get(CAS_CONCEPTS, _cas_labelkey(label), nothing)   # retry with enumerators stripped
end
