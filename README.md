EDGAR.jl — Minimal Julia scaffold for SEC EDGAR ingestion

Quick start

1. Activate the project and add dependencies:

```bash
cd ~/EDGAR.jl
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.add(["HTTP","JSON3"])'
```

2. Edit `src/EDGAR.jl` and set `USER_AGENT` to include your contact email.

3. List recent filings for a CIK (example: Apple `0000320193`):

```bash
julia --project=. -e 'using EDGAR; EDGAR.main(["0000320193", "5"])'
```

4. Download, parse and save a filing (example accession):

```bash
julia --project=. scripts/download_and_save.jl 0000320193 0000320193-23-000052 output
```

-Notes

- **Minimum Julia:** EDGAR.jl requires Julia 1.12 or later; CI runs on Julia 1.12.

- SEC requires a descriptive `User-Agent` with contact information; update `USER_AGENT` accordingly.
- The parsing is a lightweight HTML -> text conversion. Consider adding `Gumbo.jl` and `Cascadia.jl` for robust extraction.
 - The parsing prefers `Gumbo.jl` + `Cascadia.jl` when available for more robust HTML extraction. To enable:

```bash
julia --project=. -e 'using Pkg; Pkg.add(["Gumbo","Cascadia"])'
```

When present, `EDGAR.parse_filing` will use Gumbo to target the document body and then extract visible text; otherwise a safe tag-stripping fallback is used.

Section extraction

You can extract specific sections (for example, "Management's Discussion" or "Item 7") from the parsed filing text using `EDGAR.extract_section`:

```julia
using EDGAR
text = EDGAR.parse_filing("filings/0000320193-0000000000-sample.html")
sections = EDGAR.extract_section(text, ["Item 7", "Management's Discussion"])
println(sections["Item 7"]) # prints the Item 7 text if found
```

The extractor searches for the provided names (case-insensitive) and returns the substring up to the next "Item N" boundary. It's a heuristic; for more precise extraction consider enhancing the matcher list or adding Cascadia-based selectors for consistent heading markup.
- Tests in `test/` make network requests; in CI you may want to mock HTTP responses.
