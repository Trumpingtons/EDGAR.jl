// P0 structured matcher v1 — beyond the text-presence floor: does a metric's CURRENT and PRIOR
// period value land on the SAME ROW (the column-structure signal)? y is normalised per page so the
// test is candidate-agnostic (pdf.js-extract points vs pdfreader grid units). pdfexcavator is text-only
// here (its structural path needs extractTablesEnhanced — TODO), so it reports the floor only.
// Usage: node match2.mjs <candidate> <twin-id>     (run one candidate per process)
import { readFileSync } from "node:fs";

const candidate = process.argv[2] || "pdf.js-extract";
const id = process.argv[3] || "tesco_2024";
const PDF = `../../test/data/pdf/raw/${id}.pdf`;
const truth = JSON.parse(readFileSync(`../../test/data/pdf/truth/${id}.json`, "utf8"));

// metric -> [current£m, prior£m] (abs; PDFs show negatives as "(x)")
const metrics = {};
for (const [k, arr] of Object.entries(truth))
  if (arr && arr.length) metrics[k] = arr.map(x => Math.abs(Math.round(x.value / 1e6))).filter(n => n >= 1);

const ROW_TOL = 0.012; // ~1 line as a fraction of page height

function numsFrom(str) { // all integer values in a token's text (strip thousands separators)
  return [...str.matchAll(/\d[\d,]{2,}|\d{4,}/g)].map(m => parseInt(m[0].replace(/,/g, ""), 10)).filter(Number.isFinite);
}

async function tokens() {
  if (candidate === "pdf.js-extract") {
    const { PDFExtract } = await import("pdf.js-extract");
    const data = await new Promise((res, rej) => new PDFExtract().extract(PDF, {}, (e, d) => e ? rej(e) : res(d)));
    const out = [];
    data.pages.forEach((p, pi) => {
      const H = p.pageInfo?.height || Math.max(1, ...p.content.map(c => c.y));
      for (const c of p.content) for (const v of numsFrom(c.str)) out.push({ page: pi, yn: c.y / H, val: v });
    });
    return out;
  }
  if (candidate === "pdfreader") {
    const { PdfReader } = await import("pdfreader");
    const items = [];
    await new Promise((res, rej) => new PdfReader().parseFileItems(PDF, (e, it) =>
      e ? rej(e) : !it ? res() : it.text ? items.push(it) : null));
    const maxY = {};
    for (const it of items) maxY[it.page] = Math.max(maxY[it.page] || 0, it.y);
    const out = [];
    for (const it of items) for (const v of numsFrom(it.text)) out.push({ page: it.page, yn: it.y / (maxY[it.page] || 1), val: v });
    return out;
  }
  if (candidate === "pdfexcavator") {
    const pdfexcavator = (await import("pdfexcavator")).default;
    const pdf = await pdfexcavator.open(PDF);
    let text = ""; for (const pg of pdf.pages) text += " " + (await pg.extractText());
    await pdf.close();
    return { textOnly: text };
  }
  throw new Error("unknown candidate " + candidate);
}

const t0 = Date.now();
const tk = await tokens();
const secs = ((Date.now() - t0) / 1000).toFixed(1);

function floorHit(t, n) { return t.textOnly ? new RegExp(`(?<![\\d.,])${n.toLocaleString("en-US").replace(/,/g, "[,\\s]?")}(?![\\d])`).test(t.textOnly) : t.some(x => x.val === n); }
function sameRow(t, a, b) { // ∃ token==a and token==b on same page within ROW_TOL
  const A = t.filter(x => x.val === a), B = t.filter(x => x.val === b);
  return A.some(x => B.some(y => x.page === y.page && Math.abs(x.yn - y.yn) < ROW_TOL));
}

const isText = !Array.isArray(tk);
let floor = 0, struct = 0, structEligible = 0;
const detail = [];
for (const [k, vals] of Object.entries(metrics)) {
  const f = floorHit(tk, vals[0]); floor += f ? 1 : 0;
  let s = "n/a";
  if (vals.length >= 2 && !isText) { structEligible++; const hit = sameRow(tk, vals[0], vals[1]); struct += hit ? 1 : 0; s = hit ? "✓" : "✗"; }
  else if (vals.length >= 2 && isText) s = "text-only";
  detail.push(`${k}:floor=${f ? "✓" : "✗"},row=${s}`);
}
const structStr = isText ? "(text-only — structural test needs enhanced path)" : `${struct}/${structEligible}`;
console.log(`${candidate.padEnd(15)} ${id.padEnd(14)} floor ${floor}/${Object.keys(metrics).length} | same-row ${structStr}  [${detail.join("  ")}]  (${secs}s)`);
