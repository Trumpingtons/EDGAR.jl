# Companies House test fixtures

## `small-frs102.html`

A single real company accounts filing (inline XBRL, FRS 102), used as an offline parsing/
classification fixture. Company registration number **00021497**, accounting period to 2025-09-30.

Source: Companies House **bulk Accounts Data Product**
(<https://download.companieshouse.gov.uk/en_accountsdata.html>), file
`Accounts_Bulk_Data-2026-06-19.zip`, entry `Prod223_4245_00021497_20250930.html`.

Companies House data is **Crown copyright** and published free for reuse (the bulk Accounts Data
Product is provided for anyone to download and use). It is included here unmodified, solely as a
test fixture for parsing the public iXBRL accounts format.

## `ns5-canon-min.html`

A **synthetic** minimal inline-XBRL document (not a real filing) that binds the FRC `core` namespace
to a generic `ns5` prefix, to test FRC prefix canonicalization (`_ch_canonicalize`). Contains no real
company data.
