# Faithful translation of edgartools' edgar/documents/agents.py (`detect_filing_agent`).
# Identifies the filing agent from HTML signatures in the first 3000 chars (enables agent-aware TOC parsing).

const _AG_WORKIVA = "Workiva"
const _AG_DONNELLEY = "Donnelley"
const _AG_TOPPAN_MERRILL = "Toppan Merrill"
const _AG_NOVAWORKS = "Novaworks"
const _AG_COMPSCI = "CompSci"
const _AG_CERTENT = "Certent"
const _AG_BROADRIDGE = "Broadridge"
const _AG_EDGARSUITE = "EDGARsuite"
const _AG_SEC_PUBLISHER = "SEC Publisher"

function detect_filing_agent(html_content::AbstractString)
    head = first(html_content, 3000)
    occursin("Workiva", head) && return _AG_WORKIVA
    (occursin("DFIN", head) || occursin("Donnelley", head) || occursin("dfinsolutions", head)) && return _AG_DONNELLEY
    (occursin("Merrill", head) || occursin("Toppan", head)) && return _AG_TOPPAN_MERRILL
    occursin("ThunderDome", head) && return _AG_NOVAWORKS
    occursin("Field: Set; Name: xdx;", head) && return _AG_NOVAWORKS
    (occursin("CompSci", head) || occursin("compsciresources", head)) && return _AG_COMPSCI
    occursin("Certent", head) && return _AG_CERTENT
    occursin("Broadridge", head) && return _AG_BROADRIDGE
    (occursin("EDGARsuite", head) || occursin("Advanced Computer Innovations", head)) && return _AG_EDGARSUITE
    occursin("SEC Publisher", head) && return _AG_SEC_PUBLISHER
    return nothing
end
