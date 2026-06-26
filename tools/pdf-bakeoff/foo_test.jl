# Stress test — Camelot's foo.pdf (wrapped + spanning multi-row header). Shows: body y-clustering is
# fine; the fix for multi-row headers is to group header tokens by x-band and stack top->bottom.
using JSON3
const PDF = "../../test/data/pdf/raw/foo.pdf"
json = JSON3.read(read(`node pdf_words.mjs $PDF 1`, String))
W = [(x=Float64(w.x), y=Float64(w.y), w=Float64(w.w), str=String(w.str)) for w in json.pages[1].words]
center(w) = w.x + w.w/2
isnum(s) = occursin(r"^\(?-?[\d.,]+%?\)?$", strip(s))

# rows by y
function rowsof(W)
    ws = sort(W; by=w->(w.y,w.x)); R=Vector{Vector{eltype(W)}}(); cur=eltype(W)[]; cy=nothing
    for w in ws
        if cy===nothing || abs(w.y-cy)<=3; push!(cur,w); cy=cy===nothing ? w.y : cy
        else push!(R, sort(cur;by=t->t.x)); cur=[w]; cy=w.y end
    end
    isempty(cur)||push!(R, sort(cur;by=t->t.x)); R
end
R = rowsof(W)

# body rows = the data rows (>=4 numeric cells); derive column bands from their cell centers
body = [r for r in R if count(t->isnum(t.str), r) >= 4]
centers = sort([center(t) for r in body for t in r])
bands=[[centers[1]]]; for c in centers[2:end]; (c-bands[end][end])<=20 ? push!(bands[end],c) : push!(bands,[c]) end
band = [sum(b)/length(b) for b in bands]
println("body rows: $(length(body)) | columns detected: $(length(band)) @ x≈", round.(Int,band))

# header region = rows above the first body row but below the caption ("Table 2-1.")
firstbody = findfirst(r->count(t->isnum(t.str),r)>=4, R)
capidx    = findlast(r->any(t->occursin("Table 2-1.", t.str), r), R[1:firstbody])
hdr = R[(capidx===nothing ? 1 : capidx+1):firstbody-1]

# spanning header = a token whose center is far from every band edge AND sits above the others
# per-band header = assign each header token to nearest band, concatenate top->bottom (by y)
colhdr = ["" for _ in band]; spanning = String[]
for r in hdr, t in r
    isempty(strip(t.str)) && continue
    covered = count(b -> t.x <= b <= t.x + t.w, band)   # a token spanning >=2 band centres is a span
    if covered >= 2
        push!(spanning, strip(t.str)); continue
    end
    i = argmin(abs.(band .- center(t)))
    if abs(band[i]-center(t)) <= 28
        colhdr[i] = isempty(colhdr[i]) ? strip(t.str) : colhdr[i]*" "*strip(t.str)
    else
        push!(spanning, strip(t.str))
    end
end
println("\nreconstructed column headers (multi-row merged by x-band):")
for i in 1:length(band); println("  col$i  ≈x$(round(Int,band[i]))  →  \"$(colhdr[i])\""); end
isempty(spanning) || println("\nspanning header(s): ", join(spanning, " | "))

println("\nfirst data row keyed by header:")
r1 = body[1]
for t in r1
    i = argmin(abs.(band .- center(t)))
    println("  ", rpad(colhdr[i],20), " = ", t.str)
end
