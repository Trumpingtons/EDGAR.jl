# `dart-min.zip`

A **minimal synthetic** OpenDART financial-statement (`fnlttXbrl`) ZIP, hand-authored for the offline
parse test (D1, see `docs/dev/dart-plan.md`). It is **not a real filing** and contains no real company
data — just a tiny **K-IFRS** (`ifrs-full`) XBRL instance (5 facts: Assets, Equity, Revenue, ProfitLoss,
CashFlowsFromUsedInOperatingActivities, in KRW) in the **real OpenDART entry layout**: a *flat* ZIP whose
classic `.xbrl` instance is named `entity<corp_code>_<date>.xbrl`. The dummy corp_code `99999999` is not a
real registrant.

The layout was **confirmed live** against a real OpenDART `fnlttXbrl` download (Samsung Electronics,
`corp_code 00126380`, FY2023), whose package contains, flat and same-stemmed:

    entity00126380_2023-12-31.xbrl        ← classic XBRL instance (this fixture mirrors this entry)
    entity00126380_2023-12-31.xsd         ← entity extension schema
    entity00126380_2023-12-31_pre.xml     ← presentation linkbase
    entity00126380_2023-12-31_cal.xml     ← calculation linkbase
    entity00126380_2023-12-31_def.xml     ← definition linkbase
    entity00126380_2023-12-31_lab-ko.xml  ← Korean labels   (note: labels are SPLIT per language)
    entity00126380_2023-12-31_lab-en.xml  ← English labels

This fixture carries only the instance (classification is vocabulary-based, so the linkbases aren't needed
to reach BS/IS/CF); the split `_lab-ko` / `_lab-en` label files are a DART-specific N5 concern handled
separately (D4).

It exercises the DART FilingSystem (the 5th) end-to-end with no network: the flat `fnlttXbrl` layout
(`_dart_primary_report`), the shared report-package reader, and — the K-IFRS thesis — the **`ifrs-full`**
classification vocabulary reused unchanged, all through the same `fetch_filing` / `facts(f; classify=true)`
API as every other system.
