# Faithful translation of edgartools' edgar/documents/utils/anchor_targets.py.
# Resolve/match SEC anchor targets by id or (for <a>) name, over the EzXML tree.

# DFS over element nodes of an EzXML subtree.
function _walk_elems(f, node)
    f(node)
    for c in _children(node)
        _walk_elems(f, c)
    end
    return
end

# find_anchor_targets — elements matching the anchor by @id or (self::a and @name).
function find_anchor_targets(treeroot, anchor_id::AbstractString)
    isempty(anchor_id) && return EzXML.Node[]
    out = EzXML.Node[]
    _walk_elems(treeroot) do el
        if _attr(el, "id", "") == anchor_id || (_tag(el) == "a" && _attr(el, "name", "") == anchor_id)
            push!(out, el)
        end
    end
    return out
end

# is_anchor_match — does this element match the anchor by id or name?
is_anchor_match(element, anchor_id::AbstractString) = !isempty(anchor_id) &&
    (_attr(element, "id", "") == anchor_id || (_tag(element) == "a" && _attr(element, "name", "") == anchor_id))
