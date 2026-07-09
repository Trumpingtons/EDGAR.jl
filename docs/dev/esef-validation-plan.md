# ESEF jurisdiction validation — France, Italy, Spain, Netherlands (+ Sweden) — living plan

Status: **PLANNING** (2026-07-09). Follows the completed Germany arc. Unlike Germany (PDF route, not
retrievable), these are **retrievable ESEF** jurisdictions — packages live on filings.xbrl.org, so extraction
is the *standard XBRL path* on `ifrs-full`, already exercised for the two Finnish panel names (Citycon, Nokia).
The manual already carries chapters for each (`\section{France|Italy|Spain|Netherlands|Sweden}`). **This is a
validation effort, not new extraction code** — confirm the path works on real FR/IT/ES/NL filers, surface and
fix any concept/metric gaps, extend the oracle panel, and sync the manual.

## The headline: it should already work
An ESEF filing is inline-XBRL tagged with `ifrs-full` concepts, language-agnostic — so the format
particularities the manual documents (account-form for IT/ES, decimal-comma, local language) matter for the
*PDF* route, not here: `facts(f; classify=true)` reads the tagged concepts directly. The likely work is small:
a few concept-candidate additions in the metric picker, and Morningstar-standardisation deltas to document
(as with Germany), not a new pipeline.

## Two oracles per filer (both already built)
- **Arelle** (`arelle_esef_oracle.jl`) — same-document, fact-level, exact: recomputes from the bundled linkbase.
- **Yahoo/Morningstar** (`yahoo_oracle.jl`, `:esef`, ~1% tol) — independent pipeline; the Morningstar
  standardisation notes (Validation chapter §Morningstar) explain any sub-line deltas.

## Candidate filers (confirm in E0 — pick FRESH names, per `validate-on-new-filers`)
Non-bank, non-insurer (clean Revenue/NetIncome), and **not** USD-reporting / ADR-first (Yahoo would serve USD):

| Country | Yahoo suffix | Candidates (ticker) |
|---|---|---|
| France | `.PA` (Euronext Paris) | L'Oréal (OR.PA), Air Liquide (AI.PA), LVMH (MC.PA) |
| Italy | `.MI` (Borsa Italiana) | Moncler (MONC.MI), Recordati (REC.MI), Ferrari (RACE.MI) |
| Spain | `.MC` (BME Madrid) | Inditex (ITX.MC), Iberdrola (IBE.MC) |
| Netherlands | `.AS` (Euronext Amsterdam) | Heineken (HEIA.AS), Ahold Delhaize (AD.AS), Wolters Kluwer (WKL.AS) |
| Sweden | `.ST` (Nasdaq Stockholm) | H&M (HM-B.ST), Atlas Copco (ATCO-A.ST) |

LEIs are not hard-coded here — resolve each in E0 (filings.xbrl.org entity search / GLEIF), since discovery is
`discover(FilingsXBRLOrg(); lei=…)`.

## Phases

- **E0 — Recon + filer selection.** Per country pick 2 clean IFRS filers; resolve the LEI; confirm
  filings.xbrl.org returns packages (recon counts: FR 1168 / IT 872 / ES 542 / NL 655 / SE 1415) and note
  whether an `-en.zip` exists. Fix the Yahoo suffix. **Gate:** each filer has (LEI, ≥1 ESEF package, Yahoo
  ticker) and is non-bank / EUR-or-SEK-reporting.
- **E1 — Discover + fetch.** `discover(FilingsXBRLOrg(); lei)` → prefer `-en.zip` → `fetch_filing`; confirm the
  bundled presentation/calculation/label linkbases resolve from the ZIP (offline). **Gate:** package reads,
  `calculations(f)` non-empty.
- **E2 — Extract + classify + cross-foot.** `facts(f; classify=true)` → primary statements on `ifrs-full`.
  **Gate:** balance sheet cross-foots (Assets = Equity + Liabilities) and the five headline lines
  (Assets, Equity, Revenue, NetIncome, OperCF) are present for each filer.
- **E3 — Dual oracle cross-check.** Arelle (exact, same-doc) + Yahoo/Morningstar (independent, ~1%). Record
  every delta and classify: match / documented Morningstar standardisation / real gap. **Gate:** Arelle
  agrees to the cent; Yahoo agrees within 1% on the unambiguous totals, with any residual attributable to a
  Morningstar rule (Appendix `ch:morningstar-fields`).
- **E4 — Fix gaps + panel + manual.** Fix any real gaps (metric concept candidates, classification). Add the
  validated filers to the oracle panel (an `EU_FIRMS` list or extend `FIRMS`). Sync each jurisdiction's manual
  chapter: mark validated, add the Yahoo suffix, and a short reconciliation note where a systematic delta
  appears. **Gate:** `report(EU_FIRMS)` = 0 unexplained mismatches; manual chapters updated; changes committed.
- **E5 (optional) — Sweden + breadth.** Add Sweden and a second/third filer per country to harden, and note
  any local-language-only package (concepts are tagged, so language is a non-issue — a good robustness check).

## Deliverables
- Validated FR/IT/ES/NL(/SE) filers in the oracle panel (dual-oracle green).
- A per-jurisdiction validation table (mirroring the German G4 table) in each manual chapter or a shared one.
- Any concept-mapping / metric fixes, committed; manual chapters synced.

## Risks / notes
- **Should be low-effort** (standard XBRL path). If a candidate turns out to file only local-GAAP or has an
  exotic tagging, swap it (validate-on-new-filers).
- **USD trap:** some EU multinationals report in USD or are ADR-first (Yahoo serves USD) — avoid (the Infosys
  lesson). Prefer domestic-currency reporters.
- **Morningstar deltas expected** (deferred-tax gross-up, revenue standardisation, hybrid capital) — document,
  don't chase (Validation chapter §Morningstar).
- Utilities/energy (Iberdrola, Air Liquide) sit on a different Morningstar *industry template* — fine for
  `ifrs-full` totals, but a good template-coverage check.

## Hard rules honored
- **HTTP = "1.10", never 2** — `[[never-http-v2-reseau]]`.
- **Validate on NEW filers each run** — `[[validate-on-new-filers]]`.
- **Ask before running tests; commit only when told; be decisive** — `[[edgar-jl-working-style]]`.
- **Never recompile the manual unless told** — `[[no-latex-recompile]]`.
