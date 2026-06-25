# Faithful translation of edgartools' navigation-link filtering applied on Document.text()'s clean path:
# utils/anchor_cache.py `_analyze_navigation_minimal` + `filter_with_cached_patterns` (primary), and
# utils/toc_filter.py `filter_toc_links` (fallback). The disk/in-memory anchor cache is a pure performance
# optimisation and is omitted (analysis is recomputed; output identical).

# anchor_cache._analyze_navigation_minimal — anchor-link texts (<a href="#...">text</a>) occurring
# >= min_frequency times in the ORIGINAL html.
function _analyze_navigation_minimal(html::AbstractString; min_frequency::Int = 5)
    counts = Dict{String,Int}()
    for m in eachmatch(r"(?is)<a[^>]*href\s*=\s*[\"']#([^\"']*)[\"'][^>]*>(.*?)</a>", html)
        link_text = strip(replace(m.captures[2], r"<[^>]+>" => ""))
        link_text = join(split(link_text), " ")
        if !isempty(link_text) && length(link_text) < 100
            counts[link_text] = get(counts, link_text, 0) + 1
        end
    end
    return Set(t for (t, c) in counts if c >= min_frequency)
end

# anchor_cache.filter_with_cached_patterns — keep the first `max_allowed_per_pattern` (2) occurrences of
# each navigation pattern (document-structure headers), drop the rest (repetitive nav links).
function filter_with_cached_patterns(text::AbstractString, html_content::Union{Nothing,AbstractString})
    isempty(text) && return text
    patterns = html_content !== nothing ? _analyze_navigation_minimal(html_content) :
               Set(["Table of Contents", "Index to Financial Statements", "Index to Exhibits"])
    isempty(patterns) && return text
    max_allowed = 2
    seen = Dict{String,Int}()
    out = String[]
    for line in split(text, '\n')
        s = String(strip(line))
        if s in patterns
            c = get(seen, s, 0)
            if c < max_allowed
                push!(out, line); seen[s] = c + 1
            end
        else
            push!(out, line)
        end
    end
    return join(out, "\n")
end

# toc_filter.filter_toc_links — fallback: drop every line that is exactly a known nav phrase.
const _TOC_FILTER_RE = r"^(table of contents|index to financial statements|index to exhibits)$"i
function filter_toc_links(text::AbstractString)
    isempty(text) && return text
    kept = [line for line in split(text, '\n') if match(_TOC_FILTER_RE, strip(line)) === nothing]
    return join(kept, "\n")
end
