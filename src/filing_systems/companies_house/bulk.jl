# Companies House bulk discovery (C2) — the **Accounts Data Product**, a KEYLESS second source over
# the same parse path. Companies House publishes daily ZIPs of every digitally-filed iXBRL accounts
# document at https://download.companieshouse.gov.uk/en_accountsdata.html (no API key, no login). A
# daily archive (`Accounts_Bulk_Data-YYYY-MM-DD.zip`) holds thousands of inline-XBRL files named
# `Prod223_…_<companynumber>_<YYYYMMDD>.html`. This is the route that scales to the whole registrar
# (including the private/small companies absent from filings.xbrl.org), and needs no credentials —
# unlike `CompaniesHouseApi`, which is for targeted per-company lookups.
#
# `discover(::CompaniesHouseBulk; date)` lists a day's archive into `FilingHandle`s (filterable by
# company number); `fetch_filing(h)` reads one entry from the archive. Both share a single-slot memo
# of the last archive's bytes, because the archives are tens of MB (over the HTTP layer's disk-cache
# size cap), so without it every entry read would re-download the whole ZIP.

using ZipArchives: ZipReader, zip_names, zip_readentry

"""
    CompaniesHouseBulk <: FilingSource

The Companies House **Accounts Data Product** (bulk iXBRL accounts) as a [`FilingSource`](@ref) —
**keyless**: it needs no API key, just a date. Use it with [`discover`](@ref) to list a day's filings,
fetching each with [`fetch_filing`](@ref). This is the whole-registrar route (private + public
companies); [`CompaniesHouseApi`](@ref) is the keyed, per-company alternative. See
[`discover(::CompaniesHouseBulk)`](@ref).
"""
struct CompaniesHouseBulk <: FilingSource end

const _CH_BULK_BASE = "https://download.companieshouse.gov.uk"

# Single-slot memo of the last bulk archive fetched, keyed by URL (the archives exceed the HTTP cache
# size cap, so they are not disk-cached). Mirrors ESEF's `_ESEF_PKG_MEMO`.
const _CH_BULK_MEMO = Ref{Tuple{String,Vector{UInt8}}}(("", UInt8[]))

# The bytes of a bulk archive (a local path or an `http(s)://` URL), memoised. Throws on a failed fetch.
function _ch_bulk_bytes(src::AbstractString)
    src == _CH_BULK_MEMO[][1] && return _CH_BULK_MEMO[][2]
    bytes = if startswith(src, "http://") || startswith(src, "https://")
        b = fetch_url(src; headers = _CH_TAXONOMY_HEADERS)
        b === nothing && error("could not fetch Companies House bulk archive $(repr(src))")
        Vector{UInt8}(b)
    else
        read(src)
    end
    _CH_BULK_MEMO[] = (src, bytes)
    return bytes
end

# The archive URL for a date (`Accounts_Bulk_Data-YYYY-MM-DD.zip`).
_ch_bulk_url(d::Date) = "$_CH_BULK_BASE/Accounts_Bulk_Data-$(Dates.format(d, "yyyy-mm-dd")).zip"

# Parse `(company_number, period_end)` from a bulk entry name `Prod223_…_<number>_<YYYYMMDD>.html`.
# The number may carry a jurisdiction prefix (e.g. `SC…`, `NI…`); the trailing 8 digits are the date.
function _ch_bulk_entry_meta(name::AbstractString)
    m = match(r"_([A-Za-z0-9]+)_(\d{8})\.html$"i, basename(name))
    m === nothing && return (number = "", period_end = nothing)
    return (number = String(m.captures[1]),
            period_end = tryparse(Date, m.captures[2], dateformat"yyyymmdd"))
end

"""
    discover(::CompaniesHouseBulk; date, company_number=nothing, limit=1000) -> Vector{FilingHandle}

List the Companies House bulk **Accounts Data Product** archive for `date` (a `Date` or `"YYYY-MM-DD"`)
into [`FilingHandle`](@ref)s — one per iXBRL accounts document in that day's ZIP — tagged
`CompaniesHouse()`. Optionally keep only a given `company_number`; `limit` caps how many handles are
returned (the archives hold thousands of filings). Each handle's `url` is the archive and its `ref`
is the entry name; fetch one with [`fetch_filing`](@ref). **Keyless** (see [`CompaniesHouseBulk`](@ref)).

```julia
hs = discover(CompaniesHouseBulk(); date = "2026-06-19", limit = 50)
f  = fetch_filing(first(hs))
facts(f; classify = true)
```
"""
function discover(::CompaniesHouseBulk; date::Union{Date,AbstractString},
                  company_number::Union{AbstractString,Nothing}=nothing, limit::Integer=1000)
    d = date isa Date ? date : Date(date)
    url = _ch_bulk_url(d)
    z = ZipReader(_ch_bulk_bytes(url))
    want = company_number === nothing ? nothing : strip(company_number)
    handles = FilingHandle[]
    for name in zip_names(z)
        endswith(lowercase(name), ".html") || continue
        meta = _ch_bulk_entry_meta(name)
        isempty(meta.number) && continue
        want === nothing || meta.number == want || continue
        push!(handles, FilingHandle(; system = CompaniesHouse(),
              entity = EntityId(:companies_house, meta.number),
              ref = name, url = url, period_end = meta.period_end, country = "GB"))
        length(handles) >= limit && break
    end
    return handles
end

# Bulk fetch from a discovered handle: read the entry `h.ref` from the (memoised) archive at `h.url`,
# canonicalize FRC prefixes, and build an `:ixbrl` `Filing`. Identity comes from the handle.
function _ch_fetch_from_bulk(h::FilingHandle)
    z = ZipReader(_ch_bulk_bytes(h.url))
    raw = zip_readentry(z, h.ref)
    _ch_is_pdf(raw) && return Filing(CompaniesHouse(), h.entity, h.ref, basename(h.ref), h.url, :pdf, "")
    content = _ch_canonicalize(String(raw))
    ent = isempty(h.entity.value) ? EntityId(:companies_house, _ch_number(content)) : h.entity
    return Filing(CompaniesHouse(), ent, h.ref, basename(h.ref), h.url, :ixbrl, content)
end
