# Refactor plan — monolith → modules (WORKING DOC, delete when done)

> **Transient.** This tracks the in-progress split of `src/EDGAR.jl` from a monolith into
> concern-based files (Phase A) and then a jurisdiction abstraction (Phase B). The line numbers
> below are from the **pre-split monolith** and drift as files are carved — they are a guide, not a
> source of truth. Delete this file once the refactor lands. The durable version of the
> common/jurisdiction split lives in the manual (§ Architecture and Portability).

## Status

- [x] **Step 0** — split `extract_xbrl.jl` into common parsers + `extract_xbrl_sec.jl`
  (SEC linkbase access: `_fetch_linkbase`, `statement_map`, `label_map`, `calculations(::Filing)`).
  Tests green; GLEIF/ESEF native extraction unchanged.
- [ ] **Phase A** — carve the rest of the monolith per the map below (mechanical, no behavior change).
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

## File-by-file map (line refs from the pre-split monolith)

| File | Contents | Fate |
|---|---|---|
| `standardize.jl` *(exists)* | `standardize`, `set_standardizer`, `edgartools_mapping`, `_STANDARDIZER`, `_EDGARTOOLS` | 🟢 mechanism (data stays in `src/data/`) |
| `config.jl` *(new)* | `EDGARConfig` 26, `CONFIG` 38, `set_config` 100, `get_cache_dir/ttl/max_*` 115–121, user-agent get/set/persist/unpersist 137–227, `_is_persistent` 229, `_PERSIST_MARKER` 174, `_TEMP_CACHE_DIR`/`_temp_cache_dir` 43–98 | 🟢 |
| `http.jl` *(new)* | cache consts 18–24, `host_allowed` 249, `cache_path_for` 267, `_read/_write_cache` 272–298, `clean_cache` 300, `cache_metrics` 330, `_maybe_prune_persistent`/`_LAST_PRUNE` 235–247, `fetch_url` 351, `_get_json` 483 | 🟢 generic HTTP+cache |
| `util.jl` *(new)* | `_open_in_default_app` 963 | 🟢 (must be common — picker's default opener uses it) |
| `text.jl` *(new)* | `levenshtein` 425, `similarity_ratio` 447, `_str`/`_head` 557–558, `html_to_text` 1065, `clean_text`/`_ENTITIES` 1096–1131, `extract_section` 1133–1311 | 🟢 generic HTML |
| `types.jl` *(new)* | `Filing` 798, `Fact` 1345 (+kw ctor, `show`), `Selection` 1427 (+kw ctor, `show`), `FactRow` 1393, `SelectionTable` 1401, `SELECTION_SCHEMA_VERSION` 1467, `fact_row` 1382, `_tonum` 1470 | 🟢 |
| `filing.jl` *(new)* | `fetch_filing` 879, `_normalize_cik` 459, `_fetch_submissions` 470, `_filing_dir` 811, `_xbrl_instance` 817, `_find_filing` 834, `_cik_dir` 785, `download_assets` 924, `open_filing(::Filing)`/`(::String)` 970–1013, `save_filing` 1086, `_inline_images`/`_IMAGE_MIME` 1020–1054, `show(MIME"text/html")` 1056, `_filing_base_url` 902, `_ASSET_EXT` 908 | 🔵 → `sec.jl` |
| `sec_data.jl` *(new)* | `company_facts` 501, `company_concept` 516, `xbrl_frames` 533, EFTS `_efts_search`/`_entity_name`/`_efts_row` 541–616, `full_text_search`/`filings_by_text` 622–631, `filings_by_cik` 660, `profile` 707, `cik`/`_company_tickers_raw` 725–783 | 🔵 SEC-only |
| `selection.jl` *(new)* | `parse_selection` 1520, `_parse_fact` 1474, `_with_statement` 1496, `_classify_selection` 1504, `_selection_page` 1556, `open_filing(::Selection)` 1568, `_selection_slug` 1715 | 🟢 |
| `picker.jl` *(exists)* | unchanged | 🟢 |
| `present.jl` *(exists)* | `markdown`, `facts_json`, `read_facts_json` | 🟢 |
| `facts.jl` *(new)* | `facts(::AbstractVector{Selection})` 1600, `facts(::Selection)` 1611 | 🟢 |
| `extract_xbrl.jl` *(exists)* | native extractor + linkbase parsers + `facts/facts_json(::Filing)` | 🟢 |
| `extract_xbrl_sec.jl` *(DONE)* | `_fetch_linkbase`, `statement_map`, `label_map`, `calculations(::Filing)` | 🔵 |
| `export.jl` *(new)* | `save_selection` 1744, DuckDB stub methods `to_duckdb`/`statement_view`/`archive_filings` 1641–1712 | 🟢 |

## Acceptance (per step)

1. Test suite green, unchanged — the only acceptance criterion for Phase A (no logic touched).
2. Confirm the scattered `using PrettyTables` / `using CSV` / `using DuckDB` lines are inside
   docstring code-blocks, not real deps; they travel with their function.
3. No 🟢 file should `include`-time-depend on a 🔵 file.
