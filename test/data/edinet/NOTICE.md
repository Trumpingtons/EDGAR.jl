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

# `edinet-real-layout-min.zip`

A second **minimal synthetic** EDINET package, hand-authored to cover two fixes that the real-filing
layout forced (confirmed against a real Toyota annual report, E02144) but that `edinet-min.zip` could not
exercise. It carries, under `…/XBRL/PublicDoc/`:

- the **complete classic `.xbrl` instance** (3 facts: `jppfs_cor:Assets`, `jppfs_cor:NetSales`, and an
  extension `ext:OperatingRevenue`),
- a **`.htm` inline-XBRL fragment** (a stub header doc), AND
- **two split label linkbases** — `…_lab.xml` (Japanese) and `…_lab-en.xml` (English).

It tests: (1) `_edinet_primary_report` prefers the single complete `.xbrl` over the `.htm` fragment (a real
annual report ships both; picking a fragment yields almost no facts); and (2) the language-aware
`_fetch_linkbase(::EDINET; lang)` selects the right split label file, so `label_map(f; lang="en"|"ja")`
returns the requested language (EDINET splits labels per language — `_lab.xml` ja / `_lab-en.xml` en — it
is not one bilingual file). No real company data; `E99999-000` is not a real registrant.
