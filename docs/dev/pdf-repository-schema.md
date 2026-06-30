# Design — the PDF document repository: StructuredDocument JSON + DuckDB schema + filesystem

Status: **draft for review** (2026-06-29). The contract the document-first PDF pipeline hangs off, per the
decisions in [pdf-extractor-plan.md](pdf-extractor-plan.md) §1a. **No code yet — review this first.**

Governing decisions (settled): save **all** of {sections, text, tables, figures}; **general** pipeline +
per-jurisdiction **profile**; **one** repository `.duckdb` with **normalized `table_cells`**; **canonical
store is the original language**, translation is a deferred derived layer. Build order: **(1) repository
(SQL + full-text search free) → (2) facts → (3) semantic RAG/Q&A**.

Three layers, one source of truth:
- **`structured.json`** per document — the **canonical** parser output (system of record). Everything else
  is derived from it and can be rebuilt.
- **Filesystem artefacts** — human/tool-facing renders (`document.md`, `tables/*.csv`, `figures/*.png`).
- **DuckDB repository** — the queryable relational index across *all* documents (SQL + FTS now;
  text-to-SQL for the RAG agent later).

---

## 1. Filesystem layout

Rooted at **`~/RegulatoryReports/`** (configurable) — a **fresh** repository we build from scratch.
(The earlier `~/EDGAR-Reports/` stays as-is: an ad-hoc stash of the test PDFs used to validate the parser;
it is *not* the repository.) Originals stay at the root; derived artefacts live under `derived/<doc_id>/`;
one DB indexes everything.

```
~/RegulatoryReports/
├── DE-VolkswagenAGFR2023.pdf            # original (canonical INPUT), <CC>-<Company>FR<year>.pdf
├── CN-VankeFR2023.pdf
├── regulatory-reports.duckdb            # the ONE repository DB (indexes all docs)
└── derived/
    └── DE-VolkswagenAGFR2023/           # folder name == doc_id
        ├── structured.json              # canonical StructuredDocument (system of record)
        ├── document.md                  # markdown render (reading + RAG source text)
        ├── tables/
        │   ├── tbl1.csv                 # convenience mirror of table_cells
        │   └── tbl2.csv
        └── figures/
            └── fig1.png                 # extracted image bytes
```

`doc_id` = the PDF filename stem (e.g. `DE-VolkswagenAGFR2023`) — stable, human-readable, unique. The
loader **namespaces** the per-document ids (`s1`/`t1`/… in the JSON) as `<doc_id>:<localid>` so all PKs are
globally unique across the repository.

---

## 2. `StructuredDocument` JSON (produced by `EDGAR.structured_document`)

> **BUILT (2026-06-29):** `EDGAR.structured_document(pdf; …)` drives Docling **in-process via PythonCall**
> (the `EDGARDoclingExt` package extension — PythonCall is an optional weakdep, so the core stays
> Python-free for Pollis), returns a Julia `StructuredDocument`, and `persist_document` writes the JSON +
> `document.md` + `tables/*.csv` below. Verified on Tesco (9 sections / 25 text / 6 tables / 2 figures;
> equity 11,671/12,236 round-trips). Not a standalone Python script — Julia code.


One JSON per document. Coordinates are PDF points, origin **top-left** (matching `pdf_words.mjs`); every
element carries `page` + `bbox` and a global `ord` (monotonic reading order, so the doc can be linearized).
`lang` is per-element (usually the doc language; differs for bilingual reports).

```jsonc
{
  "schema_version": "1.0",
  "document": {
    "doc_id":        "DE-VolkswagenAGFR2023",
    "source_path":   "/Users/antonio/RegulatoryReports/DE-VolkswagenAGFR2023.pdf",
    "jurisdiction":  "DE",            // ISO country; from filename/profile/FilingSystem
    "filing_system": null,            // optional EDGAR.jl FilingSystem tag
    "language":      "de",            // primary detected language (ISO 639-1)
    "company":       "Volkswagen AG", // best-effort, nullable
    "report_type":   "annual_report", // best-effort, nullable
    "fiscal_year":   2023,            // nullable
    "currency":      "EUR",           // nullable
    "framework":     "HGB",           // HGB | IFRS | null
    "n_pages":       294,
    "parser":        "docling",
    "parser_version":"2.107.0",
    "ocr":           false
  },

  "sections": [
    { "section_id":"s1", "parent_id":null, "level":1,
      "title":"Bilanz der Volkswagen AG zum 31. Dezember 2023",
      "lang":"de", "ord":120, "page_start":3, "page_end":3,
      "bbox":{"page":3,"x0":56.7,"y0":78.2,"x1":402.1,"y1":94.0} }
  ],

  "text_blocks": [
    { "block_id":"t1", "section_id":"s1", "ord":121, "kind":"paragraph",
      "text":"…", "lang":"de", "page":3,
      "bbox":{"page":3,"x0":56.7,"y0":110.0,"x1":540.0,"y1":172.4}, "char_len":412 }
  ],                                   // kind: paragraph | list_item | caption | footnote

  "tables": [
    { "table_id":"tbl1", "section_id":"s1", "ord":122,
      "kind":"unknown",               // statement | descriptive | unknown  (set by the SEMANTIC layer, not the parser)
      "statement_type":null,          // balance_sheet|income_statement|cash_flow|equity_changes|null
      "caption":null, "lang":"de", "page_start":3, "page_end":4,
      "bbox":{"page":3,"x0":56.0,"y0":180.0,"x1":545.0,"y1":690.0},
      "n_rows":27, "n_cols":4,
      "cells":[
        {"row":0,"col":0,"rowspan":1,"colspan":1,"is_header":true, "text":"Aktiva"},
        {"row":1,"col":0,"rowspan":1,"colspan":1,"is_header":false,"text":"Anlagevermögen"},
        {"row":1,"col":1,"rowspan":1,"colspan":1,"is_header":false,"text":"123.456"}
      ]
    }
  ],

  "figures": [
    { "figure_id":"fig1", "section_id":"s5", "ord":300, "caption":"…",
      "page":12, "bbox":{"page":12,"x0":60,"y0":120,"x1":520,"y1":430},
      "image_path":"figures/fig1.png", "image_format":"png", "width":1840, "height":1020 }
  ]
}
```

**Parser vs semantic layer.** The parser emits structure only. `kind`/`statement_type` (which tables are
BS/IS/CF), `framework`, `company`, `fiscal_year`, etc. are **null/unknown at parse time** and filled by a
later **classification pass** that consults the per-jurisdiction **profile** (language, statement-heading
patterns, number locale, section taxonomy). This keeps `docling_extract.py` general and language-agnostic.

---

## 3. DuckDB schema (the repository)

> **BUILT (2026-06-29):** `EDGAR.to_repository(sd_or_json_path, db)` (DuckDB package extension) creates
> this schema + the §3a views and loads a `StructuredDocument` idempotently (re-load replaces the doc's
> rows). Implemented in `ext/EDGARDuckDBExt.jl`; `bbox` stored as JSON text (VARCHAR); `"tables"`/`"row"`/
> `"col"` quoted. Verified on Tesco → `~/RegulatoryReports/regulatory-reports.duckdb` (9 sections / 25 text
> / 6 tables / 1121 cells / 2 figures); `v_cell_context` resolves `11,671` → section *Group balance sheet*,
> page 133.


One DB for all documents. Clean, LLM-legible names (the RAG agent will text-to-SQL against this). `bbox`
columns are JSON `{page,x0,y0,x1,y1}`. **The original-language text always lives here; translations are a
separate table.**

```sql
CREATE TABLE documents (
  doc_id         TEXT PRIMARY KEY,
  source_path    TEXT NOT NULL,
  jurisdiction   TEXT,            -- 'DE','CN','GB',…
  filing_system  TEXT,            -- optional EDGAR.jl FilingSystem tag
  language       TEXT,            -- ISO 639-1
  company        TEXT,
  report_type    TEXT,
  fiscal_year    INTEGER,
  currency       TEXT,
  framework      TEXT,            -- 'HGB','IFRS',…
  n_pages        INTEGER,
  parser         TEXT,
  parser_version TEXT,
  ocr            BOOLEAN,
  ingested_at    TIMESTAMP
);

CREATE TABLE sections (              -- heading tree (self-referential)
  section_id  TEXT PRIMARY KEY,
  doc_id      TEXT NOT NULL REFERENCES documents(doc_id),
  parent_id   TEXT REFERENCES sections(section_id),
  level       INTEGER,
  title       TEXT,
  lang        TEXT,
  ord         INTEGER,             -- reading order
  page_start  INTEGER,
  page_end    INTEGER,
  bbox        JSON
);

CREATE TABLE text_blocks (           -- narrative segments (the FTS / RAG unit)
  block_id    TEXT PRIMARY KEY,
  doc_id      TEXT NOT NULL REFERENCES documents(doc_id),
  section_id  TEXT REFERENCES sections(section_id),
  ord         INTEGER,
  kind        TEXT,                 -- paragraph|list_item|caption|footnote
  text        TEXT,                 -- ORIGINAL language
  lang        TEXT,
  page        INTEGER,
  bbox        JSON,
  char_len    INTEGER
);

CREATE TABLE tables (
  table_id       TEXT PRIMARY KEY,
  doc_id         TEXT NOT NULL REFERENCES documents(doc_id),
  section_id     TEXT REFERENCES sections(section_id),
  ord            INTEGER,
  kind           TEXT,             -- statement|portfolio|…|descriptive|unknown  (the class's kind; semantic layer)
  statement_type TEXT,             -- balance_sheet|income_statement|cash_flow|equity_changes|null
  caption        TEXT,
  lang           TEXT,
  page_start     INTEGER,
  page_end       INTEGER,
  bbox           JSON,
  n_rows         INTEGER,
  n_cols         INTEGER,
  csv_path       TEXT              -- 'tables/tbl1.csv' (convenience mirror)
);

CREATE TABLE table_cells (           -- normalized, SQL-queryable
  table_id  TEXT NOT NULL REFERENCES tables(table_id),
  row       INTEGER NOT NULL,
  col       INTEGER NOT NULL,
  rowspan   INTEGER DEFAULT 1,
  colspan   INTEGER DEFAULT 1,
  is_header BOOLEAN DEFAULT FALSE,
  text      TEXT,                  -- ORIGINAL language
  PRIMARY KEY (table_id, row, col)
);

CREATE TABLE figures (
  figure_id    TEXT PRIMARY KEY,
  doc_id       TEXT NOT NULL REFERENCES documents(doc_id),
  section_id   TEXT REFERENCES sections(section_id),
  ord          INTEGER,
  caption      TEXT,
  page         INTEGER,
  bbox         JSON,
  image_path   TEXT,              -- 'figures/fig1.png'
  image_format TEXT,
  width        INTEGER,
  height       INTEGER
);

-- Deferred derived layer. Original text NEVER leaves the source tables; translations accrue here.
CREATE TABLE translations (
  object_type TEXT NOT NULL,       -- 'section'|'text_block'|'table_cell'|'figure'
  object_id   TEXT NOT NULL,       -- section_id/block_id/figure_id; cell = '<table_id>:<row>:<col>'
  target_lang TEXT NOT NULL,
  text        TEXT,
  source      TEXT,                -- 'dict'|'local-llm'|'cloud-llm'
  model       TEXT,
  created_at  TIMESTAMP,
  PRIMARY KEY (object_type, object_id, target_lang)
);

-- Build step 2 (facts) — STUB, shown for shape only; not populated by the repository build.
CREATE TABLE facts (
  fact_id          TEXT PRIMARY KEY,
  doc_id           TEXT NOT NULL REFERENCES documents(doc_id),
  table_id         TEXT REFERENCES tables(table_id),     -- source table
  row              INTEGER,        -- + col: the EXACT source cell; (table_id,row,col) -> table_cells
  col              INTEGER,
  section_id       TEXT REFERENCES sections(section_id),  -- denormalized from the source table (direct filtering)
  statement_type   TEXT,
  label            TEXT,           -- original line-item label
  concept          TEXT,           -- synthesized/normalized
  standard_concept TEXT,           -- W4 cross-filing key
  period_start     DATE,
  period_end       DATE,
  is_instant       BOOLEAN,
  value            DOUBLE,
  unit             TEXT,
  scale            DOUBLE,
  sign             INTEGER,
  decimals         INTEGER,
  extractor        TEXT,
  confidence       DOUBLE,
  bbox             JSON
);

-- Full-text search comes "for free" once text_blocks is loaded:
--   INSTALL fts; LOAD fts;
--   PRAGMA create_fts_index('text_blocks', 'block_id', 'text');
-- then: SELECT … FROM (SELECT *, fts_main_text_blocks.match_bm25(block_id, 'sustainability') AS score …)
```

---

## 3a. Referencing — every number → its cell → table → section/subsection

A number must always be traceable to *where it appears*, with **no storage redundancy**. The FK chain
already gives it: `facts.(table_id,row,col) → table_cells → tables.section_id → sections (parent_id tree)`.
These **views** make it ergonomic (and feed the back-link + the text-to-SQL agent):

```sql
-- a cell with its table + section context
CREATE VIEW v_cell_context AS
SELECT c.table_id, c.row, c.col, c.is_header, c.text,
       t.doc_id, t.section_id, t.kind AS table_kind, t.statement_type, t.page_start AS page
FROM table_cells c JOIN tables t USING (table_id);

-- the section breadcrumb, e.g. "Konzernabschluss > Konzernbilanz"
CREATE VIEW v_section_path AS
WITH RECURSIVE p(section_id, doc_id, path) AS (
  SELECT section_id, doc_id, title FROM sections WHERE parent_id IS NULL
  UNION ALL
  SELECT s.section_id, s.doc_id, p.path || ' > ' || s.title
  FROM sections s JOIN p ON s.parent_id = p.section_id
)
SELECT section_id, doc_id, path FROM p;

-- a fact with full provenance: exact cell + table + section path
CREATE VIEW v_fact_provenance AS
SELECT f.fact_id, f.doc_id, f.label, f.value, f.statement_type,
       f.table_id, f.row, f.col, f.section_id, sp.path AS section_path, f.bbox
FROM facts f LEFT JOIN v_section_path sp USING (section_id);
```

So "which section does this number live in?" and "give me every number in the balance-sheet table under
*Konzernabschluss*" are one-liners. Text-block numbers (numbers in prose) carry their own `section_id`
directly, so the same section reference works for them too.

---

## 4. Notes / rationale

- **One source of truth.** `structured.json` is canonical; the DB rows, CSVs and PNGs are all
  reproducible from it. Re-ingest = drop the doc's rows + rewrite the derived folder.
- **Provenance everywhere.** Every section/block/table/figure (and later fact) carries `page` + `bbox` →
  the Pollis back-link to the source pixel.
- **Language.** Source tables hold the **original** text; `lang` records it. `translations` is additive —
  `dict`/precomputed for accounting-label display, `local-llm` (default) or `cloud-llm` (Claude) for prose,
  computed later, never at ingestion.
- **General + profile.** This schema is **jurisdiction-agnostic**; `jurisdiction`/`language` are columns
  that *select* the per-jurisdiction profile used by the classification pass (statement detection, locale,
  vocabulary). Nothing here is DE/CN/JP-specific.
- **Text-to-SQL friendliness (for build step 3).** Names are explicit and stable so the RAG agent can both
  retrieve prose (FTS/embeddings over `text_blocks`) *and* emit SQL over `tables`/`table_cells`/`facts` —
  the hybrid fuzzy-NL + SQL query you described.
- **`facts` is deferred.** Shown only so the document schema and the later facts derivation fit together;
  build step 1 does **not** populate it.

## Resolved (agreed 2026-06-29)
1. `bbox` → **JSON column** `{page,x0,y0,x1,y1}`.
2. Keep **both** `tables/*.csv` and `table_cells` — the CSV is a convenience mirror of the cells.
3. Derived artefacts under a **visible `derived/`**.
4. `doc_id` = **filename stem**.
5. Repository root is **`~/RegulatoryReports/`** (new, built from scratch); the legacy `~/EDGAR-Reports/`
   test stash is kept untouched and is *not* the repository.
6. **Referencing** (your requirement): facts carry the **exact source cell** `(table_id,row,col)` and the
   **section** (`section_id` + the `v_section_path` breadcrumb); cells reach their section via
   `v_cell_context`. No denormalized duplication — it's the FK chain + views.
