# EzXML implementations of the lxml HtmlElement accessors the parser uses. EzXML and lxml both wrap
# libxml2, so these read the *same* tree; lxml just pre-folds leading/trailing text into `.text`/`.tail`,
# which we recover from the adjacent text nodes. Not an abstraction layer — the direct faithful equivalents.

_tag(n) = lowercase(nodename(n))                                   # element.tag (HTML is lowercased)
_attr(n, name) = haskey(n, name) ? n[name] : nothing              # element.get(name)  -> None default
_attr(n, name, default) = haskey(n, name) ? n[name] : default      # element.get(name, default)
_text_content(n) = nodecontent(n)                                  # element.text_content()
_children(n) = elements(n)                                         # iter(element)  (child elements only)
_nchildren(n) = countelements(n)                                   # len(element)
_findall(n, xp) = findall(xp, n)                                   # element.findall(xpath)
_findfirst(n, xp) = findfirst(xp, n)                               # element.find(xpath) -> node or nothing
_getnext(n) = EzXML.hasnextelement(n) ? nextelement(n) : nothing   # element.getnext()
_getprevious(n) = EzXML.hasprevelement(n) ? prevelement(n) : nothing  # element.getprevious()
_getparent(n) = EzXML.hasparentelement(n) ? parentelement(n) : nothing  # element.getparent()
_same(a, b) = a.ptr == b.ptr                                       # element identity (a is b)

# element.text — text between the start tag and the first child element (lxml returns None → "" here).
function _lxtext(n)
    if hasnode(n)
        fc = firstnode(n)
        istext(fc) && return nodecontent(fc)
    end
    return ""
end

# element.tail — text immediately following the element's end tag (its next text-node sibling).
function _lxtail(n)
    if EzXML.hasnextnode(n)
        nx = nextnode(n)
        istext(nx) && return nodecontent(nx)
    end
    return ""
end

# element.itertext() — every text fragment under the element, document order (element.text, then each
# child's itertext, then that child's tail — exactly the order of the underlying text nodes).
function _itertext(n)
    out = String[]
    for c in eachnode(n)
        if istext(c)
            push!(out, nodecontent(c))
        elseif iselement(c)
            append!(out, _itertext(c))
        end
    end
    return out
end

# itertext variant that emits "\n" at each <br> — replicates table_processing's `br.tail = '\n' + tail`
# mutation (the newline appears just before the br's following text, in the same fragment order).
function _itertext_br(n)
    out = String[]
    for c in eachnode(n)
        if istext(c)
            push!(out, nodecontent(c))
        elseif iselement(c)
            _tag(c) == "br" && push!(out, "\n")
            append!(out, _itertext_br(c))
        end
    end
    return out
end

# --- Python str helpers reused across the parser ------------------------------------------------------
_py_isupper(s::AbstractString) = any(isuppercase, s) && !any(islowercase, s)
function _py_istitle(s::AbstractString)
    seen = false; prev_cased = false
    for c in s
        if isuppercase(c)
            prev_cased && return false
            prev_cased = true; seen = true
        elseif islowercase(c)
            prev_cased || return false
            prev_cased = true; seen = true
        else
            prev_cased = false
        end
    end
    return seen
end
_py_isspace(s::AbstractString) = !isempty(s) && all(isspace, s)
