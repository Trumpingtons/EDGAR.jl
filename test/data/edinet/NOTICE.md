# `edinet-min.zip`

A **minimal synthetic** EDINET submission ZIP, hand-authored for the offline parse test (E1, see
`docs/dev/edinet-plan.md`). It is **not a real filing** and contains no real company data — just a tiny
Japanese-GAAP (`jppfs_cor`) XBRL instance (5 facts: Assets, NetAssets, NetSales, OperatingIncome,
NetCashProvidedByUsedInOperatingActivities) placed under the **real EDINET entry layout**
(`…/XBRL/PublicDoc/jpcrp030000-asr-…​.xbrl`).

It exercises the EDINET FilingSystem end-to-end with no network: the submission-ZIP layout
(`_edinet_primary_report`), the shared report-package reader, and the J-GAAP classification vocabulary —
all through the same `fetch_filing` / `facts(f; classify=true)` API as every other system. The dummy
EDINET code `E99999-000` is not a real registrant.
