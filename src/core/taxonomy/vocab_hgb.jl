# HGB (German Commercial Code / Handelsgesetzbuch) classification vocabulary — the German-GAAP, LABEL-driven
# analogue of vocab_cas (China). A single-entity German *Jahresabschluss* is PDF-native and its Bilanz / GuV
# lines carry German-GAAP labels, not namespaced concepts, so classification keys on the label text. This table
# maps the standard §266 (Bilanz) and §275 (GuV, Gesamtkostenverfahren) line labels to a canonical concept +
# statement + period type; the HGB PDF extractor (`extract_hgb_pdf`) looks each clustered row label up here.
# Concepts are namespaced `hgb:` so they are self-identifying in the `concept` column while the label stays
# German. HGB is single-entity German-GAAP, so the concepts are HGB's own (Anlagevermögen, Sonderposten …), not
# ifrs-full. See docs/dev/germany-plan.md (G2).

const _HGBConcept = @NamedTuple{concept::String, statement::String, instant::Bool}

# Normalise an HGB label for lookup: lower-case, drop footnote marks, collapse whitespace, and STRIP the leading
# §266/§275 enumerator ("A.", "I.", "1.", "a)") German statements prefix every line with, so "A. Anlagevermögen"
# and "1. Steuerrückstellungen" collapse onto the bare key.
function _hgb_norm(s::AbstractString)
    t = lowercase(strip(String(s)))
    t = replace(t, r"[*†‡]" => "")
    t = replace(t, r"^\s*(?:[a-z]|[ivx]{1,4}|\d{1,2})[.)]\s+" => "")   # "A. " "III. " "1. " "a) "
    return strip(replace(t, r"\s+" => " "))
end

# The anchor table. Keys are normalised German labels; several presentation variants map to one concept
# ("summe anlagevermögen" / "anlagevermögen"). A `hgb_concept` lookup tries the section-header/total labels
# used on the Bilanz (whose subtotals sit in a dedicated column) and the GuV headline lines.
const HGB_CONCEPTS = Dict{String,_HGBConcept}(
    # ── Bilanz — Aktiva (§266 Abs. 2), instant ────────────────────────────────────────────────────
    "anlagevermögen"                        => (concept="hgb:Anlagevermögen",           statement="BalanceSheet", instant=true),
    "summe anlagevermögen"                  => (concept="hgb:Anlagevermögen",           statement="BalanceSheet", instant=true),
    "umlaufvermögen"                        => (concept="hgb:Umlaufvermögen",           statement="BalanceSheet", instant=true),
    "summe umlaufvermögen"                  => (concept="hgb:Umlaufvermögen",           statement="BalanceSheet", instant=true),
    # ── Bilanz — Passiva (§266 Abs. 3), instant ───────────────────────────────────────────────────
    "eigenkapital"                          => (concept="hgb:Eigenkapital",             statement="BalanceSheet", instant=true),
    "gezeichnetes kapital"                  => (concept="hgb:GezeichnetesKapital",      statement="BalanceSheet", instant=true),
    "sonderposten für investitionszuwendungen" => (concept="hgb:Sonderposten",         statement="BalanceSheet", instant=true),
    "sonderposten"                          => (concept="hgb:Sonderposten",             statement="BalanceSheet", instant=true),
    "rückstellungen"                        => (concept="hgb:Rückstellungen",           statement="BalanceSheet", instant=true),
    "verbindlichkeiten"                     => (concept="hgb:Verbindlichkeiten",        statement="BalanceSheet", instant=true),
    # the two-sided total (Bilanzsumme) — usually an UNLABELED foot row (handled structurally), but map the
    # explicit label when a filer prints one.
    "bilanzsumme"                           => (concept="hgb:Bilanzsumme",              statement="BalanceSheet", instant=true),
    "summe aktiva"                          => (concept="hgb:Bilanzsumme",              statement="BalanceSheet", instant=true),
    "summe passiva"                         => (concept="hgb:Bilanzsumme",              statement="BalanceSheet", instant=true),
    # ── GuV (§275 Abs. 2, Gesamtkostenverfahren), duration ────────────────────────────────────────
    "umsatzerlöse"                          => (concept="hgb:Umsatzerlöse",             statement="IncomeStatement", instant=false),
    "materialaufwand"                       => (concept="hgb:Materialaufwand",          statement="IncomeStatement", instant=false),
    "personalaufwand"                       => (concept="hgb:Personalaufwand",          statement="IncomeStatement", instant=false),
    "ergebnis nach steuern"                 => (concept="hgb:ErgebnisNachSteuern",      statement="IncomeStatement", instant=false),
    "jahresüberschuss"                      => (concept="hgb:Jahresüberschuss",         statement="IncomeStatement", instant=false),
    "jahresfehlbetrag"                      => (concept="hgb:Jahresüberschuss",         statement="IncomeStatement", instant=false),
    "jahresüberschuss/jahresfehlbetrag"     => (concept="hgb:Jahresüberschuss",         statement="IncomeStatement", instant=false),
)

"""
    hgb_concept(label) -> Union{Nothing, NamedTuple{(:concept,:statement,:instant)}}

Classify a German HGB *Jahresabschluss* line `label` (as clustered from a PDF row) to its `hgb:` concept,
primary statement and period type (`instant` for the Bilanz, duration for the GuV), or `nothing` when the
label is not a recognised anchor. Leading §266/§275 enumerators are stripped before lookup. See
[`extract_hgb_pdf`](@ref) and `docs/dev/germany-plan.md` (G2).
"""
hgb_concept(label::AbstractString) = get(HGB_CONCEPTS, _hgb_norm(label), nothing)
