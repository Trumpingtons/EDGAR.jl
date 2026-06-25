# Plan — adding UK Companies House as a FilingSystem

Status: **draft / living document** (expect iteration). Follows the seam established by SEC and ESEF
(see [filing-systems.md](filing-systems.md)). Companies House (CH) is the 3rd `FilingSystem`; EDINET
(JP) is planned next and shares the C0 prerequisite.

Governing principle (unchanged): **generalize the nouns, not the verbs.** CH forces three nouns the
spec already anticipated — N3 (credentials), N4 (standard-taxonomy linkbase delegation), and a weaker
validation story. Do the noun changes once, narrowly; implement CH's verbs as an isolated adapter.

### A reframe CH forces: EDGAR.jl is about *regulatory reports*, not only XBRL

CH is the first system where a large share of filings are **not XBRL at all** — small/dormant/
paper-filed accounts are **PDF**. This breaks an invariant the FilingSystem spec leans on:
*"parse is always the common core."* That is only true for XBRL. The honest model has **three
orthogonal axes**, not two:

1. **FilingSystem** (SEC / ESEF / CH / …) — where a report comes from.
2. **Taxonomy** (us-gaap / ifrs-full / FRC) — the concept vocabulary, when structured.
3. **Format / extraction** (iXBRL · classic XBRL · **PDF** · …) — *how facts are recovered from
   the bytes.* `Filing.kind` already names this (`:ixbrl`/`:xbrl`); PDF adds `:pdf`.

The XBRL extractor (`extract_xbrl.jl`) is **one extractor on this third axis**, not the universal
core. PDF needs a *different* extractor (layout/table parsing, no taxonomy). This same axis is what
**German** companies will force: Germany is absent from filings.xbrl.org and its OAM (Bundesanzeiger)
XBRL is not openly retrievable — German annual reports are largely PDF too. So the PDF extractor we
build for CH is reusable for DE, and the format axis is a genuine noun.

**Decision for now:** name the axis, do **not** build PDF extraction or rename anything. Split CH into
**CH I (iXBRL path — this plan)** and **CH II (PDF path — separate plan)**. Where C-phases below would
say "no XBRL available", the real contract is "this filing's format is `:pdf` → defer to the PDF
extractor (CH II)", surfaced as a typed, non-fatal outcome, not a dead end.

---

## 1. What Companies House actually is

- The UK registrar (FRC) for the accounts of **all** UK companies — private + public, not just
  listed issuers. This is a *much larger and messier* universe than ESEF/SEC.
- Filing format: **single inline-XBRL (iXBRL) accounts document** (`.xhtml`/`.html`) — **not** a
  report-package ZIP. No bundled linkbases, **no issuer extension taxonomy**: the instance only
  carries `<link:schemaRef>`s to the **published FRC standard taxonomy** (FRS 101 / FRS 102 /
  FRS 105 / IFRS / the FRC "core" suite). → this is the N4 forcing case.
- Identity = **company registration number** (`EntityId(:companies_house, "01234567")`). In the
  instance the context entity identifier carries `scheme="http://www.companieshouse.gov.uk/"`.
- Access: the **Companies House REST API** (free key) + the **Document API**. Also a free **bulk
  "Accounts Data Product"** (daily/monthly ZIP of all iXBRL accounts) — a possible second source.
- Format split: digitally-filed accounts are iXBRL; a large fraction of small/dormant/paper-filed
  accounts are **PDF, no XBRL**. CH I handles the iXBRL ones and classifies each filing's format from
  the document metadata's content types; a `:pdf` filing is a **typed, non-fatal** outcome handed to
  **CH II** (the PDF extractor — separate plan), *not* an error. See the reframe above.
- Source scope: **CH is the primary source for *all* UK filers** — both UKSEF (regulated-market) and
  non-UKSEF (private/small). We deliberately build CH as **self-sufficient** and proceed *as if
  `FilingsXBRLOrg` did not exist* (it already drops the largest EU country, Germany, and may drop UK
  next — we will not depend on it). `FilingsXBRLOrg` is **demoted to a validation cross-check**: for a
  UKSEF filer reachable on both, CH and FilingsXBRLOrg must produce the same facts (a free oracle and
  test pair — see §4).

### Access mechanics (verify during C2 — these are the known shape, confirm live)

1. `GET https://api.company-information.service.gov.uk/company/{number}` → profile (name, status).
2. `GET …/company/{number}/filing-history?category=accounts` → items; each has `type` (e.g. `AA`),
   `category:"accounts"`, `date`, `description`, period fields (`made_up_date`/`action_date`), and
   `links.document_metadata` (a URL on the **document-api** host).
3. `GET {document_metadata}` (document-api) → `resources` listing available content types.
4. `GET {document_metadata}/content` with `Accept: application/xhtml+xml` → the iXBRL bytes.
   **Risk:** this returns a **302 to a signed S3 URL**; the `Authorization` header must **not** be
   forwarded to S3. Confirm HTTP.jl's redirect behaviour and strip auth on cross-host redirect.
5. Auth = **HTTP Basic**, API key as username, blank password (`Authorization: Basic b64(key + ":")`).
   Rate limit ≈ **600 requests / 5 min**.

---

## 2. The seam today (what we reuse unchanged)

- `abstract type FilingSystem` + concrete structs — [`core/filing_system.jl`](../../src/core/filing_system.jl).
- `EntityId(scheme::Symbol, value)` — open scheme set; just add `:companies_house` *data*.
- **The XBRL extractor handles any iXBRL** — [`core/extract_xbrl.jl`](../../src/core/extract_xbrl.jl)
  (validated on SEC us-gaap + ESEF/IFRS; decimal-comma fix is in). CH iXBRL needs **no parser
  change**. (This is *one* extractor on the format axis — PDF is a different one, CH II; see reframe.)
- Per-system linkbase fetcher: generic forwarder `_fetch_linkbase(f::Filing, suffix) =
  _fetch_linkbase(f.system, f, suffix)` in extract_xbrl.jl:245; SEC + ESEF bodies dispatch on system.
  Returning `""` is tolerated by classification.
- Discovery seam — [`core/discovery.jl`](../../src/core/discovery.jl): `FilingSource`,
  `FilingHandle` (`system, entity, ref, url, period_end, country`), `discover`, `fetch_filing(h)`.
- Classification vocab is keyed by **taxonomy prefix**, auto-merged in classify_engine
  (`_TAXONOMY_VOCABULARIES`). A new national GAAP = a new vocab file; no engine change.

---

## 3. Phasing

Ordered so each phase is independently testable and commit-able, cheapest/least-risky first. C0 is a
shared prerequisite (EDINET needs it too); C1 mirrors ESEF B1; C2 mirrors ESEF B2.

**Step & gate convention** (see [edgar-jl-working-style memory] → "stepped execution"). Each phase
below has a numbered step list. Step status is tracked in-line: ☐ todo · ▶ doing · ✅ done · ⏸ blocked.
A step marked **🚦 GATE** is a hard stop — I pause and report (or ask) before proceeding past it;
non-gate steps I advance through autonomously and report at the next gate (so you're not pinged on
trivia, which keeps cost down). Gates are placed at: irreversible/outward actions, anything needing
a credential or network call, fixture/dependency choices, and every "run the test suite + commit"
checkpoint (tests are only ever run with your go-ahead; commits only when you say so). You can also
interject between *any* steps — the gates are the *minimum* stops, not the only ones.

### C0 — N3: per-system credentials registry  *(shared prerequisite, core change)*

The only change that touches **shared** code (`config.jl` + `http.jl`), so do it carefully and first.

- In `config.jl`: add a per-system credential store, e.g.
  `const CREDENTIALS = Dict{Symbol,Dict{Symbol,String}}()` keyed by a system tag symbol
  (`:sec`, `:companies_house`, `:edinet`). Add:
  - `set_credentials(::FilingSystem; kwargs...)` — stores keys (e.g. `api_key`) for that system.
  - `system_headers(::FilingSystem)::Vector{Pair}` — returns the auth/UA headers for a request to
    that system. SEC method → `["User-Agent" => get_user_agent()]`. CH method → Basic-auth header
    from the stored `api_key` (UA optional).
  - Make `set_user_agent` / `get_user_agent` **SEC sugar** over `set_credentials(SEC(); …)` — keep
    the existing public API and `SEC_USER_AGENT` env behaviour intact (no breaking change).
  - CH key from env too: `COMPANIES_HOUSE_API_KEY` (mirrors `SEC_USER_AGENT`).
- In `http.jl`: generalize `fetch_url` so the caller can pass headers (or a system) instead of the
  hard-wired `["User-Agent"=>ua]` at http.jl:177. Minimal, back-compatible shape:
  `fetch_url(url; headers=nothing, …)` — when `headers===nothing`, keep today's SEC-UA behaviour
  (so every existing SEC/ESEF call is unchanged); CH discovery/fetch passes `system_headers(CH)`.
- **Redirect/auth safety:** ensure the `Authorization` header is dropped on a cross-host redirect
  (the S3 document download). Either rely on HTTP.jl stripping it, or fetch the 302 and re-issue the
  S3 GET without auth ourselves.
- Tests: unit-level only (no network) — credentials set/get, header construction, `set_user_agent`
  still works and still throws when unset. **Run the full suite once** at the checkpoint (config +
  http are load-bearing for everything).

**Steps**

1. ✅ Add `CREDENTIALS` store + `set_credentials(::FilingSystem; …)` + `system_headers(::FilingSystem)`;
   SEC methods (`system_headers(::SEC)` → UA header). *(store in config.jl; dispatched methods in
   filing_system.jl — config.jl is included before the `FilingSystem` types exist. `set_credentials`
   exported.)*
2. ✅ Unify under `set_credentials`. *Tests forced a change of plan:* `runtests.jl` sets
   `CONFIG.user_agent=nothing` and expects `get_user_agent()` to throw, and `set_config(user_agent=…)`
   writes that slot — so `CONFIG.user_agent` **must stay** SEC's canonical store. `set_user_agent`/
   `get_user_agent` left byte-for-byte; added `set_credentials(::SEC; user_agent)` that **routes to
   `set_user_agent`** (prevents the footgun of the generic method writing the wrong place).
3. ✅ `fetch_url(...; headers=nothing)` — default reproduces the SEC-UA path exactly; explicit
   `headers` replaces it and bypasses the SEC UA requirement. `_get_json` passes `headers` through too.
4. ✅ Cross-host redirect — **no code change needed**: HTTP.jl strips `SENSITIVE_HEADERS`
   (incl. `Authorization`) on a non-same-domain redirect (RedirectRequest.jl). Documented in the
   `fetch_url` docstring; confirm live against the S3 hop at C2.
5. ✅ Offline tests added (`"per-system credentials (N3, offline)"` in runtests.jl) — store/read/merge,
   unknown-key ⇒ nothing, SEC routing + validation, `system_headers(::SEC)`. *(not yet run — gate)*
6. 🚦 **GATE** — request approval to run the full suite once; on green, request approval to commit C0.

### C1 — offline parse  *(mirrors ESEF B1)*

New dir `src/filing_systems/companies_house/`. No network.

- `companies_house.jl`:
  - `struct CompaniesHouse <: FilingSystem end` (export it).
  - `const _CH_SCHEME = "http://www.companieshouse.gov.uk/"`; `_ch_number(content)` parses the
    registration number from the context entity `<identifier scheme="…companieshouse…">` (reuse the
    `_esef_lei` regex shape).
  - `fetch_filing(::CompaniesHouse, src::AbstractString; entity=nothing, ref="")` — read a **local
    iXBRL file** (path or URL via `fetch_url`); build
    `Filing(CompaniesHouse(), EntityId(:companies_house, num), ref, basename(src), src, :ixbrl, content)`.
    Detect format: a PDF input becomes a `:pdf`-tagged filing (typed, non-fatal — CH II), not an error.
  - `_fetch_linkbase(::CompaniesHouse, f, suffix) = ""` initially (no bundled linkbases; tolerated).
    Real linkbases arrive in C3.
- `src/core/taxonomy/vocab_ukgaap.jl` — UK-GAAP classification vocab keyed by FRC prefixes
  (`core`, `bus`, `frs102`/`uk-gaap`, etc.), so `facts(f; classify=true)` buckets BS/IS/CF **without**
  linkbases (same way `vocab_ifrs.jl` works for ESEF). Build it from the FRC taxonomy concept lists.
  Include it next to `vocab_ifrs.jl` in `EDGAR.jl`; it auto-merges into the registry.
- Wire includes in `EDGAR.jl` (🔵 `companies_house/`), after `vocab_ukgaap.jl`.
- **Fixture:** commit one small real CH iXBRL accounts file under
  `test/data/companies_house/` (+ a NOTICE). Prefer a tiny FRS-102 filing. Gitignore any raw bulk.
- **Test:** offline testset — parse fixture → assert known facts, `:companies_house` identity, and
  BS/IS classification via `vocab_ukgaap`. Run full `Pkg.test()` once.

**Steps**

1. ✅ New dir `companies_house/`; `struct CompaniesHouse <: FilingSystem`; exported; include wired
   (after esef/discovery.jl). `system_tag(::CompaniesHouse) = :companies_house`.
2. ✅ `_CH_SCHEME` + `_ch_number(content)` identity parse (regex mirrors `_esef_lei`).
3. ✅ `fetch_filing(::CompaniesHouse, src)` for a local path or URL; `%PDF` magic-byte → `:pdf` typed
   (empty content, url kept), else `:ixbrl` with parsed company-number identity.
4. ✅ `_fetch_linkbase(::CompaniesHouse, …) = ""` stub (real FRC linkbases = C3).
5. ✅ `vocab_ukgaap.jl` (FRC `core` prefix, first-cut concept set) + include after `vocab_ifrs.jl`;
   registered in `_TAXONOMY_VOCABULARIES`. *(Not yet load/run-verified — that's the step 8 gate.)*
6. ⏸ **DEFERRED to C2** (decided 2026-06-25) — fixture acquisition + offline test. Cleanly obtaining
   real CH iXBRL fixtures needs the Document API key, which is built in C2; rather than commit
   hand-scraped files now, we acquire the fixture set via the API mid-C2 (see C2 step 4). C1 **code**
   is committed now, **unverified by a fixture test until C2** (acknowledged trade-off). The
   `vocab_ukgaap` concept set is a first cut, tuned against the real tags at that point.
   (Was: C1 steps 6–8.)
7. → see **C2 step 4**.
8. → see **C2 step 4** (test) / **C2 step 7** (commit).

### C2 — discovery + fetch  *(mirrors ESEF B2; needs C0)*

`src/filing_systems/companies_house/discovery.jl`.

- `struct CompaniesHouseApi <: FilingSource end`.
- `discover(::CompaniesHouseApi; company_number, category="accounts", size=…) -> Vector{FilingHandle}`
  — calls filing-history (steps 1–2 above), emits `CompaniesHouse()`-tagged handles. `url` =
  the `document_metadata` URL (or a resolved content URL); `period_end` from the made-up date;
  `country = "GB"`; `ref` = transaction id.
- `fetch_filing(::CompaniesHouse, h::FilingHandle)` — resolve metadata → content endpoint
  (steps 3–4), `Accept: application/xhtml+xml`. Record the document's **format** from the metadata
  content types; when no iXBRL is offered, return a filing tagged `:pdf` (a typed, non-fatal outcome
  for CH II to consume) rather than throwing. Carry `h.entity`/`h.ref` so identity isn't re-parsed.
  Reuse a single-slot memo only if needed (CH docs are small — likely unnecessary, unlike the
  multi-MB ESEF ZIPs).
- All calls go through `fetch_url(...; headers=system_headers(CompaniesHouse()))`.
- **Second source (build it) — `CompaniesHouseBulk <: FilingSource`** over the free **Accounts Data
  Product** (daily/monthly ZIP of all iXBRL accounts; no API key, no rate limit, whole-registrar).
  This is the route that actually scales to the registrar universe — `discover` iterates the bulk
  archive's entries into `CompaniesHouse()`-tagged handles whose `url` points at the extracted iXBRL.
  Two sources (`CompaniesHouseApi` for targeted per-company lookups, `CompaniesHouseBulk` for
  whole-population sweeps) over the same `fetch`/parse path. Confirm the bulk product's iXBRL coverage
  vs. PDF-only filings (the bulk set is the digitally-filed accounts, so it is already iXBRL-biased).
- **Tests:** network-gated (`EDGAR_NETWORK_TESTS`/`RUN_NETWORK`); API path needs a CH key in CI env,
  bulk path can use a tiny committed slice of a real archive as an offline fixture. Pick a stable
  small company number as the live API fixture.

**Steps**

1. ✅ `CompaniesHouseApi <: FilingSource` + `discover(...)` over the filing-history endpoint → handles
   (exported; `system_headers(::CompaniesHouse)` = Basic-auth from `:api_key`/`COMPANIES_HOUSE_API_KEY`).
2. ✅ `fetch_filing(::CompaniesHouse, ::FilingHandle)`: metadata → `{metadata}/content` with iXBRL
   `Accept`; `:ixbrl`/`:xbrl`/`:pdf` typing; cross-host `Authorization` strip relied on from C0.
   *(Build-checked: compiles, routes, auth header round-trips.)*
3. ✅ **Shapes reconciled against the CH OpenAPI specs** (specs.developer.ch.gov.uk /
   developer-specs.company-information.service.gov.uk) — filing-history item fields
   (`transaction_id`/`category`/`type`/`date`/`links.document_metadata`) and the document content
   endpoint (`{metadata}/content`, `Accept`-selected, **302** to storage, 406 on unsupported type) all
   match `discovery.jl`; no code change needed. A **live call** remains only as final runtime
   confirmation (optional; needs a key the user couldn't mint — keyless bulk covers everything else).
4. ◑ **Fixtures + moved C1 offline test — DONE keylessly via the bulk Accounts Data Product** (the API
   key turned out to be a dead end for the user; the bulk product needs none). Committed
   `test/data/companies_house/{small-frs102.html (real, 00021497), ns5-canon-min.html (synthetic), NOTICE.md}`
   + testset "Companies House: offline iXBRL parse + FRC canonicalization (C1)" (12/12). Surfaced &
   fixed **FRC prefix instability** (`ns5` vs `uk-core` for the same namespace → `_ch_canonicalize`,
   CH-only) and a **`statement_map_multi` SEC-coupling bug** (SEC FilingSummary fallback now gated to
   SEC; generic vocab key-anchor fallback added). `vocab_ukgaap` corrected to real `uk-core:` names.
   STILL OPTIONAL (needs the live API or named-company bulk extraction): the **UKSEF cross-check pair**
   Jupiter + Kainos and a **large** non-UKSEF filer — defer to the live-API probe or a bulk name lookup.
5. ✅ `CompaniesHouseBulk <: FilingSource` over the **keyless** Accounts Data Product (daily
   `Accounts_Bulk_Data-YYYY-MM-DD.zip`): `discover(; date, company_number, limit)` lists a day's
   archive into handles; `fetch_filing` reads an entry (single-slot archive memo, à la ESEF).
   `fetch_filing(::CompaniesHouse, h)` now dispatches API-vs-bulk on a `.zip` url. Committed offline
   slice `bulk-min.zip` + testset "Companies House: bulk Accounts Data Product (C2, offline)" (13/13,
   full path via a seeded memo). Verified on the real 34 MB archive: 253 facts → IS/BS/CF, ns5→uk-core.
6. ☐ Network-gated tests (API) + offline bulk-slice test + the CH↔FilingsXBRLOrg parity test.
7. 🚦 **GATE** — approval to run the suite; on green, approval to commit C2.

### C3 — N4: standard-taxonomy linkbase delegation  *(heaviest; can defer; benefits ESEF too)*

Goal: real **labels** + presentation/calculation-driven statements for CH (and `ifrs-full` standard
labels for ESEF, which has the same gap — see [esef-expansion memory]).

- `_fetch_linkbase(::CompaniesHouse, f, suffix)` resolves the instance's `<link:schemaRef href=…>`
  to the published FRC taxonomy, then locates the pre/cal/lab linkbase for that entry point and
  fetches it (cached `fetch_url`). Two implementation options, cheapest first:
  1. **Registry**: a small map `FRC entry-point schema URL → {pre,cal,lab} linkbase URLs` for the
     common FRS-102/101/105 versions. Fast, no DTS walk. Start here.
  2. **DTS discovery**: parse the schema's `linkbaseRef`s generically (the proper, version-proof
     route). Larger; do only if the registry proves too brittle across taxonomy years.
- Because this is shared "delegate to the published standard taxonomy", structure it so ESEF's
  `ifrs-full` standard-label fetch can reuse the same resolver (consider a core helper
  `_standard_linkbase(schema_url, suffix)`).
- Tests: labels/statements on the C1 fixture (network-gated for the taxonomy fetch, or commit a
  trimmed FRC linkbase fixture as we did for GLEIF).

**Steps**

1. ✅ Resolver — **simpler than the registry**: the FRC `core` label-linkbase URL **derives directly
   from the `core` namespace** the instance declares. Probed the live taxonomy (FRS-102 entry point →
   imports `frc-core-<date>.xsd` → linkbaseRef `frc-core-<date>-label.xml`), and the concepts sit in
   `http://xbrl.frc.org.uk/fr/<date>/core`, so `_frc_core_label_url` maps that namespace →
   `https://xbrl.frc.org.uk/fr/<date>/core/frc-core-<date>-label.xml`. No schemaRef/DTS walk needed
   for labels.
2. ✅ (folded into 1 — derivation replaces the registry for the core label linkbase.)
3. ✅ `_fetch_linkbase(::CompaniesHouse, _, "lab")` fetches that linkbase (keyless public GET,
   `_CH_TAXONOMY_HEADERS`) and rewrites `#core_` → `#uk-core_` so `_concept_labels` keys match the
   canonicalized facts. **Verified live**: `uk-core:NetAssetsLiabilities` → "Net assets (liabilities)",
   all 12 facts on the real fixture labelled. (pre/cal still return ""; vocab classification suffices.
   ESEF `ifrs-full` standard-label reuse: noted, deferred — the derivation pattern transfers.)
4. ✅ **GATE resolved**: derivation is robust across years (date comes from the namespace), so the
   DTS-walk fallback is **not needed** for core labels.
5. ✅ Tests: offline "Companies House: FRC standard-taxonomy labels (C3, offline)" (6/6, derivation +
   `#core_`→`#uk-core_` re-keying against synthetic `frc-core-label-min.xml`) + network-gated live
   "Companies House FRC labels (live)" (fetches the real ~6 MB linkbase).
6. 🚦 **GATE** — approval to run the suite; on green, approval to commit C3.

---

## 4. Validation

The registrar universe is the hard part — most CH filers are **not** on filings.xbrl.org, so the
Arelle/xBRL-JSON oracle does **not** cover them (it covers only UKSEF GB filings already). We need a
CH-native oracle in addition to the cross-checks.

- **CH extraction-library oracle (find one — the edgartools analogue for CH).** Just as `edgartools`
  anchors SEC and Arelle/xBRL-JSON anchors ESEF, we want an independent library that extracts facts
  from CH iXBRL accounts to compare against our own parse, as a new include-on-demand module in
  `src/sources/` (e.g. `companies_house_oracle.jl`). **Hard constraints (the openesef lesson):** it
  must be **permissively licensed (MIT/BSD/Apache — not GPL)** and stays an *oracle*, never a package
  dependency. Candidates to evaluate: the FRC/Companies-House community iXBRL tooling and
  general-purpose iXBRL parsers (e.g. `ixbrl-parse`-style libraries, `stream-read-xbrl`). If none
  qualify on licence, fall back to Arelle (already wired) for the iXBRL subset it can read.
- **FilingsXBRLOrg as a cross-check pair (not a source).** For a UKSEF filer reachable on *both* CH
  and filings.xbrl.org, assert **CH facts == FilingsXBRLOrg facts** — a free, high-confidence parity
  test that also guards against either source drifting. (This is the only role FilingsXBRLOrg keeps;
  see §1 source scope.)
- **Arelle oracle** (`src/sources/arelle_oracle.jl`): unchanged — high-confidence baseline for the
  UKSEF/GB filers that appear on filings.xbrl.org.
- **Yahoo oracle** (`src/sources/yahoo_oracle.jl`): add `YahooOracle.validate(:companies_house, …)`
  once `_edgar_rows`/`_edgar_metric` knows the system. Covers headline totals for **listed** UK
  companies (`.L` tickers) that also file at CH. Mind GBp/pence on price (not on fundamentals).
- **Registrar-only filers (no external oracle):** rely on (a) the CH extraction-library oracle above;
  (b) **internal consistency** — calculation-linkbase roll-ups (Assets = ΣAssets, etc.) once C3
  lands; (c) the C1 fixture's hand-verified facts as a regression anchor.
- Reminder: oracle comparisons use **raw `facts()`**, never `facts(; classify=true)` (sign differs
  on `negatedLabel` concepts) — see esef-expansion memory.

---

## 5. Manual

Populate the existing **Companies House** placeholder chapter in `docs/manual/EDGAR.tex` with **two
distinct workflows**, because the UKSEF and non-UKSEF paths differ in practice:

1. **Workflow A — UKSEF (regulated-market) filers, iXBRL.** The fully-supported CH I path:
   `set_credentials(CompaniesHouse(); api_key=…)` → `discover(CompaniesHouseApi(); company_number=…)`
   (or `CompaniesHouseBulk`) → `fetch_filing` → `facts(...)`. Note the optional FilingsXBRLOrg
   cross-check for these filers. This is the worked, runnable example.
2. **Workflow B — non-UKSEF (private/small) filers.** Same discovery/fetch entry points. When the
   account is iXBRL it flows exactly as Workflow A. When it is **PDF**, `fetch_filing` returns a
   `:pdf`-tagged filing that the XBRL extractor cannot read — extraction is **CH II** (PDF) and is
   **not yet available**. Define this workflow as a near-empty placeholder now (entry points +
   the `:pdf` outcome), to be fleshed out when CH II lands.

Also document the N4 standard-taxonomy (FRC) label/statement story under Workflow A. Keep manual edits
out of the code commits (per working style).

---

## 6. Risks / open questions (resolve during implementation)

1. **302→S3 auth leakage** on document content download (C2) — the top correctness risk.
2. **Format axis / CH II (PDF)** — confirm the `:pdf` typed outcome's shape now so CH I and CH II
   share it cleanly; the PDF extractor itself is a separate plan (also serves German Bundesanzeiger).
3. **CH oracle licence** — does a permissive (non-GPL) CH iXBRL extraction library exist (§4)? If not,
   how far does Arelle cover the CH iXBRL subset?
4. **FRC taxonomy versioning** (C3) — many yearly entry points; registry vs. DTS-walk trade-off.
5. **`vocab_ukgaap` coverage** — which FRC prefixes/concepts to seed for reliable BS/IS/CF buckets.
6. **Bulk archive shape** — `CompaniesHouseBulk` granularity (daily vs. monthly), size, and how much
   of the registrar is iXBRL vs. PDF-only in it.

---

## 7. Workflow constraints

Per [edgar-jl-working-style memory]: **ASK before running tests**; **commit only when explicitly
told**; don't run the full suite for trivial edits (batch verification once per checkpoint); be
decisive.

**Base branch (confirmed 2026-06-25):** branch off **`fix-chunkeddoc-precompile`**, *not* `main`. The
entire FilingSystem seam, ESEF, the discovery layer, and the validation oracles that CH builds on are
the 11 commits on `fix-chunkeddoc-precompile`, which is **not merged and not pushed** (no
`origin/fix-chunkeddoc-precompile` yet). `main` (`faca596`) has none of it. Alternative: merge
`fix-chunkeddoc-precompile` → `main` first, then branch CH off `main` — the user's call.
