# ESEF test fixture — attribution

`gleif-2024-min.zip` is a **size-reduced, derived** test fixture built from the public ESEF annual
financial report of the **Global Legal Entity Identifier Foundation (GLEIF)** for the year ended
31 December 2024.

- **Source:** GLEIF Annual Report 2024, published by GLEIF (https://www.gleif.org/) as an ESEF
  report package. LEI `506700GE1G29325QX363`.
- **What this fixture is:** a valid XBRL Report Package (documentType
  `https://xbrl.org/report-package/2023`) containing the classic XBRL instance
  (`reports/gleif-2024-12-31-0-en.xbrl`) plus the issuer's bundled extension taxonomy and its
  presentation / calculation / definition / label linkbases, with `META-INF/`
  (reportPackage.json + taxonomyPackage.xml + catalog.xml). The multi-megabyte inline `.xhtml`
  rendering of the original package has been **omitted** to keep the fixture small; the inline path is
  already covered by the SEC iXBRL tests.
- **Purpose:** offline regression testing of EDGAR.jl's ESEF FilingSystem (`fetch_filing(::ESEF, …)`)
  and the system-agnostic XBRL extraction/classification path against a genuine non-SEC, IFRS filing.

GLEIF's published materials are made available under terms permitting reuse with attribution; this
fixture is included solely for testing and is credited to GLEIF accordingly. No affiliation with or
endorsement by GLEIF is implied. The full original packages are not redistributed here (kept locally,
gitignored, under `test/data/esef/raw/`).
