# Faithful translation of edgartools' edgar/documents/extractors/pattern_section_extractor.py.
# SectionExtractor — pattern/regex section detection (the fallback strategy, and primary for forms without
# a usable TOC). Per-form SECTION_PATTERNS (order-preserving) + header finding (headings/bold/tables/plain)
# + TOC-aware matching with a main-header-over-cross-reference preference + HTML-after-TOC fallback.

# Per-form ordered section patterns: form => [(section_name, [(regex, title), …]), …]. All regexes are
# matched case-insensitively (re.IGNORECASE in _match_sections), so the "i" flag is applied here.
_p(s) = Regex(s, "i")
const _PSE_SECTION_PATTERNS = Dict{String,Vector{Pair{String,Vector{Tuple{Regex,String}}}}}(
    "10-K" => [
        "business" => [(_p("^(Item|ITEM)\\s+1\\.?\\s*Business"), "Item 1 - Business"),
            (_p("^Business\\s*\$"), "Business"), (_p("^Business Overview"), "Business Overview"),
            (_p("^Our Business"), "Our Business"), (_p("^Company Overview"), "Company Overview")],
        "risk_factors" => [(_p("^(Item|ITEM)\\s+1A\\.?\\s*Risk\\s+Factors"), "Item 1A - Risk Factors"),
            (_p("^Risk\\s+Factors"), "Risk Factors"), (_p("^Factors\\s+That\\s+May\\s+Affect"), "Risk Factors")],
        "properties" => [(_p("^(Item|ITEM)\\s+2\\.?\\s*Properties"), "Item 2 - Properties"),
            (_p("^Properties"), "Properties"), (_p("^Real\\s+Estate"), "Real Estate")],
        "legal_proceedings" => [(_p("^(Item|ITEM)\\s+3\\.?\\s*Legal\\s+Proceedings"), "Item 3 - Legal Proceedings"),
            (_p("^Legal\\s+Proceedings"), "Legal Proceedings"), (_p("^Litigation"), "Litigation")],
        "market_risk" => [(_p("^(Item|ITEM)\\s+7A\\.?\\s*Quantitative.*Disclosures"), "Item 7A - Market Risk"),
            (_p("^Market\\s+Risk"), "Market Risk"), (_p("^Quantitative.*Qualitative.*Market\\s+Risk"), "Market Risk")],
        "mda" => [(_p("^(Item|ITEM)\\s+7\\.?\\s*Management.*Discussion"), "Item 7 - MD&A"),
            (_p("^Management.*Discussion.*Analysis"), "MD&A"), (_p("^MD&A"), "MD&A")],
        "financial_statements" => [(_p("^(Item|ITEM)\\s+8\\.?\\s*Financial\\s+Statements"), "Item 8 - Financial Statements"),
            (_p("^Financial\\s+Statements"), "Financial Statements"),
            (_p("^Consolidated\\s+Financial\\s+Statements"), "Consolidated Financial Statements")],
        "controls_procedures" => [(_p("^(Item|ITEM)\\s+9A\\.?\\s*Controls.*Procedures"), "Item 9A - Controls and Procedures"),
            (_p("^Controls.*Procedures"), "Controls and Procedures"), (_p("^Internal\\s+Control"), "Internal Controls")],
    ],
    "10-Q" => [
        "part_i_item_1" => [(_p("^(Item|ITEM)\\s+1\\.?\\s*[-–—.]?\\s*Financial\\s+Statements"), "Item 1 - Financial Statements"),
            (_p("^Financial\\s+Statements"), "Financial Statements"), (_p("^Condensed.*Financial\\s+Statements"), "Condensed Financial Statements")],
        "part_i_item_2" => [(_p("^(Item|ITEM)\\s+2\\.?\\s*[-–—.]?\\s*Management.*Discussion"), "Item 2 - MD&A"),
            (_p("^Management.*Discussion.*Analysis"), "MD&A")],
        "part_i_item_3" => [(_p("^(Item|ITEM)\\s+3\\.?\\s*[-–—.]?\\s*Quantitative.*Disclosures"), "Item 3 - Market Risk"),
            (_p("^Market\\s+Risk"), "Market Risk")],
        "part_i_item_4" => [(_p("^(Item|ITEM)\\s+4\\.?\\s*[-–—.]?\\s*Controls.*Procedures"), "Item 4 - Controls and Procedures"),
            (_p("^Controls.*Procedures"), "Controls and Procedures")],
        "part_ii_item_1" => [(_p("^(Item|ITEM)\\s+1\\.?\\s*[-–—.]?\\s*Legal\\s+Proceedings"), "Item 1 - Legal Proceedings"),
            (_p("^Legal\\s+Proceedings"), "Legal Proceedings")],
        "part_ii_item_1a" => [(_p("^(Item|ITEM)\\s+1A\\.?\\s*[-–—.]?\\s*Risk\\s+Factors"), "Item 1A - Risk Factors"),
            (_p("^Risk\\s+Factors"), "Risk Factors")],
        "part_ii_item_2" => [(_p("^(Item|ITEM)\\s+2\\.?\\s*[-–—.]?\\s*Unregistered\\s+Sales"), "Item 2 - Unregistered Sales"),
            (_p("^Unregistered\\s+Sales.*Equity"), "Unregistered Sales")],
        "part_ii_item_3" => [(_p("^(Item|ITEM)\\s+3\\.?\\s*[-–—.]?\\s*Defaults"), "Item 3 - Defaults Upon Senior Securities"),
            (_p("^Defaults\\s+Upon\\s+Senior"), "Defaults Upon Senior Securities")],
        "part_ii_item_4" => [(_p("^(Item|ITEM)\\s+4\\.?\\s*[-–—.]?\\s*Mine\\s+Safety"), "Item 4 - Mine Safety Disclosures"),
            (_p("^Mine\\s+Safety"), "Mine Safety Disclosures")],
        "part_ii_item_5" => [(_p("^(Item|ITEM)\\s+5\\.?\\s*[-–—.]?\\s*Other\\s+Information"), "Item 5 - Other Information"),
            (_p("^Other\\s+Information"), "Other Information")],
        "part_ii_item_6" => [(_p("^(Item|ITEM)\\s+6\\.?\\s*[-–—.]?\\s*Exhibits"), "Item 6 - Exhibits"),
            (_p("^Exhibits"), "Exhibits")],
    ],
    "20-F" => [
        "item_1" => [(_p("^(Item|ITEM)\\s+1\\.?\\s*[-–—.]?\\s*Identity.*Directors"), "Item 1 - Identity of Directors, Senior Management and Advisers"),
            (_p("^Identity.*Directors.*Senior\\s+Management"), "Identity of Directors")],
        "item_2" => [(_p("^(Item|ITEM)\\s+2\\.?\\s*[-–—.]?\\s*Offer\\s+Statistics"), "Item 2 - Offer Statistics and Expected Timetable"),
            (_p("^Offer\\s+Statistics.*Timetable"), "Offer Statistics")],
        "item_3" => [(_p("^(Item|ITEM)\\s+3\\.?\\s*[-–—.]?\\s*Key\\s+Information"), "Item 3 - Key Information"),
            (_p("^Key\\s+Information"), "Key Information"), (_p("^Risk\\s+Factors"), "Risk Factors")],
        "item_4" => [(_p("^(Item|ITEM)\\s+4\\.?\\s*[-–—.]?\\s*Information\\s+on\\s+the\\s+Company"), "Item 4 - Information on the Company"),
            (_p("^Information\\s+on\\s+the\\s+Company"), "Information on the Company"), (_p("^Business\\s+Overview"), "Business Overview")],
        "item_4a" => [(_p("^(Item|ITEM)\\s+4A\\.?\\s*[-–—.]?\\s*Unresolved\\s+Staff"), "Item 4A - Unresolved Staff Comments"),
            (_p("^Unresolved\\s+Staff\\s+Comments"), "Unresolved Staff Comments")],
        "item_5" => [(_p("^(Item|ITEM)\\s+5\\.?\\s*[-–—.]?\\s*Operating.*Financial\\s+Review"), "Item 5 - Operating and Financial Review and Prospects"),
            (_p("^Operating.*Financial\\s+Review"), "Operating and Financial Review"), (_p("^Management.*Discussion.*Analysis"), "MD&A")],
        "item_6" => [(_p("^(Item|ITEM)\\s+6\\.?\\s*[-–—.]?\\s*Directors.*Senior\\s+Management.*Employees"), "Item 6 - Directors, Senior Management and Employees"),
            (_p("^Directors.*Senior\\s+Management.*Employees"), "Directors and Employees")],
        "item_7" => [(_p("^(Item|ITEM)\\s+7\\.?\\s*[-–—.]?\\s*Major\\s+Shareholders"), "Item 7 - Major Shareholders and Related Party Transactions"),
            (_p("^Major\\s+Shareholders.*Related\\s+Party"), "Major Shareholders")],
        "item_8" => [(_p("^(Item|ITEM)\\s+8\\.?\\s*[-–—.]?\\s*Financial\\s+Information"), "Item 8 - Financial Information"),
            (_p("^Financial\\s+Information"), "Financial Information")],
        "item_9" => [(_p("^(Item|ITEM)\\s+9\\.?\\s*[-–—.]?\\s*The\\s+Offer\\s+and\\s+Listing"), "Item 9 - The Offer and Listing"),
            (_p("^The\\s+Offer\\s+and\\s+Listing"), "Offer and Listing")],
        "item_10" => [(_p("^(Item|ITEM)\\s+10\\.?\\s*[-–—.]?\\s*Additional\\s+Information"), "Item 10 - Additional Information"),
            (_p("^Additional\\s+Information"), "Additional Information")],
        "item_11" => [(_p("^(Item|ITEM)\\s+11\\.?\\s*[-–—.]?\\s*Quantitative.*Qualitative.*Market\\s+Risk"), "Item 11 - Quantitative and Qualitative Disclosures About Market Risk"),
            (_p("^Quantitative.*Qualitative.*Market\\s+Risk"), "Market Risk Disclosures")],
        "item_12" => [(_p("^(Item|ITEM)\\s+12\\.?\\s*[-–—.]?\\s*Description.*Securities"), "Item 12 - Description of Securities Other Than Equity Securities"),
            (_p("^Description.*Securities.*Equity"), "Securities Description")],
        "item_13" => [(_p("^(Item|ITEM)\\s+13\\.?\\s*[-–—.]?\\s*Defaults"), "Item 13 - Defaults, Dividend Arrearages and Delinquencies"),
            (_p("^Defaults.*Dividend.*Arrearages"), "Defaults and Arrearages")],
        "item_14" => [(_p("^(Item|ITEM)\\s+14\\.?\\s*[-–—.]?\\s*Material\\s+Modifications"), "Item 14 - Material Modifications to the Rights of Security Holders"),
            (_p("^Material\\s+Modifications.*Rights"), "Material Modifications")],
        "item_15" => [(_p("^(Item|ITEM)\\s+15\\.?\\s*[-–—.]?\\s*Controls.*Procedures"), "Item 15 - Controls and Procedures"),
            (_p("^Controls.*Procedures"), "Controls and Procedures")],
        "item_16" => [(_p("^(Item|ITEM)\\s+16\\.?\\s*[-–—.]?\\s*\\[?Reserved\\]?"), "Item 16 - [Reserved]")],
        "item_16a" => [(_p("^(Item|ITEM)\\s+16A\\.?\\s*[-–—.]?\\s*Audit\\s+Committee"), "Item 16A - Audit Committee Financial Expert"),
            (_p("^Audit\\s+Committee\\s+Financial\\s+Expert"), "Audit Committee Expert")],
        "item_16b" => [(_p("^(Item|ITEM)\\s+16B\\.?\\s*[-–—.]?\\s*Code\\s+of\\s+Ethics"), "Item 16B - Code of Ethics"),
            (_p("^Code\\s+of\\s+Ethics"), "Code of Ethics")],
        "item_16c" => [(_p("^(Item|ITEM)\\s+16C\\.?\\s*[-–—.]?\\s*Principal\\s+Accountant"), "Item 16C - Principal Accountant Fees and Services"),
            (_p("^Principal\\s+Accountant\\s+Fees"), "Accountant Fees")],
        "item_16d" => [(_p("^(Item|ITEM)\\s+16D\\.?\\s*[-–—.]?\\s*Exemptions.*Audit\\s+Committees"), "Item 16D - Exemptions from the Listing Standards for Audit Committees"),
            (_p("^Exemptions.*Listing\\s+Standards"), "Audit Committee Exemptions")],
        "item_16e" => [(_p("^(Item|ITEM)\\s+16E\\.?\\s*[-–—.]?\\s*Purchases.*Equity\\s+Securities"), "Item 16E - Purchases of Equity Securities by the Issuer"),
            (_p("^Purchases.*Equity\\s+Securities.*Issuer"), "Equity Purchases")],
        "item_16f" => [(_p("^(Item|ITEM)\\s+16F\\.?\\s*[-–—.]?\\s*Change.*Certifying\\s+Accountant"), "Item 16F - Change in Registrant's Certifying Accountant"),
            (_p("^Change.*Certifying\\s+Accountant"), "Accountant Change")],
        "item_16g" => [(_p("^(Item|ITEM)\\s+16G\\.?\\s*[-–—.]?\\s*Corporate\\s+Governance"), "Item 16G - Corporate Governance"),
            (_p("^Corporate\\s+Governance"), "Corporate Governance")],
        "item_16h" => [(_p("^(Item|ITEM)\\s+16H\\.?\\s*[-–—.]?\\s*Mine\\s+Safety"), "Item 16H - Mine Safety Disclosure"),
            (_p("^Mine\\s+Safety\\s+Disclosure"), "Mine Safety")],
        "item_16i" => [(_p("^(Item|ITEM)\\s+16I\\.?\\s*[-–—.]?\\s*Disclosure.*Foreign\\s+Jurisdictions"), "Item 16I - Disclosure Regarding Foreign Jurisdictions That Prevent Inspections"),
            (_p("^Disclosure.*Foreign\\s+Jurisdictions.*Inspections"), "Foreign Jurisdiction Disclosure"), (_p("^(Item|ITEM)\\s+16I\\.?\\s*\$"), "Item 16I")],
        "item_16j" => [(_p("^(Item|ITEM)\\s+16J\\.?\\s*[-–—.]?\\s*Insider\\s+Trading"), "Item 16J - Insider Trading Policies"),
            (_p("^Insider\\s+Trading\\s+Policies"), "Insider Trading Policies"), (_p("^(Item|ITEM)\\s+16J\\.?\\s*\$"), "Item 16J")],
        "item_16k" => [(_p("^(Item|ITEM)\\s+16K\\.?\\s*[-–—.]?\\s*Cybersecurity"), "Item 16K - Cybersecurity"),
            (_p("^Cybersecurity"), "Cybersecurity"), (_p("^(Item|ITEM)\\s+16K\\.?\\s*\$"), "Item 16K")],
        "item_17" => [(_p("^(Item|ITEM)\\s+17\\.?\\s*[-–—.]?\\s*Financial\\s+Statements"), "Item 17 - Financial Statements")],
        "item_18" => [(_p("^(Item|ITEM)\\s+18\\.?\\s*[-–—.]?\\s*Financial\\s+Statements"), "Item 18 - Financial Statements")],
        "item_19" => [(_p("^(Item|ITEM)\\s+19\\.?\\s*[-–—.]?\\s*Exhibits"), "Item 19 - Exhibits"), (_p("^Exhibits"), "Exhibits")],
        "part_i" => [(_p("^PART\\s+I\\s*\$"), "Part I")],
        "part_ii" => [(_p("^PART\\s+II\\s*\$"), "Part II")],
        "part_iii" => [(_p("^PART\\s+III\\s*\$"), "Part III")],
        "part_iv" => [(_p("^PART\\s+IV\\s*\$"), "Part IV")],
        "part_v" => [(_p("^PART\\s+V\\s*\$"), "Part V")],
        "signatures" => [(_p("^SIGNATURES?\\s*\$"), "Signatures")],
    ],
    "8-K" => [
        "item_101" => [(_p("^(Item|ITEM)\\s+1\\.\\s*01"), "Item 1.01 - Entry into Material Agreement"), (_p("^Entry.*Material.*Agreement"), "Material Agreement")],
        "item_102" => [(_p("^(Item|ITEM)\\s+1\\.\\s*02"), "Item 1.02 - Termination of Material Agreement"), (_p("^Termination.*Material.*Agreement"), "Termination of Agreement")],
        "item_103" => [(_p("^(Item|ITEM)\\s+1\\.\\s*03"), "Item 1.03 - Bankruptcy or Receivership"), (_p("^Bankruptcy.*Receivership"), "Bankruptcy")],
        "item_104" => [(_p("^(Item|ITEM)\\s+1\\.\\s*04"), "Item 1.04 - Mine Safety"), (_p("^Mine\\s+Safety"), "Mine Safety")],
        "item_105" => [(_p("^(Item|ITEM)\\s+1\\.\\s*05"), "Item 1.05 - Material Cybersecurity Incidents"), (_p("^Material\\s+Cybersecurity"), "Cybersecurity Incidents")],
        "item_201" => [(_p("^(Item|ITEM)\\s+2\\.\\s*01"), "Item 2.01 - Completion of Acquisition"), (_p("^Completion.*Acquisition"), "Acquisition")],
        "item_202" => [(_p("^(Item|ITEM)\\s+2\\.\\s*02"), "Item 2.02 - Results of Operations"), (_p("^Results.*Operations"), "Results of Operations")],
        "item_203" => [(_p("^(Item|ITEM)\\s+2\\.\\s*03"), "Item 2.03 - Creation of Direct Financial Obligation"), (_p("^Creation.*Financial\\s+Obligation"), "Financial Obligation")],
        "item_204" => [(_p("^(Item|ITEM)\\s+2\\.\\s*04"), "Item 2.04 - Triggering Events"), (_p("^Triggering\\s+Events"), "Triggering Events")],
        "item_205" => [(_p("^(Item|ITEM)\\s+2\\.\\s*05"), "Item 2.05 - Costs with Exit or Disposal"), (_p("^Costs.*Exit.*Disposal"), "Exit or Disposal Costs")],
        "item_206" => [(_p("^(Item|ITEM)\\s+2\\.\\s*06"), "Item 2.06 - Material Impairments"), (_p("^Material\\s+Impairments"), "Material Impairments")],
        "item_301" => [(_p("^(Item|ITEM)\\s+3\\.\\s*01"), "Item 3.01 - Notice of Delisting"), (_p("^Notice.*Delisting"), "Delisting Notice")],
        "item_302" => [(_p("^(Item|ITEM)\\s+3\\.\\s*02"), "Item 3.02 - Unregistered Sales of Equity"), (_p("^Unregistered\\s+Sales"), "Unregistered Sales")],
        "item_303" => [(_p("^(Item|ITEM)\\s+3\\.\\s*03"), "Item 3.03 - Material Modification to Rights"), (_p("^Material\\s+Modification.*Rights"), "Rights Modification")],
        "item_401" => [(_p("^(Item|ITEM)\\s+4\\.\\s*01"), "Item 4.01 - Changes in Certifying Accountant"), (_p("^Changes.*Accountant"), "Accountant Changes")],
        "item_402" => [(_p("^(Item|ITEM)\\s+4\\.\\s*02"), "Item 4.02 - Non-Reliance on Financial Statements"), (_p("^Non-Reliance.*Financial"), "Non-Reliance")],
        "item_501" => [(_p("^(Item|ITEM)\\s+5\\.\\s*01"), "Item 5.01 - Changes in Control"), (_p("^Changes.*Control"), "Changes in Control")],
        "item_502" => [(_p("^(Item|ITEM)\\s+5\\.\\s*02"), "Item 5.02 - Departure/Election of Directors"), (_p("^Departure.*Directors.*Officers"), "Director/Officer Changes")],
        "item_503" => [(_p("^(Item|ITEM)\\s+5\\.\\s*03"), "Item 5.03 - Amendments to Articles/Bylaws"), (_p("^Amendments.*Articles.*Bylaws"), "Charter Amendments")],
        "item_504" => [(_p("^(Item|ITEM)\\s+5\\.\\s*04"), "Item 5.04 - Temporary Suspension of Trading"), (_p("^Temporary\\s+Suspension"), "Suspension of Trading")],
        "item_505" => [(_p("^(Item|ITEM)\\s+5\\.\\s*05"), "Item 5.05 - Amendment to Code of Ethics"), (_p("^Amendment.*Code.*Ethics"), "Code of Ethics")],
        "item_506" => [(_p("^(Item|ITEM)\\s+5\\.\\s*06"), "Item 5.06 - Change in Shell Company Status"), (_p("^Change.*Shell\\s+Company"), "Shell Company Status")],
        "item_507" => [(_p("^(Item|ITEM)\\s+5\\.\\s*07"), "Item 5.07 - Submission of Matters to Vote"), (_p("^Submission.*Vote"), "Shareholder Vote")],
        "item_508" => [(_p("^(Item|ITEM)\\s+5\\.\\s*08"), "Item 5.08 - Shareholder Nominations"), (_p("^Shareholder\\s+Nominations"), "Shareholder Nominations")],
        "item_601" => [(_p("^(Item|ITEM)\\s+6\\.\\s*01"), "Item 6.01 - ABS Informational Material"), (_p("^ABS\\s+Informational"), "ABS Information")],
        "item_602" => [(_p("^(Item|ITEM)\\s+6\\.\\s*02"), "Item 6.02 - Change of Servicer/Trustee"), (_p("^Change.*Servicer.*Trustee"), "Servicer Change")],
        "item_603" => [(_p("^(Item|ITEM)\\s+6\\.\\s*03"), "Item 6.03 - Change in Credit Enhancement"), (_p("^Change.*Credit\\s+Enhancement"), "Credit Enhancement")],
        "item_604" => [(_p("^(Item|ITEM)\\s+6\\.\\s*04"), "Item 6.04 - Failure to Make Distribution"), (_p("^Failure.*Distribution"), "Distribution Failure")],
        "item_605" => [(_p("^(Item|ITEM)\\s+6\\.\\s*05"), "Item 6.05 - Securities Act Updating"), (_p("^Securities\\s+Act\\s+Updating"), "Securities Act Update")],
        "item_606" => [(_p("^(Item|ITEM)\\s+6\\.\\s*06"), "Item 6.06 - Static Pool"), (_p("^Static\\s+Pool"), "Static Pool")],
        "item_701" => [(_p("^(Item|ITEM)\\s+7\\.\\s*01"), "Item 7.01 - Regulation FD Disclosure"), (_p("^Regulation\\s+FD"), "Regulation FD")],
        "item_801" => [(_p("^(Item|ITEM)\\s+8\\.\\s*01"), "Item 8.01 - Other Events"), (_p("^Other\\s+Events"), "Other Events")],
        "item_901" => [(_p("^(Item|ITEM)\\s+9\\.\\s*01"), "Item 9.01 - Financial Statements and Exhibits"), (_p("^Financial.*Exhibits"), "Financial Statements and Exhibits")],
    ],
    "424B" => [
        "about_this_prospectus" => [(_p("^ABOUT\\s+THIS\\s+PROSPECTUS"), "About This Prospectus")],
        "summary" => [(_p("^(?:THE\\s+)?OFFERING\\s*\$"), "The Offering"), (_p("^SUMMARY\\s*\$"), "Summary"), (_p("^PROSPECTUS\\s+SUMMARY"), "Prospectus Summary")],
        "risk_factors" => [(_p("^RISK\\s+FACTORS\\s*\$"), "Risk Factors")],
        "use_of_proceeds" => [(_p("^USE\\s+OF\\s+PROCEEDS\\s*\$"), "Use of Proceeds")],
        "dilution" => [(_p("^DILUTION\\s*\$"), "Dilution")],
        "capitalization" => [(_p("^CAPITALIZATION\\s*\$"), "Capitalization")],
        "description_of_securities" => [(_p("^DESCRIPTION\\s+OF\\s+(?:CAPITAL\\s+)?STOCK"), "Description of Capital Stock"),
            (_p("^DESCRIPTION\\s+OF\\s+(?:THE\\s+)?SECURITIES"), "Description of Securities"), (_p("^DESCRIPTION\\s+OF\\s+(?:THE\\s+)?NOTES"), "Description of Notes")],
        "description_of_debt_securities" => [(_p("^DESCRIPTION\\s+OF\\s+DEBT\\s+SECURITIES"), "Description of Debt Securities")],
        "description_of_warrants" => [(_p("^DESCRIPTION\\s+OF\\s+WARRANTS"), "Description of Warrants")],
        "selling_stockholders" => [(_p("^SELLING\\s+(?:STOCK|SECURITY)\\s*HOLDERS"), "Selling Stockholders")],
        "underwriting" => [(_p("^UNDERWRITING\\s*\$"), "Underwriting")],
        "plan_of_distribution" => [(_p("^PLAN\\s+OF\\s+DISTRIBUTION"), "Plan of Distribution")],
        "legal_matters" => [(_p("^LEGAL\\s+MATTERS\\s*\$"), "Legal Matters")],
        "experts" => [(_p("^EXPERTS\\s*\$"), "Experts")],
        "tax_considerations" => [(_p("^(?:U\\.?S\\.?\\s+)?(?:FEDERAL\\s+)?(?:INCOME\\s+)?TAX\\s+CONSIDERATIONS"), "Tax Considerations"),
            (_p("^(?:CERTAIN|MATERIAL)\\s+.*TAX\\s+(?:CONSIDERATIONS|CONSEQUENCES)"), "Tax Considerations")],
        "where_you_can_find_more_information" => [(_p("^WHERE\\s+YOU\\s+CAN\\s+FIND\\s+MORE\\s+INFORMATION"), "Where You Can Find More Information")],
        "incorporation_by_reference" => [(_p("^INCORPORATION\\s+(?:OF\\s+CERTAIN\\s+(?:INFORMATION|DOCUMENTS)\\s+)?BY\\s+REFERENCE"), "Incorporation by Reference")],
    ],
)

# SectionExtractor defined in pattern_section_extractor_stub earlier — redefine fully here.
struct SectionExtractor
    form::Union{Nothing,String}
end
SectionExtractor() = SectionExtractor(nothing)
SectionExtractor(form::AbstractString) = SectionExtractor(String(form))

function extract(e::SectionExtractor, document::Document)
    form = nothing
    if e.form !== nothing
        form = e.form
    elseif document.metadata.form !== nothing
        form = document.metadata.form
    elseif document.config !== nothing && document.config.form !== nothing
        form = document.config.form
    end
    pattern_key = form
    (form !== nothing && startswith(form, "424B")) && (pattern_key = "424B")
    (form === nothing || !haskey(_PSE_SECTION_PATTERNS, pattern_key)) && return Sections()
    patterns = _PSE_SECTION_PATTERNS[pattern_key]
    headers = _find_section_headers(e, document)
    part_context = form == "10-Q" ? _detect_10q_parts(e, headers) : nothing
    matched = _match_sections(e, headers, patterns, document, part_context)
    return _create_sections(e, matched, document)
end

function _is_bold(e::SectionExtractor, node)
    (node.style === nothing) && return false
    fw = node.style.font_weight
    fw === nothing && return false
    fw in ("bold", "700") && return true
    iv = tryparse(Int, fw)
    return iv !== nothing && iv >= 700
end

function _looks_like_section_header(text_::AbstractString)
    stripped = strip(text_)
    (isempty(stripped) || length(stripped) > 300) && return false
    return match(r"^\s*(?:Item|ITEM)\s+\d|^\s*SIGNATURE|^\s*PART\s+[IV]|^\s*EXHIBIT|^\s*FINANCIAL\s+STATEMENTS|^\s*FORWARD[\s-]LOOKING|^\s*RISK\s+FACTORS|^\s*(?:TABLE\s+OF\s+CONTENTS|INDEX)"i, stripped) !== nothing
end

function _is_main_section_header(e::SectionExtractor, text_::AbstractString)
    isempty(text_) && return false
    text_ = strip(text_)
    m = match(r"^(ITEM|Item|item)\s+\d+", text_)
    if m !== nothing && m.captures[1] == "ITEM"
        match(r"[\s\n]+-\s*[A-Z]\.", text_) !== nothing && return false
        return true
    end
    match(r"[\s\n]+-\s*[A-Z]\.", text_) !== nothing && return false
    lower = lowercase(text_)
    (occursin("see ", lower) || occursin("in this", lower) || occursin("described in", lower)) && return false
    return true
end

function _is_likely_toc_entry(e::SectionExtractor, node, text_::AbstractString, toc_start::Int, toc_end::Int, html_content::AbstractString)
    (isempty(text_) || toc_start <= 0 || toc_end <= toc_start) && return false
    text_stripped = strip(text_)
    m = match(r"^(Item\s+\d+[A-Z]?\.?)"i, text_stripped)
    text_snippet = m !== nothing ? m.captures[1] : first(text_stripped, 30)
    isempty(text_snippet) && return false
    idx = findfirst(text_snippet, html_content)
    text_pos = idx === nothing ? (i2 = findfirst(lowercase(text_snippet), lowercase(html_content)); i2 === nothing ? -1 : first(i2)) : first(idx)
    if text_pos > 0 && toc_start <= text_pos <= toc_end
        if match(r"^Item\s+\d", text_) !== nothing && match(r"^ITEM\s+\d", text_) === nothing
            return true
        end
        context_end = min(text_pos + 200, ncodeunits(html_content))
        context = _byte_span(html_content, text_pos, context_end)
        match(r">\s*\d{1,3}\s*<", context) !== nothing && return true
    end
    return false
end

function _find_section_headers(e::SectionExtractor, document::Document)
    headers = Tuple{AbstractNode,String,Int}[]
    for node in find_nodes(document.root, n -> n isa HeadingNode)
        t = text(node)
        isempty(t) || push!(headers, (node, t, _get_node_position(e, node, document)))
    end
    for node in find_nodes(document.root, n -> n isa SectionNode)
        fh = find_first(node, n -> n isa HeadingNode)
        if fh !== nothing
            t = text(fh)
            isempty(t) || push!(headers, (node, t, _get_node_position(e, node, document)))
        end
    end
    is_complete_item_header(t) = begin
        m = match(r"^(Item|ITEM)\s+\d+[A-Za-z]?\.?\s*[-–—.]?\s*(.+)?$"i, strip(t))
        m === nothing && return false
        title = m.captures[2]
        title !== nothing && length(strip(title)) > 3
    end
    has_complete = any(h -> is_complete_item_header(h[2]), headers)
    if !has_complete
        for node in find_nodes(document.root, n -> n isa ParagraphNode)
            if _is_bold(e, node)
                t = text(node)
                (!isempty(t) && _looks_like_section_header(t)) && push!(headers, (node, t, _get_node_position(e, node, document)))
            end
        end
    end
    has_item = any(h -> match(r"Item\s+\d"i, h[2]) !== nothing, headers)
    if !has_item
        for table in find_nodes(document.root, n -> n isa TableNode)
            for row in table.rows
                row_text = join((strip(cell_text(c)) for c in row.cells if !isempty(strip(cell_text(c)))), " ")
                if match(r"^\s*Item\s+\d"i, row_text) !== nothing
                    push!(headers, (table, row_text, _get_node_position(e, table, document)))
                    break
                end
            end
        end
    end
    has_item = any(h -> match(r"Item\s+\d"i, h[2]) !== nothing, headers)
    if !has_item
        for node in find_nodes(document.root, n -> n isa ParagraphNode)
            t = text(node)
            if !isempty(t) && length(t) < 500
                if match(r"^\s*Item\s+\d"i, strip(first(t, 100))) !== nothing
                    push!(headers, (node, strip(t), _get_node_position(e, node, document)))
                end
            end
        end
    end
    sort!(headers; by = h -> h[3])
    return headers
end

function _get_node_position(e::SectionExtractor, node, document::Document)
    position = 0
    for n in walk(document.root)
        n === node && return position
        position += 1
    end
    return position
end

function _detect_10q_parts(e::SectionExtractor, headers)
    part_context = Dict{Int,String}()
    current_part = nothing
    for (i, (node, text_, position)) in enumerate(headers)
        ts = strip(text_)
        if match(r"^\s*PART\s+I\b"i, ts) !== nothing
            current_part = "Part I"; part_context[i] = current_part
        elseif match(r"^\s*PART\s+II\b"i, ts) !== nothing
            current_part = "Part II"; part_context[i] = current_part
        elseif current_part !== nothing
            part_context[i] = current_part
        end
    end
    return part_context
end

function _match_sections(e::SectionExtractor, headers, patterns, document::Document, part_context)
    matched_sections = Dict{String,Tuple{AbstractNode,String,Int,Int}}()
    used_headers = Set{Int}()
    toc_start, toc_end = 0, 0
    html_content = document.metadata.original_html
    if html_content !== nothing
        toc_start, toc_end = find_toc_boundaries(html_content)
    end
    for (section_name, section_patterns) in patterns
        candidates = NamedTuple[]
        for (pattern, title) in section_patterns
            for (i, (node, text_, position)) in enumerate(headers)
                i in used_headers && continue
                if part_context !== nothing && startswith(section_name, "part_")
                    expected_part = startswith(section_name, "part_i_") ? "Part I" : "Part II"
                    actual_part = get(part_context, i, nothing)
                    (actual_part !== nothing && actual_part != expected_part) && continue
                end
                if match(pattern, strip(text_)) !== nothing
                    end_position = _find_section_end(e, i, headers, document)
                    final_title = (part_context !== nothing && haskey(part_context, i)) ? "$(part_context[i]) - $title" : title
                    is_main = _is_main_section_header(e, text_)
                    is_toc_entry = (toc_start > 0 && toc_end > 0) ? _is_likely_toc_entry(e, node, text_, toc_start, toc_end, html_content) : false
                    push!(candidates, (index = i, node = node, text = text_, position = position,
                        end_position = end_position, title = final_title, is_main = is_main,
                        is_toc_entry = is_toc_entry, content_size = end_position - position))
                end
            end
        end
        if !isempty(candidates)
            non_toc = [c for c in candidates if !c.is_toc_entry]
            if !isempty(non_toc)
                selection_pool = non_toc
            else
                actual_section = nothing
                if html_content !== nothing && toc_end > 0
                    actual_section = _find_actual_section_after_toc(e, section_name, section_patterns, html_content, toc_end, document)
                end
                if actual_section !== nothing
                    matched_sections[section_name] = actual_section
                    continue
                end
                selection_pool = candidates
            end
            main_headers = [c for c in selection_pool if c.is_main]
            best = !isempty(main_headers) ? argmax_by(main_headers, c -> c.content_size) : argmax_by(selection_pool, c -> c.content_size)
            matched_sections[section_name] = (best.node, best.title, best.position, best.end_position)
            push!(used_headers, best.index)
        end
    end
    return matched_sections
end

argmax_by(v, f) = v[argmax([f(x) for x in v])]

function _find_section_end(e::SectionExtractor, section_index::Int, headers, document::Document)
    if section_index + 1 <= length(headers)
        current_node = headers[section_index][1]
        current_level = current_node isa HeadingNode ? current_node.level : 1
        for i in (section_index + 1):length(headers)
            next_node = headers[i][1]
            next_level = next_node isa HeadingNode ? next_node.level : 1
            next_level <= current_level && return headers[i][3]
        end
    end
    return length(walk(document.root))
end

function _find_actual_section_after_toc(e::SectionExtractor, section_name, section_patterns, html_content, toc_end, document)
    search_region = _byte_span(html_content, toc_end + 1, ncodeunits(html_content))
    sp = Dict("business" => "ITEM[\\s&#;0-9xnbsp]+1\\.", "risk_factors" => "ITEM[\\s&#;0-9xnbsp]+1A\\.",
        "properties" => "ITEM[\\s&#;0-9xnbsp]+2\\.", "legal_proceedings" => "ITEM[\\s&#;0-9xnbsp]+3\\.",
        "mda" => "ITEM[\\s&#;0-9xnbsp]+7\\.", "market_risk" => "ITEM[\\s&#;0-9xnbsp]+7A\\.",
        "financial_statements" => "ITEM[\\s&#;0-9xnbsp]+8\\.", "controls_procedures" => "ITEM[\\s&#;0-9xnbsp]+9A\\.")
    if haskey(sp, section_name)
        search_pattern = Regex(sp[section_name])
    else
        isempty(section_patterns) && return nothing
        return nothing   # generic fallback rarely used; skipped (pattern-string surgery is filing-specific)
    end
    m = match(search_pattern, search_region)
    m === nothing && (m = match(Regex(sp[section_name], "i"), search_region))
    if m !== nothing
        html_position = toc_end + m.offset
        title = isempty(section_patterns) ? section_name : section_patterns[1][2]
        section_text = _extract_section_text_from_html(e, html_content, html_position, section_name)
        if !isempty(section_text) && length(section_text) > 100
            section_node = SectionNode(section_name = section_name)
            set_metadata!(section_node, "html_extracted_text", section_text)
            return (section_node, title, -1, -1)
        end
    end
    return nothing
end

function _extract_section_text_from_html(e::SectionExtractor, html_content, start_pos::Int, section_name)
    search_start = start_pos + 100
    end_patterns = [r"ITEM\s*&#160;\s*\d+[A-Z]?\.?"i, r"ITEM\s+\d+[A-Z]?\.?"i, r"PART\s+[IVX]+"i, r"SIGNATURES?\s*<"i]
    end_pos = ncodeunits(html_content)
    region = _byte_span(html_content, search_start + 1, ncodeunits(html_content))
    for pattern in end_patterns
        m = match(pattern, region)
        if m !== nothing
            candidate_end = search_start + m.offset
            candidate_end < end_pos && (end_pos = candidate_end)
        end
    end
    section_html = _byte_span(html_content, start_pos, end_pos)
    try
        text_ = nodecontent(EzXML.root(EzXML.parsehtml("<div>$section_html</div>")))
        return strip(replace(text_, r"\s+" => " "))
    catch
        return ""
    end
end

function _create_sections(e::SectionExtractor, matched_sections, document::Document)
    sections = Sections()
    for (section_name, (node, title, start_pos, end_pos)) in matched_sections
        html_extracted = get_metadata(node, "html_extracted_text")
        if start_pos == -1 && html_extracted !== nothing
            section_node = node
            add_child!(section_node, TextNode(content = html_extracted))
            detection_method = "html_fallback"; confidence = 0.6
        else
            section_node = SectionNode(section_name = section_name)
            nodes_in_range = AbstractNode[]
            position = 0
            for n in walk(document.root)
                (start_pos <= position < end_pos) && push!(nodes_in_range, n)
                position += 1
            end
            for n in nodes_in_range
                !(n.parent in nodes_in_range) && add_child!(section_node, n)
            end
            detection_method = "pattern"; confidence = 0.7
        end
        part, item = parse_section_name(section_name)
        sections[section_name] = Section(name = section_name, title = title, node = section_node,
            start_offset = start_pos, end_offset = end_pos, confidence = confidence,
            detection_method = detection_method, part = part, item = item)
    end
    return sections
end
