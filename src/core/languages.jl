# Language registry — the single source of truth for the set of PRESENTATION languages the PDF fact path is
# sensitive to, and which components cover each. This is STEP 1 of unifying the fragmented surface mapped in
# docs/dev/language-support.md: it DECLARES the supported set + per-component coverage in one place and adds a
# coverage/verify check. Nothing consumes it yet — ZERO behaviour change. A later step re-homes each component's
# data here so coverage becomes DERIVED (not declared), and routes the consumers (`:auto` selection, explicit
# `lang=`) through it. Until then a VERIFIER cross-checks the declared coverage against the live tables for the
# two components whose per-language data is introspectable (detection, statement location), so the registry
# cannot silently drift from the code.
#
# AXIS NOTE: this is the PRESENTATION-language axis (the natural language a PDF is written in). The accounting
# FRAMEWORK / GAAP-vocabulary axis (HGB, DCCA, CAS, US-GAAP, …) is separate and lives in the vocab_*.jl files.

# The six language-sensitive components, in the coverage order of docs/dev/language-support.md.
const LANGUAGE_COMPONENTS = (:detect, :tableclass, :stmtloc, :months, :labels, :locale)

const _LANGUAGE_COMPONENT_DESC = Dict(
    :detect     => "prose language detection (_LANG_MARKERS / _detect_lang)",
    :tableclass => "table-class headings (TABLE_CLASSES)",
    :stmtloc    => "statement location (_STMT_LANGS)",
    :months     => "month-name parsing (_IFRS_MONTHS)",
    :labels     => "line-item label -> ifrs-full (ifrs_label_concept)",
    :locale     => "number locale (amount_locale, via jurisdiction)")

"""
    LanguageProfile

One presentation language in the registry. `code` is the BCP 47 primary subtag (`"en"`, `"pt"`, `"zh"`; a
regional variant, if ever needed, is a subtagged code like `"pt-PT"` — never a re-used ISO code such as `br`,
which is Breton). `script` is `:latin` / `:han` / `:hangul` / `:kana` / `:cyrillic`. `markers` holds the
re-homed prose-detection markers (empty ⇒ detected by script, or not detectable). `declared` lists the
components not yet re-homed into the profile. Ask [`components`](@ref) for the full covered set (derived +
declared) — do not read the fields directly.
"""
struct LanguageProfile
    code::String
    name::String
    script::Symbol
    markers::Vector{String}       # RE-HOMED (step 2): prose-detection markers — empty ⇒ by script, or not
    months::Vector{Pair{String,Int}}  # RE-HOMED (step 2): month-name → number (incl. abbreviations)
    jurisdiction::String          # default jurisdiction for the statement path (number locale); "" if none
    stmt_patterns::Dict{Symbol,String}  # RE-HOMED (step 2): primary-statement heading regex body per type
    declared::Set{Symbol}         # components NOT yet re-homed, whose coverage is still declared here
end

# `:detect`/`:months`/`:stmtloc` are DERIVED, not declared: detection needs markers (Latin) or a non-Latin
# script; months needs a non-empty month table; stmtloc needs non-empty statement patterns.
_covers_detect(p::LanguageProfile) = p.script != :latin || !isempty(p.markers)

"""
    components(p::LanguageProfile) -> Set{Symbol}

The [`LANGUAGE_COMPONENTS`](@ref) covering `p`: DERIVED from re-homed data where available (`:detect` from the
profile's markers/script, `:months` from its month table, `:stmtloc` from its statement patterns) UNION the
still-`declared` components not yet re-homed.
"""
function components(p::LanguageProfile)
    s = copy(p.declared)
    _covers_detect(p) && push!(s, :detect)
    isempty(p.months) || push!(s, :months)
    isempty(p.stmt_patterns) || push!(s, :stmtloc)
    return s
end

_lp(code, name, script, markers, months, declared...; jurisdiction = "", stmt_patterns = Dict{Symbol,String}()) =
    LanguageProfile(code, name, script, collect(String, markers), collect(Pair{String,Int}, months),
                    jurisdiction, stmt_patterns, Set{Symbol}(declared))

# The canonical supported set. Detection markers are RE-HOMED here (the single source; `_LANG_MARKERS` in
# narratives.jl is now a view over this). Remaining coverage is the VERIFIED status quo
# (docs/dev/language-support.md, 2026-07-12): detection reaches 16, extraction narrows to statement location (6)
# and labels (5). Order matches the original `_LANG_MARKERS` so `_detect_lang`'s argmax tie-break is unchanged.
# Month names re-homed per language (the union equals the original flat `_IFRS_MONTHS`; shared names like
# "mai"/"marzo"/"agosto" appear in more than one profile with the same value, which the merge collapses).
const _M_EN = ("january"=>1,"february"=>2,"march"=>3,"april"=>4,"may"=>5,"june"=>6,"july"=>7,"august"=>8,"september"=>9,"october"=>10,"november"=>11,"december"=>12)
const _M_DE = ("januar"=>1,"jan"=>1,"februar"=>2,"feb"=>2,"mär"=>3,"märz"=>3,"mar"=>3,"apr"=>4,"mai"=>5,"jun"=>6,"juni"=>6,"jul"=>7,"juli"=>7,"aug"=>8,"sep"=>9,"sept"=>9,"oct"=>10,"okt"=>10,"oktober"=>10,"nov"=>11,"dec"=>12,"dez"=>12,"dezember"=>12)
const _M_PT = ("janeiro"=>1,"fevereiro"=>2,"março"=>3,"marco"=>3,"abril"=>4,"maio"=>5,"junho"=>6,"julho"=>7,"agosto"=>8,"setembro"=>9,"outubro"=>10,"novembro"=>11,"dezembro"=>12)
const _M_FR = ("janvier"=>1,"février"=>2,"fevrier"=>2,"mars"=>3,"avril"=>4,"mai"=>5,"juin"=>6,"juillet"=>7,"août"=>8,"aout"=>8,"septembre"=>9,"octobre"=>10,"novembre"=>11,"décembre"=>12,"decembre"=>12)
const _M_IT = ("gennaio"=>1,"febbraio"=>2,"marzo"=>3,"aprile"=>4,"maggio"=>5,"giugno"=>6,"luglio"=>7,"agosto"=>8,"settembre"=>9,"ottobre"=>10,"novembre"=>11,"dicembre"=>12)
const _M_ES = ("enero"=>1,"febrero"=>2,"marzo"=>3,"abril"=>4,"mayo"=>5,"junio"=>6,"julio"=>7,"agosto"=>8,"septiembre"=>9,"octubre"=>10,"noviembre"=>11,"diciembre"=>12)
# The 6 detect-only Latin languages — full month names (mechanical; no ambiguous 3-letter abbreviations).
const _M_NL = ("januari"=>1,"februari"=>2,"maart"=>3,"april"=>4,"mei"=>5,"juni"=>6,"juli"=>7,"augustus"=>8,"september"=>9,"oktober"=>10,"november"=>11,"december"=>12)
const _M_SV = ("januari"=>1,"februari"=>2,"mars"=>3,"april"=>4,"maj"=>5,"juni"=>6,"juli"=>7,"augusti"=>8,"september"=>9,"oktober"=>10,"november"=>11,"december"=>12)
const _M_DA = ("januar"=>1,"februar"=>2,"marts"=>3,"april"=>4,"maj"=>5,"juni"=>6,"juli"=>7,"august"=>8,"september"=>9,"oktober"=>10,"november"=>11,"december"=>12)
const _M_NO = ("januar"=>1,"februar"=>2,"mars"=>3,"april"=>4,"mai"=>5,"juni"=>6,"juli"=>7,"august"=>8,"september"=>9,"oktober"=>10,"november"=>11,"desember"=>12)
const _M_FI = ("tammikuu"=>1,"helmikuu"=>2,"maaliskuu"=>3,"huhtikuu"=>4,"toukokuu"=>5,"kesäkuu"=>6,"heinäkuu"=>7,"elokuu"=>8,"syyskuu"=>9,"lokakuu"=>10,"marraskuu"=>11,"joulukuu"=>12)
const _M_PL = ("stycznia"=>1,"lutego"=>2,"marca"=>3,"kwietnia"=>4,"maja"=>5,"czerwca"=>6,"lipca"=>7,"sierpnia"=>8,"września"=>9,"października"=>10,"listopada"=>11,"grudnia"=>12)
# The 4 script languages — dates are numeric (2024年12月31日 / 2024년 12월), so the number IS the month name.
const _M_CJK = ("一月"=>1,"二月"=>2,"三月"=>3,"四月"=>4,"五月"=>5,"六月"=>6,"七月"=>7,"八月"=>8,"九月"=>9,"十月"=>10,"十一月"=>11,"十二月"=>12)
const _M_RU = ("января"=>1,"февраля"=>2,"марта"=>3,"апреля"=>4,"мая"=>5,"июня"=>6,"июля"=>7,"августа"=>8,"сентября"=>9,"октября"=>10,"ноября"=>11,"декабря"=>12)

# German consolidated-statement heading shape, moved here from ifrs_pdf.jl so German is a NORMAL profile entry
# (its `stmt_patterns` below are pre-expanded through this). A stem marks the group in one of three shapes:
# PREFIX "Konzern-<stmt>" (Siemens) · SUFFIX "<stmt> des/der … Konzerns" (Volkswagen) · GRUPPE "<stmt>
# <Company>-Gruppe" (BASF). The des/der excludes the segment breakdown "… NACH Konzernbereichen".
_dekonz(stem) = "konzern[-\\s]*(?:$stem)|\\b(?:$stem)\\s+(?:des|der)\\s+[\\w\\s]{0,25}konzerns?\\b|" *
                "\\b(?:$stem)\\s+[\\wäöüÄÖÜ]{1,20}-?gruppe\\b"

# Primary-statement heading regex bodies per type (:is P&L/OCI, :bs balance sheet, :cf cash flow, :eq changes
# in equity) — RE-HOMED (step 2) from `_STMT_LANGS`. English keeps "consolidated" required (bare names echo in
# notes/MD&A); Romance make it optional (the primary-cluster + TOC validation disambiguates); German via _dekonz.
const _SP_EN = Dict(
    :is => "(?:consolidated )?(?:income statements?|statements? of (?:profit or loss|comprehensive income|earnings|income|operations))",
    :bs => "(?:consolidated )?(?:balance sheets?|statements? of financial position)",
    :cf => "(?:consolidated )?(?:cash flow statements?|statements? of cash flows?)",
    :eq => "(?:consolidated )?statements? of changes in equity")
const _SP_PT = Dict(
    :is => "demonstraç(?:ão|ões) d[eo]s? resultados?(?: abrangentes?)?",
    :bs => "balanç(?:o|os) patrimoni(?:al|ais)",
    :cf => "demonstraç(?:ão|ões) d[eo]s? fluxos? de caixa",
    :eq => "demonstraç(?:ão|ões) das mutações do patrim[ôo]nio líquido")
const _SP_FR = Dict(
    :is => "compte(?:s)? de résultat|état(?:s)? (?:consolidé(?:s)? )?du résultat(?: global| net)?|résultat global",
    :bs => "bilan(?:s)? consolidé(?:s)?|état(?:s)? (?:consolidé(?:s)? )?de (?:la )?situation financière",
    :cf => "tableau(?:x)? (?:consolidé(?:s)? )?des? flux de trésorerie|état(?:s)? des flux de trésorerie",
    :eq => "(?:tableau|état)(?:x|s)? (?:de(?:s)? )?variation(?:s)? des capitaux propres")
const _SP_IT = Dict(
    :is => "conto economico(?: complessivo)?",
    :bs => "stato patrimoniale|situazione patrimoniale[-\\s]*finanziaria",
    :cf => "rendiconto finanziario",
    :eq => "prospetto delle variazioni di patrimonio netto|variazioni del patrimonio netto")
const _SP_ES = Dict(
    :is => "cuenta(?:s)? de (?:pérdidas y ganancias|resultados)|estado(?:s)? de resultados|estado(?:s)? del resultado(?: global| integral)?",
    :bs => "estado(?:s)? de situación (?:financiera|patrimonial)|balance(?:s)? de situación",
    :cf => "estado(?:s)? de flujos de efectivo",
    :eq => "estado(?:s)? de cambios en el patrimonio(?: neto)?")
const _SP_DE = Dict(
    :is => _dekonz("gewinn[-\\s]*und[-\\s]*verlustrechnung|gesamtergebnisrechnung"),
    :bs => _dekonz("bilanz"),
    :cf => _dekonz("kapitalflussrechnung"),
    :eq => "entwicklung des konzern[-\\s]*eigenkapitals|" * _dekonz("eigenkapitalveränderungsrechnung|eigenkapitalentwicklung"))
# Nordic statement names (distinctive local-GAAP/IFRS headings, so "koncern"/"koncernens" is not required to
# disambiguate — unlike English). sv from H&M's "Koncernens resultaträkning/balansräkning/kassaflödesanalys/
# förändring i eget kapital"; da from Coop's "Resultatopgørelse/Balance(n)/Pengestrømsopgørelse/
# Egenkapitalopgørelse". :is is the P&L only (the separate comprehensive-income/totalresultat report is left
# out, so its "Årets resultat" line does not duplicate profit).
const _SP_SV = Dict(
    :is => "resultaträkning",
    :bs => "balansräkning",
    :cf => "kassaflödesanalys",
    :eq => "förändring(?:ar)? i eget kapital")
const _SP_DA = Dict(
    :is => "resultatopgørelse",
    :bs => "balancen?\\b",
    :cf => "pengestrømsopgørelse",
    :eq => "egenkapitalopgørelse")
# Dutch (Liander): "Geconsolideerde winst- en verliesrekening / balans / kasstroomoverzicht / Mutatieoverzicht
# … eigen vermogen". `\bbalans\b` so it does not swallow Swedish "balansräkning" in the shared language sniff.
const _SP_NL = Dict(
    :is => "winst[-\\s]*en[-\\s]*verliesrekening",
    :bs => "\\bbalans\\b",
    :cf => "kasstroomoverzicht",
    :eq => "(?:mutatieoverzicht|wijzigingen|mutaties).{0,30}eigen vermogen")
# Polish (KGHM): IFRS-form "sprawozdanie z wyniku / z sytuacji finansowej / z przepływów pieniężnych / ze zmian
# w kapitale własnym", plus the traditional "rachunek zysków i strat" / "bilans" forms other filers use.
const _SP_PL = Dict(
    :is => "sprawozdanie z wyniku|rachunek zysków i strat",
    :bs => "sprawozdanie z sytuacji finansowej|\\bbilans\\b",
    :cf => "sprawozdanie z przepływów pieniężnych|rachunek przepływów pieniężnych",
    :eq => "(?:sprawozdanie ze|zestawienie) zmian w kapitale własnym")
# Finnish (Kesko): "Konsernin tuloslaskelma / Konsernitase / rahavirtalaskelma / oman pääoman muutoksista".
# :is excludes the OCI "laaja tuloslaskelma" via lookbehind; :bs matches the "konsernitase" compound.
const _SP_FI = Dict(
    :is => "(?<!laaja )tuloslaskelma",
    :bs => "(?:konserni)?tase\\b",
    :cf => "rahavirtalaskelma",
    :eq => "oman pääoman muuto")
# Norwegian (NorgesGruppen): "Resultatregnskap / Balanse / Kontantstrømoppstilling / endringer i egenkapital".
const _SP_NO = Dict(
    :is => "resultatregnskap",
    :bs => "\\bbalanse\\b",
    :cf => "kontantstrøm",
    :eq => "endringer i egenkapital")
# Non-Latin statement names (the SAME vocabulary already carried by `TABLE_CLASSES`) so the Generic path can
# LOCATE statements in Japanese/Korean/Russian/Chinese PDFs too — the long tail Generic is for (a filer not in
# EDINET/DART/CNINFO). Optional 連結 (ja) / 연결 (ko) = "consolidated". For ja/ko/ru it is locate + table-class
# only; mapping the line-item labels to `ifrs-full` (K-IFRS / JP-IFRS) or a native vocab (JP-GAAP / RAS) is the
# follow-on, and these are standard names not yet validated against live filings. Chinese (zh) is added too,
# but its role is DETECTION: once `extract_ifrs_pdf` sniffs a Chinese report it delegates to `extract_cas_pdf`
# (Chinese filers report under CAS — `cas:` concepts, not `ifrs-full`).
const _SP_JA = Dict(
    :is => "(?:連結)?(?:損益計算書|包括利益計算書)",
    :bs => "(?:連結)?(?:財政状態計算書|貸借対照表)",
    :cf => "(?:連結)?キャッシュ・?フロー計算書",
    :eq => "(?:連結)?株主資本等変動計算書")
const _SP_KO = Dict(
    :is => "(?:연결)?(?:손익계산서|포괄손익계산서)",
    :bs => "(?:연결)?(?:재무상태표|대차대조표)",
    :cf => "(?:연결)?현금흐름표",
    :eq => "(?:연결)?자본변동표")
const _SP_RU = Dict(
    :is => "отч[её]т о (?:прибыл|совокупном доходе|финансовых результатах)|о прибыли или убытке",
    :bs => "отч[её]т о финансовом положении|бухгалтерский баланс",
    :cf => "отч[её]т о движении денежных средств",
    :eq => "отч[её]т об изменени.{0,15}капитал")
const _SP_ZH = Dict(
    :is => "利润表|损益表|综合收益表",
    :bs => "资产负债表",
    :cf => "现金流量表",
    :eq => "(?:所有者|股东)权益变动表")

const SUPPORTED_LANGS = LanguageProfile[
    _lp("en", "English",    :latin, (" the "," and "," of "," to "," in "," is "," for "," was "," with "," that "," on "," as "," by "," are "), _M_EN, :tableclass, :labels, :locale; jurisdiction = "HK", stmt_patterns = _SP_EN),
    _lp("pt", "Portuguese", :latin, (" de "," que "," não "," do "," da "," os "," uma "," para "," com "," dos "," das "," é ","ção","ções","ão "," e "), _M_PT, :tableclass, :labels, :locale; jurisdiction = "BR", stmt_patterns = _SP_PT),
    _lp("es", "Spanish",    :latin, (" de "," que "," la "," el "," los "," del "," para "," con "," una "," por "," se "," su ","ñ"," y "), _M_ES, :tableclass, :labels, :locale; jurisdiction = "ES", stmt_patterns = _SP_ES),
    _lp("fr", "French",     :latin, (" de "," la "," le "," et "," des "," les "," une "," pour "," est "," du "," à "," qui "," dans "," sur "), _M_FR, :tableclass, :labels, :locale; jurisdiction = "FR", stmt_patterns = _SP_FR),
    _lp("de", "German",     :latin, (" und "," der "," die "," das "," den "," von "," mit "," für "," ist "," im "," ein "," auf ","ß"," zu "), _M_DE, :tableclass, :labels, :locale; jurisdiction = "DE", stmt_patterns = _SP_DE),
    _lp("it", "Italian",    :latin, (" di "," il "," la "," che "," del "," per "," con "," una "," dei "," è "," gli "," nel "," non "," sono "), _M_IT, :tableclass, :labels, :locale; jurisdiction = "IT", stmt_patterns = _SP_IT),
    _lp("nl", "Dutch",      :latin, (" de "," het "," een "," van "," en "," op "," voor "," met "," dat "," die "," zijn "," aan "," niet "," wordt "), _M_NL, :tableclass, :labels, :locale; jurisdiction = "NL", stmt_patterns = _SP_NL),
    _lp("sv", "Swedish",    :latin, (" och "," att "," det "," som "," för "," med "," av "," är "," på "," till "," inte "," ett "," en "), _M_SV, :tableclass, :labels, :locale; jurisdiction = "SE", stmt_patterns = _SP_SV),
    _lp("da", "Danish",     :latin, (" og "," at "," det "," som "," for "," med "," af "," er "," på "," til "," ikke "," en ","æ","ø"), _M_DA, :tableclass, :labels, :locale; jurisdiction = "DK", stmt_patterns = _SP_DA),
    _lp("no", "Norwegian",  :latin, (" og "," å "," det "," som "," for "," med "," av "," er "," på "," til "," ikke "," en "," ikkje ","æ","ø"), _M_NO, :tableclass, :labels, :locale; jurisdiction = "NO", stmt_patterns = _SP_NO),
    _lp("fi", "Finnish",    :latin, (" ja "," on "," ei "," että "," se "," ovat "," oli "," joka "," mutta "," tai "," kuin "," myös "), _M_FI, :tableclass, :labels, :locale; jurisdiction = "FI", stmt_patterns = _SP_FI),
    _lp("pl", "Polish",     :latin, (" i "," w "," na "," się "," że "," do "," nie "," z "," jest "," oraz "," dla "," po "," lub "), _M_PL, :tableclass, :labels, :locale; jurisdiction = "PL", stmt_patterns = _SP_PL),
    _lp("ja", "Japanese",   :kana,     (), _M_CJK, :tableclass, :locale; jurisdiction = "JP", stmt_patterns = _SP_JA),
    _lp("ko", "Korean",     :hangul,   (), _M_CJK, :tableclass, :locale; jurisdiction = "KR", stmt_patterns = _SP_KO),
    _lp("zh", "Chinese",    :han,      (), _M_CJK, :tableclass, :locale; jurisdiction = "CN", stmt_patterns = _SP_ZH),   # detection → extract_ifrs_pdf delegates to extract_cas_pdf
    _lp("ru", "Russian",    :cyrillic, (), _M_RU, :tableclass, :locale; jurisdiction = "RU", stmt_patterns = _SP_RU),
]

# All month-name → number pairs across the registry — the single source for `_IFRS_MONTHS` (see ifrs_pdf.jl).
language_month_pairs() = [pr for p in SUPPORTED_LANGS for pr in p.months]

"""
    supported_languages() -> Vector{String}

The BCP 47 codes of every language in the registry ([`SUPPORTED_LANGS`](@ref)).
"""
supported_languages() = [p.code for p in SUPPORTED_LANGS]

"""
    language_profile(code) -> Union{LanguageProfile,Nothing}

The [`LanguageProfile`](@ref) for `code`, or `nothing` if it is not registered.
"""
language_profile(code) = (i = findfirst(p -> p.code == String(code), SUPPORTED_LANGS);
                          i === nothing ? nothing : SUPPORTED_LANGS[i])

"""
    language_covers(code, component::Symbol) -> Bool

Whether the registered language `code` is covered by `component` (one of [`LANGUAGE_COMPONENTS`](@ref)).
"""
language_covers(code, component::Symbol) = (p = language_profile(code); p !== nothing && component in components(p))

"""
    normalize_language(code) -> String

Lower-case a language `code` and strip any BCP 47 region/script subtag (`"en-US"` → `"en"`, `"pt_BR"` → `"pt"`)
to its primary subtag when that is registered; otherwise return the lower-cased input unchanged.
"""
function normalize_language(code)
    s = lowercase(strip(String(code)))
    isempty(s) && return s
    prim = String(first(split(s, r"[-_]"; limit = 2)))
    prim in supported_languages() ? prim : s
end

"""
    is_supported_language(code) -> Bool

Whether `code` (case-insensitive, region-subtag-insensitive) is a registered presentation language.
"""
is_supported_language(code) = normalize_language(code) in supported_languages()

# Validate a caller-supplied PRESENTATION language against the registry. `:auto`/`nothing`/`""` pass through
# untouched; a code outside the set is WARNED about (never an error — a caller may legitimately tag prose in an
# unsupported language) and returned unchanged, so behaviour is preserved. NOT for XBRL label-language `lang=`
# (facts/breakdown/label_map), which is a different axis (any tag the filer provided).
function _validate_presentation_lang(code; context::AbstractString = "")
    (code === :auto || code === nothing) && return code
    s = strip(String(code))
    (isempty(s) || is_supported_language(s)) && return code
    @warn "language $(repr(String(code))) is not in the supported presentation-language set" *
          (isempty(context) ? "" : " [$context]") *
          ". Supported: " * join(supported_languages(), ", ") *
          ". Add one with register_language! (see docs/dev/language-support.md)."
    return code
end

"""
    register_language!(code, name, script; markers = String[], declared = Symbol[]) -> LanguageProfile

Add (or replace) a language in the registry. This is the defined **"add a language"** entry point: register the
profile with its detection `markers` (re-homed here — the MECHANICAL detect component; empty for a non-Latin
script, which `_detect_lang` recognises by codepoint range), then fill the remaining components' data in their
tables and list them in `declared` until they too are re-homed (statement patterns in `_STMT_LANGS`, months in
`_IFRS_MONTHS`, label branches in `ifrs_label_concept`, headings in `TABLE_CLASSES`, a jurisdiction locale in
`_AMOUNT_LOCALE`). The DOMAIN components (stmtloc/labels/tableclass) are real accounting translation and must be
authored and verified on a live filer. [`language_coverage`](@ref) then shows what a language still lacks.
"""
function register_language!(code, name, script; markers = String[], declared = Symbol[])
    prof = LanguageProfile(String(code), String(name), Symbol(script),
                           collect(String, markers), Set(Symbol.(declared)))
    i = findfirst(p -> p.code == prof.code, SUPPORTED_LANGS)
    i === nothing ? push!(SUPPORTED_LANGS, prof) : (SUPPORTED_LANGS[i] = prof)
    return prof
end

# Cross-check the still-DECLARED coverage against the live tables for the components whose per-language data is
# introspectable but not yet re-homed, so the registry cannot drift from the code unnoticed. Detection is no
# longer here — it is re-homed (derived from `markers`), so `_LANG_MARKERS` IS this registry and cannot drift.
# Returns mismatch strings (empty = OK).
function _verify_language_registry()
    issues = String[]
    stmt = Set(String(l) for (l, _, _) in _STMT_LANGS); push!(stmt, "de")   # _STMT_LANGS + German (via _DE_STEMS)
    reg_stmt = Set(p.code for p in SUPPORTED_LANGS if !isempty(p.stmt_patterns))   # registry-derived stmtloc set
    stmt == reg_stmt ||
        push!(issues, "stmtloc: _STMT_LANGS=$(sort(collect(stmt))) vs registry=$(sort(collect(reg_stmt)))")
    return issues
end

"""
    language_coverage(; io = stdout) -> Vector{LanguageProfile}

Print the live language × component coverage matrix and the per-component funnel, then the result of
[`_verify_language_registry`](@ref) (which cross-checks the declared coverage against the real tables for the
introspectable components). The single, non-drifting answer to "what languages do we support, and how far?"
"""
function language_coverage(; io::IO = stdout)
    comps = collect(LANGUAGE_COMPONENTS)
    println(io, "Supported presentation languages: ", length(SUPPORTED_LANGS),
            "  (components: ", join(string.(comps), ", "), ")")
    println(io, rpad("code", 6), rpad("name", 12), rpad("script", 9), join(rpad.(string.(comps), 11), ""))
    println(io, repeat("-", 6 + 12 + 9 + 11 * length(comps)))
    for p in SUPPORTED_LANGS
        cov = components(p)
        cells = join((rpad(c in cov ? "yes" : "·", 11) for c in comps), "")
        println(io, rpad(p.code, 6), rpad(first(p.name, 11), 12), rpad(String(p.script), 9), cells)
    end
    println(io, repeat("-", 6 + 12 + 9 + 11 * length(comps)))
    println(io, "coverage funnel:")
    for c in comps
        println(io, "  ", rpad(String(c), 11), count(p -> c in components(p), SUPPORTED_LANGS), "/",
                length(SUPPORTED_LANGS), "   ", _LANGUAGE_COMPONENT_DESC[c])
    end
    issues = _verify_language_registry()
    isempty(issues) ? println(io, "registry ✓ consistent with live tables (stmtloc); detect + months re-homed (derived)") :
        (println(io, "DRIFT vs live tables:"); foreach(s -> println(io, "  ! ", s), issues))
    return SUPPORTED_LANGS
end
