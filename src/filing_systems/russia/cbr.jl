# Russia route 2 — the CBR (Bank of Russia) bank-reporting channel. The financial sector is carved out of
# RFSD (route 1) by law, so banks are reached instead through the CBR's public per-institution forms —
# Form 0409101 (turnover balance by account) and 0409102 (financial results) — served as HTML per bank
# registration number (`regnum`) and reporting date, behind the CBR's ddos-guard (a replayable cookie).
# Unlike route 1 (structured RFSD rows), these are HTML account tables on the bank chart of accounts, so they
# need their own fetch (C2), extractor (C3) and account→statement map (C4). Insurers and NPFs are NOT
# reachable: CBR publishes only aggregate sector statistics for them and their XBRL instances are not public
# (their per-entity accounts are not served in HTML the way banks' are). See docs/dev/russia-plan.md (route 2).
#
# This file is C0 — the SEAM only: the `FilingSource` type + host, so `using EDGAR` loads clean. The
# FullCoList `regnum` resolver + `discover` (C1), the Form 101/102 fetch (C2), the HTML-table extractor (C3)
# and the chart-of-accounts → bank-statement map (C4) are the next phases.

"""
    CBRBankFilings <: FilingSource

The Bank of Russia (CBR) bank-reporting channel — **route 2**, for the financial sector that RFSD (route 1)
excludes. A Russian bank publishes its statutory reporting as CBR **Form 0409101** (turnover balance by
account) and **0409102** (financial results), served as HTML per **registration number** (`regnum`) and
reporting date. Identity is `EntityId(:cbr_regnum, "1481")` (Sberbank), resolved from a name / INN through
the CBR bank directory (`FullCoList`, planned C1). Only **credit institutions** (~320 banks) are reachable:
insurers and non-state pension funds report XBRL to the CBR whose per-entity instances are not public.

Discovery (`discover`, C1) and fetch (C2) are the next phases; this is the seam so `using EDGAR` loads clean.
"""
struct CBRBankFilings <: FilingSource end

# CBR host. Behind ddos-guard — a first request sets a replayable `__ddg*_` cookie, bootstrapped in the C2
# fetch path. Form 101/102 live under `/banking_sector/credit/coinfo/`, the bank directory under
# `/banking_sector/credit/FullCoList/`. https required.
const _CBR_BASE = "https://www.cbr.ru"

# ── C1: the bank directory (regnum resolver) + discover ──────────────────────────────────────────
#
# The CBR bank directory is a downloadable XLSX (UniDbQuery 98547) with `cregnum` (the registration number),
# `bnk_name`, `ogrn` and `lic_status` (Действующая = active). DuckDB reads it straight from the URL
# (read_xlsx), so `_cbr_directory_rows` is a weakdep (real method in EDGARDuckDBExt); the parsed directory is
# cached in-process. Neither the directory nor the Form 101/102 pages need the ddos-guard cookie — a browser
# User-Agent alone suffices (C2).

_cbr_dmy(d::Date) = Dates.format(d, "mm/dd/yyyy")
_cbr_directory_url() = "$_CBR_BASE/Queries/UniDbQuery/DownloadExcel/98547?" *
                       "FromDate=$(_cbr_dmy(today()))&ToDate=$(_cbr_dmy(today()))&posted=False"

# Weakdep: parse a LOCAL directory XLSX with DuckDB read_xlsx. Real method in EDGARDuckDBExt. (The file is
# downloaded first — DuckDB's xlsx reader needs random access, which httpfs range-reads of a dynamically
# generated response don't support.)
_cbr_directory_rows(args...) =
    error("CBR bank discovery needs DuckDB.jl to read the bank directory — run `using DuckDB` (EDGARDuckDBExt).")

const _CBR_DIR_CACHE = Ref{Any}(nothing)

# The bank directory as a vector of `(regnum, name, ogrn, status)` NamedTuples, fetched once and cached:
# download the XLSX to a temp file (browser UA, no cookie), parse it with DuckDB, then discard the file.
function _cbr_directory()
    if _CBR_DIR_CACHE[] === nothing
        resp = HTTP.get(_cbr_directory_url(); headers = system_headers(Russia()),
                        status_exception = false, redirect = true)
        tmp = tempname() * ".xlsx"
        try
            write(tmp, resp.body)
            _CBR_DIR_CACHE[] = _cbr_directory_rows(tmp)
        finally
            isfile(tmp) && rm(tmp; force = true)
        end
    end
    return _CBR_DIR_CACHE[]
end

"""
    cbr_bank_directory(; active_only=true) -> Vector{@NamedTuple{regnum,name,ogrn,status}}

The CBR credit-institution directory (cached): each bank's registration number (`regnum`), name, OGRN and
licence status. With `active_only` (the default) only currently-licensed banks (\rus{Действующая}) are
returned. Needs `using DuckDB`.
"""
function cbr_bank_directory(; active_only::Bool=true)
    dir = _cbr_directory()
    return active_only ? filter(b -> b.status == "Действующая", dir) : dir
end

# Active-bank matches for a name (case-insensitive substring) or exact OGRN.
function _cbr_match(; name=nothing, ogrn=nothing)
    banks = cbr_bank_directory(; active_only = true)
    if ogrn !== nothing
        og = string(ogrn)
        return filter(b -> b.ogrn == og, banks)
    end
    q = uppercase(strip(string(name)))
    return filter(b -> occursin(q, uppercase(b.name)), banks)
end

_cbr_form_path(form::Symbol) = form === :f101 ? "f101" : form === :f102 ? "f102" :
    throw(ArgumentError("form must be :f101 (turnover balance) or :f102 (financial results)"))

function _cbr_handle(regnum::AbstractString, form::Symbol, dt::Union{Date,Nothing})
    path = _cbr_form_path(form)
    url  = "$_CBR_BASE/banking_sector/credit/coinfo/$path/?regnum=$regnum" *
           (dt === nothing ? "" : "&dt=$dt")
    return FilingHandle(; system = Russia(), entity = EntityId(:cbr_regnum, regnum),
                        ref = "cbr:$path:$regnum" * (dt === nothing ? "" : ":$dt"),
                        url = url, period_end = dt, country = "RU")
end

"""
    discover(::CBRBankFilings; regnum|name|ogrn, form=:f101, dt=nothing) -> Vector{FilingHandle}

Discover a Russian bank's CBR reporting. Identify it by `regnum` (registration number, direct), or by `name`
/ `ogrn` resolved through the bank directory ([`cbr_bank_directory`](@ref)); `form` selects Form 0409101
(`:f101`, turnover balance) or 0409102 (`:f102`, financial results), and `dt` the reporting date (a `Date`;
`nothing` = the latest available, resolved at fetch). A name may match several active banks — one handle each.
"""
function discover(::CBRBankFilings; regnum=nothing, name=nothing, ogrn=nothing,
                  form::Symbol=:f101, dt::Union{Date,Nothing}=nothing)
    _cbr_form_path(form)                                       # validate form early
    regnums = if regnum !== nothing
        [string(regnum)]
    elseif name !== nothing || ogrn !== nothing
        matches = _cbr_match(; name, ogrn)
        isempty(matches) && error("CBR directory: no active bank matching " *
                                  (name !== nothing ? "name \"$name\"" : "OGRN $ogrn") * ".")
        [m.regnum for m in matches]
    else
        throw(ArgumentError("discover(CBRBankFilings; …) needs `regnum`, `name` or `ogrn`."))
    end
    return [_cbr_handle(rn, form, dt) for rn in regnums]
end

# ── C2: fetch the Form 0409101/102 HTML → a :cbr_form Filing ─────────────────────────────────────
#
# `fetch_filing` routes a `:cbr_regnum` handle here. The reporting date matters: a valid month-first with a
# published form returns a ~130–210 KB account table; a not-yet-published month returns a ~29 KB shell. When
# `dt` is unset, the latest available is resolved by probing month-firsts back from the current month (the
# forms lag ~1 month). No cookie is needed (browser UA only). The HTML is the payload; the account-table
# extractor is C3.

# GET a CBR page as a String (utf-8), browser UA, no cookie. `nothing` on request failure.
_cbr_get(url::AbstractString) =
    (b = fetch_url(url; headers = system_headers(Russia())); b === nothing ? nothing : String(b))

# A fetched page holds the account table (has data) when it is well past the empty-shell size.
_cbr_has_data(html::AbstractString) = ncodeunits(html) > 50_000 && occursin("<td", html)

_cbr_form_of(url::AbstractString) = occursin("/f102/", url) ? :f102 : :f101
_cbr_url(regnum::AbstractString, form::Symbol, dt::Date) =
    "$_CBR_BASE/banking_sector/credit/coinfo/$(_cbr_form_path(form))/?regnum=$regnum&dt=$dt"

# The latest published reporting date for a bank's form: probe month-firsts back from the current month,
# returning the first with data, or `nothing` after ~8 months of misses.
function _cbr_latest_dt(regnum::AbstractString, form::Symbol)
    d = firstdayofmonth(today())
    for _ in 1:8
        html = _cbr_get(_cbr_url(regnum, form, d))
        html !== nothing && _cbr_has_data(html) && return d
        d -= Month(1)
    end
    return nothing
end

function _cbr_fetch(h::FilingHandle)
    regnum = h.entity.value
    form   = _cbr_form_of(h.url)
    fp     = _cbr_form_path(form)
    dt     = h.period_end === nothing ? _cbr_latest_dt(regnum, form) : h.period_end
    dt === nothing &&
        error("no published Form $(uppercase(fp)) for bank regnum $regnum in the last 8 months.")
    url  = _cbr_url(regnum, form, dt)
    html = _cbr_get(url)
    (html === nothing || !_cbr_has_data(html)) &&
        error("Form $(uppercase(fp)) for bank regnum $regnum at dt=$dt has no data (pick another " *
              "reporting date; forms are published monthly as of the 1st).")
    return Filing(Russia(), h.entity, "cbr:$fp:$regnum:$dt", "cbr-$fp-$regnum-$dt.html",
                  url, :cbr_form, html)
end
