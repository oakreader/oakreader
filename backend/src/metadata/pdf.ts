/**
 * What a PDF says about itself before anyone looks anything up.
 *
 * Three sources, in descending trustworthiness: the XMP packet, the Info
 * dictionary, and the glyphs. The first two are free — the file already
 * carries them — and the old recogniser read neither, which is why a paper
 * whose publisher had stamped the DOI into `prism:doi` still ended up named
 * after its filename.
 *
 * The third is the interesting one. `titleByTypography` recovers the title
 * the way a reader does: the biggest text on the first page, above the
 * authors. That is the step Zotero sends to a server; doing it here means a
 * document with no identifier at all still gets a real title, and nothing
 * about the file leaves the machine to get it.
 */
import { getDocumentProxy } from "unpdf";

export interface PdfFacts {
  /** `/Title`, `/Author`… from the Info dictionary, and the XMP equivalents. */
  info: Record<string, string>;
  /** Leading pages plus the last one, in reading order. */
  pages: string[];
  /** The largest-font line on page 1, when the page has a clear winner. */
  typographicTitle: string | null;
  pageCount: number;
}

/** How much of a document can hold its own identifier. */
const LEAD_PAGES = 3;

/** Values that are a PDF producer's idea of "I had nothing to put here". */
const JUNK_TITLE = /^(untitled|microsoft word -|doc\d+|pdfsam|print|output|\s*$)/i;

/**
 * An Info-dict title that is really a filename.
 *
 * macOS Preview stamps whatever the file was called into `/Title`, so a paper
 * saved as `full-issue.pdf` asserts that its title is "full-issue" — and the
 * assertion outranks the correct title sitting in 20pt type on page one. A
 * title with no spaces, or one that is a hyphen- or underscore-joined slug, is
 * a filename wearing a title's clothes.
 */
function looksLikeFileName(value: string): boolean {
  const bare = value.replace(/\.(pdf|docx?|tex|pages|epub)$/i, "").trim();
  if (bare === "") return true;
  if (!bare.includes(" ")) return true;
  return /^[\w]+([-_][\w]+)+$/.test(bare);
}
const JUNK_AUTHOR = /^(latex|pdftex|dvips|acrobat|unknown|user|admin|windows)/i;

/** Drop the Info-dict values that are a tool's name, not the document's. */
function usefulInfo(raw: Record<string, unknown>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(raw)) {
    if (typeof value !== "string") continue;
    const trimmed = value.trim();
    if (trimmed === "") continue;
    if (key === "Title" && (JUNK_TITLE.test(trimmed) || looksLikeFileName(trimmed))) continue;
    if (key === "Author" && JUNK_AUTHOR.test(trimmed)) continue;
    // "LaTeX with hyperref" is the producer, not a person.
    if (key === "Author" && /\b(hyperref|pdflatex|latex)\b/i.test(trimmed)) continue;
    out[key] = trimmed;
  }
  return out;
}

/** The handful of XMP fields worth having, pulled without an XML parser. */
function fromXmp(xmp: string): Record<string, string> {
  const out: Record<string, string> = {};
  const one = (tag: string): string | null => {
    // Both the bare form and the rdf:Alt/rdf:li wrapping Adobe writes.
    const direct = new RegExp(`<${tag}[^>]*>([^<]{1,500})</${tag}>`, "i").exec(xmp);
    if (direct !== null) return direct[1]!.trim();
    const wrapped = new RegExp(
      `<${tag}[^>]*>\\s*<rdf:Alt[^>]*>\\s*<rdf:li[^>]*>([^<]{1,500})</rdf:li>`, "i").exec(xmp);
    return wrapped === null ? null : wrapped[1]!.trim();
  };
  for (const [field, tag] of [
    ["XmpTitle", "dc:title"], ["XmpCreator", "dc:creator"],
    ["XmpDoi", "prism:doi"], ["XmpPublication", "prism:publicationName"],
    ["XmpIssn", "prism:issn"], ["XmpIsbn", "prism:isbn"],
    ["XmpDate", "prism:coverDate"],
  ] as const) {
    const value = one(tag);
    if (value !== null && value !== "") out[field] = value;
  }
  return out;
}

/**
 * The biggest line on the first page, when one line is clearly biggest.
 *
 * pdf.js reports each run's transform, whose vertical scale is the rendered
 * font size. Runs are grouped into lines by baseline, because a title that
 * wraps arrives as several runs at the same height. The winner has to beat
 * the page's body text by a clear margin — a page set in one size has no
 * title to find, and guessing there is how you end up naming a document
 * after its running header.
 */
function titleByTypography(items: Array<{ str: string; transform: number[] }>): string | null {
  interface Line { size: number; y: number; parts: string[] }
  const lines: Line[] = [];
  for (const item of items) {
    const text = item.str;
    if (text.trim() === "") continue;
    const size = Math.round(Math.abs(item.transform[3] ?? 0) * 10) / 10;
    const y = Math.round(item.transform[5] ?? 0);
    if (size <= 0) continue;
    const previous = lines[lines.length - 1];
    if (previous !== undefined && Math.abs(previous.y - y) <= 2 && previous.size === size) {
      previous.parts.push(text);
    } else {
      lines.push({ size, y, parts: [text] });
    }
  }
  if (lines.length === 0) return null;

  // The body size is the one the most characters are set in.
  const weight = new Map<number, number>();
  for (const line of lines) {
    const chars = line.parts.join("").length;
    weight.set(line.size, (weight.get(line.size) ?? 0) + chars);
  }
  let bodySize = 0;
  let bodyWeight = -1;
  for (const [size, chars] of weight) {
    if (chars > bodyWeight) { bodyWeight = chars; bodySize = size; }
  }

  const biggest = Math.max(...lines.map((l) => l.size));
  // A title is set meaningfully larger than the body. 15% is low enough for a
  // conservative journal template and high enough to reject a bold run-in.
  if (biggest < bodySize * 1.15) return null;

  const title = lines
    .filter((line) => line.size === biggest)
    .map((line) => line.parts.join("").replace(/\s+/g, " ").trim())
    .filter((text) => text !== "")
    .join(" ")
    .trim();

  // What the biggest line has to look like before it is treated as a title.
  // Each of these rejects something this met in a real library:
  //   - one word: "INTERPRETER", a cover device above the actual title
  //   - under 12 characters: "IN USE", the tail of a wrapped cover line
  //   - no hyphen-joined slug: "full-issue", a publisher's own filename
  //     printed in the margin and set larger than the body
  // In every case the file's own Info dictionary or its filename said more.
  if (title.length < 12 || title.length > 300) return null;
  if (!/[a-z]/i.test(title)) return null;
  if (title.trim().split(/\s+/).length < 2) return null;
  if (/^[a-z0-9]+(-[a-z0-9]+)+$/.test(title.trim())) return null;
  return title;
}

/** Read everything a recogniser can get from the file itself. */
export async function readPdfFacts(data: Uint8Array): Promise<PdfFacts> {
  // pdf.js takes ownership of the buffer it is handed, so a caller that reads
  // the same bytes twice gets "The object can not be cloned" on the second
  // pass. A copy costs one allocation and removes a trap from the API.
  const document = await getDocumentProxy(new Uint8Array(data));
  const pageCount = document.numPages;

  let info: Record<string, string> = {};
  try {
    const meta = await document.getMetadata();
    info = usefulInfo((meta.info ?? {}) as Record<string, unknown>);
    const xmp = (meta.metadata as { getRaw?: () => string } | undefined)?.getRaw?.();
    if (typeof xmp === "string" && xmp !== "") info = { ...fromXmp(xmp), ...info };
  } catch {
    // A broken metadata stream is not a reason to abandon the text.
  }

  // The leading pages carry the identifier; the last often carries the
  // copyright page's ISBN, which is the only place a scanned book states it.
  const wanted = new Set<number>();
  for (let i = 1; i <= Math.min(LEAD_PAGES, pageCount); i++) wanted.add(i);
  if (pageCount > LEAD_PAGES) wanted.add(pageCount);

  const pages: string[] = [];
  let typographicTitle: string | null = null;
  for (const number of [...wanted].sort((a, b) => a - b)) {
    try {
      const page = await document.getPage(number);
      const content = await page.getTextContent();
      const items = content.items as Array<{ str: string; transform: number[] }>;
      pages.push(items.map((i) => i.str).join(" "));
      if (number === 1) typographicTitle = titleByTypography(items);
    } catch {
      pages.push("");
    }
  }

  return { info, pages, typographicTitle, pageCount };
}
