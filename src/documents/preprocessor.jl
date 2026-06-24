# Faithful translation of edgartools' edgar/documents/processors/preprocessor.py (+ remove_xml_declaration
# from utils/html_utils.py). Cleans/normalises raw HTML before parsing: encoding fixes, script/style/ix:hidden
# removal, entity normalisation, malformed-tag repair, whitespace normalisation, empty-tag removal. This
# stage materially shapes the extracted text (e.g. it strips the spaces around inline tags), so it is on the
# critical path for char-for-char parity.

# utils/html_utils.remove_xml_declaration
remove_xml_declaration(html::AbstractString) = replace(html, r"<\?xml[^>]*\?>" => "")

struct HTMLPreprocessor
    config::ParserConfig
end

function preprocess(p::HTMLPreprocessor, html::AbstractString)
    startswith(html, '﻿') && (html = html[nextind(html, 1):end])
    html = remove_xml_declaration(html)
    html = _fix_encoding_issues(html)
    html = _remove_script_style(html)
    html = _normalize_entities(html)
    html = _fix_malformed_tags(html)
    p.config.preserve_whitespace || (html = _normalize_whitespace(html))
    html = _remove_empty_tags(html)
    html = _fix_common_issues(html)
    return html
end

const _PP_CONTROL_CHARS = r"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]"

function _fix_encoding_issues(html::AbstractString)
    html = replace(html,
        '\x91' => "'", '\x92' => "'", '\x93' => "\"", '\x94' => "\"",
        '\x95' => "•", '\x96' => "–", '\x97' => "—", '\xa0' => " ")
    return replace(html, _PP_CONTROL_CHARS => "")
end

function _remove_script_style(html::AbstractString)
    html = replace(html, r"(?is)<script[^>]*>.*?</script>" => "")
    html = replace(html, r"(?is)<style[^>]*>.*?</style>" => "")
    html = replace(html, r"(?i)<link[^>]*>" => "")
    html = replace(html, r"(?s)<!--.*?-->" => "")
    html = replace(html, r"(?is)<ix:hidden[^>]*>.*?</ix:hidden>" => "")
    html = replace(html, r"(?is)<ix:header[^>]*>.*?</ix:header>" => "")
    return html
end

function _normalize_entities(html::AbstractString)
    html = replace(html,
        "&nbsp;" => " ", "&ensp;" => " ", "&emsp;" => "  ", "&thinsp;" => " ",
        "&#160;" => " ", "&#32;" => " ", "&zwj;" => "", "&zwnj;" => "", "&#8203;" => "")
    html = replace(html, "&amp;amp;" => "&amp;")
    html = replace(html, "&amp;nbsp;" => " ")
    html = replace(html, "&amp;lt;" => "&lt;")
    html = replace(html, "&amp;gt;" => "&gt;")
    return html
end

function _fix_malformed_tags(html::AbstractString)
    html = replace(html, r"(?i)<br(?![^>]*/)>" => "<br/>")
    html = replace(html, r"(?i)<img([^>]+)(?<!/)>" => s"<img\1/>")
    html = replace(html, r"(?i)<input([^>]+)(?<!/)>" => s"<input\1/>")
    html = replace(html, r"(?i)<hr(?![^>]*/)>" => "<hr/>")
    html = replace(html, r"(?i)<p>\s*<p>" => "<p>")
    html = replace(html, r"(?i)</p>\s*</p>" => "</p>")
    return html
end

function _normalize_whitespace(html::AbstractString)
    html = replace(html, r"[ \t]+" => " ")
    html = replace(html, r"\n{3,}" => "\n\n")
    html = replace(html, r"(?<=>)\s+(?=<)" => " ")
    html = replace(html, r"(?<!>)\s+(?=<)" => "")
    html = replace(html, r"(?<=>)\s+(?!<)" => "")
    html = replace(html, r"(?i)(<(?:div|p|h[1-6]|table|tr|ul|ol|li|blockquote)[^>]*>)" => s"\n\1")
    html = replace(html, r"(?i)(</(?:div|p|h[1-6]|table|tr|ul|ol|li|blockquote)>)" => s"\1\n")
    html = replace(html, r"\n{3,}" => "\n\n")
    return strip(html)
end

function _remove_empty_tags(html::AbstractString)
    html = replace(html, r"(?i)<(?:span|div|p|font|b|i|u|strong|em)\b[^>]*>\s*</(?:span|div|p|font|b|i|u|strong|em)>" => "")
    html = replace(html, r"(?i)<(?:span|div|p|font|b|i|u|strong|em)\b[^>]*/>\s*" => "")
    return html
end

function _fix_common_issues(html::AbstractString)
    html = replace(html, r"(?i)(<br\s*/?>[\s\n]*){3,}" => "<br/><br/>")
    html = replace(html, r"\s+([.,;!?])" => s"\1")
    html = replace(html, r"(?<=\w{2})([.!?])([A-Z])" => s"\1 \2")
    html = replace(html, "​" => "")
    html = replace(html, "﻿" => "")
    html = replace(html, "<tabel" => "<table")
    html = replace(html, "</tabel>" => "</table>")
    return html
end
