# Runtime configuration and the SEC User-Agent (jurisdiction-agnostic). Carved from the monolith in Phase A; see docs/dev/refactor-plan.md.


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

