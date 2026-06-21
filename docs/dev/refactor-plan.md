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
