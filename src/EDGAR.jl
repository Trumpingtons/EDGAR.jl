module EDGAR

using HTTP
using JSON3
using Base64
using Dates
using Sockets
import EzXML   # qualified-only; used by forty_f.jl / subsidiaries.jl / sections.jl HTML text extraction

# Light module shell: shared dependencies, the include list, and the public exports.
# Each concern lives in its own file (see docs/dev/refactor-plan.md). The markers below
# record the Phase-B fault line: 🟢 = jurisdiction-agnostic core, 🔵 = SEC-specific.
include("standardize.jl")        # 🟢 concept standardization mechanism (W4)
include("config.jl")             # 🟢 runtime configuration + SEC User-Agent
include("http.jl")               # 🟢 HTTP + on-disk cache (fetch_url, _get_json)
include("util.jl")               # 🟢 small cross-cutting helpers
include("text.jl")               # 🟢 html_to_text, fuzzy match, extract_section
include("types.jl")              # 🟢 Filing, Fact, Selection, FactRow
include("cross_reference.jl")    # 🟢 cross-reference-index item extraction (GE-class)
include("forty_f.jl")            # 🔵 40-F AIF-exhibit discovery (aif_html)
include("sections.jl")           # 🟢 form-agnostic item segmentation (sections)
include("documents/Documents.jl") # 🟢 module Documents — faithful EzXML port of edgartools' edgar/documents parser + section detectors
include("chunked_document.jl")    # 🟢 module ChunkedDoc — faithful EzXML port of edgartools' (deprecated) ChunkedDocument
include("twenty_f.jl")           # 🔵 TwentyF (company_reports/twenty_f.py): 20-F items prefer ChunkedDocument, fall back to Documents.sections
include("ten_k.jl")              # 🔵 TenK (company_reports/ten_k.py): 10-K items prefer Documents.sections, then cross-ref index, then ChunkedDocument
include("sec_data.jl")           # 🔵 SEC data.sec.gov APIs + CIK/ticker lookup
include("filing.jl")             # 🔵 fetch / open / save a filing (EDGAR Archives)
include("selection.jl")          # 🟢 picker transport → Selection
include("picker.jl")             # 🟢 browser picker overlay (PICKER_JS)
include("present.jl")            # 🟢 markdown / facts_json exports
include("facts.jl")              # 🟢 facts(::Selection) row table
include("subsidiaries.jl")       # 🔵 EX-21 subsidiary-list extraction (subsidiaries)
include("current_report.jl")     # 🔵 8-K / 6-K press-release + exhibit discovery
include("auditor.jl")            # 🔵 auditor(::Filing) from DEI XBRL facts
include("sixk.jl")               # 🟢 6-K cover-page metadata (sixk_cover)
include("vocab_usgaap.jl")       # 🟢 us-gaap classification vocabulary
include("vocab_ifrs.jl")         # 🟢 ifrs-full classification vocabulary (shared across IFRS regimes)
include("classify_engine.jl")    # 🟢 statement-classification engine (adapted from edgartools, MIT)
include("extract_xbrl.jl")       # 🟢 standard-agnostic XBRL parsing + native extraction
include("extract_xbrl_sec.jl")   # 🔵 SEC linkbase access: statement_map/label_map/calculations
include("export.jl")             # 🟢 save_selection + DuckDB extension stubs

export Filing, fetch_filing, save_filing, open_filing, download_assets, extract_section, sections,
       Selection, Fact, select_section, select_sections, markdown, facts, facts_json,
       read_facts_json, standardize, set_standardizer, edgartools_mapping, statement_map,
       label_map, calculations, select_statement, reconstruct_from_notes, to_duckdb, statement_view, save_selection, archive_filings,
       set_config, set_user_agent, get_user_agent, persist_user_agent, unpersist_user_agent,
       fetch_url, clean_cache, cache_metrics, cache_path_for,
       company_facts, company_concept, xbrl_frames, full_text_search, filings_by_text, filings_by_cik,
       profile, cik,
       subsidiaries, Subsidiary, parse_subsidiaries, auditor, AuditorInfo,
       press_releases, PressRelease, press_release_html, press_release_text, exhibits, sixk_cover,
       extract_items_from_sections,
       TwentyF, tf_items, tf_section,
       TenK, tk_items, tk_section

end # module
