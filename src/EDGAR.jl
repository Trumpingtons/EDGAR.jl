module EDGAR

using HTTP
using JSON3
using Base64
using Dates
using Sockets
import EzXML   # qualified-only; used by forty_f.jl / subsidiaries.jl / sections.jl HTML text extraction

# Light module shell: shared dependencies, the include list, and the public exports.
# Files are split by the FilingSystem seam (see docs/dev/filing-systems.md):
#   🟢 src/core/             — jurisdiction-agnostic core (incl. core/taxonomy/, core/documents/)
#   🔵 src/filing_systems/   — per-FilingSystem code (today only sec/; EDGAR)
# Include ORDER is load-bearing: types/consts used in signatures or const initializers must be
# included before use; method bodies may forward-reference (resolved at call time). Order unchanged
# from the pre-reorg monolith — only paths moved.
include("core/standardize.jl")              # 🟢 concept standardization mechanism (W4)
include("core/config.jl")                   # 🟢 runtime configuration + SEC User-Agent
include("core/http.jl")                     # 🟢 HTTP + on-disk cache (fetch_url, _get_json)
include("core/util.jl")                     # 🟢 small cross-cutting helpers
include("core/text.jl")                     # 🟢 html_to_text, fuzzy match, extract_section
include("core/filing_system.jl")            # 🟢 FilingSystem seam: abstract type + SEC + EntityId
include("core/types.jl")                    # 🟢 Filing, Fact, Selection, FactRow
include("core/discovery.jl")                # 🟢 discovery seam: FilingSource + FilingHandle + fetch_filing(handle)
include("filing_systems/sec/cross_reference.jl") # 🔵 SEC FORM 10-K cross-reference-index item extraction (GE-class)
include("filing_systems/sec/forty_f.jl")    # 🔵 40-F AIF-exhibit discovery (aif_html)
include("filing_systems/sec/sections.jl")   # 🔵 SEC Item/Part segmentation (sections); reuses Documents/ChunkedDoc parsing
include("core/documents/Documents.jl")      # 🟢/🔵 module Documents — 🟢 parser core (HTML→tree/text/tables) + 🔵 SEC section detectors (see Documents.jl)
include("filing_systems/sec/chunked_document.jl") # 🔵 module ChunkedDoc — SEC ChunkedDocument (Item/Part/signature detectors) on the common parser
include("filing_systems/sec/twenty_f.jl")   # 🔵 TwentyF (company_reports/twenty_f.py): 20-F items prefer ChunkedDocument, fall back to Documents.sections
include("filing_systems/sec/ten_k.jl")      # 🔵 TenK (company_reports/ten_k.py): 10-K items prefer Documents.sections, then cross-ref index, then ChunkedDocument
include("filing_systems/sec/data.jl")       # 🔵 SEC data.sec.gov APIs + CIK/ticker lookup
include("filing_systems/sec/filing.jl")     # 🔵 fetch / open / save a filing (EDGAR Archives)
include("core/selection.jl")                # 🟢 picker transport → Selection
include("core/picker.jl")                   # 🟢 browser picker overlay (PICKER_JS)
include("core/present.jl")                  # 🟢 markdown / facts_json exports
include("core/facts.jl")                    # 🟢 facts(::Selection) row table
include("filing_systems/sec/subsidiaries.jl")    # 🔵 EX-21 subsidiary-list extraction (subsidiaries)
include("filing_systems/sec/current_report.jl")  # 🔵 8-K / 6-K press-release + exhibit discovery
include("filing_systems/sec/auditor.jl")    # 🔵 auditor(::Filing) from DEI XBRL facts
include("filing_systems/sec/sixk.jl")       # 🔵 SEC Form 6-K cover-page metadata (sixk_cover) — per-form SEC accessor
include("core/taxonomy/vocab_usgaap.jl")    # 🟢 us-gaap classification vocabulary
include("core/taxonomy/vocab_ifrs.jl")      # 🟢 ifrs-full classification vocabulary (shared across IFRS regimes)
include("core/taxonomy/vocab_ukgaap.jl")    # 🟢 UK GAAP / FRC classification vocabulary (Companies House FRS 101/102/105)
include("core/classify_engine.jl")          # 🟢 statement-classification engine (adapted from edgartools, MIT)
include("core/extract_xbrl.jl")             # 🟢 standard-agnostic XBRL parsing + native extraction
include("filing_systems/sec/xbrl.jl")       # 🔵 SEC linkbase access: statement_map/label_map/calculations
include("filing_systems/esef/report_package.jl") # 🔵 ESEF report-package ZIP reader (offline; ZipArchives)
include("filing_systems/esef/esef.jl")      # 🔵 ESEF FilingSystem: fetch_filing(::ESEF, path/url) + bundled-linkbase fetch
include("filing_systems/esef/discovery.jl") # 🔵 ESEF discovery: FilingsXBRLOrg source (filings.xbrl.org) → handles
include("filing_systems/companies_house/companies_house.jl") # 🔵 Companies House FilingSystem: offline iXBRL accounts parse (C1)
include("filing_systems/companies_house/discovery.jl")       # 🔵 Companies House discovery: CompaniesHouseApi source + authenticated fetch (C2)
include("filing_systems/companies_house/bulk.jl")            # 🔵 Companies House bulk: CompaniesHouseBulk source over the keyless Accounts Data Product (C2)
include("core/export.jl")                   # 🟢 save_selection + DuckDB extension stubs

export FilingSystem, SEC, ESEF, CompaniesHouse, EntityId,
       FilingSource, FilingHandle, FilingsXBRLOrg, CompaniesHouseApi, CompaniesHouseBulk, discover,
       Filing, fetch_filing, save_filing, open_filing, download_assets, extract_section, find_paragraphs, sections,
       Selection, Fact, select_section, select_sections, markdown, facts, facts_json,
       read_facts_json, standardize, set_standardizer, edgartools_mapping, statement_map,
       label_map, calculations, select_statement, reconstruct_from_notes, to_duckdb, statement_view, save_selection, archive_filings,
       set_config, set_user_agent, get_user_agent, set_credentials, persist_user_agent, unpersist_user_agent,
       fetch_url, clean_cache, cache_metrics, cache_path_for,
       company_facts, company_concept, xbrl_frames, full_text_search, filings_by_text, filings_by_cik,
       profile, cik,
       subsidiaries, Subsidiary, parse_subsidiaries, auditor, AuditorInfo,
       press_releases, PressRelease, press_release_html, press_release_text, exhibits, sixk_cover,
       extract_items_from_sections,
       TwentyF, tf_items, tf_section,
       TenK, tk_items, tk_section

end # module
