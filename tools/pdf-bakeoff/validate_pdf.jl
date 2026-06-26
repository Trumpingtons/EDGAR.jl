# P3 — twin-validation harness for the PDF extractor. For each dual-format filer, take the iXBRL twin's
# facts as ground truth and ask: did extract_pdf recover them? Matching is by (period_end, value within
# tolerance) — value-based, so it sidesteps the label<->concept gap and measures pure number recovery.
# Run from tools/pdf-bakeoff/:  julia --project=../.. validate_pdf.jl
using EDGAR, Dates, Printf

const TWINS = [
    ("Tesco FY24",    "../../test/data/pdf/raw/tesco_2024.pdf",    "../../test/data/pdf/raw/tesco_2024_ixbrl.zip"),
    ("Vodafone FY25", "../../test/data/pdf/raw/vodafone_2025.pdf", "../../test/data/pdf/raw/vodafone_2025_ixbrl.zip"),
]
const PRIMARY = ("BalanceSheet", "IncomeStatement", "CashFlow")
nodim(r) = isempty(r.dimensions) || r.dimensions == "{}"
near(a, b) = abs(a - b) <= 0.005 * max(abs(b), 1.0)   # 0.5% tolerance

function run_twin(name, pdf, zip)
    truth = [r for r in facts(fetch_filing(ESEF(), abspath(zip)); classify = true)
             if nodim(r) && r.statement in PRIMARY && r.value != 0.0]
    pdf = try
        extract_pdf(abspath(pdf))
    catch e
        @warn "extract_pdf failed for $name" exception = e
        return
    end
    recovered(t) = any(p -> p.period_end == t.period_end && near(p.value, t.value), pdf)
    println("\n══ $name ══  iXBRL primary/undim facts = $(length(truth))  ·  PDF facts = $(length(pdf))")
    total_m = total_n = 0
    for s in PRIMARY
        ts = [t for t in truth if t.statement == s]
        isempty(ts) && continue
        m = count(recovered, ts); total_m += m; total_n += length(ts)
        @printf("   %-16s recall %3d/%-3d  (%3.0f%%)\n", s, m, length(ts), 100m / length(ts))
    end
    @printf("   %-16s recall %3d/%-3d  (%3.0f%%)\n", "TOTAL", total_m, total_n, total_n == 0 ? 0 : 100total_m / total_n)
    # precision proxy: PDF facts not matching any primary/undim truth (period,value)
    fp = count(p -> !any(t -> t.period_end == p.period_end && near(p.value, t.value), truth), pdf)
    @printf("   PDF facts unmatched to primary truth: %d/%d (noise / dimensioned / notes)\n", fp, length(pdf))
end

for (n, p, z) in TWINS
    run_twin(n, p, z)
end
