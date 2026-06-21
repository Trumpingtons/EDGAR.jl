# Vendored third-party data — edgartools concept mappings

`edgartools_concept_mappings.json` is vendored **verbatim** from the **edgartools** project:

- File: `edgar/xbrl/standardization/concept_mappings.json`
- Project: <https://github.com/dgunning/edgartools>
- Licence: **MIT** — Copyright (c) 2022-present Dwight Gunning <dgunning@gmail.com>
  (full text in `edgartools_LICENSE.txt`, alongside this file)

It maps each standard concept (e.g. `"Revenue"`, `"Contract Revenue"`) to the list of
company-specific XBRL concepts that should roll up to it. EDGAR.jl loads it when you call
`set_standardizer(:edgartools)`; it normalises the `us-gaap_X` keys to the `us-gaap:X` form and
inverts the mapping to `concept => standard_concept`. The file is used unmodified; only the
in-memory representation is transformed.

## Adapted code: the statement classifier

`src/classify.jl` is a **translation/adaptation** (not a verbatim copy) of the statement-type
matching logic and registry data in edgartools' `edgar/xbrl/statement_resolver.py` — the per-
statement `primary`/`alternative`/`key` concepts, concept-name patterns and role patterns (including
the IFRS equivalents and issue-tracked refinements such as IFRS P&L role names). The matching logic
was re-expressed in idiomatic Julia and is fed by EDGAR.jl's own XBRL data model; the surrounding
edgartools object model was not ported. Same project, same MIT licence and attribution as the
mapping data below.

## Refreshing the snapshot

This is a point-in-time copy. To pick up upstream mapping fixes, re-vendor it with the maintainer
script (it downloads the file, validates it as JSON, and overwrites only this copy):

```sh
julia --project scripts/refresh_standardizer.jl          # from edgartools' default branch
julia --project scripts/refresh_standardizer.jl v4.18.0  # …or a specific tag/branch/commit
```

Then review the change with `git diff` and re-run the test suite. The licence is unchanged by a
refresh — only the mapping data is updated.
