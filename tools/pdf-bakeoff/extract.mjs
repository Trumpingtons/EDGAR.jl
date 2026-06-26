// P0 bake-off harness — run one table-specialist candidate over a PDF and emit JSON.
// Usage:  node extract.mjs <pdf.js-extract|pdfreader|pdfexcavator> <file.pdf>
// This is evaluation-only tooling (see docs/dev/pdf-extractor-plan.md), not part of EDGAR.jl.

const [, , candidate, pdfPath] = process.argv;
if (!candidate || !pdfPath) {
  console.error("usage: node extract.mjs <pdf.js-extract|pdfreader|pdfexcavator> <file.pdf>");
  process.exit(2);
}

async function run() {
  if (candidate === "pdf.js-extract") {
    const { PDFExtract } = await import("pdf.js-extract");
    const data = await new Promise((res, rej) =>
      new PDFExtract().extract(pdfPath, {}, (err, d) => (err ? rej(err) : res(d))));
    const totalWords = data.pages.reduce((a, p) => a + p.content.length, 0);
    const sample = (data.pages[0]?.content || [])
      .slice(0, 8).map(c => ({ x: Math.round(c.x), y: Math.round(c.y), str: c.str }));
    return { candidate, kind: "words+coords (no table finder)", pages: data.pages.length, totalWords, sample };
  }

  if (candidate === "pdfreader") {
    const { PdfReader } = await import("pdfreader");
    const items = [];
    await new Promise((res, rej) =>
      new PdfReader().parseFileItems(pdfPath, (err, item) => {
        if (err) rej(err);
        else if (!item) res();
        else if (item.text) items.push({ page: item.page, x: item.x, y: item.y, text: item.text });
      }));
    return { candidate, kind: "items(x,y,text) + column/table parsers", items: items.length, sample: items.slice(0, 8) };
  }

  if (candidate === "pdfexcavator") {
    const pdfexcavator = (await import("pdfexcavator")).default;
    const pdf = await pdfexcavator.open(pdfPath);
    const meta = await pdf.metadata;
    let tables = 0, sampleRows = null;
    for (const page of pdf.pages) {
      const t = await page.extractTables();
      tables += t.length;
      if (!sampleRows && t.length) sampleRows = t[0].rows.slice(0, 5);
    }
    await pdf.close();
    return { candidate, kind: "tables (rows[][])", pages: meta?.pageCount, tablesFound: tables, sampleRows };
  }

  throw new Error("unknown candidate: " + candidate);
}

run()
  .then(r => console.log(JSON.stringify(r, null, 2)))
  .catch(e => { console.error("ERROR", candidate, "::", e.message); process.exit(1); });
