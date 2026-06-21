# HTTP layer: the injectable client, the on-disk response cache, and fetch_url/_get_json (cached, User-Agent-aware). Uses a built-in hash for the cache key (no extra stdlib). Jurisdiction-agnostic.

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


# Internal: fetch `url` through the cached, User-Agent-aware `fetch_url` and
# parse the body as JSON. Throws if the request fails (bad User-Agent, network
# error, or the resource does not exist).
function _get_json(url::AbstractString; use_cache::Bool=true)
    body = fetch_url(url; use_cache = use_cache)
    body === nothing && error("EDGAR request failed: $url (network error, SEC rate limit, or the resource does not exist)")
    return JSON3.read(body)
end
