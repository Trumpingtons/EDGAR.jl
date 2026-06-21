# Refactor plan — monolith → modules (WORKING DOC, delete when done)

> **Transient.** This tracks the in-progress split of `src/EDGAR.jl` from a monolith into
> concern-based files (Phase A) and then a jurisdiction abstraction (Phase B). The line numbers
> below are from the **pre-split monolith** and drift as files are carved — they are a guide, not a
> source of truth. Delete this file once the refactor lands. The durable version of the
> common/jurisdiction split lives in the manual (§ Architecture and Portability).

## Status

- [x] **Step 0** — split `extract_xbrl.jl` into common parsers + `extract_xbrl_sec.jl`
  (SEC linkbase access: `_fetch_linkbase`, `statement_map`, `label_map`, `calculations(::Filing)`).
- [x] **Phase A** — monolith carved into the files below (mechanical, no behavior change). The
  shell `EDGAR.jl` is now just deps + includes + exports. Verified: line-number partition (every
  body line assigned exactly once — slice total 1737 = 1770 − 33 shell lines), full test suite
  green, GLEIF/ESEF extraction byte-identical, and no SEC code leaks into 🟢 files.
  Deviations from the original map, for contiguity (all within one colour, so harmless):
  `_normalize_cik`/`_fetch_submissions`/`_str`/`_head` → `sec_data.jl` (not `filing.jl`/`text.jl`);
  include order is `…types, sec_data, filing, selection, picker, present, facts, …` so every
  cross-file reference is a call-time body reference, never an include-time one.
- [ ] **Phase B** — introduce `abstract type Jurisdiction`, move 🔵 files behind `SEC <: Jurisdiction`,
  add `ESEF` as the second jurisdiction to validate the seam (and close the `classify_role` IFRS gap).
- [x] **Classifier registry** — `classify.jl`: multi-signal scorer adapted from edgartools (MIT),
  IFRS-aware. Replaced the brittle substring `_classify_role`. Validated 32/33 (BS/IS/CF) across
  mainstream + IFRS 20-F + BDC. (See the durable write-up in the manual, § "Statement classification:
  two orthogonal axes".)
- [ ] **Phase R — port the edgartools resolver cascade** (the ~28 issue-tuned rules). See below.

## Phase R — classification engine + taxonomy vocabularies (planned)

Two **orthogonal axes**: a *jurisdiction* axis (fetch/identity, the `Jurisdiction` adapters) and a
*taxonomy* axis (classification vocabularies, auto-selected by the concept prefixes a filing uses).
Three knowledge layers — engine (common) / taxonomy vocabulary (per-taxonomy, `ifrs-full` shared) /
jurisdiction adapter. Of edgartools' ~28 rules: ~45% common engine logic, ~30% `us-gaap`, ~20%
`ifrs-full` (reused by ESEF/SEDAR+/Companies House/DART/MOPS/EDINET). The 7-function resolver
(`statement_resolver.py` 732–1306, ~575 LoC) → est. ~400–500 Julia LoC; the rules are irreducible.

- [x] **R0 (DONE)** — factored `classify.jl` → `classify_engine.jl` (engine: scorer + `_STATEMENT_ROLES`
  role/concept-patterns + priority/exclusions + `_build_statement_registry` merge) + `vocab_usgaap.jl`
  + `vocab_ifrs.jl` (per-taxonomy concept anchors). The engine merges every vocabulary into
  `STATEMENT_REGISTRY` (union load = behaviour-preserving; prefix-selection is a later refinement).
  Verified: merged registry identical to pre-split; offline suite green; live SAP/ORCL/STT unchanged.
  `classify.jl` removed.
- [x] **R1 (DONE)** — offline fail→correct corpus `test/data/classification_corpus.json` (65 cases,
  8 filers spanning us-gaap mainstream/bank STT/BDC ARCC/FilingSummary MSFT/ProfitLoss PNC + ifrs-full
  SAP/NVS/AZN), each `(filer, accession, taxonomy, jurisdiction, role, concepts, expected)` with
  `concepts` = exactly what `_classify_role` receives. Generator `scripts/build_classification_corpus.jl`
  (live → JSON). Harness testset "classification corpus (offline, Phase R)" asserts the classifier
  over all cases — green baseline. To port a rule (R2): add the offending filing with `expected` =
  correct → red → fix → green.
- **R2** — port the cascade + each `#issue` rule, **one rule = one corpus test**; tag with the issue
  ref + edgartools attribution. Land green at each step (no blind 500-line drop).
- **R3** — integrate: engine picks the best role per statement type → build the concept→statement map;
  keep the query-time combined-statement alias (the one-role-two-types case a single label can't store).
- **R4** — per jurisdiction: a `Jurisdiction` adapter (fetch/identity/linkbase-location) + declare its
  taxonomies. ESEF/SEDAR/MOPS/DART mostly reuse `vocab_ifrs`; Companies House/EDINET add `vocab_uk`/`vocab_jp`.
  No re-port of the engine.

## Target shell — `src/EDGAR.jl`

```julia
module EDGAR
using HTTP, JSON3, Base64, Dates, Sockets   # the only real top-level deps
export ...                                   # unchanged export list
include("standardize.jl")     # 🟢
include("config.jl")          # 🟢
include("http.jl")            # 🟢
include("util.jl")            # 🟢
include("text.jl")            # 🟢
include("types.jl")           # 🟢
include("filing.jl")          # 🔵 → sec.jl
include("sec_data.jl")        # 🔵
include("selection.jl")       # 🟢
include("picker.jl")          # 🟢
include("present.jl")         # 🟢
include("facts.jl")           # 🟢
include("extract_xbrl.jl")    # 🟢 parsers + native extraction
include("extract_xbrl_sec.jl")# 🔵 SEC linkbase access  (DONE)
include("export.jl")          # 🟢
end
```

Order rule: types/consts used in *signatures* or *const initializers* must be included before use;
method *bodies* may forward-reference (resolved at call time).

## What landed

All files, in include order (the 37-line `EDGAR.jl` shell is just deps + includes + exports).

| File | Role | | |
|---|---|---|---|
| `standardize.jl` | concept standardization mechanism (data in `src/data/`) | 🟢 | pre-existing |
| `config.jl` | runtime config + SEC User-Agent | 🟢 | new |
| `http.jl` | HTTP client + on-disk cache, `fetch_url`/`_get_json` | 🟢 | new |
| `util.jl` | OS opener helper | 🟢 | new |
| `text.jl` | fuzzy match, `html_to_text`/`clean_text`, `extract_section` | 🟢 | new |
| `types.jl` | `Filing`, `Fact`, `Selection`, row schemas | 🟢 | new |
| `sec_data.jl` | `data.sec.gov`/EFTS APIs, CIK/ticker lookup | 🔵 | new |
| `filing.jl` | fetch/open/save from EDGAR Archives | 🔵 | new |
| `selection.jl` | picker transport → `Selection` | 🟢 | new |
| `picker.jl` | browser picker overlay (`PICKER_JS`) | 🟢 | pre-existing |
| `present.jl` | `markdown` / `facts_json` exports | 🟢 | pre-existing |
| `facts.jl` | `facts(::Selection)` row table | 🟢 | new |
| `extract_xbrl.jl` | native XBRL parsing + extraction + linkbase parsers | 🟢 | pre-existing |
| `extract_xbrl_sec.jl` | SEC linkbase access (`statement_map`/`label_map`/`calculations`) | 🔵 | pre-existing |
| `export.jl` | `save_selection` + DuckDB extension stubs | 🟢 | new |

## Acceptance (per step)

1. Test suite green, unchanged — the only acceptance criterion for Phase A (no logic touched).
2. Confirm the scattered `using PrettyTables` / `using CSV` / `using DuckDB` lines are inside
   docstring code-blocks, not real deps; they travel with their function.
3. No 🟢 file should `include`-time-depend on a 🔵 file.
