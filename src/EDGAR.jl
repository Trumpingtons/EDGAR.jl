module EDGAR

using HTTP
using JSON3
using Gumbo
using Cascadia
# avoid requiring extra stdlib; use built-in hash for cache key

const USER_AGENT = "EDGAR.jl/0.1 (https://github.com/yourname/EDGAR.jl)"

# HTTP helper (injectable for tests)
http_get = HTTP.get

# Simple cache defaults (can be overridden via set_config)
const CACHE_DIR = joinpath(pwd(), ".edgar_cache")
const CACHE_TTL = 24 * 3600 # seconds
const CACHE_MAX_SIZE = 10_000_000 # bytes

# Simple metrics
const CACHE_METRICS = Dict(:hits=>0, :misses=>0, :requests=>0, :bytes_downloaded=>0)

mutable struct EDGARConfig
    cache_dir::Union{Nothing,String}
    cache_ttl::Union{Nothing,Int}
    cache_max_size::Union{Nothing,Int}
    host_whitelist::Vector{String}
    allow_file::Bool
    user_agent::Union{Nothing,String}
end

const CONFIG = EDGARConfig(nothing, nothing, nothing, String[], false, nothing)

function set_config(; cache_dir=nothing, cache_ttl=nothing, cache_max_size=nothing, host_whitelist=nothing, allow_file=nothing, user_agent=nothing)
    if cache_dir !== nothing CONFIG.cache_dir = cache_dir end
    if cache_ttl !== nothing CONFIG.cache_ttl = cache_ttl end
    if cache_max_size !== nothing CONFIG.cache_max_size = cache_max_size end
    if host_whitelist !== nothing CONFIG.host_whitelist = host_whitelist end
    if allow_file !== nothing CONFIG.allow_file = allow_file end
    if user_agent !== nothing CONFIG.user_agent = user_agent end
    return CONFIG
end

get_cache_dir() = CONFIG.cache_dir === nothing ? CACHE_DIR : CONFIG.cache_dir
get_cache_ttl() = CONFIG.cache_ttl === nothing ? CACHE_TTL : CONFIG.cache_ttl
get_cache_max_size() = CONFIG.cache_max_size === nothing ? CACHE_MAX_SIZE : CONFIG.cache_max_size
get_user_agent() = CONFIG.user_agent === nothing ? USER_AGENT : CONFIG.user_agent

function host_allowed(host::AbstractString)
    if isempty(CONFIG.host_whitelist)
        return true
    end
    for w in CONFIG.host_whitelist
        if host == w || endswith(host, "." * w) || occursin(w, host)
            return true
        end
    end
    return false
end

if !isdir(get_cache_dir())
    mkpath(get_cache_dir())
end

function cache_path_for(url::AbstractString)
    h = string(abs(hash(url)))
    return joinpath(get_cache_dir(), h)
end

function _read_cache(path::AbstractString)
    bodyfile = path * ".body"
    metafile = path * ".meta"
    if isfile(bodyfile) && isfile(metafile)
        meta = JSON3.read(read(metafile, String))
        return (meta, read(bodyfile))
    end
    return nothing
end

function _write_cache(path::AbstractString, body::Vector{UInt8}, meta::Dict)
    bodyfile = path * ".body"
    metafile = path * ".meta"
    open(bodyfile, "w") do io
        write(io, body)
    end
    open(metafile, "w") do io
        write(io, JSON3.write(meta))
    end
end

function clean_cache(max_age_seconds::Int=CACHE_TTL)
    nowts = time()
    removed = 0
    for f in readdir(get_cache_dir())
        full = joinpath(get_cache_dir(), f)
        # consider only .meta files
        if endswith(full, ".meta")
            try
                meta = JSON3.read(read(full, String))
                if haskey(meta, "timestamp") && (nowts - meta["timestamp"] > max_age_seconds)
                    # remove meta and body
                    rm(full)
                    body = replace(full, ".meta" => ".body")
                    if isfile(body) rm(body) end
                    removed += 1
                end
            catch
                # ignore corrupt
            end
        end
    end
    @info "clean_cache removed=$removed"
    return removed
end

function cache_metrics()
    return deepcopy(CACHE_METRICS)
end

function fetch_url(url::AbstractString; use_cache::Bool=true, timeout::Int=15, allow_file::Bool=false)
    # Support file: for tests only when allow_file=true
    if startswith(url, "file://")
        if !allow_file
            @info "file:// URLs disabled"
            return nothing
        end
        p = replace(url, "file://" => "")
        if isfile(p)
            return read(p)
        end
        return nothing
    end

    if !(startswith(url, "http://") || startswith(url, "https://") || startswith(url, "//"))
        return nothing
    end

    # Normalize protocol-relative
    if startswith(url, "//")
        url = "https:" * url
    end

    path = cache_path_for(url)
    if use_cache
        cand = _read_cache(path)
        if cand !== nothing
            meta, body = cand
            if haskey(meta, "timestamp") && (time() - meta["timestamp"] <= CACHE_TTL)
                CACHE_METRICS[:hits] += 1
                return body
            end
        end
    end

    # perform HTTP request
    CACHE_METRICS[:requests] += 1
    r = nothing
    try
        r = http_get(url, headers=["User-Agent"=>get_user_agent()], readtimeout=timeout)
    catch e
        @info "fetch_url error: $e"
    end
    if r === nothing
        return nothing
    end
    status = hasproperty(r, :status) ? getproperty(r, :status) : nothing
    if status !== 200
        @info "fetch_url non-200: $status for $url"
        return nothing
    end
    body = hasproperty(r, :body) ? getproperty(r, :body) : nothing
    if body === nothing
        return nothing
    end
    nb = length(body)
    CACHE_METRICS[:bytes_downloaded] += nb
    CACHE_METRICS[:misses] += 1
    # enforce max size
    if nb > CACHE_MAX_SIZE
        @info "fetch_url: body too large ($(nb) bytes), skipping cache"
        return body
    end
    status2 = hasproperty(r, :status) ? getproperty(r, :status) : 200
    meta = Dict("url"=>url, "timestamp"=>time(), "status"=>status2)
    try
        _write_cache(path, body, meta)
    catch e
        @info "failed to write cache: $e"
    end
    return body
end

function levenshtein(a::AbstractString, b::AbstractString)
    ca = collect(a)
    cb = collect(b)
    la = length(ca); lb = length(cb)
    if la == 0 return lb end
    if lb == 0 return la end
    d = Array{Int}(undef, la+1, lb+1)
    for i in 0:la
        d[i+1, 1] = i
    end
    for j in 0:lb
        d[1, j+1] = j
    end
    for i in 1:la
        for j in 1:lb
            cost = ca[i] == cb[j] ? 0 : 1
            d[i+1, j+1] = min(d[i, j+1] + 1, d[i+1, j] + 1, d[i, j] + cost)
        end
    end
    return d[la+1, lb+1]
end

function similarity_ratio(a::AbstractString, b::AbstractString)
    a2 = lowercase(strip(a)); b2 = lowercase(strip(b))
    if isempty(a2) && isempty(b2) return 1.0 end
    d = levenshtein(a2, b2)
    maxlen = max(length(a2), length(b2))
    return 1.0 - d / maxlen
end

function fetch_submissions(cik::AbstractString)
    url = "https://data.sec.gov/submissions/CIK$(strip(cik)).json"
    r = HTTP.get(url, headers = ["User-Agent"=>USER_AGENT])
    return JSON3.read(String(r.body))
end

function list_recent_filings(cik::AbstractString; count::Int=10)
    subs = fetch_submissions(cik)
    filings = get(subs, "filings", Dict())
    recent = get(filings, "recent", Dict())
    accnos = get(recent, "accessionNumber", [])
    types = get(recent, "form", [])
    dates = get(recent, "filingDate", [])
    n = min(count, length(accnos))
    result = []
    for i in 1:n
        push!(result, (accession=accnos[i], form=types[i], date=dates[i]))
    end
    return result
end

function _cik_dir(cik)
    return joinpath(pwd(), "data", strip(cik))
end

function download_filing(cik::AbstractString, accession::AbstractString; primary::Bool=true, destdir=".")
    acc = replace(accession, "-"=>"")
    cikp = lpad(strip(cik), 10, '0')
    url = "https://www.sec.gov/Archives/edgar/data/$(strip(parse(Int, cikp)))/$(acc)/$(primary ? "" : "")"
    # Best-effort: try common filename patterns
    candidates = ["/" * accession * "-index.htm", "/" * accession * ".txt", "/" * accession * ".html", "/index.htm"]
    if !isdir(destdir)
        mkpath(destdir)
    end
    for cand in candidates
        full = "https://www.sec.gov/Archives/edgar/data/$(strip(parse(Int, cikp)))/$(acc)" * cand
        try
            r = HTTP.get(full, headers=["User-Agent"=>USER_AGENT])
            if r.status == 200
                out = joinpath(destdir, basename(cand))
                open(out, "w") do io
                    write(io, String(r.body))
                end
                return out
            end
        catch
            # continue
        end
    end
    error("Could not download filing for $(cik) $(accession)")
end

function html_to_text(html::AbstractString)
    m = match(r"(?is)<body.*?</body>", html)
    body = m === nothing ? html : m.match
    txt = replace(body, r"(?is)<script.*?</script>" => "")
    txt = replace(txt, r"(?is)<style.*?</style>" => "")
    txt = replace(txt, r"<[^>]+>" => " ")
    txt = replace(txt, r"\s+" => " ")
    return strip(txt)
end

function parse_filing(path::AbstractString)
    # Return raw HTML string; extraction functions operate on HTML
    return read(path, String)
end

function save_filing(text::AbstractString, metadata::Dict; outdir="out")
    if !isdir(outdir)
        mkpath(outdir)
    end
    fn = joinpath(outdir, metadata[:accession] * ".txt")
    open(fn, "w") do io
        write(io, text)
    end
    return fn
end

function extract_section(html::AbstractString, names::Vector{String}; max_chars::Int=200_000, base_path::Union{Nothing,String}=nothing)
    results = Dict{String,String}()
    body_html = match(r"(?is)<body.*?</body>", html)
    body_html = body_html === nothing ? html : body_html.match

    # Try TOC-based extraction heuristics
    toc_present = occursin(r"(?i)id=[\"']?toc[\"']?", body_html) || occursin("table of contents", lowercase(body_html))
    toc_items = String[]
    toc_hrefs = String[]
    if toc_present
        # try to extract a TOC block if present
        mblock = match(r"(?is)<div[^>]*id=[\"']?toc[\"']?[^>]*>.*?</div>", body_html)
        toc_html = mblock === nothing ? body_html : mblock.match
        # Look for anchors in the TOC region: <a href="#...">Label</a>
        for m in eachmatch(r"<a[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", toc_html)
            push!(toc_hrefs, m.captures[1])
            push!(toc_items, replace(strip(m.captures[2]), r"<[^>]+>" => " "))
        end
        # fallback: list items lines
        if isempty(toc_items)
            for m in eachmatch(r"(?m)^\s*\d+\.\s*(.+)$", toc_html)
                push!(toc_items, strip(m.captures[1])); push!(toc_hrefs, "")
            end
        end
    end

    # Helper to extract fragment by id/name from html string
    extract_fragment = function(h::AbstractString, anchor::AbstractString)
        # id or name match
        # escape anchor to avoid regex injection
        esc = replace(anchor, r"([\\\^\$\.\|\?\*\+\(\)\[\{])" => s"\\\\\1")
        pat = Regex("(?is)<(h\\d|div|p|section)[^>]*(?:id|name)=[\"']?" * esc * "[\"']?[^>]*>")
        m = match(pat, h)
        if m !== nothing
            spos = m.offset
            tag = lowercase(String(m.captures[1]))
            # try to capture the full element contents (non-greedy)
            s2 = h[spos:end]
            elem_pat = Regex("(?is)^<" * tag * "[^>]*>.*?</" * tag * ">")
            m2 = match(elem_pat, s2)
            if m2 !== nothing
                sec_html = m2.match
            else
                # fallback: find next heading or end
                nr = findnext(r"(?is)<h[1-6][^>]*>", h, spos+1)
                next_pos = nr === nothing ? lastindex(h) + 1 : first(nr)
                sec_html = h[spos:min(next_pos-1, lastindex(h))]
            end
            txt = replace(sec_html, r"(?is)<script.*?</script>" => "")
            txt = replace(txt, r"(?is)<style.*?</style>" => "")
            txt = replace(txt, r"<[^>]+>" => " ")
            txt = replace(txt, r"\s+" => " ")
            return strip(txt)
        end
        return nothing
    end

    # Try TOC items matching requested names
    for name in names
        found = false
        best_idx = 0; best_score = 0.0
        for (i, label) in enumerate(toc_items)
            # prefer substring matches (e.g., "Item 7" in "Item 7. Management's Discussion")
            if occursin(lowercase(strip(name)), lowercase(strip(label)))
                s = 1.0
            else
                s = similarity_ratio(name, label)
            end
            if s > best_score
                best_score = s; best_idx = i
            end
        end
        if best_score > 0.6 && best_idx > 0
            href = toc_hrefs[best_idx]
                if startswith(href, "#") || href == ""
                anchor = replace(href, "#"=>"")
                frag = extract_fragment(body_html, anchor)
                if frag !== nothing
                    results[name] = frag; continue
                end
            else
                # may point to other file or fragment
                parts = split(href, '#')
                href_file = parts[1]; anchor = length(parts) > 1 ? parts[2] : ""
                if base_path !== nothing && href_file != ""
                    # If href_file is an absolute URL, fetch it remotely
                    if occursin("://", href_file) || startswith(href_file, "//")
                        raw = fetch_url(href_file)
                        if raw !== nothing
                            other_html = String(raw)
                            frag = anchor == "" ? html_to_text(other_html) : extract_fragment(other_html, anchor)
                            if frag !== nothing
                                results[name] = frag; continue
                            end
                        end
                    else
                        other_path = joinpath(dirname(base_path), href_file)
                        if isfile(other_path)
                            other_html = read(other_path, String)
                            frag = anchor == "" ? html_to_text(other_html) : extract_fragment(other_html, anchor)
                            if frag !== nothing
                                results[name] = frag; continue
                            end
                        end
                    end
                end
            end
        end
    end

    # If not found via TOC, try DOM headings
    try
        doc = Gumbo.parsehtml(body_html)
        for name in names
            nodes = Cascadia.eachmatch(Selector("h1,h2,h3,h4,h5,h6"), doc.root)
            best_node = nothing; best_score = 0.0
            for n in nodes
                lab = strip(Gumbo.innerText(n))
                s = similarity_ratio(name, lab)
                if s > best_score
                    best_score = s; best_node = n
                end
            end
            if best_node !== nothing && best_score > 0.5
                # extract until next heading
                # get outerHTML from best_node and siblings
                outer = Gumbo.innerHTML(best_node)
                # fallback: use text from node
                txt = strip(replace(outer, r"<[^>]+>" => " "))
                results[name] = txt
            end
        end
    catch
        # ignore
    end

    # Final fallback: simple text search for the heading labels
    plain = html_to_text(body_html)
    plain_norm = replace(lowercase(replace(plain, r"\s+" => " ")), r"[\W_]" => "")
    for name in names
        if haskey(results, name) continue end
        target = replace(lowercase(name), r"[\W_]" => "")
        r = findfirst(target, plain_norm)
        if r !== nothing
            # map normalized index back to original plain by searching the substring
            # take a window around the match in the original plain text
            idx = r.start
            start = max(idx - 200, 1)
            stop = min(idx + max_chars, lastindex(plain_norm))
            # extract corresponding region from original plain (approximate)
            results[name] = strip(plain[start: min(stop, lastindex(plain))])
        end
    end

    return results
end

function main(argv::Vector{String}=ARGS)
    println("EDGAR.jl: simple tool. Use functions from module.")
end

export fetch_submissions, list_recent_filings, download_filing, parse_filing, extract_section, save_filing, main,
       set_config, fetch_url, clean_cache, cache_metrics, cache_path_for

end # module
