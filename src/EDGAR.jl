module EDGAR

using HTTP
using JSON3
using Gumbo
using Cascadia
# avoid requiring extra stdlib; use built-in hash for cache key

# HTTP helper (injectable for tests)
http_get = HTTP.get

# HTTP-response cache defaults (overridable via set_config). CACHE_DIR is the
# :persistent-mode location — a per-user cache dir, never the working directory.
# (The default :temporary mode uses a per-process temp dir instead.)
const CACHE_DIR = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")), "EDGAR.jl")
const CACHE_TTL = 24 * 3600 # seconds (freshness: how long a response is reused)
const CACHE_MAX_SIZE = 10_000_000 # bytes
const CACHE_MAX_AGE = 7 * 24 * 3600 # seconds (persistence: delete files older than this)

# Cache hit/miss counters, exposed via cache_metrics().
const CACHE_METRICS = Dict(:hits=>0, :misses=>0, :requests=>0, :bytes_downloaded=>0)

mutable struct EDGARConfig
    cache_dir::Union{Nothing,String}
    cache_ttl::Union{Nothing,Int}
    cache_max_size::Union{Nothing,Int}
    cache_max_age::Union{Nothing,Int}
    host_whitelist::Vector{String}
    allow_file::Bool
    user_agent::Union{Nothing,String}
    cache_mode::Symbol
end

# cache_mode defaults to :temporary — ephemeral, wiped when the process exits.
const CONFIG = EDGARConfig(nothing, nothing, nothing, nothing, String[], false, nothing, :temporary)

# Lazily-created per-process temp cache directory. mktempdir registers an atexit
# hook that deletes it when the Julia process exits, so the :temporary cache is
# discarded automatically (process-scoped, like an in-memory DB but on disk).
const _TEMP_CACHE_DIR = Ref{String}("")
function _temp_cache_dir()
    if isempty(_TEMP_CACHE_DIR[]) || !isdir(_TEMP_CACHE_DIR[])
        _TEMP_CACHE_DIR[] = mktempdir(; prefix = "EDGAR_jl_")
    end
    return _TEMP_CACHE_DIR[]
end

"""
    set_config(; cache, cache_dir, cache_ttl, cache_max_size, cache_max_age, host_whitelist, allow_file, user_agent) -> EDGARConfig

Override the global runtime configuration. Only the keyword arguments you pass
(anything other than `nothing`) are changed; the rest keep their current values.
Returns the live configuration object.

- `user_agent` — the `User-Agent` header sent with every request. **Required**: the
  SEC rejects requests without a descriptive value with contact information.
  [`set_user_agent`](@ref) is the convenient way to set it.
- `cache` — caching mode, `:temporary` / `:persistent` / `:off`; see *Caching* below.
- `cache_dir`, `cache_ttl`, `cache_max_size`, `cache_max_age` — cache location and
  limits; see *Caching* below.
- `host_whitelist` — hosts that requests are restricted to (empty = no restriction).
- `allow_file` — whether `file://` URLs are permitted (off by default; used in tests).

```julia
set_config(user_agent = "Jane Doe jane@example.com", cache = :persistent)
```

# Extended help

## Caching

Responses are cached so that repeated calls in a session do not re-download the
same data. The `cache` keyword selects where the cache lives and how long it
survives:

- `:temporary` (default) — an ephemeral per-process temporary directory, deleted
  when the Julia process exits. Nothing persists across sessions or accumulates
  on disk (an in-memory-database-style lifecycle, but on disk).
- `:persistent` — kept in `~/.cache/EDGAR.jl` (or `XDG_CACHE_HOME`) across
  sessions; files older than `cache_max_age` are pruned automatically.
- `:off` — no caching; every call re-fetches.

`cache_dir` pins a specific directory, which implies persistent storage.

Two **independent** time limits apply:

- `cache_ttl` (default 24 h) is *freshness* — how long a cached response is reused
  before being re-fetched. It deletes nothing.
- `cache_max_age` (default 7 days) is *retention* — how long a file is kept on
  disk in persistent storage before being deleted. Pruning is on by default and
  runs opportunistically; it never affects freshness.

`cache_max_size` (default 10 MB) caps the size of any single cached response. Use
[`clean_cache`](@ref) to prune on demand and [`cache_metrics`](@ref) to inspect
hit/miss counts.
"""
function set_config(; cache=nothing, cache_dir=nothing, cache_ttl=nothing, cache_max_size=nothing, cache_max_age=nothing, host_whitelist=nothing, allow_file=nothing, user_agent=nothing)
    if cache !== nothing
        cache in (:temporary, :persistent, :off) || throw(ArgumentError("cache must be :temporary, :persistent or :off"))
        CONFIG.cache_mode = cache
    end
    if cache_dir !== nothing CONFIG.cache_dir = cache_dir end
    if cache_ttl !== nothing CONFIG.cache_ttl = cache_ttl end
    if cache_max_size !== nothing CONFIG.cache_max_size = cache_max_size end
    if cache_max_age !== nothing CONFIG.cache_max_age = cache_max_age end
    if host_whitelist !== nothing CONFIG.host_whitelist = host_whitelist end
    if allow_file !== nothing CONFIG.allow_file = allow_file end
    if user_agent !== nothing CONFIG.user_agent = user_agent end
    return CONFIG
end

function get_cache_dir()
    CONFIG.cache_dir === nothing || return CONFIG.cache_dir
    return CONFIG.cache_mode === :temporary ? _temp_cache_dir() : CACHE_DIR
end
get_cache_ttl() = CONFIG.cache_ttl === nothing ? CACHE_TTL : CONFIG.cache_ttl
get_cache_max_size() = CONFIG.cache_max_size === nothing ? CACHE_MAX_SIZE : CONFIG.cache_max_size
get_cache_max_age() = CONFIG.cache_max_age === nothing ? CACHE_MAX_AGE : CONFIG.cache_max_age
"""
    get_user_agent() -> String

Return the SEC `User-Agent` string that will be sent with every request. The
resolution order is: an explicit value set via [`set_user_agent`](@ref) or
[`set_config`](@ref) wins; otherwise the `SEC_USER_AGENT` environment variable is
used (how hosts such as a notebook env or an editor extension can inject the
contact into the session); if neither is set, an `ArgumentError` is thrown, since
the SEC rejects requests without a descriptive User-Agent.

```julia
set_user_agent("Jane Doe jane@example.com")
get_user_agent()     # "Jane Doe jane@example.com"
```
"""
function get_user_agent()
    if CONFIG.user_agent === nothing
        env_ua = get(ENV, "SEC_USER_AGENT", "")
        isempty(env_ua) || return env_ua
        throw(ArgumentError(
            "No SEC User-Agent set. The SEC requires a descriptive User-Agent with " *
            "contact information. Set one with:\n    set_user_agent(\"Your Name you@example.com\")\n" *
            "or set the SEC_USER_AGENT environment variable."))
    end
    return CONFIG.user_agent
end

"""
    set_user_agent(user_agent) -> String

Set the SEC `User-Agent` from a single string containing your name and a contact
email, e.g. `"Jane Doe jane@example.com"`. The SEC requires a descriptive
User-Agent with contact information; requests without one are rejected with HTTP
403. This is the validated counterpart to [`get_user_agent`](@ref): it checks the
string is non-empty and contains an email before storing it, then returns it.

```julia
set_user_agent("Jane Doe jane@example.com")
```
"""
function set_user_agent(user_agent::AbstractString)
    ua = strip(user_agent)
    isempty(ua) && throw(ArgumentError("User-Agent must not be empty"))
    occursin('@', ua) || throw(ArgumentError(
        "\"$ua\" does not contain a contact email. The SEC requires a descriptive " *
        "User-Agent with contact information, e.g. \"Jane Doe jane@example.com\"."))
    set_config(user_agent = ua)
    return ua
end

# Marker comment tagging the line that persist_user_agent writes to startup.jl, so
# the write can be updated or removed idempotently without touching the user's own lines.
const _PERSIST_MARKER = "# added by EDGAR.persist_user_agent"

"""
    persist_user_agent(user_agent; depot = first(DEPOT_PATH)) -> String

Persist the SEC `User-Agent` across Julia sessions by writing it into the depot's
`config/startup.jl`, so `ENV["SEC_USER_AGENT"]` is set every time Julia starts and
EDGAR.jl reads it automatically — no per-session [`set_user_agent`](@ref) call. The
string is validated as in [`set_user_agent`](@ref) and also applied to the current
session. The write is idempotent: it replaces the line a previous call added rather
than appending a duplicate, and it leaves any `SEC_USER_AGENT` line you wrote
yourself untouched. Returns the path it modified. Undo with [`unpersist_user_agent`](@ref).

```julia
persist_user_agent("Jane Doe jane@example.com")
```
"""
function persist_user_agent(user_agent::AbstractString; depot::AbstractString=first(DEPOT_PATH))
    ua = set_user_agent(user_agent)          # validate + set for the current session
    path = joinpath(depot, "config", "startup.jl")
    mkpath(dirname(path))
    line = "ENV[\"SEC_USER_AGENT\"] = $(repr(ua))   $(_PERSIST_MARKER)"
    lines = isfile(path) ? readlines(path) : String[]
    filter!(l -> !occursin(_PERSIST_MARKER, l), lines)   # drop our previous line, if any
    push!(lines, line)
    open(path, "w") do io
        foreach(l -> println(io, l), lines)
    end
    @info "Persisted SEC_USER_AGENT to $path (effective in new Julia sessions)."
    return path
end

"""
    unpersist_user_agent(; depot = first(DEPOT_PATH)) -> Bool

Remove the `SEC_USER_AGENT` line that [`persist_user_agent`](@ref) added to the
depot's `config/startup.jl`. Returns `true` if a line was removed, `false` if there
was nothing to remove. Only lines written by `persist_user_agent` are affected; the
current session's User-Agent is left unchanged.
"""
function unpersist_user_agent(; depot::AbstractString=first(DEPOT_PATH))
    path = joinpath(depot, "config", "startup.jl")
    isfile(path) || return false
    lines = readlines(path)
    kept = filter(l -> !occursin(_PERSIST_MARKER, l), lines)
    length(kept) < length(lines) || return false
    open(path, "w") do io
        foreach(l -> println(io, l), kept)
    end
    @info "Removed persisted SEC_USER_AGENT from $path."
    return true
end

# True when the cache is stored persistently (named mode or a pinned directory),
# as opposed to the ephemeral per-process :temporary dir.
_is_persistent() = CONFIG.cache_dir !== nothing || CONFIG.cache_mode === :persistent

# In persistent storage, delete files older than cache_max_age. Runs at most once
# per hour per process, on fetch. This bounds how long files linger on disk; it
# does NOT touch freshness (cache_ttl) — stale-but-present entries are still
# re-fetched as before. Uses the public clean_cache.
const _LAST_PRUNE = Ref(0.0)
function _maybe_prune_persistent()
    _is_persistent() || return
    now = time()
    now - _LAST_PRUNE[] < 3600 && return
    _LAST_PRUNE[] = now
    try
        clean_cache(get_cache_max_age())
    catch
        # best-effort
    end
    return
end

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

"""
    cache_path_for(url) -> String

Return the on-disk path (without extension) used to cache `url`. The actual
cache files are this path with `.body` and `.meta` suffixes.
"""
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
    mkpath(dirname(bodyfile))
    open(bodyfile, "w") do io
        write(io, body)
    end
    open(metafile, "w") do io
        write(io, JSON3.write(meta))
    end
end

"""
    clean_cache(max_age_seconds=CACHE_TTL) -> Int

Delete cached responses whose stored timestamp is older than `max_age_seconds`,
and return how many entries were removed. Corrupt cache entries are ignored.
"""
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

"""
    cache_metrics() -> Dict

Return a snapshot (copy) of the cache counters: `:hits`, `:misses`,
`:requests` and `:bytes_downloaded`.
"""
function cache_metrics()
    return deepcopy(CACHE_METRICS)
end

"""
    fetch_url(url; use_cache=true, timeout=15, allow_file=false) -> Vector{UInt8} or nothing

The low-level HTTP GET that every higher-level function is built on. Fetches
`url` and returns the raw response body as bytes, or `nothing` on any failure
(network error, non-200 status, or a disallowed URL).

Use it as an escape hatch to reach SEC endpoints that EDGAR.jl does not yet wrap:
you get the configured `User-Agent` and the cache for free, and parse the bytes
yourself (e.g. with `JSON3.read`). Caching behaviour — where the cache lives and
when it expires — is configured through [`set_config`](@ref).

`use_cache=false` ignores any cached copy on read, `timeout` is the read-inactivity
timeout in seconds (a stalled connection is abandoned after this long with no data,
so it does not cut off slow-but-steady large downloads), and `file://` URLs are only
read when `allow_file=true` (for tests).
"""
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

    caching = CONFIG.cache_mode !== :off
    path = caching ? cache_path_for(url) : ""
    caching && _maybe_prune_persistent()
    if caching && use_cache
        cand = _read_cache(path)
        if cand !== nothing
            meta, body = cand
            if haskey(meta, "timestamp") && (time() - meta["timestamp"] <= get_cache_ttl())
                CACHE_METRICS[:hits] += 1
                return body
            end
        end
    end

    ua = get_user_agent()   # throws a clear error if unset, before any network call
    CACHE_METRICS[:requests] += 1
    r = nothing
    try
        r = http_get(url, headers=["User-Agent"=>ua], read_idle_timeout=timeout)
    catch e
        @info "fetch_url error: $e"
    end
    if r === nothing
        return nothing
    end
    status = hasproperty(r, :status) ? getproperty(r, :status) : nothing
    if status != 200
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
    # skip the write when caching is off or the body exceeds the size limit
    if !caching || nb > get_cache_max_size()
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

"""
    fetch_submissions(cik) -> JSON3.Object

Fetch a filer's complete submissions document from `data.sec.gov/submissions/`:
company metadata plus its recent filings index. `cik` should be the 10-digit,
zero-padded Central Index Key (e.g. `"0000320193"`). See [`list_recent_filings`](@ref)
for a tidied view of just the recent filings.
"""
function fetch_submissions(cik::AbstractString)
    return _get_json("https://data.sec.gov/submissions/CIK$(strip(cik)).json")
end

"""
    list_recent_filings(cik; count=10) -> Vector{NamedTuple}

Return a filer's most recent filings as up to `count` rows of
`(accession, form, date)`, newest first. Built on [`fetch_submissions`](@ref).

```julia
for f in list_recent_filings("0000320193"; count = 5)
    println(f.date, "  ", f.form, "  ", f.accession)
end
```
"""
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

# ── XBRL financial data, full-text search, and ticker lookup ─────────────────
#
# These call the public data.sec.gov / efts.sec.gov / sec.gov JSON endpoints
# through `fetch_url`, so they share the on-disk cache and the configured
# User-Agent. Each returns the parsed JSON (a `JSON3.Object`/`JSON3.Array`).

# Internal: fetch `url` through the cached, User-Agent-aware `fetch_url` and
# parse the body as JSON. Throws if the request fails (bad User-Agent, network
# error, or the resource does not exist).
function _get_json(url::AbstractString; use_cache::Bool=true)
    body = fetch_url(url; use_cache = use_cache)
    body === nothing && error("EDGAR request failed: $url (network error, SEC rate limit, or the resource does not exist)")
    return JSON3.read(body)
end

"""
    company_facts(cik) -> JSON3.Object

Every XBRL fact a company has ever reported, in a single document, from the
`/api/xbrl/companyfacts/` endpoint. `cik` is zero-padded to 10 digits.

```julia
facts = company_facts("320193")
keys(facts.facts)              # taxonomies, e.g. :dei and Symbol("us-gaap")
```
"""
function company_facts(cik::AbstractString)
    c = lpad(strip(cik), 10, '0')
    return _get_json("https://data.sec.gov/api/xbrl/companyfacts/CIK$(c).json")
end

"""
    company_concept(cik, taxonomy, tag) -> JSON3.Object

One XBRL concept over time for a single filer, from `/api/xbrl/companyconcept/`.

```julia
ni = company_concept("320193", "us-gaap", "NetIncomeLoss")
ni.units.USD[end].val
```
"""
function company_concept(cik::AbstractString, taxonomy::AbstractString, tag::AbstractString)
    c = lpad(strip(cik), 10, '0')
    return _get_json("https://data.sec.gov/api/xbrl/companyconcept/CIK$(c)/$(taxonomy)/$(tag).json")
end

"""
    xbrl_frames(taxonomy, tag, unit, period) -> JSON3.Object

One XBRL concept for one period across *every* filer that reported it, from
`/api/xbrl/frames/`. A trailing `I` on the period denotes an instant (point in
time, e.g. `"CY2022Q4I"`); drop it for a duration (e.g. `"CY2022"`).

```julia
fr = xbrl_frames("us-gaap", "Assets", "USD", "CY2022Q4I")
length(fr.data)
```
"""
function xbrl_frames(taxonomy::AbstractString, tag::AbstractString, unit::AbstractString, period::AbstractString)
    return _get_json("https://data.sec.gov/api/xbrl/frames/$(taxonomy)/$(tag)/$(unit)/$(period).json")
end

"""
    full_text_search(query; forms=nothing, startdate=nothing, enddate=nothing, from=0, size=10) -> JSON3.Object

Full-text search across filing *contents* (2001 onward) via the EDGAR full-text
search (EFTS) API. `forms` may be a single string (`"10-K"`) or a collection;
`startdate`/`enddate` are `"YYYY-MM-DD"` strings. Results are under `.hits.hits`.

```julia
res = full_text_search("climate risk"; forms = "10-K")
res.hits.total.value
```
"""
function full_text_search(query::AbstractString; forms=nothing, startdate=nothing, enddate=nothing, from::Int=0, size::Int=10)
    url = "https://efts.sec.gov/LATEST/search-index?q=$(HTTP.escapeuri(query))&from=$(from)&size=$(size)"
    if forms !== nothing
        url *= "&forms=$(forms isa AbstractString ? forms : join(forms, ","))"
    end
    startdate !== nothing && (url *= "&startdt=$(startdate)")
    enddate !== nothing && (url *= "&enddt=$(enddate)")
    return _get_json(url)
end

"""
    company_tickers() -> JSON3.Object

The SEC's `company_tickers.json`, mapping ticker symbols to CIK numbers and
company names.
"""
company_tickers() = _get_json("https://www.sec.gov/files/company_tickers.json")

"""
    cik_for_ticker(ticker) -> String or nothing

Resolve a ticker symbol (case-insensitive) to its 10-digit, zero-padded CIK,
or `nothing` if no match is found.

```julia
cik_for_ticker("AAPL")     # "0000320193"
```
"""
function cik_for_ticker(ticker::AbstractString)
    t = uppercase(strip(ticker))
    for (_, v) in company_tickers()
        if uppercase(String(v.ticker)) == t
            return lpad(v.cik_str, 10, '0')
        end
    end
    return nothing
end

function _cik_dir(cik)
    return joinpath(pwd(), "data", strip(cik))
end

"""
    download_filing(cik, accession; primary=true, destdir=".") -> String

Download a filing's document from the EDGAR `Archives` into `destdir`, creating
the directory if needed, and return the local file path. The accession number may
be given with or without dashes. Several common document/index URL patterns are
tried in turn; the first that responds with HTTP 200 is saved. Throws if none of
them succeed.
"""
function download_filing(cik::AbstractString, accession::AbstractString; destdir=".")
    acc = replace(accession, "-"=>"")
    cik_path = string(parse(Int, strip(cik)))
    url = "https://www.sec.gov/Archives/edgar/data/$(cik_path)/$(acc)/"
    # Best-effort: try common filename patterns
    candidates = ["/" * accession * "-index.htm", "/" * accession * ".txt", "/" * accession * ".html", "/index.htm"]
    if !isdir(destdir)
        mkpath(destdir)
    end
    ua = get_user_agent()   # throws a clear error if unset, before any network call
    for cand in candidates
        full = url * cand
        try
            r = HTTP.get(full, headers=["User-Agent"=>ua])
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

"""
    parse_filing(path) -> String

Read a downloaded filing from `path` and return its raw HTML. The extraction
functions (such as [`extract_section`](@ref)) operate directly on this HTML.
"""
function parse_filing(path::AbstractString)
    # Return raw HTML string; extraction functions operate on HTML
    return read(path, String)
end

"""
    save_filing(text, metadata; outdir="out") -> String

Write `text` to `<outdir>/<accession>.txt`, taking the accession number from
`metadata[:accession]` and creating `outdir` if needed. Returns the path written.
"""
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

"""
    extract_section(html, names; max_chars=200_000, base_path=nothing) -> Dict{String,String}

Pull one or more named sections out of a filing's `html`, returning a dictionary
that maps each requested name to the matched text. Names that cannot be located
are simply absent from the result, so look them up with `get`.

Matching is heuristic and tried in order: the document's table of contents
(following anchor links), then DOM headings (`h1`–`h6`, via Gumbo + Cascadia),
then a plain-text search as a last resort. `base_path` lets table-of-contents
links that point to sibling files be resolved relative to it; `max_chars` bounds
the size of the plain-text fallback window.

```julia
sections = extract_section(html, ["Item 7", "Management's Discussion"])
println(get(sections, "Item 7", "(not found)"))
```
"""
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

export fetch_submissions, list_recent_filings, download_filing, parse_filing, extract_section, save_filing,
       set_config, set_user_agent, get_user_agent, persist_user_agent, unpersist_user_agent,
       fetch_url, clean_cache, cache_metrics, cache_path_for,
       company_facts, company_concept, xbrl_frames, full_text_search, company_tickers, cik_for_ticker

end # module
