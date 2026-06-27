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

This fixture carries the instance plus the two **split label linkbases** — `entity99999999_2023-12-31_lab-en.xml`
(English) and `entity99999999_2023-12-31_lab-ko.xml` (Korean), each a single-language label linkbase for the
five concepts — which mirror DART's per-language label split (the N5 concern). They let the offline test
exercise `label_map(f; lang="en"|"ko")` selecting the right file (D4). Classification itself is
vocabulary-based, so the presentation/calculation/definition linkbases are still omitted.

It exercises the DART FilingSystem (the 5th) end-to-end with no network: the flat `fnlttXbrl` layout
(`_dart_primary_report`), the shared report-package reader, and — the K-IFRS thesis — the **`ifrs-full`**
classification vocabulary reused unchanged, all through the same `fetch_filing` / `facts(f; classify=true)`
API as every other system.
