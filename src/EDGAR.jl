module EDGAR

using HTTP
using JSON3
using Base64
using Dates
using Sockets

# Light module shell: shared dependencies, the include list, and the public exports.
# Each concern lives in its own file (see docs/dev/refactor-plan.md). The markers below
# record the Phase-B fault line: 🟢 = jurisdiction-agnostic core, 🔵 = SEC-specific.
include("standardize.jl")        # 🟢 concept standardization mechanism (W4)
include("config.jl")             # 🟢 runtime configuration + SEC User-Agent
include("http.jl")               # 🟢 HTTP + on-disk cache (fetch_url, _get_json)
include("util.jl")               # 🟢 small cross-cutting helpers
include("text.jl")               # 🟢 html_to_text, fuzzy match, extract_section
include("types.jl")              # 🟢 Filing, Fact, Selection, FactRow
include("sec_data.jl")           # 🔵 SEC data.sec.gov APIs + CIK/ticker lookup
include("filing.jl")             # 🔵 fetch / open / save a filing (EDGAR Archives)
include("selection.jl")          # 🟢 picker transport → Selection
include("picker.jl")             # 🟢 browser picker overlay (PICKER_JS)
include("present.jl")            # 🟢 markdown / facts_json exports
include("facts.jl")              # 🟢 facts(::Selection) row table
include("classify.jl")           # 🟢 statement classifier (adapted from edgartools, MIT)
include("extract_xbrl.jl")       # 🟢 standard-agnostic XBRL parsing + native extraction
include("extract_xbrl_sec.jl")   # 🔵 SEC linkbase access: statement_map/label_map/calculations
include("export.jl")             # 🟢 save_selection + DuckDB extension stubs

export Filing, fetch_filing, save_filing, open_filing, download_assets, extract_section,
       Selection, Fact, select_section, select_sections, markdown, facts, facts_json,
       read_facts_json, standardize, set_standardizer, edgartools_mapping, statement_map,
       label_map, calculations, to_duckdb, statement_view, save_selection, archive_filings,
       set_config, set_user_agent, get_user_agent, persist_user_agent, unpersist_user_agent,
       fetch_url, clean_cache, cache_metrics, cache_path_for,
       company_facts, company_concept, xbrl_frames, full_text_search, filings_by_text, filings_by_cik,
       profile, cik

end # module
