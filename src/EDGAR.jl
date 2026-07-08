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
include("filing_systems/sec/auditor.jl")    # 🔵 _sec_auditor(::Filing): SEC reader behind auditor() — AuditorInfo from DEI XBRL facts
include("filing_systems/sec/sixk.jl")       # 🔵 SEC Form 6-K cover-page metadata (sixk_cover) — per-form SEC accessor
include("core/taxonomy/vocab_usgaap.jl")    # 🟢 us-gaap classification vocabulary
include("core/taxonomy/vocab_ifrs.jl")      # 🟢 ifrs-full classification vocabulary (shared across IFRS regimes)
include("core/taxonomy/vocab_ukgaap.jl")    # 🟢 UK GAAP / FRC classification vocabulary (Companies House FRS 101/102/105)
include("core/taxonomy/vocab_jpgaap.jl")    # 🟢 Japanese GAAP classification vocabulary (EDINET jppfs_cor)
include("core/taxonomy/vocab_indas.jl")     # 🟢 Ind-AS (in-bse-fin) classification vocabulary (India NSE/BSE; INDAS/BANKING/NBFC formats)
include("core/taxonomy/vocab_incapmkt.jl")  # 🟢 in-capmkt (SEBI Integrated Filing) vocabulary (India; INDAS/BANKING/NBFC + Life/General Insurance)
include("core/taxonomy/vocab_cas.jl")       # 🟡 CAS (China 企业会计准则) label-driven vocabulary (PDF path; cas_concept)
include("core/taxonomy/vocab_ifrs_labels.jl") # 🟢 English-label → ifrs-full vocabulary for the PDF path (HK HKFRS + UK Companies House FRS 101/102; ifrs_label_concept)
include("core/classify_engine.jl")          # 🟢 statement-classification engine (adapted from edgartools, MIT)
include("core/extract_xbrl.jl")             # 🟢 standard-agnostic XBRL parsing + native extraction
include("core/breakdown.jl")                # 🟢 dimensional breakdown (revenue by segment/product/geography)
include("filing_systems/sec/xbrl.jl")       # 🔵 SEC linkbase access: statement_map/label_map/calculations
include("filing_systems/esef/report_package.jl") # 🔵 ESEF report-package ZIP reader (offline; ZipArchives)
include("filing_systems/esef/esef.jl")      # 🔵 ESEF FilingSystem: fetch_filing(::ESEF, path/url) + bundled-linkbase fetch
include("filing_systems/esef/discovery.jl") # 🔵 ESEF discovery: FilingsXBRLOrg source (filings.xbrl.org) → handles
include("filing_systems/companies_house/companies_house.jl") # 🔵 Companies House FilingSystem: offline iXBRL accounts parse (C1)
include("filing_systems/companies_house/discovery.jl")       # 🔵 Companies House discovery: CompaniesHouseApi source + authenticated fetch (C2)
include("filing_systems/companies_house/bulk.jl")            # 🔵 Companies House bulk: CompaniesHouseBulk source over the keyless Accounts Data Product (C2)
include("filing_systems/nsm/nsm_categories.jl")              # 🔵 NSM (FCA) category vocabulary: type_code → description
include("filing_systems/nsm/nsm.jl")                         # 🔵 NSM discovery: FCA National Storage Mechanism source (UKSEF AFR iXBRL → ESEF parse)
include("filing_systems/edinet/edinet.jl")                   # 🔵 EDINET (Japan FSA) FilingSystem: offline submission-ZIP parse (reuses ESEF report-package path)
include("filing_systems/edinet/concepts.jl")                 # 🔵 EDINET concept table: pre-distilled concept→balance (sign) + bilingual labels from the standard taxonomy
include("filing_systems/edinet/discovery.jl")                # 🔵 EDINET discovery: EDINETApi source over the EDINET REST API (date-based)
include("filing_systems/dart/dart.jl")                       # 🔵 DART (KR FSS) FilingSystem: offline OpenDART fnlttXbrl-package parse (reuses ESEF report-package path)
include("filing_systems/dart/discovery.jl")                  # 🔵 DART discovery: OpenDARTApi source over the OpenDART REST API (by-company) + corp_code resolver
include("filing_systems/india/india.jl")                     # 🔵 India (NSE/BSE, Ind-AS) FilingSystem — I0 seam + I1 offline parse + NSE cookie session
include("filing_systems/india/discovery.jl")                 # 🔵 India discovery: NSEFilings source over the keyless (cookie-gated) NSE financial-results API
include("filing_systems/india/auditor.jl")                   # 🔵 _india_auditor(::Filing): India reader behind auditor() — AuditorInfo from in-capmkt AuditorsFirmName + opinion
include("filing_systems/china/china.jl")                     # 🟡 China (CSRC/CNINFO, CAS) FilingSystem — C0 seam + C2 fetch→:pdf Filing (first PDF-native jurisdiction; facts via the PDF extractor)
include("filing_systems/china/discovery.jl")                 # 🟡 China discovery: CNINFOFilings source over the keyless CNINFO JSON API (topSearch + hisAnnouncement) [C1]
include("filing_systems/hkex/hkex.jl")                       # 🟣 Hong Kong (HKEX/HKEXnews, HKFRS) FilingSystem — HK0 seam (2nd PDF-native jurisdiction; English/ifrs-full, facts via the PDF extractor)
include("filing_systems/hkex/discovery.jl")                  # 🟣 HKEX discovery (HK1): HKEXFilings source over the keyless HKEXnews JSON API (prefix.do + titleSearchServlet.do) + fetch→:pdf
include("filing_systems/russia/russia.jl")                   # 🔴 Russia (MOEX/CBR/e-Disclosure, RAS) FilingSystem — R0 seam + R1 :ras structured-row facts (route 1 = RFSD; first "filing = dataset row")
include("filing_systems/russia/vocab_ras.jl")                # 🔴 Russia R3: vocab_ras — OKUD line-code → statement-type classification + English labels (the numeric RAS analogue of vocab_cas/vocab_indas)
include("filing_systems/russia/discovery.jl")                # 🔴 Russia discovery (R2): RFSDFilings source — MOEX ISS name/ticker→INN resolver + fetch_filing→DuckDB partition query (weakdep _rfsd_query in EDGARDuckDBExt)
include("filing_systems/russia/cbr.jl")                       # 🔴 Russia route 2 (C0 seam): CBRBankFilings source — CBR bank Forms 0409101/102 per regnum (financial sector, excluded from RFSD; banks only)
include("filing_systems/russia/vocab_cbr.jl")                # 🔴 Russia route 2 (C4): vocab_cbr — bank chart-of-accounts → BankBalanceSheet line classification (_cbr_line / cbr_line)
include("filing_systems/generic/generic.jl")                 # 🟢 Generic: the shared core with NO jurisdiction adapter — fetch_filing(Generic(), path/url) sniffs format → facts/narratives/toc via the generic extractors
include("extractors/pdf.jl")                # 🟢 PDF extractor (Format axis): pdfjs-dist → words → row/column → coordinate-anchored Facts
include("extractors/structured_document.jl")# 🟢 StructuredDocument substrate (document-first PDF repository); Docling extraction via PythonCall ext
include("extractors/document_profile.jl")   # 🟢 extensible table-classification taxonomy (BS/IS/CF/EC + open registry)
include("extractors/facts_derive.jl")        # 🟢 facts derivation core: locale-aware amount parsing + column-axis inference
include("filing_systems/china/cas.jl")       # 🟡 China CAS PDF extraction (C3): consolidated statements → Facts via vocab_cas (extract_cas_pdf)
include("filing_systems/china/portfolio.jl") # 🟡 China fund §8 portfolio (投资组合报告): holdings + summaries (extract_fund_portfolio)
include("extractors/ifrs_pdf.jl")           # 🟢 English-PDF statement extraction: primary statements → Facts on ifrs-full via vocab_ifrs_labels (extract_ifrs_pdf) — shared by HK (HKFRS) + UK Companies House
include("filing_systems/hkex/reit_portfolio.jl") # 🟣 HK REIT property-portfolio composition (extract_reit_portfolio) — the REIT analogue of extract_fund_portfolio, reusing FundPortfolio
include("core/export.jl")                   # 🟢 save_selection + DuckDB extension stubs
include("core/narratives.jl")               # 🟢 narratives(): prose/text layer parallel to facts() — Narrative rows from XBRL/iXBRL/PDF/HTML
include("core/auditor.jl")                   # 🟢 auditor(): generic cross-jurisdiction accessor → AuditorInfo; routes to each system's reader (SEC: _sec_auditor)
include("core/toc.jl")                       # 🟢 toc(): structure layer — document outline from PDF bookmarks / HTML headings / XBRL statement roles

export FilingSystem, SEC, ESEF, CompaniesHouse, EDINET, EDINETApi, DART, OpenDARTApi, dart_corp_code, dart_index_ttl!, India, NSEFilings, IntegratedFilings, China, CNINFOFilings, cninfo_org, HKEX, HKEXFilings, hkex_stock, Russia, RFSDFilings, rfsd_download, set_rfsd_local, set_rfsd_cache_dir, ras_label, rfsd_flags, CBRBankFilings, cbr_bank_directory, cbr_line, Generic, EntityId,
       FilingSource, FilingHandle, FilingsXBRLOrg, CompaniesHouseApi, CompaniesHouseBulk, NSM, nsm_categories, discover,
       company_search, CompanyHit,
       Filing, fetch_filing, save_filing, open_filing, download_assets, extract_section, find_paragraphs, sections,
       Selection, Fact, select_section, select_sections, markdown, facts, facts_json, extract_pdf, extract_cas_pdf, cas_concept, extract_ifrs_pdf, ifrs_label_concept, born_digital, extract_fund_portfolio, extract_reit_portfolio, FundPortfolio, FundHolding, FundAssetClass, FundIndustryExposure,
       Narrative, narratives,
       toc, TocNode, TocRow,
       structured_document, StructuredDocument, persist_document, write_structured_document,
       read_structured_document, to_repository, classify_tables!, derive_facts!,
       classify_table_class, table_class_kind, register_table_class!, TableClass, TABLE_CLASSES,
       parse_amount, amount_locale, infer_columns, parse_period_end, period_dates,
       read_facts_json, standardize, set_standardizer, edgartools_mapping, statement_map,
       label_map, calculations, check_calculations, breakdown, segments, select_statement, reconstruct_from_notes, to_duckdb, statement_view, save_selection, archive_filings,
       set_config, set_user_agent, get_user_agent, set_credentials, set_cache_policy, persist_user_agent, unpersist_user_agent,
       fetch_url, clean_cache, cache_metrics, cache_path_for,
       company_facts, company_concept, xbrl_frames, full_text_search, filings_by_text, filings_by_cik,
       profile, cik,
       subsidiaries, Subsidiary, parse_subsidiaries, auditor, AuditorInfo,
       press_releases, PressRelease, press_release_html, press_release_text, exhibits, sixk_cover,
       extract_items_from_sections,
       TwentyF, tf_items, tf_section,
       TenK, tk_items, tk_section

end # module
