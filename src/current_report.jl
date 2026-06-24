# Current-report attachments — a faithful port of edgartools' press-release / exhibit discovery
# (company_reports/current_report.py `CurrentReport.press_releases`, press_release.py, and the exhibit
# listing reused by sixk.py). An 8-K (or 6-K) carries its substance in exhibits — chiefly the EX-99.x
# press release — rather than inline; these locate them. 🔵 SEC-specific (attachment list + fetch).

"""
    PressRelease

A press-release exhibit on an 8-K / 6-K filing (typically `EX-99.1`). Carries the locating
metadata (`document` filename, `description`, exhibit `type`, `url`); fetch its content with
[`press_release_html`](@ref) or [`press_release_text`](@ref).
"""
struct PressRelease
    cik::String
    accession::String
    document::String
    description::String
    type::String
    url::String
end

Base.show(io::IO, pr::PressRelease) =
    print(io, "PressRelease(", repr(pr.type), ", ", repr(pr.document), ")")

"""
    press_releases(f::Filing) -> Vector{PressRelease}

The press-release exhibits attached to an 8-K / 6-K — a faithful port of edgartools' query: an `.htm`
document whose description mentions a release, or whose exhibit type is `EX-99.1` / `EX-99` / `EX-99.01`.
Returns an empty vector when there are none.
"""
function press_releases(f::Filing)
    base = _filing_dir(f.cik, f.accession)
    out = PressRelease[]
    for d in _filing_documents(f.cik, f.accession)
        endswith(d.filename, ".htm") || continue
        is_release = occursin("RELEASE", d.description) || d.type in ("EX-99.1", "EX-99", "EX-99.01")
        is_release || continue
        push!(out, PressRelease(f.cik, f.accession, d.filename, d.description, d.type, "$base/$(d.filename)"))
    end
    return out
end

"""
    press_release_html(pr::PressRelease) -> Union{String,Nothing}

Download the press release's raw HTML, or `nothing` if it cannot be fetched.
"""
press_release_html(pr::PressRelease) = (b = fetch_url(pr.url); b === nothing ? nothing : String(b))

"""
    press_release_text(pr::PressRelease) -> Union{String,Nothing}

The press release rendered to plain text (via [`html_to_text`](@ref)), or `nothing` if unavailable.
"""
press_release_text(pr::PressRelease) = (h = press_release_html(pr); h === nothing ? nothing : html_to_text(h))

"""
    exhibits(f::Filing) -> Vector{@NamedTuple{type::String, filename::String, description::String, size::Int, url::String}}

The filing's content exhibits — every attached document except graphics and the primary (cover) document.
A faithful port of edgartools' `SixK.exhibits` (used for 6-K, but form-agnostic), surfacing the EX-99.x
press releases, financial statements and other exhibits that carry a current report's substance.
"""
function exhibits(f::Filing)
    base = _filing_dir(f.cik, f.accession)
    T = @NamedTuple{type::String, filename::String, description::String, size::Int, url::String}
    out = T[]
    for d in _filing_documents(f.cik, f.accession)
        (isempty(d.type) || d.type == "GRAPHIC" || d.filename == f.document) && continue
        push!(out, (type = d.type, filename = d.filename, description = d.description,
                    size = d.size, url = "$base/$(d.filename)"))
    end
    return out
end
