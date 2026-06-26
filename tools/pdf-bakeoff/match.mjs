// P0 single-twin proof: run each candidate on the PDF, check whether the iXBRL-twin's
// headline figures (in the PDF's reporting scale, £m) appear in each candidate's extraction.
// Presence-in-output is the floor metric; full (line-item × period) matching is P0.5.
import { readFileSync } from "node:fs";

const PDF = process.argv[3] || "../../test/data/pdf/raw/tesco_2024.pdf";
const TRUTH = JSON.parse(readFileSync("../../test/data/pdf/raw/tesco_2024_truth.json", "utf8"));

// truth values are full GBP; the PDF reports in £m → target = round(value / 1e6)
const targets = {};
for (const [k, v] of Object.entries(TRUTH)) if (v && v.value) targets[k] = Math.round(v.value / 1e6);

async function extractAll(candidate) {
  if (candidate === "pdf.js-extract") {
    const { PDFExtract } = await import("pdf.js-extract");
    const data = await new Promise((res, rej) =>
      new PDFExtract().extract(PDF, {}, (e, d) => (e ? rej(e) : res(d))));
    const text = data.pages.flatMap(p => p.content.map(c => c.str)).join(" ");
    return { text, struct: `${data.pages.length}pp / ${data.pages.reduce((a,p)=>a+p.content.length,0)} words` };
  }
  if (candidate === "pdfreader") {
    const { PdfReader } = await import("pdfreader");
    const parts = [];
    await new Promise((res, rej) => new PdfReader().parseFileItems(PDF, (e, it) =>
      e ? rej(e) : !it ? res() : it.text ? parts.push(it.text) : null));
    return { text: parts.join(" "), struct: `${parts.length} items` };
  }
  if (candidate === "pdfexcavator") {
    const pdfexcavator = (await import("pdfexcavator")).default;
    const pdf = await pdfexcavator.open(PDF);
    let text = "";
    for (const page of pdf.pages) text += " " + (await page.extractText());
    await pdf.close();
    // NOTE (v0.1.2): default extractTables() is ruling-line based → ~0 on borderless financials, and
    // interleaving it with extractText() detaches the pdf.js buffer (crash). Borderless tables need the
    // lower-level extractTablesEnhanced(chars,lines,rects,…) path — deferred to the full P0.4 harness.
    return { text, struct: "text-only (default table finder ~0 on borderless; enhanced path TODO)" };
  }
  throw new Error("unknown candidate " + candidate);
}

// present if the comma-formatted (e.g. 68,187) or plain figure appears with non-digit boundaries
function present(text, n) {
  const comma = n.toLocaleString("en-US");
  const re = new RegExp(`(?<![\\d.,])(?:${comma.replace(/,/g, "[,\\s]?")}|${n})(?![\\d])`);
  return re.test(text);
}

// Run ONE candidate per process: the three bundle different pdf.js versions, and running them in a
// single process cross-contaminates the pdf.js worker/global (detaches buffers). Loop via the shell.
const candidate = process.argv[2] || "pdf.js-extract";
try {
  const t0 = Date.now();
  const { text, struct } = await extractAll(candidate);
  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  const hits = Object.entries(targets).map(([k, n]) => `${k}:${present(text, n) ? "✓" : "✗"}`);
  const score = Object.entries(targets).filter(([k, n]) => present(text, n)).length;
  console.log(`${candidate.padEnd(15)} ${score}/${Object.keys(targets).length}  [${hits.join("  ")}]  (${struct}, ${secs}s)`);
} catch (e) {
  console.log(`${candidate.padEnd(15)} ERROR :: ${e.message}`);
}
