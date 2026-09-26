/**
 * Reading a document's text.
 *
 * PDF text comes from pdf.js rather than PDFKit, which is what makes this
 * command work anywhere rather than only on a Mac. Measured over the 606 PDFs
 * in a real library: 602 extracted, 2 are scans with no text layer, and 2 are
 * one malformed file pdf.js refuses — 43 ms to 650 ms for a paper, and a
 * 247-page book in under a second.
 *
 * A `content.md` beside the file wins over extraction whenever the whole
 * document is being read: the importer writes it from the page's own markup,
 * so it has the structure that flattening a PDF's glyphs throws away.
 */
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { extractText, getDocumentProxy } from "unpdf";
import { OakError } from "./resolve.ts";

async function contentMarkdown(filePath: string): Promise<string | null> {
  try {
    const text = await readFile(join(dirname(filePath), "content.md"), "utf8");
    return text === "" ? null : text;
  } catch {
    return null;
  }
}

export async function readDocument(
  filePath: string, contentType: string, pages: string | null,
): Promise<string> {
  switch (contentType) {
    case "pdf": return await readPDF(filePath, pages);
    case "html": return await readHTML(filePath);
    case "markdown": return await readFile(filePath, "utf8");
    default:
      throw new OakError(
        `Unsupported content type '${contentType}' for text extraction.`);
  }
}

async function readPDF(filePath: string, pages: string | null): Promise<string> {
  if (pages === null) {
    const markdown = await contentMarkdown(filePath);
    if (markdown !== null) return markdown;
  }

  const data = new Uint8Array(await readFile(filePath));
  let document;
  try {
    document = await getDocumentProxy(data);
  } catch (error) {
    throw new OakError(
      `Failed to open PDF at ${filePath}: ${error instanceof Error ? error.message : error}`);
  }

  const { totalPages, text } = await extractText(document, { mergePages: false });
  const perPage = text as string[];

  const wanted = pages === null
    ? perPage.map((_, i) => i)
    : parsePageRange(pages, totalPages);

  if (pages !== null && wanted.length === 0) {
    throw new OakError(
      `Invalid page range: "${pages}". Use formats like "1-5" or "3,7,12". `
      + `Document has ${totalPages} pages.`);
  }

  const parts = wanted
    .map((i) => [i, (perPage[i] ?? "").trim()] as const)
    .filter(([, body]) => body !== "")
    .map(([i, body]) => `--- Page ${i + 1} ---\n${body}`);

  return parts.length === 0 ? "No text content found on the requested pages." : parts.join("\n\n");
}

async function readHTML(filePath: string): Promise<string> {
  const markdown = await contentMarkdown(filePath);
  if (markdown !== null) return markdown;
  return htmlToText(await readFile(filePath, "utf8"));
}

/** Tags whose content is machinery, not reading matter. */
const SUPPRESSED = /<(script|style|noscript|svg|math)\b[^>]*>[\s\S]*?<\/\1>/gi;

/** Tags that end a line when they open or close. */
const BLOCK = new RegExp(
  "</?(p|div|section|article|header|footer|nav|main|h[1-6]|blockquote|pre"
  + "|ul|ol|li|table|tr|td|th|br|hr|figcaption|figure|details|summary)\\b[^>]*>",
  "gi");

const ENTITIES: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ",
};

/**
 * Flatten markup to the text a reader would see.
 *
 * Deliberately not a parser: this is the fallback for a page whose `content.md`
 * is missing, and a regex sweep that keeps block boundaries is enough to read
 * by. Anything needing real structure should go through the importer.
 */
export function htmlToText(html: string): string {
  return html
    .replace(SUPPRESSED, " ")
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(BLOCK, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&#(\d+);/g, (_, code: string) => String.fromCodePoint(Number(code)))
    .replace(/&#x([0-9a-f]+);/gi, (_, code: string) => String.fromCodePoint(parseInt(code, 16)))
    .replace(/&([a-z]+);/gi, (whole, name: string) => ENTITIES[name.toLowerCase()] ?? whole)
    .split("\n")
    .map((line) => line.trim())
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** "1-5", "3,7,12", or both. Out-of-range parts are dropped, not an error. */
export function parsePageRange(input: string, maxPage: number): number[] {
  const indices: number[] = [];
  for (const part of input.split(",").map((p) => p.trim())) {
    if (part.includes("-")) {
      const bounds = part.split("-").map((b) => Number(b.trim()));
      if (bounds.length !== 2) continue;
      const [from, to] = bounds as [number, number];
      if (!Number.isInteger(from) || !Number.isInteger(to) || from < 1 || to < from) continue;
      for (let page = Math.max(from, 1); page <= Math.min(to, maxPage); page++) {
        indices.push(page - 1);
      }
    } else {
      const page = Number(part);
      if (Number.isInteger(page) && page >= 1 && page <= maxPage) indices.push(page - 1);
    }
  }
  return indices;
}
