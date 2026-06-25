# Multi–FilingSystem design (DESIGN SPEC, persistent)

> The durable design contract for extending EDGAR.jl beyond US SEC EDGAR to other electronic
> financial-reporting systems (ESEF, EDINET, Companies House, DART, …). This is the spec that
> **Phase B** of [refactor-plan.md](refactor-plan.md) implements. It supersedes the loose
> "jurisdiction" wording used in the refactor plan and the manual's *Architecture and Portability*
> section: the correct unit is a **FilingSystem**, not a country (see D9).
>
> Status legend: ✅ exists · 🅱 Phase-B work · 🔭 horizon (informs naming only, no code yet).

## 0. Governing principle — generalize the nouns, not the verbs

**Generalize the data model** (types, public signatures, persisted schema) **now**; **implement
behavior** (discovery/fetch adapters) **one FilingSystem at a time**.

- *Nouns* are baked into the `Filing` struct, the DuckDB schema, every signature, and any saved
  artifact — expensive to change once several systems and stored data depend on them.
- *Verbs* live behind a single adapter method each and touch nothing else — cheap to add or change.

The test for "is this a noun?": **would adding a new FilingSystem later force rewriting existing code
or migrating stored data?** If yes, generalize now. If adding it is just "write `edinet.jl`
implementing the adapter methods," it is a verb — leave it until then.

The opposite failure (over-generalizing) is just as real: building EDINET/UK/DART machinery before
those systems exist is a flexibility tax that makes the start painful. We generalize against the
**five well-understood driver systems** below — not against every regime on earth.

## 1. The unit of adaptation: `FilingSystem` (not a country)

```julia
abstract type FilingSystem end
struct EDGAR <: FilingSystem end   # US SEC. (Type named `SEC` in code today to avoid clashing with
                                   # `module EDGAR`; rename to `EDGAR` if/when the package is renamed.)
struct ESEF  <: FilingSystem end   # EU (per-country OAMs; aggregated by filings.xbrl.org)
# later: EDINET, CompaniesHouse, DART, UKSEF, MOPS, HKIRD, …
```

A **country hosts many filing systems** (D9). The reference data source agrees: filings.xbrl.org
indexes by *programme* + *country*, and the UK alone has two (Companies House + UKSEF). So country is
an **attribute** of a FilingSystem, never the key.

### Capability decomposition (D10)

A FilingSystem implements a **subset** of three responsibilities:

| | discover | fetch | parse |
|---|---|---|---|
| EDGAR, ESEF, EDINET, Companies House, DART | ✓ | ✓ | ✓ (common) |
| HK IRD (private tax filings), China SOE (internal) | — | — | ✓ (common) |

- **parse is always the common core** (format + taxonomy) — it already works on any iXBRL/XBRL
  ([extract_xbrl.jl](../../src/extract_xbrl.jl), GLEIF-validated).
- A capability a system lacks is simply **a method it does not define** — Julia dispatch expresses
  this with zero extra machinery (calling `discover(::HKIRD, …)` is a clean MethodError, not a flag
  check). No trait system.
- **Public-repository** systems (retrievable third-party filings) vs **private-submission** systems
  (HK IRD profits-tax filings are confidential; China SOE is internal; India MCA21 is paid). For
  submission-only systems we can still parse a *locally supplied* iXBRL file; discover/fetch are N/A.

## 2. Reference set (tiered)

The design must satisfy the **drivers**; the **watch** systems are kept in mind so we don't
accidentally design them out, but no code is written for them now.

**Drivers — full (discover+fetch+parse) adapters (5):**

| System | Identity | Filing ref | Access | Container | Taxonomy / script |
|---|---|---|---|---|---|
| **EDGAR** ✅ | CIK | accession | `data.sec.gov`+EFTS, **User-Agent**, no key | loose files | us-gaap/dei/srt · Latin |
| **ESEF** 🅱 | LEI | filing id / pkg URL | filings.xbrl.org (no key); OAMs | **report-package ZIP** | ifrs-full+esef_cor+ext · multilingual |
| **EDINET** 🔭 | EDINET code / 法人番号 / ticker | docID `S100…` | API v2, **subscription key**, 3–5 s rate | **ZIP** | jpcrp/jppfs/jpdei; IFRS · **JP** |
| **Companies House** 🔭 | company number | transaction id | API, **free key**, 600/5 min | **single iXBRL file** | FRC FRS 101/102, UK-IFRS · Latin |
| **DART** 🔭 | corp_code / stock code | rcept_no | OpenDART, **free key**, 10k/day; **+ structured stmt API** | ZIP | K-IFRS · **KR** |

These five exercise *every* forcing characteristic D1–D10 between them: multi-scheme identity, three
access models (UA / key / none), all four container shapes, bundled-vs-absent-vs-standard-only
linkbases, the structured-data capability (EDGAR + DART), non-Latin labels (JP + KR), and four
taxonomy families. Clear these five and the rest follow by construction.

**Watch / boundary (parse-only or quirky access) — note, don't build:**

- **HK IRD** 🔭 — parse-only · private · tax purpose · IRD-FS taxonomy (HKFRS / HKFRS-PE) · identity = BRN.
  Proves the architecture handles a system we cannot fetch from. Costs nothing (parser already eats it).
- **Taiwan MOPS** 🔭 — official but non-REST endpoint (`emops.twse.com.tw`); TIFRS · ZH-Hant.
- **India MCA21** 🔭 — paid + per-country multi-channel (MCA21 / BSE / NSE); Ind-AS · Latin.

**Horizon (informs D9 naming only):**

- **China ×3** 🔭 — CSRC (listed) / MOF+SASAC (SOE) / AMAC (funds): the strongest multi-system-per-country
  example, but lowest XBRL-retrieval maturity (CNINFO/exchange portals, no clean API) and a large
  standalone CAS national-GAAP vocabulary. Drives no type decision today.

**Deliberately excluded:** Canada SEDAR+ (Canada doesn't broadly mandate XBRL — a *document* system,
near-useless for XBRL extraction), Singapore ACRA, South Africa CIPC (marginal volume / limited access).

## 3. Forcing characteristics (D1–D10)

1. **D1 — Identity is a `(scheme, value)` pair, never a bare string.** ≥8 schemes (CIK, LEI, EDINET
   code, 法人番号, company number, corp_code, stock code, CIN, BRN); entities often carry several.
2. **D2 — A filing reference is an opaque, system-defined token** (accession / filing id / docID /
   transaction id / rcept_no). The portable currency is a *resolvable handle*, not a tuple the core
   understands.
3. **D3 — Access policy varies per system:** User-Agent (EDGAR) vs API key (EDINET, CH, DART) vs
   none (filings.xbrl.org) vs scraping (MOPS/CN).
4. **D4 — Container varies:** loose files / report-package ZIP / single iXBRL file / API-delivered.
5. **D5 — Linkbases may be bundled (ESEF/EDINET), absent (Companies House — no extension taxonomy;
   classify against the *standard* taxonomy), or replaced by a fallback (EDGAR FilingSummary).**
6. **D6 — Structured financial-data APIs are an optional capability** (EDGAR companyfacts/frames,
   DART statement API), not universal. Keep as plain per-system methods until a 2nd instance justifies
   a trait.
7. **D7 — Non-Latin scripts + multi-language labels** (JP/KR/TW/CN); the label linkbase carries
   `xml:lang`. Label parsing must take a language preference.
8. **D8 — One system hosts multiple taxonomies; one taxonomy spans systems** (ifrs-full ⊂ ESEF, DART,
   MOPS, …; EDINET and UK each mix national-GAAP + IFRS). → vocab/standardization keyed by **taxonomy
   prefix**, never by system.
9. **D9 — The unit of adaptation is a FilingSystem, not a country.** One country → many systems.
10. **D10 — A FilingSystem implements a subset of {discover, fetch, parse};** parse is common;
    public-repository vs private-submission.

## 4. The six "generalize-now" nouns

1. **N1 — Typed identity.** `EntityId(scheme::Symbol, value::String)` (`:cik`, `:lei`, `:edinet`,
   `:companies_house`, `:corp_code`, `:brn`, …). Replaces the bare `cik::String`. *Open-ended scheme
   set — adding `:brn` is data, not a code change.*
2. **N2 — Fetchable handle.** Discovery yields a handle carrying everything fetch needs (system +
   identity + ref + source URL); `fetch_filing(handle)` is the one canonical path. Per-system
   conveniences (`fetch_filing(cik, accession)`, `fetch_filing(::ESEF, lei; period)`) construct a
   handle. Existing `fetch_filing(cik, accession)` stays as the EDGAR default — **no current call
   changes.**
3. **N3 — Per-system credentials/policy registry** in [config.jl](../../src/config.jl):
   `set_credentials(::FilingSystem; …)`. `set_user_agent` becomes EDGAR sugar over it.
4. **N4 — `fetch_linkbase` may delegate.** Its contract allows "not in the filing — use the standard
   taxonomy for prefix X" (Companies House). A documented return contract; costs nothing now.
5. **N5 — Language-aware labels.** `label_map(f; lang="en")` and a `lang`-aware `_concept_labels`
   (touches a 🟢 parser — get the signature right early).
6. **N6 — Taxonomy-prefix-keyed vocab & standardization.** Already the design ([vocab_ifrs.jl](../../src/vocab_ifrs.jl),
   [standardize.jl](../../src/standardize.jl) ships no default, data is taxonomy-keyed). Add IFRS
   standardization data alongside the us-gaap map; hold the line that vocab is never system-keyed.

### `Filing` struct change

Carry the FilingSystem + typed identity + opaque ref (drop the earlier "overload `cik`" idea — D1
kills it):

```julia
struct Filing
    system::FilingSystem      # EDGAR(), ESEF(), …
    entity::EntityId          # EntityId(:cik,"0000320193") | EntityId(:lei,"…")
    ref::String               # opaque filing reference (accession / docID / …)
    document::String
    url::String
    kind::Symbol              # :ixbrl | :xbrl | :html
    content::String
end
```

## 5. Two orthogonal axes + a third (source)

- **FilingSystem axis** — discover / fetch / identity / linkbase-location. Per system.
- **Taxonomy axis** — classification vocab + standardization data, auto-selected from concept
  prefixes. Per taxonomy, often shared (ifrs-full everywhere). *Union-merge of vocabularies stays
  valid because prefixes don't collide; prefix auto-selection is a later refinement, required only
  once a system mixes taxonomies (EDINET/UK), not for ESEF.*
- **Discovery-source axis (≠ FilingSystem).** One source can feed many systems: **filings.xbrl.org**
  covers ESEF + UKSEF + others. So the index abstraction is a `FilingSource` yielding
  **system-tagged handles**, not an `ESEFIndex`. EDINET-API / OpenDART / CH-API / national OAMs are
  other sources. National-OAM pluggability (per the original ESEF decision) lives here.

*Optional fast-paths:* EDINET CSV (`type=5`), filings.xbrl.org **xBRL-JSON**, DART statement API all
return pre-parsed facts — a per-system optimization over the iXBRL regex extractor. A verb; defer.

## 6. What NOT to build now

Any adapter beyond EDGAR (exists) + ESEF (Phase B); the D6 structured-data-API *trait* (one-member
set today); `catalog.xml` full URI resolution (suffix-match linkbases suffices for facts +
classification); scraping infrastructure (MOPS/CN); multi-identifier entity resolution; the validation
story beyond what each source publishes (ESEF has no companyfacts analog — surface filings.xbrl.org's
published validation + reuse `calculations()`; document the reduced guarantee honestly).

## 7. Mapping to phases

- **B0** — directory reorg (`core/` + `filing_systems/<system>/`, see refactor-plan) + introduce
  `FilingSystem` and the N1–N6 nouns, with `EDGAR` as the sole implementation. **No behavior change**;
  full suite green, byte-identical EDGAR behavior.
- **B1** — offline ESEF: `report_package.jl` (in-memory ZIP) + ESEF `fetch_linkbase` (bundled), driven
  by a checked-in GLEIF fixture. Assert facts + IFRS classification with no network.
- **B2** — ESEF discovery: a `FilingSource` for filings.xbrl.org (system-tagged handles, OAM-pluggable).
- **B3** — docs (manual *Architecture* update), CHANGELOG, retire the relevant refactor-plan lines.

See also: [refactor-plan.md](refactor-plan.md) (Phase B / R4), [R2-rules.md](R2-rules.md) (taxonomy
classifier), and the manual's *Architecture and Portability* + *two orthogonal axes* sections.
