# iXBRL decimal-comma parsing — split into small, individually-runnable testsets.
#
# Run just these (fast):   julia --project=. test/test_decimal_comma.jl
# Also `include`d by runtests.jl as part of the full suite.
#
# Background: European filers tag numbers with the comma as the DECIMAL separator
# (format "ixt:num-comma-decimal") and dot/space as thousands grouping — the opposite of the US
# default. Regression for a bug where the decimal comma was stripped like a thousands separator,
# scaling the value by 10ⁿ (e.g. an EPS of "0,12" parsed as 12). Found via the Nokia ESEF cross-check.

using Test
using EDGAR
using Dates

# Build a one-fact inline-XBRL document and return the parsed Float64 value, so each case below reads
# as "displayed text (with this format/scale/sign) → the value EDGAR.jl extracts".
function _dc_pv(valtext; fmt = "ixt:num-comma-decimal", scale = "0", sign = "")
    signattr = isempty(sign) ? "" : " sign=\"$sign\""
    ix = """<html><body><ix:header><ix:resources>
    <xbrli:context id="d1"><xbrli:entity><xbrli:identifier scheme="x">L</xbrli:identifier></xbrli:entity><xbrli:period><xbrli:instant>2025-12-31</xbrli:instant></xbrli:period></xbrli:context>
    <xbrli:unit id="eur"><xbrli:measure>iso4217:EUR</xbrli:measure></xbrli:unit>
    </ix:resources></ix:header>
    <ix:nonFraction name="x:V" contextRef="d1" unitRef="eur" decimals="2" format="$fmt" scale="$scale"$signattr id="f1">$valtext</ix:nonFraction>
    </body></html>"""
    f = EDGAR.Filing(ESEF(), EntityId(:lei, "L"), "ref", "d.xhtml", "https://x/d.xhtml", :ixbrl, ix)
    rows = facts(f)
    return isempty(rows) ? nothing : only(rows).value
end

@testset "decimal-comma: comma becomes the decimal point" begin
    @test _dc_pv("0,12") ≈ 0.12          # the EPS case that exposed the bug — NOT 12
    @test _dc_pv("3,5") ≈ 3.5
    @test _dc_pv("0") ≈ 0.0
end

@testset "decimal-comma: thousands separators dropped" begin
    @test _dc_pv("1.234.567,89") ≈ 1234567.89
    @test _dc_pv("1 234 567,89") ≈ 1234567.89
    @test _dc_pv("1\u00a0234,5") ≈ 1234.5          # non-breaking space
    @test _dc_pv("1.234") ≈ 1234.0                  # whole number: dot is grouping, no fraction
end

@testset "decimal-comma: negatives" begin
    @test _dc_pv("(1.234,56)") ≈ -1234.56           # parentheses
    @test _dc_pv("0,45"; sign = "-") ≈ -0.45        # iXBRL sign="-" attribute
end

@testset "decimal-comma: scale applied after normalisation" begin
    @test _dc_pv("1,5"; scale = "6") ≈ 1.5e6
    @test _dc_pv("-2,5"; scale = "3") ≈ -2500.0
end

@testset "decimal-comma: dot-decimal default unchanged (US filers)" begin
    @test _dc_pv("1,234.56"; fmt = "ixt:num-dot-decimal") ≈ 1234.56
    @test _dc_pv("1,234,567"; fmt = "") ≈ 1234567.0
end
