// P1.1 — Node helper: PDF -> positioned words JSON, straight on pdfjs-dist (no wrapper).
// Emits {file, numPages, pages:[{page, width, height, words:[{x,y,w,h,str}]}]} with TOP-DOWN y
// (distance from page top) so downstream row clustering reads naturally. Coordinates in PDF points.
// Usage: node pdf_words.mjs <file.pdf> [page]      (page optional: dump a single 1-based page)
import { readFileSync } from "node:fs";
if (typeof globalThis.DOMMatrix === "undefined") globalThis.DOMMatrix = (await import("dommatrix")).default;
const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");

const file = process.argv[2];
const only = process.argv[3] ? parseInt(process.argv[3], 10) : null;
const doc = await pdfjs.getDocument({ data: new Uint8Array(readFileSync(file)), isEvalSupported: false, useSystemFonts: true }).promise;

const pages = [];
const lo = only || 1, hi = only || doc.numPages;
for (let i = lo; i <= hi; i++) {
  const page = await doc.getPage(i);
  const vp = page.getViewport({ scale: 1 });
  const H = vp.height, W = vp.width;
  const words = (await page.getTextContent()).items
    .filter(it => it.str && it.str.trim())
    .map(it => ({
      x: +it.transform[4].toFixed(2),
      y: +(H - it.transform[5]).toFixed(2), // baseline from bottom -> distance from top
      w: +(it.width || 0).toFixed(2),
      h: +(it.height || 0).toFixed(2),
      str: it.str,
    }));
  pages.push({ page: i, width: +W.toFixed(1), height: +H.toFixed(1), words });
}
process.stdout.write(JSON.stringify({ file, numPages: doc.numPages, pages }));
