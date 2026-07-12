# Language support in EDGAR.jl — status quo (the fragmented surface)

**Purpose.** A factual, verified snapshot of *where* EDGAR.jl is language-sensitive today, and *which languages
each place covers*. It is the baseline for any future unification (a single supported-language set + registry).
It documents the current state only — it is **not** a plan. Counts here were verified against the source on
2026-07-12, not taken from code comments (one of which is wrong — see the note under Prose detection).

## Two orthogonal axes — do not conflate

Language-sensitivity in EDGAR.jl splits along two independent axes:

1. **Presentation language** — the natural language a *PDF report* is written in (English, Portuguese, …).
   Drives statement location, table classification, line-item labels, number locale, month parsing, and prose
   language tagging. This is what this document maps.
2. **Accounting framework / GAAP vocabulary** — HGB, DCCA, CAS, US-GAAP, IFRS, Ind-AS, JP-GAAP, UK-GAAP …
   Drives concept mapping and lives in the per-framework `vocab_*.jl` files. A *different* axis: a German HGB
   `Jahresabschluss` and a German IFRS `Konzernabschluss` share a presentation language (de) but different
   framework vocabularies. Not tabulated here.

The observations below are about **axis 1** (presentation language).

## The map

Each language-sensitive component keeps its **own** table, and they cover **different, inconsistent** subsets:

| Component | Where (`file` → symbol) | Languages covered | Keyed by |
|---|---|---|---|
| Prose language detection | `core/narratives.jl` → `_LANG_MARKERS` + `_detect_lang` | **16**: en pt es fr de it nl sv da no fi pl · ja ko zh ru | marker words (Latin) / script ranges (CJK, Cyrillic) |
| Table-class headings | `extractors/document_profile.jl` → `TABLE_CLASSES` | **16**: en pt es fr de it nl sv da no fi pl · zh ja ko ru | per-class heading regexes |
| Statement location | `extractors/ifrs_pdf.jl` → `_STMT_LANGS` (+ `_DE_STEMS`) | **6**: en pt fr it es de | per-language statement-name patterns |
| Month-name parsing | `extractors/ifrs_pdf.jl` → `_IFRS_MONTHS` / `_MON` | **16** (step 2; was 6) — re-homed to the registry, all languages | month-name → number, per `LanguageProfile` |
| Line-item label → `ifrs-full` | `core/taxonomy/vocab_ifrs_labels.jl` → `ifrs_label_concept` | **6**: en de fr it pt es | pattern branches per statement |
| Number locale (separators) | `extractors/facts_derive.jl` → `_AMOUNT_LOCALE` / `amount_locale` | 3 separator **classes** | by **country** → `:en` / `:eu_dot` / `:eu_space` |

### Consumers (derive the presentation language, then use the tables above)

- `extractors/ifrs_pdf.jl` → `_LANG_SNIFF` / `_ifrs_doc_juris`: sniffs the presentation language from the
  statement headings, returning `(jurisdiction, language)`; covers the `_STMT_LANGS` set (6) and picks the
  number locale via `amount_locale`.
- `extractors/structured_document.jl` → `structured_document(...; language=…)`: a free-form `language` kwarg,
  seeded by the caller (jurisdiction paths pass a fixed code; the generic PDF path passes the sniff result).
- `narratives(...; lang=:auto)`: `:auto` runs `_detect_lang`; an explicit `lang=:xx` bypasses it.

## The observations

1. **A coverage funnel, widening the wrong way.** We can *detect* 16 languages and *classify* statement tables in
   16, but only *locate* primary statements in 6 and *map line-item labels* in 6. A report can be recognised as
   Finnish or Dutch prose, and its tables classified, and still be un-extractable, because statement location and
   label mapping do not reach that far.
2. **No single source of truth.** The supported set is defined implicitly and differently in six places. Adding
   a language means editing each table that should cover it, with nothing enforcing that they agree.
3. **No defined "add a language" process.** There is no registry entry to fill, no completeness check that says
   "language X has detection + months but no statement patterns or labels yet."
4. **Mechanical vs domain data.** The components differ in what adding a language *costs*:
   - *Mechanical* (systematically fillable): detection markers, month names, number-locale class.
   - *Domain* (real accounting translation, must be authored and verified on a live filer per the
     validate-on-new-filers rule): statement-name patterns, line-item label → concept.
   Any "add a language and everything updates" mechanism is therefore only *partly* automatable: a registry can
   declare the set and enforce that each language *provides* its per-component data, but the domain data has to
   be authored, not generated.

## Known inaccuracy to fix (documentation defect, not behavioural)

`core/narratives.jl` — the `_detect_lang` header comment states it recognises "**EIGHTEEN** languages" but the
implementation covers **16** (12 in `_LANG_MARKERS` + 4 by script). The comment should read sixteen. (Left
as-is here; this doc only records the status quo.)

## Unification — step 1 done

The `LanguageProfile` registry now exists: `src/core/languages.jl` (exported: `SUPPORTED_LANGS`,
`supported_languages`, `language_profile`, `language_covers`, `register_language!`, `language_coverage`). It is
the single source of truth for the supported set and declares the per-component coverage matrix above; run
`language_coverage()` to print the live matrix + funnel. Coverage is **declared** for now, with a verifier
(`_verify_language_registry`) that cross-checks the two introspectable components (detection, statement
location) against the real `_LANG_MARKERS` / `_STMT_LANGS` tables so the registry cannot silently drift. It has
**no consumers yet** (zero behaviour change).

**Remaining steps.** (2) Re-home each component's per-language data into the profile so coverage becomes
*derived* not declared (detection markers, statement patterns and month names move cleanly; `TABLE_CLASSES` is
class-keyed and `ifrs_label_concept` is a function, so those need more care). (3) Route the consumers
(`:auto` selection, explicit `lang=`) through the registry, and document the "add a language" process
(`register_language!` is the entry point) in the Manual. See `docs/dev/pdf-extractor-plan.md` for the
surrounding roadmap and the per-jurisdiction PROFILE concept it anticipates.
