s = read("test/data/sample_multi_main.html", String)
mb = match(r"(?is)<div[^>]*id=[\"']?toc[\"']?[^>]*>.*?</div>", s)
toc_html = mb === nothing ? s : mb.match
println("--- TOC HTML ---")
println(toc_html)
println("--- ANCHORS ---")
for m in eachmatch(r"<a[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", toc_html)
    println("HREF=", m.captures[1], " LABEL=", replace(strip(m.captures[2]), r"<[^>]+>" => " "))
end
using EDGAR
println("similarity(Item 7, label) = ", EDGAR.similarity_ratio("Item 7", "Item 7. Management's Discussion"))
