using Test
using EDGAR

# Extraction against a real 10-K (Apple Inc., accession 0000320193-25-000079),
# trimmed to head + table of contents + Item 1 (Business) and Item 1A (Risk
# Factors). This exercises the parts synthetic fixtures cannot: a real multi-link
# TOC (each row is "Item 1A." / "Risk Factors" / page-number links to one target),
# &#160; (NBSP) labels, deep nesting, and inline-XBRL tags interleaved with text.
@testset "real_10k_extract" begin
    sample_path = joinpath(@__DIR__, "data", "apple_10k_trimmed.html")
    html = read(sample_path, String)
    sections = EDGAR.extract_section(html, ["Item 1.", "Item 1A"])

    item1 = get(sections, "Item 1.", "")
    item1a = get(sections, "Item 1A", "")

    # One snapshot of the properties that matter: both found, each starts at its
    # own heading, Item 1 stops at the Item 1A boundary (no bleed), and Item 1A is
    # the full, substantial Risk Factors section.
    summary = (
        found        = (haskey(sections, "Item 1."), haskey(sections, "Item 1A")),
        item1_starts = startswith(item1, "Item 1. Business"),
        item1_nobleed = !occursin(r"(?i)Item 1A\.\s*Risk Factors", item1),
        item1a_starts = startswith(item1a, "Item 1A. Risk Factors"),
        item1a_full  = length(item1a) > 10_000 && occursin("material adverse", lowercase(item1a)),
    )
    @test summary == (
        found        = (true, true),
        item1_starts = true,
        item1_nobleed = true,
        item1a_starts = true,
        item1a_full  = true,
    )
end
