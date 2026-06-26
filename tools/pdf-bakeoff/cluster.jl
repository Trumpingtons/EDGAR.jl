# P1.3 prototype — pdfjs words JSON -> row/column reconstruction -> coordinate-anchored cells.
# Node parses (pdf_words.mjs); Julia does the geometry + number semantics. Run from tools/pdf-bakeoff/:
#   julia --project=../.. cluster.jl <pdf> <page>
using JSON3

const PDF  = length(ARGS) >= 1 ? ARGS[1] : "../../test/data/pdf/raw/tesco_2024.pdf"
const PAGE = length(ARGS) >= 2 ? ARGS[2] : "133"

# --- number semantics (the moat, minimal v1): parentheses = negative, strip £/commas, en-dash = nil ---
function parse_num(s::AbstractString)
    t = strip(s)
    t = replace(t, r"[*†]+$" => "")               # footnote markers
    (t in ("–", "-", "—", "")) && return (val=0.0, nil=true)
    neg = startswith(t, "(") && endswith(t, ")")
    t = strip(t, ['(', ')'])
    t = replace(t, "," => "")
    t = replace(t, r"[£$€]" => "")
    v = tryparse(Float64, t)
    v === nothing && return nothing                # not a number
    return (val = neg ? -v : v, nil = false)
end
isnumlike(s) = parse_num(s) !== nothing

# --- fetch positioned words for one page via the Node helper ---
json = JSON3.read(read(`node pdf_words.mjs $PDF $PAGE`, String))
pg = json.pages[1]
words = [(x=Float64(w.x), y=Float64(w.y), w=Float64(w.w), h=Float64(w.h), str=String(w.str)) for w in pg.words]
println("page $(pg.page)  $(pg.width)x$(pg.height)  $(length(words)) words")

# --- rows: cluster by y (tolerance ~ half a line) ---
function rows(words; ytol=3.5)
    ws = sort(words; by = w -> (w.y, w.x))
    out = Vector{typeof(ws)}(); cur = similar(ws, 0); cy = nothing
    for w in ws
        if cy === nothing || abs(w.y - cy) <= ytol
            push!(cur, w); cy = cy === nothing ? w.y : cy
        else
            push!(out, sort(cur; by=t->t.x)); cur = [w]; cy = w.y
        end
    end
    isempty(cur) || push!(out, sort(cur; by=t->t.x))
    return out
end

# --- period columns: cluster right-edges of numeric tokens that sit right of the label/notes area ---
function period_columns(words; xmin=400.0, gap=12.0)
    edges = sort([w.x + w.w for w in words if w.x >= xmin && isnumlike(w.str) && !parse_num(w.str).nil])
    isempty(edges) && return Float64[]
    bands = [[edges[1]]]
    for e in edges[2:end]
        (e - bands[end][end]) <= gap ? push!(bands[end], e) : push!(bands, [e])
    end
    bands = filter(b -> length(b) >= 4, bands)         # real columns recur down the statement
    return [sum(b)/length(b) for b in bands]           # band centres (right-edges), left->right
end

cols = period_columns(words)
println("detected $(length(cols)) period columns @ right-edges ≈ ", round.(Int, cols))

# --- assemble grid: per row, label (left text) + a value per column (nearest right-edge) ---
assign(w, cols) = (e = w.x + w.w; i = argmin(abs.(cols .- e)); abs(cols[i]-e) <= 14 ? i : 0)

println("\nlabel".*" "^36, "  ", join(["col$i" for i in 1:length(cols)], "      "))
for r in rows(words)
    labels = [w.str for w in r if w.x < 360 && !isnumlike(w.str)]
    label = strip(join(labels, " "))
    vals = Vector{Union{Nothing,Float64}}(nothing, length(cols))
    bbox = Vector{Any}(nothing, length(cols))
    for w in r
        isnumlike(w.str) || continue
        i = assign(w, cols); i == 0 && continue
        p = parse_num(w.str); p.nil && continue
        vals[i] = p.val; bbox[i] = (page=pg.page, x=w.x, y=w.y, w=w.w, h=w.h)
    end
    (all(isnothing, vals) && isempty(label)) && continue
    any(!isnothing, vals) || continue                  # show value rows only
    vs = join([v === nothing ? "   ." : string(Int(v)) for v in vals], "  ")
    println(rpad(first(label, 40), 42), vs)
end
