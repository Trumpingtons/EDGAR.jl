# Bundled BSE Financial Results taxonomy — presentation linkbases

`in-bse-fin-pre-2020-03-31.xml` and `in-bse-fin-pre-2019-09-30.xml` are the **presentation linkbases** of
BSE's **Financial Results** XBRL taxonomy — the `in-bse-fin` taxonomy that every NSE/BSE Ind-AS results
instance is written against (see `docs/manual` §13.3). They group each concept into its statement role
(`StatementOfAssetsAndLiabilitiesIndAS` → balance sheet, the results P&L role → income statement,
`CashFlowStatementIndirect` → cash flow, `OtherComprehensiveItems…` → OCI, …), which is what lets
`facts(f; classify=true)` place the **full** statements rather than only the `vocab_indas` key anchors.

- **`in-bse-fin-pre-2020-03-31.xml`** — the general **Ind-AS** format (`INDAS_` filings; e.g. Reliance, IOC,
  Infosys, TCS, Maruti).
- **`in-bse-fin-pre-2019-09-30.xml`** — the **Banking** format (`BANKING_` filings; e.g. HDFC Bank).
- **`in-bse-fin-pre-nbfc-2020-03-31.xml`** — the **NBFC** format (`NBFC_INDAS_` filings; e.g. Bajaj Finance).
  Shares the `2020-03-31` version tag with the general Ind-AS linkbase but is a *different* file (an NBFC
  balance sheet differs), so the selector routes by the filename prefix, not the version.
- **`in-bse-fin-pre-other-2019-09-30.xml`** — the **Other than Banks** format (non-Ind-AS companies; entry
  point `other_than_banks_entry_point_2019-09-30.xsd`). Same version tag as Banking but a different file;
  routed by the `schemaRef` entry-point name. *No real filer validated yet* (most companies are on Ind-AS).

## The two taxonomy families, and why insurance/REITs are NOT here

SEBI's results formats split across **two** taxonomies:

- **`in-bse-fin`** — Ind AS (general), Banking, NBFC, Other than Banks. These are what `vocab_indas` and the
  linkbases above cover. Ind AS / Banking / NBFC are **verified** against real feed filings; Other than
  Banks is bundled but unvalidated.
- **`in-capmkt`** — **General Insurance, Life Insurance, REITs/InvITs**. A *different* taxonomy (concepts are
  `in-capmkt:…`, not `in-bse-fin:…`), so `vocab_indas` does not apply and these would need their own
  classification path. They are also **not reachable through the results feed** (all insurers probed return
  zero rows — they disclose via IRDAI; REITs/InvITs file under SEBI's REIT/InvIT regulations), and General
  vs Life Insurance even share a presentation-linkbase filename+version (`in-capmkt-pre-2020-03-31.xml`) so
  cannot be told apart without a real instance. For those reasons they are **deliberately not bundled** here;
  in-capmkt is a separate sub-effort for when such instances are actually in scope. The taxonomy packages
  themselves are stashed in `~/EDGAR-Reports/IN-taxonomy-*-incapmkt.zip` for that day.

Why bundled rather than fetched at runtime: BSE does **not** host the taxonomy at a resolvable URL (its
namespace URL, `www.bseindia.com/xbrl/fin/…`, serves the exchange homepage). NSE publishes the taxonomy
**packages** on its keyless archive
(`nsearchives.nseindia.com/web/sites/default/files/inline-files/Financial Results_*.zip`), from which these
presentation linkbases were extracted (2026-07). The taxonomy is dated and stable, so bundling it — the
EDINET pattern — keeps classification deterministic and offline (no network at `facts` time). The full
taxonomy packages (schema + calculation/definition/label/reference linkbases) are stashed alongside the
report fixtures for the label work (I4). NBFC and insurance formats can be added by bundling their
presentation linkbases and extending `_india_taxonomy_version`.
