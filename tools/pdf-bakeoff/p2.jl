# P2.1/P2.2 prototype — on top of P1's geometry, read the HEADER row(s) to give each column its
# MEANING (period date vs analysis column) and detect the scale (£m, etc). Run from tools/pdf-bakeoff/:
#   julia --project=../.. p2.jl <pdf> <page>
using JSON3, Dates

const PDF  = length(ARGS) >= 1 ? ARGS[1] : "../../test/data/pdf/raw/tesco_2024.pdf"
const PAGE = length(ARGS) >= 2 ? ARGS[2] : "133"

function parse_num(s)
    t = strip(s); t = replace(t, r"[*†‡]+$" => "")
    (t in ("–","-","—","")) && return (val=0.0, nil=true)
    neg = startswith(t,"(") && endswith(t,")"); t = strip(t, ['(',')'])
    t = replace(replace(t, "," => ""), r"[£$€]" => "")
    v = tryparse(Float64, t); v === nothing && return nothing
    return (val = neg ? -v : v, nil=false)
end
isnumlike(s) = parse_num(s) !== nothing

json = JSON3.read(read(`node pdf_words.mjs $PDF $PAGE`, String))
pg = json.pages[1]
W = [(x=Float64(w.x), y=Float64(w.y), w=Float64(w.w), h=Float64(w.h), str=String(w.str)) for w in pg.words]

# rows by y-bin
function rows(ws; ytol=3.5)
    ws = sort(ws; by=w->(w.y,w.x)); out=Vector{typeof(ws)}(); cur=similar(ws,0); cy=nothing
    for w in ws
        if cy===nothing || abs(w.y-cy)<=ytol; push!(cur,w); cy = cy===nothing ? w.y : cy
        else push!(out, sort(cur;by=t->t.x)); cur=[w]; cy=w.y end
    end
    isempty(cur)||push!(out, sort(cur;by=t->t.x)); out
end
# period columns by numeric right-edge bands
function columns(ws; xmin=400.0, gap=12.0)
    e = sort([w.x+w.w for w in ws if w.x>=xmin && isnumlike(w.str) && !parse_num(w.str).nil])
    isempty(e) && return Float64[]
    b=[[e[1]]]; for x in e[2:end]; (x-b[end][end])<=gap ? push!(b[end],x) : push!(b,[x]) end
    [sum(c)/length(c) for c in filter(c->length(c)>=4,b)]
end

R = rows(W); cols = columns(W)
center(w) = w.x + w.w/2

# --- P2.2 scale: scan all text for a units/scale marker ---
alltext = join((w.str for w in W), " ")
scale = occursin(r"£\s?m\b|£\s?million|in £m|£ million"i, alltext) ? "£m (millions)" :
        occursin(r"£\s?000|£\s?thousand|TEUR|in Tausend"i, alltext) ? "thousands" : "unknown"

# --- the body starts at the first row with numbers ALIGNED TO THE COLUMN BANDS (excludes page
# numbers / margins that happen to be numeric but sit outside the columns) ---
incol(w) = !isempty(cols) && minimum(abs.(cols .- (w.x + w.w))) <= 14
isbodyrow(r) = count(w -> isnumlike(w.str) && incol(w), r) >= max(1, length(cols)-1)
firstbody = findfirst(isbodyrow, R)

# --- P2.1 header: rows above the body; pull period descriptors (a date, or a bare year) and map to columns ---
DATE = r"\d{1,2}\s+\p{L}+\s+\d{4}"
YEAR = r"\b(19|20)\d{2}\b"
function parse_period(s)
    m = match(DATE, s)
    if m !== nothing
        d = tryparse(Date, m.match, dateformat"d U yyyy"); d!==nothing && return string(d)
    end
    m = match(YEAR, s); m!==nothing && return m.match
    return nothing
end

println("page $(pg.page)  scale=$scale  columns(right-edge)=", round.(Int, cols))
colperiod = fill("?", length(cols))
colother  = ["" for _ in cols]
for r in R[1:(firstbody===nothing ? length(R) : firstbody-1)]
    for w in r
        isempty(strip(w.str)) && continue
        i = isempty(cols) ? 0 : argmin(abs.(cols .- center(w)))
        (i==0 || abs(cols[i]-center(w))>40) && continue
        p = parse_period(w.str)
        if p !== nothing && colperiod[i]=="?"; colperiod[i]=p
        elseif p===nothing && !isnumlike(w.str) && length(strip(w.str))>3 && isempty(colother[i]); colother[i]=strip(w.str) end
    end
end
for i in 1:length(cols)
    lbl = colperiod[i]!="?" ? "PERIOD $(colperiod[i])" : (isempty(colother[i]) ? "(no header)" : "ANALYSIS “$(colother[i])”")
    println("  col$i  →  $lbl")
end

# --- P2.3 (start): emit period-anchored, coordinate-bearing fact records from the body ---
# Only columns resolved to a PERIOD become facts; analysis/unknown columns are skipped (semantics TODO).
periodcol = [i for i in 1:length(cols) if colperiod[i] != "?"]
assign(w) = (e=w.x+w.w; i=isempty(cols) ? 0 : argmin(abs.(cols .- e)); abs(cols[i]-e)<=14 ? i : 0)
println("\nproto-facts (label · period · value£m · bbox) — equity section:")
for r in (firstbody===nothing ? R : R[firstbody:end])
    label = strip(join([w.str for w in r if w.x<360 && !isnumlike(w.str)], " "))
    (isempty(label) || !occursin(r"equity|net assets|share capital|share premium|reserves|retained earnings|non-controlling"i, label)) && continue
    for w in r
        isnumlike(w.str) || continue
        i = assign(w); (i==0 || !(i in periodcol)) && continue
        p = parse_num(w.str); p.nil && continue
        println("  ", rpad(first(label,38),40), " · ", colperiod[i], " · ",
                lpad(string(Int(p.val)),8), " · (p$(pg.page) x$(round(Int,w.x)) y$(round(Int,w.y)) w$(round(Int,w.w)) h$(round(Int,w.h)))")
    end
end
