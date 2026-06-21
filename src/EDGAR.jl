module EDGAR

using HTTP
using JSON3
using Base64
using Dates
using Sockets
# avoid requiring extra stdlib; use built-in hash for cache key

include("standardize.jl")   # standardize(concept) — cross-company concept mapping (W4)

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

# Internal: normalize a CIK given as an integer or a string (with or without
# leading zeros) to the SEC's canonical 10-digit, zero-padded string form,
# e.g. 320193, "320193" and "0000320193" all become "0000320193". Throws on
# empty, non-numeric, or over-long input.
function _normalize_cik(cik::Union{Integer,AbstractString})
    s = cik isa Integer ? string(cik) : strip(cik)
    isempty(s) && throw(ArgumentError("CIK must not be empty"))
    all(isdigit, s) || throw(ArgumentError("CIK must contain only digits, got $(repr(cik))"))
    length(s) > 10 && throw(ArgumentError("CIK has more than 10 digits: $(repr(cik))"))
    return lpad(s, 10, '0')
end

# Internal: fetch a filer's submissions document from `data.sec.gov/submissions/`
# (company profile + recent filings index under `.filings.recent`). Used by
# `filings_by_cik` to enrich EFTS hits with submissions-only fields.
function _fetch_submissions(cik::Union{Integer,AbstractString})
    return _get_json("https://data.sec.gov/submissions/CIK$(_normalize_cik(cik)).json")
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
`/api/xbrl/companyfacts/` endpoint. `cik` may be an integer or a string, with or
without leading zeros; it is normalized to the 10-digit form.

```julia
facts = company_facts("320193")
keys(facts.facts)              # taxonomies, e.g. :dei and Symbol("us-gaap")
```
"""
function company_facts(cik::Union{Integer,AbstractString})
    c = _normalize_cik(cik)
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
function company_concept(cik::Union{Integer,AbstractString}, taxonomy::AbstractString, tag::AbstractString)
    c = _normalize_cik(cik)
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

# Internal: build and run an EDGAR full-text-search (EFTS) query. `q` is the
# already-prepared query string (quoted or not); `ciks` filters by filer. EFTS
# only applies a date filter when BOTH bounds are present, so a lone `startdate`
# or `enddate` is completed with the edge of EDGAR's coverage (2001 onward).
function _efts_search(; q::AbstractString="", ciks=nothing, forms=nothing, startdate=nothing, enddate=nothing, from::Int=0)
    url = "https://efts.sec.gov/LATEST/search-index?q=$(HTTP.escapeuri(q))&from=$(from)"
    ciks !== nothing && (url *= "&ciks=$(_normalize_cik(ciks))")
    if forms !== nothing
        url *= "&forms=$(forms isa AbstractString ? forms : join(forms, ","))"
    end
    if startdate !== nothing || enddate !== nothing
        sd = startdate === nothing ? "2001-01-01" : startdate
        ed = enddate === nothing ? "2099-12-31" : enddate
        url *= "&startdt=$(sd)&enddt=$(ed)"
    end
    return _get_json(url)
end

# Internal: null-safe string ("" for a missing/null JSON value) and the first
# element of a possibly-empty/absent JSON array.
_str(x) = (x === nothing || x === missing) ? "" : String(x)
_head(a) = (a === nothing || isempty(a)) ? nothing : first(a)

# Internal: the entity (filer) name from an EFTS `display_names` entry,
# "NAME (TICKER) (CIK …)" — the trailing ticker and CIK groups are dropped (the
# CIK is its own column; tickers belong to `cik()`).
function _entity_name(dn::AbstractString)
    m = match(r"^(.*?)\s*(?:\(([^()]*)\)\s*)?\(CIK\s+\d+\)\s*$", dn)
    return m === nothing ? String(strip(dn)) : String(strip(something(m.captures[1], "")))
end

# Internal: the columns shared by both search functions, built from one EFTS hit.
# `entity` is the filer's name (a company, fund, ETF, institutional manager, …).
# `document` (the primary filename) is recovered from the hit `_id` ("accession:file").
# Some filings (e.g. fund forms) carry a null `period_ending`, so guard every field.
function _efts_row(h)
    s = h._source
    return (cik        = _str(_head(s.ciks)),
            entity     = _entity_name(_str(_head(s.display_names))),
            form       = _str(s.form),
            reportDate = _str(s.period_ending),
            filed      = _str(s.file_date),
            accession  = _str(s.adsh),
            document   = _str(last(split(h._id, ':'))))
end

"""
    full_text_search(query; exact=true, forms=nothing, startdate=nothing, enddate=nothing, from=0) -> Vector{NamedTuple}
    filings_by_text(query; …)   # alias

Search filing *contents* (2001 onward) for `query` via the EDGAR full-text search
(EFTS) API, returning a Tables.jl *row table* (a `Vector` of `NamedTuple`s) of the
matching filings. Also exported as `filings_by_text`, to pair with
[`filings_by_cik`](@ref) (which looks up a filer's filings by CIK instead).

By default `query` is matched as an **exact phrase** (it is wrapped in quotes for
you), so `supply chain disruption` finds only filings with those three words
adjacent — the same as quoting the phrase in the EDGAR web UI. Pass `exact=false`
to send the query verbatim instead, matching the words loosely and letting you use
EDGAR's own operators (e.g. `word1 word2`).

`forms` may be a single string (`"10-K"`) or a collection; `startdate`/`enddate`
are `"YYYY-MM-DD"` strings (passing only one still filters — the other bound
defaults to the edge of EDGAR's coverage). Results come back ranked by relevance.

Columns: `cik`, `entity` (the filer's name — a company, mutual fund, ETF,
money-market fund, institutional manager, …), `form`, `reportDate` (period
covered), `filed` (filing date), `accession`, `document` (primary filename) and
`score` (relevance). Tickers are a filer attribute — use [`cik`](@ref), joining on
the CIK; richer filer data is in [`profile`](@ref).

EFTS returns a **fixed page of 100** results per request. The total match count is
not returned, so to page, advance `from` in steps of 100 until you get fewer than
100 rows (or an empty page). The submissions-only fields (`acceptanceDateTime`, the
XBRL flags) are **not** included: a text search spans many filers, so adding them
would need a submissions fetch per filer (~100 per page) — see
[`filings_by_cik`](@ref), which enriches a single filer cheaply.

```julia
rows = full_text_search("climate risk"; forms = "10-K", startdate = "2024-01-01")
rows[1].entity         # the top hit's filer
using PrettyTables
pretty_table(rows)     # the page as a table
```
"""
function full_text_search(query::AbstractString; exact::Bool=true, forms=nothing, startdate=nothing, enddate=nothing, from::Int=0)
    # Quote the query for an exact-phrase match unless `exact=false` or it is
    # already quoted.
    q = (exact && !(startswith(query, '"') && endswith(query, '"'))) ? "\"" * query * "\"" : query
    res = _efts_search(; q, forms, startdate, enddate, from)
    return [merge(_efts_row(h), (; score = Float64(h._score))) for h in res.hits.hits]
end

"Alias for [`full_text_search`](@ref); pairs with [`filings_by_cik`](@ref)."
const filings_by_text = full_text_search

"""
    filings_by_cik(cik; forms=nothing, startdate=nothing, enddate=nothing, from=0) -> Vector{NamedTuple}

List a single filer's filings (2001 onward) via the EDGAR full-text search (EFTS)
API, using its **entity filter** rather than a text query, returning a Tables.jl
*row table*. `cik` may be an integer or a string, with or without leading zeros.
This is the EFTS counterpart of the web search's company/CIK field — a true "filed
*by* this filer" query, unlike searching for the CIK as document text (which also
matches filings that merely *mention* it).

Each row is **one filing**: `form`, `reportDate` (period covered), `filed` (filing
date), `acceptanceDateTime` (when the SEC accepted it), `accession`, `document`
(primary filename), and the XBRL flags `isXBRL`, `isInlineXBRL`, `isXBRLNumeric`.
The XBRL flags are joined per-filing on the accession (so a `10-K` is XBRL while a
`Form 4` is not), and are `missing` for any filing outside the submissions recent
window. Filer-level data (name, `entityType`, SIC, fiscal year-end, …) is *not*
repeated on every row — get it from [`profile`](@ref).

Results are newest-first (there is no relevance to rank by). `forms`/dates/`from`
behave as in [`full_text_search`](@ref); the page is 100, and there is no total
count, so page by advancing `from` until you get fewer than 100 rows.

```julia
rows = filings_by_cik(320193; forms = "8-K", startdate = "2026-01-01")
rows[1].form, rows[1].filed, rows[1].isXBRL
```
"""
function filings_by_cik(cik; forms=nothing, startdate=nothing, enddate=nothing, from::Int=0)
    res = _efts_search(; ciks = cik, forms, startdate, enddate, from)
    rec = _fetch_submissions(cik).filings.recent
    # accession -> row index in the submissions recent array, for the per-filing join
    idx = Dict(String(rec.accessionNumber[i]) => i for i in eachindex(rec.accessionNumber))
    mstr(x) = x === nothing ? missing : String(x)
    mflag(x) = x === nothing ? missing : Bool(x)
    # Explicit row type: the enrichment columns are `missing` for any filing outside
    # the submissions recent window, so they must be Union{Missing,…} for all rows.
    RowT = @NamedTuple{form::String, reportDate::String, filed::String,
                       acceptanceDateTime::Union{Missing,String}, accession::String,
                       document::String, isXBRL::Union{Missing,Bool},
                       isInlineXBRL::Union{Missing,Bool}, isXBRLNumeric::Union{Missing,Bool}}
    function row(h)
        e = _efts_row(h)
        i = get(idx, String(h._source.adsh), nothing)
        at(arr) = i === nothing ? nothing : arr[i]   # nothing if the filing isn't in the recent window
        return (form = e.form, reportDate = e.reportDate, filed = e.filed,
                acceptanceDateTime = mstr(at(rec.acceptanceDateTime)),
                accession = e.accession, document = e.document,
                isXBRL = mflag(at(rec.isXBRL)), isInlineXBRL = mflag(at(rec.isInlineXBRL)),
                isXBRLNumeric = mflag(at(rec.isXBRLNumeric)))
    end
    return RowT[row(h) for h in res.hits.hits]
end

"""
    profile(cik) -> NamedTuple

The filer-level profile from the SEC submissions API — the data that is invariant
across a filer's filings, so it lives here rather than being repeated in the
per-filing rows of [`filings_by_cik`](@ref). `cik` may be an integer or a string,
with or without leading zeros.

Fields: `cik`, `name`, `entityType` (`"operating"` for a company, `"investment"`
for a mutual fund / ETF / money-market fund, …), `sic`, `sicDescription`,
`fiscalYearEnd`, `stateOfIncorporation`, `tickers`, `exchanges`, `ein`, `category`,
`website`, `description`, `formerNames`.

```julia
p = profile(320193)
p.name           # "Apple Inc."
p.entityType     # "operating"
p.sic            # "3571"
p.fiscalYearEnd  # "0927"
```
"""
function profile(cik)
    s = _fetch_submissions(cik)
    return (cik                  = _normalize_cik(cik),
            name                 = _str(get(s, :name, nothing)),
            entityType           = _str(get(s, :entityType, nothing)),
            sic                  = _str(get(s, :sic, nothing)),
            sicDescription       = _str(get(s, :sicDescription, nothing)),
            fiscalYearEnd        = _str(get(s, :fiscalYearEnd, nothing)),
            stateOfIncorporation = _str(get(s, :stateOfIncorporation, nothing)),
            tickers              = String[String(x) for x in get(s, :tickers, ())],
            exchanges            = String[String(x) for x in get(s, :exchanges, ())],
            ein                  = _str(get(s, :ein, nothing)),
            category             = _str(get(s, :category, nothing)),
            website              = _str(get(s, :website, nothing)),
            description          = _str(get(s, :description, nothing)),
            formerNames          = String[_str(get(x, :name, nothing)) for x in get(s, :formerNames, ())])
end

_company_tickers_raw() = _get_json("https://www.sec.gov/files/company_tickers.json")

"""
    cik() -> Vector{@NamedTuple{entity::String, ticker::String, cik::String}}
    cik(entity::AbstractString; by::Symbol = :any) -> Vector{…}

Look up ticketed entities (companies and ETFs/funds with a ticker) in the SEC's
`company_tickers.json`, always returned as a Tables.jl *row table* — a `Vector` of
`NamedTuple`s with fields `entity` (name), `ticker` and the 10-digit, zero-padded
`cik`.

- `cik()` returns every entity.
- `cik(entity)` (the default, `by = :any`) returns the rows matching `entity`
  *either* by name (case-insensitive substring) or by an exact ticker — so a short
  string like `"IBM"` finds the ticker and a word like `"apple"` finds the name,
  without you having to say which. Each row is tested once, so a row matching both
  is returned only once.
- `cik(entity; by = :name)` matches the name only (substring).
- `cik(entity; by = :ticker)` matches an exact (case-insensitive) ticker — `0` or
  `1` row; pull the bare CIK with `only(cik("AAPL"; by = :ticker)).cik`.

The result type is the same for every form, so it stays type-stable. A query may
match several rows, since one company can have multiple tickers (e.g. share
classes like `GOOGL`/`GOOG`) and a loose name can match more than one filer.

Because it implements the [Tables.jl](https://github.com/JuliaData/Tables.jl)
interface, any tool that reads tables takes the result directly — `DataFrames`, a
`CSV` file, Arrow, a SQL database — and as a plain `Vector` it indexes and slices
naturally.

```julia
cik()[1:5]                          # first 5 of every company
cik("IBM")                          # by = :any (default) — finds the ticker
cik("alphabet"; by = :name)        # company-name substring
cik("AAPL"; by = :ticker)          # 0 or 1 row

using CSV
CSV.write("tickers.csv", cik())
```
"""
function cik()
    raw = _company_tickers_raw()
    return [(entity = String(v.title), ticker = String(v.ticker), cik = lpad(v.cik_str, 10, '0'))
            for (_, v) in raw]
end

function cik(entity::AbstractString; by::Symbol = :any)
    needle = lowercase(strip(entity))
    t = uppercase(strip(entity))
    if by === :name
        return filter!(r -> occursin(needle, lowercase(r.entity)), cik())
    elseif by === :ticker
        return filter!(r -> uppercase(r.ticker) == t, cik())
    elseif by === :any
        return filter!(r -> occursin(needle, lowercase(r.entity)) || uppercase(r.ticker) == t, cik())
    else
        throw(ArgumentError("`by` must be :name, :ticker or :any, got $(repr(by))"))
    end
end

function _cik_dir(cik)
    return joinpath(pwd(), "data", strip(cik))
end

"""
    Filing

A single filing document fetched into memory by [`fetch_filing`](@ref): its
`content` (a `String`) plus `cik` (10-digit), `accession`, `document` (the
filename), source `url`, and `kind` — `:ixbrl` (inline-XBRL HTML), `:xbrl` (a
classic XBRL instance), or `:html` (a filing with no XBRL). Persist it with
[`save_filing`](@ref).
"""
struct Filing
    cik::String
    accession::String
    document::String
    url::String
    kind::Symbol
    content::String
end

Base.show(io::IO, f::Filing) =
    print(io, "Filing(", repr(f.kind), ", ", repr(f.document), ", ", length(f.content), " bytes)")

# Internal: the base Archives URL for a filing's directory.
_filing_dir(cik, accession) =
    "https://www.sec.gov/Archives/edgar/data/$(parse(Int, _normalize_cik(cik)))/$(replace(accession, "-" => ""))"

# Internal: locate the XBRL *instance* document in a filing's directory (via its
# `index.json` file list), skipping the schema (`.xsd`) and the linkbases
# (`_cal`/`_def`/`_lab`/`_pre`/`_ref`.xml). Prefers the iXBRL-extracted `_htm.xml`.
function _xbrl_instance(base)
    names = String[String(it.name) for it in _get_json("$base/index.json").directory.item]
    xml = filter(n -> endswith(lowercase(n), ".xml") &&
                      !occursin(r"_(cal|def|lab|pre|ref)\.xml$"i, n), names)
    isempty(xml) && error("no XBRL instance (.xml) found in $base")
    j = findfirst(n -> endswith(lowercase(n), "_htm.xml"), xml)
    return j === nothing ? first(xml) : xml[j]
end

# Internal: locate a filing by accession across a filer's *entire* submissions
# history and return the fields `fetch_filing` needs (`primaryDocument` and the
# `isInlineXBRL`/`isXBRL` flags), or `nothing` if the accession is not found.
#
# The submissions document only inlines the most recent ~1000 filings under
# `filings.recent`; for a prolific filer (Apple files Form 4s almost daily) older
# filings spill into additional JSON pages listed in `filings.files`. Those pages
# carry the same column arrays at their top level, so the same scan works on both.
function _find_filing(cik, accession)
    sub = _fetch_submissions(cik)
    function scan(rec)
        i = findfirst(a -> String(a) == accession, rec.accessionNumber)
        i === nothing && return nothing
        flag(arr) = (v = arr[i]; v !== nothing && v == 1)
        return (primaryDocument = String(rec.primaryDocument[i]),
                isInlineXBRL = flag(rec.isInlineXBRL),
                isXBRL = flag(rec.isXBRL))
    end
    r = scan(sub.filings.recent)
    r === nothing || return r
    for f in get(sub.filings, :files, ())
        page = _get_json("https://data.sec.gov/submissions/$(String(f.name))")
        r = scan(page)
        r === nothing || return r
    end
    return nothing
end

"""
    fetch_filing(cik, accession; kind=:auto) -> Filing

Fetch a single filing's document into memory (no disk write) as a [`Filing`](@ref).
`cik` may be an integer or string; `accession` is the dashed accession number
(e.g. `"0000320193-26-000011"`). The fetch goes through [`fetch_url`](@ref), so it
is cached and uses the configured User-Agent.

`kind` selects which document:
- `:auto` (default) — the **inline-XBRL** primary document if the filing has it
  (`isInlineXBRL`), else the classic **XBRL** instance if it has one (`isXBRL`),
  else the plain primary HTML.
- `:ixbrl` / `:html` — the primary document (`primaryDocument` from submissions).
- `:xbrl` — the classic XBRL instance (`.xml`), located via the filing's `index.json`.

The filing is located anywhere in the filer's submissions history: the recent
window plus the older paginated pages, so even a long-past accession from a prolific
filer is found. Save the result with `save_filing(f; destdir)`.

```julia
f = fetch_filing(320193, "0000320193-26-000011")   # :auto -> iXBRL for a recent 10-K/8-K
f.kind, f.document
save_filing(f; destdir = "filings")
```
"""
function fetch_filing(cik::Union{Integer,AbstractString}, accession::AbstractString; kind::Symbol=:auto)
    cik10 = _normalize_cik(cik)
    base = _filing_dir(cik, accession)
    info = _find_filing(cik, accession)
    info === nothing && error("filing $(accession) was not found in $(cik10)'s submissions history")
    want = kind === :auto ? (info.isInlineXBRL ? :ixbrl :
                             info.isXBRL ? :xbrl : :html) : kind
    doc = if want === :ixbrl || want === :html
        info.primaryDocument
    elseif want === :xbrl
        _xbrl_instance(base)
    else
        throw(ArgumentError("`kind` must be :auto, :ixbrl, :xbrl or :html, got $(repr(kind))"))
    end
    url = "$base/$doc"
    body = fetch_url(url)
    body === nothing && error("could not fetch $url")
    return Filing(cik10, accession, doc, url, want, String(body))
end

# Internal: the directory URL a filing was fetched from — everything up to and
# including the final slash of `f.url` — against which the relative asset
# references (images, stylesheets) inside the filing HTML are resolved.
_filing_base_url(f::Filing) = f.url[1:something(findlast('/', f.url), 0)]

# Internal: file extensions of the relative assets worth downloading to make a
# saved filing self-contained — chiefly the embedded images, plus any external
# CSS/JS. Extensions outside this list (e.g. `.htm` links to sibling filings, or
# document anchors) are deliberately skipped.
const _ASSET_EXT = (".jpg", ".jpeg", ".png", ".gif", ".svg", ".webp", ".bmp", ".ico", ".css", ".js")

"""
    download_assets(f::Filing; destdir=".") -> Vector{String}

Download the relative assets — chiefly the embedded images — that a fetched
[`Filing`](@ref)'s HTML references, writing each next to the document under
`destdir` so the saved filing renders self-contained (a filing's images live
beside it in the EDGAR Archives directory, and [`fetch_filing`](@ref) downloads
only the primary document). The `src`/`href` attributes are scanned; only relative
URLs with a known asset extension ([`_ASSET_EXT`]) are taken, so links to sibling
filings and in-page anchors are skipped. Each asset is fetched through the cached
[`fetch_url`](@ref) and written preserving any sub-path. The download is
best-effort: a reference that cannot be fetched is skipped. Returns the filenames
written. Called automatically by [`open_filing`](@ref) and [`save_filing`](@ref).
"""
function download_assets(f::Filing; destdir=".")
    base = _filing_base_url(f)
    isempty(base) && return String[]
    seen = Set{String}()
    written = String[]
    for m in eachmatch(r"(?:src|href)\s*=\s*[\"']([^\"'#?]+)"i, f.content)
        rel = strip(m.captures[1])
        (isempty(rel) || rel in seen) && continue
        (startswith(rel, "http://") || startswith(rel, "https://") || startswith(rel, "//") ||
         startswith(rel, "data:") || startswith(rel, "mailto:")) && continue
        any(e -> endswith(lowercase(rel), e), _ASSET_EXT) || continue
        push!(seen, rel)
        cleaned = startswith(rel, "./") ? rel[3:end] : rel
        body = fetch_url(base * cleaned)
        body === nothing && continue
        dest = joinpath(destdir, cleaned)
        mkpath(dirname(dest))
        write(dest, body)
        push!(written, cleaned)
    end
    return written
end

"""
    open_filing(f::Filing; assets=true) -> String

View a fetched [`Filing`](@ref) in your default browser. A browser can only open a
file or URL, not an in-memory string, so this writes `f` to a fresh **temporary**
directory (under the filename `f.document`, so the extension/title are right) and
opens it, returning that path. This is a throwaway view — use [`save_filing`](@ref)
to keep a copy.

With `assets=true` (the default) the filing's relative assets — chiefly its
embedded images — are downloaded beside the document via [`download_assets`](@ref)
so they render; pass `assets=false` to open just the HTML (faster, no extra
requests, but images referenced relatively appear blank).
"""
# Internal: hand a local file path (or URL) to the OS to open in its default
# application — the browser, for HTML. The single place the platform dispatch lives.
function _open_in_default_app(target::AbstractString)
    cmd = Sys.isapple()   ? `open $target` :
          Sys.iswindows() ? `cmd /c start "" $target` : `xdg-open $target`
    run(cmd)
    return target
end

function open_filing(f::Filing; assets::Bool=true)
    # cleanup=true (the default, made explicit) registers an atexit hook that
    # removes this directory — the document and its downloaded images together —
    # when the Julia process exits, so nothing lingers in the temp dir. Deletion
    # waits until exit (not right after `run`) since the browser opens the file
    # asynchronously and must still be able to read it.
    dir = mktempdir(; prefix="EDGAR_filing_", cleanup=true)
    path = joinpath(dir, f.document)
    write(path, f.content)
    assets && download_assets(f; destdir=dir)
    return _open_in_default_app(path)
end

"""
    open_filing(path::AbstractString) -> String

Open a filing **already saved on disk** in your default browser, returning `path` —
the on-disk counterpart to [`open_filing(f::Filing)`](@ref). Use it to view a filing
written with [`save_filing`](@ref), or any HTML page you saved yourself (an extracted
section such as a balance sheet, say — still part of the filing). The path must exist
(an `ArgumentError` is thrown otherwise); an `http(s)://` URL is passed through as-is.

```julia
path = save_filing(f; destdir = "filings")
open_filing(path)                            # reload from disk and view
```
"""
function open_filing(path::AbstractString)
    is_url = startswith(path, "http://") || startswith(path, "https://")
    is_url || isfile(path) || throw(ArgumentError("no such file to open: $(repr(path))"))
    return _open_in_default_app(path)
end

"""
    open_filing(cik, accession; kind=:auto, assets=true) -> String

Fetch a filing and view it in your default browser in one step — the convenience
combination of [`fetch_filing`](@ref) and [`open_filing`](@ref). `cik`, `accession`
and `kind` are exactly as in [`fetch_filing`](@ref); `assets` is as in
[`open_filing`](@ref). Returns the temporary file path that was opened.

```julia
open_filing(320193, "0000320193-25-000079")   # fetch the 10-K and open it
```
"""
open_filing(cik::Union{Integer,AbstractString}, accession::AbstractString; kind::Symbol=:auto, assets::Bool=true) =
    open_filing(fetch_filing(cik, accession; kind); assets)

# Internal: image extensions → MIME type, for the `data:` URIs used to inline a
# filing's images when rendering it self-contained in a notebook.
const _IMAGE_MIME = Dict(".jpg"=>"image/jpeg", ".jpeg"=>"image/jpeg", ".png"=>"image/png",
                         ".gif"=>"image/gif", ".svg"=>"image/svg+xml", ".webp"=>"image/webp",
                         ".bmp"=>"image/bmp", ".ico"=>"image/x-icon")

# Internal: return `f.content` with every relative image reference rewritten to a
# self-contained base64 `data:` URI, so the HTML renders with its images and no
# external files — the in-memory equivalent of `download_assets`, used by the
# notebook `show` method (which renders an HTML string in-page, where relative
# `src` paths cannot resolve). Each image is fetched once through the cached
# `fetch_url`; a reference that fails to download is left untouched.
function _inline_images(f::Filing)
    base = _filing_base_url(f)
    isempty(base) && return f.content
    html = f.content
    uris = Dict{String,String}()
    for m in eachmatch(r"(src|href)\s*=\s*([\"'])([^\"'#?]+)\2"i, f.content)
        rel = strip(m.captures[3])
        (startswith(rel, "http://") || startswith(rel, "https://") || startswith(rel, "//") ||
         startswith(rel, "data:") || startswith(rel, "mailto:")) && continue
        mime = get(_IMAGE_MIME, lowercase(splitext(rel)[2]), nothing)
        mime === nothing && continue
        if !haskey(uris, rel)
            body = fetch_url(base * (startswith(rel, "./") ? rel[3:end] : rel))
            uris[rel] = body === nothing ? "" : "data:$mime;base64,$(base64encode(body))"
        end
        isempty(uris[rel]) && continue
        html = replace(html, m.match => "$(m.captures[1])=$(m.captures[2])$(uris[rel])$(m.captures[2])")
    end
    return html
end

# Render a Filing inline in notebook front-ends (Jupyter/IJulia, Pluto, …) that
# request `text/html`. iXBRL/HTML filings are emitted with their images inlined as
# `data:` URIs (via `_inline_images`) so the document renders self-contained; a
# classic XBRL instance is XML, not HTML, so its source is shown escaped inside a
# <pre> instead of being interpreted as markup.
function Base.show(io::IO, ::MIME"text/html", f::Filing)
    if f.kind === :xbrl
        esc = replace(f.content, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
        print(io, "<pre>", esc, "</pre>")
    else
        print(io, _inline_images(f))
    end
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
    save_filing(f::Filing; destdir=".", assets=true) -> String

Persist a fetched [`Filing`](@ref) (iXBRL/XBRL/HTML) verbatim to
`<destdir>/<f.document>`, creating `destdir` if needed, and return the path written
— the save half of what the old `download_filing` did, now separate from
[`fetch_filing`](@ref). With `assets=true` (the default) the filing's relative
assets — chiefly its embedded images — are also downloaded into `destdir` via
[`download_assets`](@ref) so the saved copy renders self-contained; pass
`assets=false` to write only the document.
"""
function save_filing(f::Filing; destdir=".", assets::Bool=true)
    isdir(destdir) || mkpath(destdir)
    path = joinpath(destdir, f.document)
    write(path, f.content)
    assets && download_assets(f; destdir)
    return path
end

# Internal: the handful of named HTML entities common in filings, plus the ones
# that must be decoded last (so a literal "&amp;lt;" survives as "&lt;").
const _ENTITIES = ["&nbsp;" => " ", "&#160;" => " ", "&lt;" => "<", "&gt;" => ">",
                   "&quot;" => "\"", "&#39;" => "'", "&apos;" => "'", "&mdash;" => "—",
                   "&ndash;" => "–", "&rsquo;" => "’", "&lsquo;" => "‘",
                   "&amp;" => "&"]

# Internal: turn a fragment of filing HTML into plain text — drop <script>/<style>
# blocks, strip the remaining tags, decode the common HTML entities, and collapse
# runs of whitespace. Shared by every extraction path so output is uniform.
function clean_text(fragment::AbstractString)
    txt = replace(fragment, r"(?is)<script.*?</script>" => " ")
    txt = replace(txt, r"(?is)<style.*?</style>" => " ")
    txt = replace(txt, r"(?is)<[^>]+>" => " ")
    txt = replace(txt, r"&#(\d+);" => m -> string(Char(parse(Int, m[3:end-1]))))   # numeric entities
    txt = replace(txt, _ENTITIES...)                                               # &amp; decoded last
    txt = replace(txt, ' ' => ' ')                                            # NBSP -> space
    txt = replace(txt, r"\s+" => " ")
    return strip(txt)
end

"""
    extract_section(html, names; base_path=nothing) -> Dict{String,String}

Pull one or more named sections out of a filing's `html`, returning a dictionary
that maps each requested name to the matched text. Names that cannot be located
are simply absent from the result, so look them up with `get`.

Matching is heuristic and tried in order: the document's table of contents
(following anchor links), then the document's own headings (`h1`–`h6`), then a
plain-text search as a last resort. `base_path` lets table-of-contents links that
point to sibling files be resolved relative to it. Each section's full text is
returned (bounded only by where the next section starts).

```julia
sections = extract_section(html, ["Item 7", "Management's Discussion"])
println(get(sections, "Item 7", "(not found)"))
```
"""
function extract_section(html::AbstractString, names::Vector{String}; base_path::Union{Nothing,String}=nothing)
    results = Dict{String,String}()

    # Step 1 — reduce to the <body>. All later offsets are within `body`. Locate the
    # open/close tags with bounded searches rather than a `.*?` span — a 10-K can be
    # >10 MB, which overruns PCRE's backtracking limit on a lazy match.
    bopen = match(r"(?is)<body\b[^>]*>", html)
    if bopen === nothing
        body = String(html)
    else
        bclose = findlast("</body>", html)
        stop = bclose === nothing ? lastindex(html) : last(bclose)
        body = String(html[bopen.offset:stop])
    end

    # Label normaliser: drop tags, decode numeric entities and NBSP, collapse
    # whitespace. Filings write item numbers as "Item&#160;1A.", so decoding the
    # entity is what lets a query like "Item 1A" match the label.
    function norm(s)
        t = replace(s, r"<[^>]+>" => " ")
        t = replace(t, r"&#(\d+);" => m -> string(Char(parse(Int, m[3:end-1]))))
        t = replace(t, "&nbsp;" => " ", '\u00a0' => ' ')
        return strip(replace(t, r"\s+" => " "))
    end

    # Step 2 — collect heading markers: each <h1>-<h6> becomes a section start at
    # its offset, labelled by its (tag-stripped) inner text. (`\1` ties the close
    # tag to the same level as the open tag.)
    markers = Tuple{Int,String}[]
    for h in eachmatch(r"(?is)<(h[1-6])\b[^>]*>(.*?)</\1>", body)
        push!(markers, (h.offset, norm(h.captures[2])))
    end

    # Step 3 — parse the table of contents into an id -> label map, and add a
    # marker for each element the TOC targets. The TOC gives section anchors a
    # human label (and `toc_links` carries cross-file hrefs for Step 8).
    toc_links = Tuple{String,String}[]                      # (href, label)
    for a in eachmatch(r"(?is)<a\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", body)
        label = norm(a.captures[2])
        isempty(label) || push!(toc_links, (String(a.captures[1]), label))
    end
    # id -> label, for same-document (#id) targets. A TOC row is often several
    # links to the same target ("Item 1A." / "Risk Factors" / "5"); join them so
    # the section name is preserved rather than overwritten by the page number.
    id_label = Dict{String,String}()
    for (href, label) in toc_links
        startswith(href, "#") || continue
        id = href[2:end]
        id_label[id] = haskey(id_label, id) ? id_label[id] * " " * label : label
    end
    # Add a marker only for elements the TOC actually targets. Filings tag nearly
    # every inline value with an id (XBRL facts etc.); treating all of them as
    # section starts would chop a section at its first inline anchor, so we keep
    # only the TOC-target ids (real section starts) plus the headings from Step 2.
    for e in eachmatch(r"(?is)<[a-z][a-z0-9]*\b[^>]*\b(?:id|name)=[\"']([^\"']+)[\"'][^>]*>", body)
        id = String(e.captures[1])
        haskey(id_label, id) || continue
        # Fold the de-slugified id into the label as well. Some filers (e.g.
        # Microsoft) link only the section *title* in the TOC and put the item
        # number in the id ("item_1a_risk_factors"), so this lets a query like
        # "Item 1A" match too; an opaque id (Apple's "i7193…_94") is harmless noise.
        push!(markers, (e.offset, id_label[id] * " " * replace(id, r"[_\-]+" => " ")))
    end

    # Step 4 — merge into one document-order boundary list. Headings and anchors
    # often coincide (a heading just inside its anchored <div>); collapse the two
    # only when nothing but tags/whitespace separates them — never two markers with
    # real text between them — keeping the labelled one.
    sort!(markers, by = first)
    boundaries = Tuple{Int,String}[]
    for (off, label) in markers
        if !isempty(boundaries) &&
           isempty(strip(replace(body[first(boundaries[end]):prevind(body, off)], r"(?is)<[^>]*>" => "")))
            # same boundary as the previous marker: fill in a label if we lacked one
            isempty(last(boundaries[end])) && !isempty(label) && (boundaries[end] = (first(boundaries[end]), label))
        else
            push!(boundaries, (off, label))
        end
    end

    # Step 5 — match each requested name to its best boundary. An exact
    # case-insensitive substring (e.g. "Item 7" inside "Item 7. Management's…")
    # wins outright; otherwise fall back to fuzzy similarity. Records the index
    # into `boundaries` so Step 6 can slice to the next one.
    best_boundary = Dict{String,Int}()
    for name in names
        needle = lowercase(strip(name))
        best_i = 0; best_score = 0.0
        for (i, (_, label)) in enumerate(boundaries)
            isempty(label) && continue
            score = occursin(needle, lowercase(label)) ? 1.0 : similarity_ratio(name, label)
            if score > best_score
                best_score = score; best_i = i
            end
        end
        best_score > 0.6 && (best_boundary[name] = best_i)
    end

    # Step 6 — slice each matched section: from its boundary offset up to the start
    # of the *next* boundary (or end of body), then strip to plain text. Slicing to a
    # boundary is what makes nesting irrelevant.
    #
    # One refinement: a top-level "Item N" often contains its own sub-sections that
    # are themselves TOC targets (Item 8's Balance Sheets, Income Statements, Notes,
    # …). Stopping at the first of those would truncate the item to its heading, so
    # when the matched boundary names an item, the section runs to the next boundary
    # that names a *different* item — skipping the sub-sections in between.
    item_no(label) = (m = match(r"(?i)\bitem\s+(\d+[a-z]?)\b", label); m === nothing ? nothing : lowercase(m.captures[1]))
    for (name, i) in best_boundary
        start = first(boundaries[i])
        cur = item_no(boundaries[i][2])
        j = i + 1
        if cur !== nothing
            # advance past sub-sections (no item, or the same item) to the next
            # boundary that names a different item
            while j <= length(boundaries)
                nj = item_no(boundaries[j][2])
                (nj !== nothing && nj != cur) && break
                j += 1
            end
        end
        stop = j <= length(boundaries) ? prevind(body, first(boundaries[j])) : lastindex(body)
        results[name] = clean_text(body[start:stop])
    end

    # Step 8 — cross-file links. A TOC entry may point into another document
    # ("other_page.html#item7"). For any name not found in this body, match it
    # against the TOC link labels; if the best link carries a file part, load that
    # file (locally via `base_path`, or remotely) and extract the section from it.
    for name in names
        haskey(results, name) && continue
        needle = lowercase(strip(name))
        best_href = ""; best_score = 0.0
        for (href, label) in toc_links
            score = occursin(needle, lowercase(label)) ? 1.0 : similarity_ratio(name, label)
            if score > best_score
                best_score = score; best_href = href
            end
        end
        best_score > 0.6 || continue
        file = first(split(best_href, '#'))
        isempty(file) && continue                       # same-document, already handled
        other_html = if occursin("://", file) || startswith(file, "//")
            raw = fetch_url(file); raw === nothing ? nothing : String(raw)
        elseif base_path !== nothing
            p = joinpath(dirname(base_path), file); isfile(p) ? read(p, String) : nothing
        else
            nothing
        end
        other_html === nothing && continue
        sub = extract_section(other_html, [name])
        haskey(sub, name) && (results[name] = sub[name])
    end

    # Step 9 — last-resort plain-text fallback for a body with no usable TOC or
    # headings. Search the cleaned text for the name with flexible whitespace and
    # return from the match to the end of the text. The index comes from the *same*
    # string we searched, so it stays aligned (the previous implementation searched a
    # stripped copy but sliced the original, misaligning the result).
    local plain
    for name in names
        haskey(results, name) && continue
        @isdefined(plain) || (plain = clean_text(body))
        pat = Regex(join((replace(w, r"([\\^\$.|?*+()\[\]{}])" => s"\\\1") for w in split(strip(name))), "\\s+"), "i")
        r = findfirst(pat, plain)
        r === nothing && continue
        results[name] = strip(plain[first(r):end])
    end

    return results
end

# ── Interactive selection ──────────────────────────────────────────────────
#
# The picker (see `select_section`) lets a user click a region in a rendered
# filing; that region comes back as a `Selection`, the unit every export layer
# (Markdown, facts, …) operates on. The type is defined here as a stable contract
# ahead of the machinery that produces it.

include("picker.jl")   # PICKER_JS — the browser-side overlay (Step 1.1)

"""
    Fact

One numeric XBRL fact extracted from a tagged region of a filing — the atom of the
analytical (Layer 2/3) output. Values are stored **normalised** (the displayed
number with `scale` and `sign` already applied), and the context/unit references are
**resolved** so a row is self-describing, while the raw refs are kept for provenance.

Fields:

- `cik`, `accession` — the filer and filing (provenance/identity).
- `statement` — which statement/section the fact sits in (e.g. `"BalanceSheet"`), or
  `""` if not classified.
- `concept` — the XBRL concept, namespaced (`"us-gaap:Assets"`, or an issuer extension).
- `label` — the human-readable label as presented.
- `value` — the **normalised** numeric value (`displayed × 10^scale × sign`).
- `unit` — the resolved unit (`"USD"`, `"shares"`, `"USD/shares"`, `"pure"`).
- `period_start` — the start of a duration; `nothing` for an instant.
- `period_end` — the period end (instants) or duration end.
- `is_instant` — `true` for a point-in-time fact (balance-sheet items), `false` for a
  flow (income-statement / cash-flow items).
- `dimensions` — axis ⇒ member qualifiers (segment, geography, …); empty when none.
- `decimals` — reported precision; `nothing` for `INF` / unspecified.
- `context_ref`, `unit_ref` — the raw iXBRL references (provenance/debug).
- `source_selector` — the DOM region ([`Selection`](@ref)) the fact came from.

Only **numeric** facts are represented here; non-numeric tags (text/date) belong to
the presentation/text layer. `Fact`s flow to disk as a Tables.jl row table (see the
internal `fact_row` for the exact column schema and the dedup key). Build one with the
keyword constructor.
"""
struct Fact
    cik::String
    accession::String
    statement::String
    concept::String
    label::String
    value::Float64
    unit::String
    period_start::Union{Date,Nothing}
    period_end::Date
    is_instant::Bool
    dimensions::Dict{String,String}
    decimals::Union{Int,Nothing}
    context_ref::String
    unit_ref::String
    source_selector::String
end

# Keyword constructor — the positional form has 15 fields; this keeps construction
# (in Phase 3 and in tests) readable, with sensible defaults for the optional ones.
function Fact(; concept, value, period_end, is_instant, unit="",
              cik="", accession="", statement="", label="",
              period_start=nothing, dimensions=Dict{String,String}(), decimals=nothing,
              context_ref="", unit_ref="", source_selector="")
    return Fact(cik, accession, statement, concept, label, Float64(value), unit,
                period_start, period_end, is_instant, dimensions, decimals,
                context_ref, unit_ref, source_selector)
end

Base.show(io::IO, f::Fact) =
    print(io, "Fact(", f.concept, " = ", f.value, " ", f.unit,
          " @ ", f.is_instant ? f.period_end : "$(f.period_start)..$(f.period_end)", ")")

# Internal: one fact as a Tables.jl row (a NamedTuple) — the exact column schema and
# order written to disk. `dimensions` is serialised to a JSON string for storage. The
# warehouse dedup key is (accession, concept, context_ref, unit_ref) — i.e. one fact
# per concept × context × unit within a filing — so re-importing a filing is a no-op.
fact_row(f::Fact) =
    (cik = f.cik, accession = f.accession, statement = f.statement, concept = f.concept,
     standard_concept = standardize(f.concept), label = f.label, value = f.value, unit = f.unit,
     period_start = f.period_start, period_end = f.period_end, is_instant = f.is_instant,
     dimensions = JSON3.write(f.dimensions), decimals = f.decimals,
     context_ref = f.context_ref, unit_ref = f.unit_ref, source_selector = f.source_selector)

# The fact row-table schema: the element type of the Tables.jl row table that `facts`
# returns. It mirrors `fact_row` exactly, so an empty table (from a prose-only
# selection) is still concretely typed rather than a `Vector{Any}`. `standard_concept`
# is the cross-company mapping (W4), `nothing` when the concept is unmapped.
const FactRow = @NamedTuple{cik::String, accession::String, statement::String,
    concept::String, standard_concept::Union{Nothing,String}, label::String, value::Float64,
    unit::String, period_start::Union{Nothing,Date}, period_end::Date, is_instant::Bool,
    dimensions::String, decimals::Union{Nothing,Int}, context_ref::String,
    unit_ref::String, source_selector::String}

# A structured table captured from a selection: a header row and the body rows, each a
# vector of cell strings (the browser resolves colspan/rowspan before sending).
const SelectionTable = @NamedTuple{header::Vector{String}, rows::Vector{Vector{String}}}

"""
    Selection

A region a user picked from a rendered filing via [`select_section`](@ref) — the
unit the export layers operate on. It carries enough provenance to trace any
downstream artifact (a Markdown chunk, a fact row) back to the exact filing and DOM
region it came from:

- `cik` — the filer's 10-digit, zero-padded Central Index Key.
- `accession` — the filing's dashed accession number.
- `url` — the source document URL the region was picked from.
- `selector` — a CSS selector locating the region within the document, so the same
  pick can be re-applied to a later filing of the same form.
- `kind` — `:table`, `:prose`, or `:mixed`: what the region holds, which decides the
  export layers that apply (a table yields facts/rows; prose yields text only).
- `text` — the region's plain text (its `innerText`).
- `html` — the region's raw `outerHTML` (the lossless fragment).
- `table` — the structured table (`header` + `rows`) when the region is/contains one,
  else `nothing` (drives the Markdown table export).
- `facts` — the resolved numeric [`Fact`](@ref)s in the region (empty for prose).

`Selection`s are produced by [`select_section`](@ref); you rarely build one by hand
outside of tests (use the keyword constructor there).
"""
struct Selection
    cik::String
    accession::String
    url::String
    selector::String
    kind::Symbol
    text::String
    html::String
    table::Union{Nothing,SelectionTable}
    facts::Vector{Fact}
end

Selection(; cik="", accession="", url="", selector="", kind::Symbol=:prose, text="",
          html="", table=nothing, facts=Fact[]) =
    Selection(cik, accession, url, selector, kind, text, html, table, facts)

Base.show(io::IO, s::Selection) =
    print(io, "Selection(", repr(s.kind), ", ", repr(s.selector), ", ",
          length(s.text), " chars, ", length(s.facts), " facts)")

# ── Transport contract (browser → Julia) ───────────────────────────────────
#
# The picker's JS POSTs a JSON payload describing the selected region. Because the
# browser has the whole document DOM (and its <ix:header>), it resolves contexts,
# units and dimensions before sending; Julia only normalises the numeric value
# (value × 10^scale × sign) and shapes the types. Payload (version 1):
#
#   { "version": 1,
#     "provenance": { "cik": "...", "accession": "...", "url": "..." },
#     "selector": "#item8 table", "kind": "table",
#     "text": "ASSETS …", "html": "<table>…</table>",
#     "table": { "header": ["", "2025", "2024"],
#                "rows":   [["Cash","10729","10727"], …] },          // or null
#     "facts": [ { "concept": "us-gaap:CashAndCashEquivalents...",
#                  "label": "Cash and cash equivalents",
#                  "value": 10729, "scale": 6, "sign": "", "decimals": -6,
#                  "unit": "USD", "unitRef": "usd", "contextRef": "c-3",
#                  "periodStart": null, "periodEnd": "2025-04-30",
#                  "isInstant": true, "dimensions": {} }, … ]        // or []
#   }
const SELECTION_SCHEMA_VERSION = 1

# Internal: JSON value (number or comma-formatted string) → Float64.
_tonum(x) = x isa Number ? Float64(x) : parse(Float64, replace(strip(String(x)), "," => ""))

# Internal: build one Fact from a payload fact object, applying scale/sign and
# resolving the (already JS-resolved) period/unit/dimensions into Julia types.
function _parse_fact(fj, cik, accession, source_selector)
    scale = Int(get(fj, :scale, 0))
    sign  = String(get(fj, :sign, ""))
    value = _tonum(fj.value) * 10.0^scale * (sign == "-" ? -1.0 : 1.0)
    ps = get(fj, :periodStart, nothing)
    period_start = (ps === nothing || ps == "") ? nothing : Date(String(ps))
    dec = get(fj, :decimals, nothing)
    decimals = (dec === nothing || dec == "INF") ? nothing : Int(dec)
    dims = Dict{String,String}()
    dj = get(fj, :dimensions, nothing)
    dj === nothing || for (k, v) in pairs(dj); dims[String(k)] = String(v); end
    return Fact(; cik, accession, statement = String(get(fj, :statement, "")),
                concept = String(fj.concept), label = String(get(fj, :label, "")),
                value, unit = String(get(fj, :unit, "")),
                period_start, period_end = Date(String(fj.periodEnd)),
                is_instant = Bool(get(fj, :isInstant, false)), dimensions = dims, decimals,
                context_ref = String(get(fj, :contextRef, "")),
                unit_ref = String(get(fj, :unitRef, "")), source_selector)
end

# Internal: a copy of a Fact with its `statement` replaced (Fact is immutable). Used to apply
# statement classification to picked facts after the fact, mirroring `facts(::Filing; classify)`.
_with_statement(f::Fact, statement::AbstractString) =
    Fact(f.cik, f.accession, String(statement), f.concept, f.label, f.value, f.unit,
         f.period_start, f.period_end, f.is_instant, f.dimensions, f.decimals,
         f.context_ref, f.unit_ref, f.source_selector)

# Internal: fill a picked Selection's facts' `statement` from a concept => statement map (from the
# filing's presentation linkbase). Concepts absent from the map (e.g. note-only) keep their empty
# statement. Returns the Selection unchanged when there is nothing to classify.
function _classify_selection(sel::Selection, statements::AbstractDict)
    (isempty(sel.facts) || isempty(statements)) && return sel
    facts = [haskey(statements, f.concept) ? _with_statement(f, statements[f.concept]) : f
             for f in sel.facts]
    return Selection(sel.cik, sel.accession, sel.url, sel.selector, sel.kind, sel.text,
                     sel.html, sel.table, facts)
end

"""
    parse_selection(payload::AbstractString) -> Selection

Parse a picker transport payload (the JSON the browser POSTs back, schema version
$(SELECTION_SCHEMA_VERSION)) into a [`Selection`](@ref) — resolving its structured
table and normalising its [`Fact`](@ref)s. Throws if the payload's `version` is not
understood. This is the seam between the browser picker and the Julia export layers.
"""
function parse_selection(payload::AbstractString)
    o = JSON3.read(payload)
    get(o, :version, nothing) == SELECTION_SCHEMA_VERSION ||
        throw(ArgumentError("unsupported selection payload version $(get(o, :version, "missing"))"))
    p = o.provenance
    cik = String(p.cik); accession = String(p.accession); url = String(get(p, :url, ""))
    selector = String(get(o, :selector, ""))
    tj = get(o, :table, nothing)
    table = tj === nothing ? nothing :
        (header = String[String(x) for x in get(tj, :header, ())],
         rows = Vector{String}[String[String(c) for c in r] for r in get(tj, :rows, ())])
    facts = Fact[]
    fj = get(o, :facts, nothing)
    fj === nothing || for f in fj; push!(facts, _parse_fact(f, cik, accession, selector)); end
    return Selection(cik, accession, url, selector, Symbol(get(o, :kind, "prose")),
                     String(get(o, :text, "")), String(get(o, :html, "")), table, facts)
end

"""
    open_filing(sel::Selection) -> String

View a region captured with [`select_section`](@ref)/[`select_sections`](@ref) in your
browser — the picked-region counterpart of [`open_filing(::Filing)`](@ref). The captured
HTML (`sel.html`) is wrapped in a minimal page (with a `<base>` so the fragment's relative
images still resolve to the SEC Archives, and a small provenance header naming the filer,
accession and selector), written to a throwaway temporary directory and opened. Returns the
path. This is a quick visual check of what you picked; to keep a copy, use the export layers.

```julia
sel = select_section(f)
open_filing(sel)               # eyeball exactly what was captured
```
"""
# Internal: wrap a Selection's captured HTML in a minimal, self-contained preview
# page — a `<base>` so relative images resolve to the SEC Archives, plus a provenance
# header. Pure (no I/O), so it can be tested without launching a browser.
function _selection_page(sel::Selection)
    dirurl = sel.url[1:something(findlast('/', sel.url), 0)]
    basetag = isempty(dirurl) ? "" : "<base href=\"$dirurl\">"
    prov = string("<p style=\"font:13px system-ui,sans-serif;color:#555;",
                  "border-bottom:1px solid #ddd;padding-bottom:6px;margin:0 0 12px\">",
                  "EDGAR selection &middot; ", sel.kind, " &middot; CIK ", sel.cik,
                  " &middot; ", sel.accession, " &middot; <code>", sel.selector, "</code></p>")
    return string("<!doctype html><html><head><meta charset=\"utf-8\">", basetag,
                  "<title>EDGAR selection &mdash; ", sel.kind, "</title></head><body>",
                  prov, sel.html, "</body></html>")
end

function open_filing(sel::Selection)
    dir = mktempdir(; prefix = "EDGAR_selection_", cleanup = true)
    path = joinpath(dir, "selection.html")
    write(path, _selection_page(sel))
    return _open_in_default_app(path)
end

include("present.jl")   # markdown(::Selection) — the presentation export layer (Step 2.2)

"""
    facts(sel::Selection) -> Vector{FactRow}
    facts(sels::AbstractVector{<:Selection}) -> Vector{FactRow}

Assemble the resolved XBRL facts captured in `sel` (or several selections) into a
[Tables.jl](https://github.com/JuliaData/Tables.jl) *row table* — the hardened fact
schema: `cik`, `accession`, `statement`, `concept`, `label`, normalised `value`, `unit`,
`period_start`/`period_end`, `is_instant`, `dimensions` (JSON), `decimals`, the raw
`context_ref`/`unit_ref`, and `source_selector`. Values are already normalised
(`displayed × 10^scale × sign`, in [`parse_selection`](@ref)).

Rows are de-duplicated on the natural key `(accession, concept, context_ref, unit_ref)` —
one fact per concept × context × unit — so picking the same region twice, or combining
overlapping selections, does not double-count. A prose-only selection yields an **empty**
table (no error). Being a `Vector` of `NamedTuple`s, the result is a Tables.jl source —
render it with `PrettyTables`, or feed it to `CSV`, `Arrow`, `DataFrames`, a database, ….

```julia
sel = select_section(f)            # pick the income statement
using PrettyTables
pretty_table(facts(sel))           # the normalised facts as a table
```
"""
function facts(sels::AbstractVector{<:Selection})
    rows = FactRow[]
    seen = Set{NTuple{4,String}}()
    for sel in sels, f in sel.facts
        key = (f.accession, f.concept, f.context_ref, f.unit_ref)
        key in seen && continue
        push!(seen, key)
        push!(rows, fact_row(f))
    end
    return rows
end
facts(sel::Selection) = facts([sel])

include("extract_xbrl.jl")   # facts(::Filing) — Julia-native bulk XBRL extraction (W2)

"""
    to_duckdb(data, db; table="facts") -> Int

Append the XBRL facts in `data` to a DuckDB table, returning the number of rows **newly**
inserted. `data` is a [`Selection`](@ref), a vector of selections, or a fact row table
(the output of [`facts`](@ref)); `db` is a database-file path (created if it does not
exist) or an open `DuckDB.DB` connection.

The table is the canonical fact warehouse — one schema every source maps into (the picker
now, with `source='picker'`; the structured-data API later, filling `form`/`fy`/`fp`/`frame`).
Its primary key is each fact's **semantic identity** `(cik, accession, concept, unit,
period_start, period_end, is_instant, dimensions)` — *not* the document-internal
`context_ref`/`unit_ref`, which are kept only as provenance — and rows are inserted with
`ON CONFLICT DO NOTHING`. So re-importing the same filing is **idempotent** (returning `0`),
and the same fact arriving from two sources collapses to one row. Append filing by filing
to grow the warehouse. Once the facts are in DuckDB, export to Parquet/CSV/SQLite is a single
`COPY … TO` / `ATTACH … (TYPE SQLITE)`; and because a fact table is already a Tables.jl
source, `CSV.write`/`Arrow.write`/`SQLite.load!` also take it directly.

This is a **package extension**: it is available only after `using DuckDB`.

```julia
using DuckDB
to_duckdb(select_section(f), "filings.duckdb")   # append; running it again -> 0 new rows
```
"""
function to_duckdb(args...; kwargs...)
    error("`to_duckdb` requires DuckDB.jl. Run `using DuckDB` to load the EDGAR.jl " *
          "DuckDB extension (`EDGARDuckDBExt`).")
end

"""
    statement_view(db; table="facts", statement=nothing, accession=nothing,
                   consolidated=true, months=nothing, by=:concept) -> Vector{NamedTuple}

Pivot the long fact table in DuckDB `db` (a database-file path or an open `DuckDB.DB`)
into a **wide statement view** — the familiar shape of a financial statement: one row per
`concept`/`label`, one column per reporting period (`period_end`), each cell the normalised
value. The newest period comes first. Because the warehouse may hold many filings, the view
**stitches** a statement across them automatically.

- `statement` — restrict to one financial statement, e.g. `"IncomeStatement"`, `"BalanceSheet"`,
  `"CashFlow"` (requires facts ingested with `classify=true`; see [`statement_map`](@ref)).
- `months` — keep only duration periods of about this many months (e.g. `3` quarterly, `12`
  annual) plus all instants. This is **smart period selection**: it stops the 3-month and
  9-month periods that share an end date from colliding in one column.
- `consolidated=true` (default) shows the face of the statement (no dimensional qualifier);
  `consolidated=false` adds the dimensional breakdowns and a `dimensions` column.
- `accession` restricts to a single filing.
- `by=:standard_concept` groups by the standardized concept (see [`set_standardizer`](@ref))
  for cross-company comparison, instead of the raw `concept`/`label`.

The result is a Tables.jl row table (the period dates are the column names), so
`pretty_table(statement_view(db))` renders the statement and it feeds any Tables.jl sink.

This is a **package extension**: available only after `using DuckDB`.

```julia
using DuckDB, PrettyTables
to_duckdb(select_section(f), "filings.duckdb")     # accumulate facts
pretty_table(statement_view("filings.duckdb"))     # see them as a statement
```
"""
function statement_view(args...; kwargs...)
    error("`statement_view` requires DuckDB.jl. Run `using DuckDB` to load the EDGAR.jl " *
          "DuckDB extension (`EDGARDuckDBExt`).")
end

"""
    archive_filings(cik, db; forms=nothing, startdate=nothing, enddate=nothing,
                    facts=true, classify=false, labels=false, kind=:auto, limit=nothing) -> NamedTuple

Bulk-archive a filer's filings into the DuckDB warehouse `db` (a path): list them with
[`filings_by_cik`](@ref), then for each fetch the document and store it in `documents`
(the lossless iXBRL HTML, Layer 1) and — when `facts=true` — extract its XBRL facts
natively with [`facts(::Filing)`](@ref) into `facts` (tagged `source='filing'`) plus a
filing-level Facts JSON snapshot in `extractions`. One open connection is reused across
the whole run, and every write is idempotent (re-running adds nothing new).

`forms` / `startdate` / `enddate` filter the listing as in [`filings_by_cik`](@ref);
`limit` caps how many filings are processed; `kind` is passed to [`fetch_filing`](@ref).
`classify=true` fills each fact's `statement` (presentation linkbase) and `labels=true` its
`label` (label linkbase), at one extra fetch each per filing.
Returns a summary `(filings, documents, facts)` of how many were processed and how many
rows were newly added. A filing that fails to fetch is skipped.

Requires DuckDB: `using DuckDB` loads this method.

```julia
using DuckDB
archive_filings(104169, "wmt.duckdb"; forms = "10-Q", limit = 4)   # last 4 Walmart 10-Qs
```
"""
function archive_filings(args...; kwargs...)
    error("`archive_filings` requires DuckDB.jl. Run `using DuckDB` to load the EDGAR.jl " *
          "DuckDB extension (`EDGARDuckDBExt`).")
end

# Internal: a filesystem-safe basename for a selection's export files — the accession
# plus a slug of the selector, so several picks from one filing do not collide.
function _selection_slug(sel::Selection)
    s = strip(replace(sel.selector, r"[^A-Za-z0-9]+" => "-"), '-')
    isempty(s) && (s = string(sel.kind))
    length(s) > 48 && (s = s[1:48])
    return string(isempty(sel.accession) ? "selection" : sel.accession, "_", s)
end

"""
    save_selection(sel::Selection; as::Symbol, dir=".", db=nothing) -> String | Int

Export a [`Selection`](@ref) to disk in one of the four formats — the unified "Export As"
menu — returning the path written (or, for `:duckdb`, the number of rows appended). `dir`
is created if needed; file names are `<accession>_<selector-slug>.<ext>`.

- `:ixbrl`    — the lossless captured fragment (`sel.html`) as `…​.ixbrl.html`. View a
  self-contained, image-resolving version with [`open_filing(::Selection)`](@ref).
- `:markdown` — [`markdown`](@ref) (table/prose + provenance) as `…​.md`.
- `:facts`    — [`facts_json`](@ref) (the Layer-2 semantic JSON) as `…​.facts.json`.
- `:duckdb`   — append via `to_duckdb` to `db` (default `<dir>/facts.duckdb`); **requires**
  `using DuckDB`. Returns the number of rows newly inserted.

```julia
sel = select_section(f)
save_selection(sel; as = :markdown, dir = "out")    # -> "out/0000..._div-....md"
save_selection(sel; as = :facts,    dir = "out")    # -> "out/0000..._div-....facts.json"
using DuckDB
save_selection(sel; as = :duckdb,   dir = "out")    # -> 42  (rows appended to out/facts.duckdb)
```
"""
function save_selection(sel::Selection; as::Symbol, dir::AbstractString=".", db=nothing)
    if as === :duckdb
        isdir(dir) || mkpath(dir)
        return to_duckdb(sel, db === nothing ? joinpath(dir, "facts.duckdb") : db)
    end
    ext, content = as === :ixbrl    ? (".ixbrl.html", sel.html) :
                   as === :markdown ? (".md", markdown(sel)) :
                   as === :facts    ? (".facts.json", facts_json(sel)) :
                   throw(ArgumentError("`as` must be :ixbrl, :markdown, :facts or :duckdb, got $(repr(as))"))
    isdir(dir) || mkpath(dir)
    path = joinpath(dir, _selection_slug(sel) * ext)
    write(path, content)
    return path
end

export Filing, fetch_filing, save_filing, open_filing, download_assets, extract_section,
       Selection, Fact, select_section, select_sections, markdown, facts, facts_json,
       read_facts_json, standardize, set_standardizer, edgartools_mapping, statement_map,
       label_map, calculations, to_duckdb, statement_view, save_selection, archive_filings,
       set_config, set_user_agent, get_user_agent, persist_user_agent, unpersist_user_agent,
       fetch_url, clean_cache, cache_metrics, cache_path_for,
       company_facts, company_concept, xbrl_frames, full_text_search, filings_by_text, filings_by_cik,
       profile, cik

end # module
