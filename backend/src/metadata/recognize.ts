/**
 * Working out what a document is.
 *
 * The old recogniser was one step: a DOI regex over three pages, then
 * CrossRef. Everything it missed — every book, every preprint, every PubMed
 * record, every paper whose DOI sat in the XMP rather than the text — landed
 * on the filename. For a 541-page textbook that meant the item was called
 * "UnderstandingDeepLearning_02_09_26_C (1)".
 *
 * The order below is by descending certainty, and it stops at the first answer
 * that clears its bar:
 *
 *   1. the file's own metadata, for a DOI someone already stamped in
 *   2. an identifier printed on the page: DOI, arXiv, ISBN, PMID
 *   3. a search, on the title the typography gives up
 *   4. the file's own title and author, unresolved
 *   5. the filename, cleaned
 *
 * Steps 3 and 4 are the ones Zotero needs its recogniser server for, and step
 * 2's last three identifiers it has translators for that this had nothing for
 * at all. Nothing here sends a page anywhere: searches carry a title and an
 * author name, never the document.
 */
import type { CslItem } from "../catalog/citekeys.js";
import { findIdentifiers, findDoi, findIsbn, type Identifiers } from "./identifiers.js";
import { readPdfFacts, type PdfFacts } from "./pdf.js";
import { accepts, normalizeTitle, sharesAuthor, titleSimilarity } from "./match.js";
import {
  arxivById, crossRefByDoi, crossRefSearch, dataCiteByDoi, googleBooksByIsbn,
  openLibraryByIsbn, openLibrarySearch, pubMedByPmid, splitName, type Candidate,
} from "./providers.js";

/** How the answer was arrived at. Shown to the user, so it is plain English. */
export type Method =
  | "doi" | "arxiv" | "isbn" | "pmid"
  | "title-search" | "embedded" | "filename";

export interface Recognized {
  csl: CslItem;
  method: Method;
  /** 0–1. Below `0.5` the answer is a description, not an identification. */
  confidence: number;
  /** Which service answered, when one did. */
  provider?: string;
  /** Identifiers read off the document, whether or not they resolved. */
  identifiers: Identifiers;
  /** Every step tried, in order, for `--explain` and for bug reports. */
  trail: string[];
}

export interface RecognizeInput {
  /** The PDF itself. Omit for a document with no file to read. */
  data?: Uint8Array;
  /** The file's name, the fallback of last resort. */
  fileName?: string;
  /** What the catalog already believes, used when the file says nothing. */
  title?: string;
  author?: string;
  /** Skip every network call. The embedded and filename steps still run. */
  offline?: boolean;
  /**
   * Resolve this identifier and nothing else.
   *
   * What the panel's lookup button sends when someone types an identifier in
   * by hand. The shape decides the registry, so one field serves a DOI, an
   * arXiv id, an ISBN and a PMID where the old button served only DOIs.
   */
  identifier?: string;
}

/** Which registry a hand-typed identifier belongs to. */
export function classifyIdentifier(raw: string): Identifiers {
  const text = raw.trim();
  if (text === "") return {};
  const found = findIdentifiers(text);
  if (Object.keys(found).length > 0) return found;
  // Typed bare, without the "doi:" or "ISBN" the matchers look for.
  if (/^10\.\d{4,9}\//.test(text)) return { doi: text.toLowerCase() };
  if (/^\d{4}\.\d{4,5}(v\d+)?$/.test(text)) return { arxiv: text };
  const digits = text.replace(/[-\s]/g, "");
  if (/^(\d{13}|\d{9}[\dxX])$/.test(digits)) {
    const asIsbn = findIsbn(`ISBN ${text}`);
    if (asIsbn !== null) return { isbn: asIsbn };
  }
  if (/^\d{4,8}$/.test(text)) return { pmid: text };
  return {};
}

/**
 * A title out of a filename, which is the answer of last resort.
 *
 * Order matters here. Separators have to survive long enough for the date
 * pattern to see them: turning `_` into a space first leaves
 * `UnderstandingDeepLearning 02 09 26 C`, where `02_09_26` is no longer one
 * token and the date never matches.
 */
export function titleFromFileName(fileName: string): string {
  let name = fileName.replace(/\.[a-z0-9]{1,5}$/i, "");
  name = name.replace(/\s*\(\d+\)\s*$/, "");              // the duplicate marker
  // `\b` cannot help here: `_` is a word character, so there is no boundary
  // between it and the digit after it. The separators are matched explicitly.
  name = name.replace(/[_\s-]\d{1,4}([-_.]\d{1,4}){1,3}(?=[_\s-]|$)/g, " "); // embedded dates
  name = name.replace(/\bet\s+al\.?/gi, " ");
  name = name.replace(/^\s*[^-]{1,40}\s+-\s+(?:\d{4}\s+-\s+)?/, ""); // "Campbell - 2022 - "
  name = name.replace(/\b(19|20)\d{2}\b/g, " ");
  name = name.replace(/\b(final|draft|copy|v\d+|preprint)\b/gi, " ");
  name = name.replace(/[_]+/g, " ");

  // CamelCase is a filename convention, not a title: split it per word, so a
  // name that is partly spaced and partly run together comes out even.
  name = name.split(/\s+/)
    .map((word) => (/[a-z][A-Z]/.test(word) ? word.replace(/([a-z0-9])([A-Z])/g, "$1 $2") : word))
    .join(" ");

  const words = name.replace(/\s+/g, " ").trim().split(" ").filter((w) => w !== "");
  // A trailing single character is a revision marker, never a word of a title.
  while (words.length > 1 && words[words.length - 1]!.length === 1) words.pop();
  return words.join(" ");
}

/** The first author's family name, for a search's second term. */
function firstFamily(csl: CslItem | undefined): string | undefined {
  const first = csl?.author?.[0];
  if (first === undefined) return undefined;
  return first.family ?? first.literal;
}

/** Pick the candidate that actually matches, or none. */
function bestMatch(
  candidates: Candidate[], title: string, authors: CslItem["author"],
): { item: CslItem; similarity: number } | null {
  let best: { item: CslItem; similarity: number } | null = null;
  for (const candidate of candidates) {
    const other = candidate.item.title;
    if (typeof other !== "string") continue;
    const similarity = titleSimilarity(title, other);
    if (best === null || similarity > best.similarity) {
      best = { item: candidate.item, similarity };
    }
  }
  if (best === null) return null;
  return accepts(best.similarity, sharesAuthor(authors, best.item.author)) ? best : null;
}

/** What the file itself claims, as CSL. Never a lookup. */
function embedded(facts: PdfFacts | null, input: RecognizeInput): CslItem {
  const info = facts?.info ?? {};
  const title = info.XmpTitle ?? info.Title ?? facts?.typographicTitle
    ?? input.title ?? (input.fileName === undefined ? undefined : titleFromFileName(input.fileName));
  const author = info.XmpCreator ?? info.Author ?? input.author;

  const csl: CslItem = { type: "document" };
  if (title !== undefined && title !== "") csl.title = title;
  if (author !== undefined && author !== "") {
    // "Kingma, Diederik; Ba, Jimmy" and "A and B" are both common here.
    csl.author = author.split(/\s*;\s*|\s+and\s+/i)
      .map((part) => part.trim()).filter((part) => part !== "")
      .map(splitName);
  }
  if (info.XmpPublication !== undefined) csl["container-title"] = info.XmpPublication;
  if (info.XmpIssn !== undefined) csl.ISSN = info.XmpIssn;
  if (info.XmpIsbn !== undefined) csl.ISBN = info.XmpIsbn;
  if (info.Keywords !== undefined) csl.keyword = info.Keywords;
  if (facts !== null && facts.pageCount > 0) {
    csl["number-of-pages"] = String(facts.pageCount);
  }
  return csl;
}

/** Guard a provider call: a dead service is a step that did not help. */
async function attempt<T>(trail: string[], label: string, run: () => Promise<T | null>): Promise<T | null> {
  try {
    const result = await run();
    trail.push(result === null ? `${label}: no match` : `${label}: hit`);
    return result;
  } catch (error) {
    trail.push(`${label}: failed (${error instanceof Error ? error.message : String(error)})`);
    return null;
  }
}

export async function recognize(input: RecognizeInput): Promise<Recognized> {
  const trail: string[] = [];

  let facts: PdfFacts | null = null;
  if (input.data !== undefined) {
    try {
      facts = await readPdfFacts(input.data);
      trail.push(`pdf: ${facts.pageCount} pages, ${Object.keys(facts.info).length} metadata fields`
        + (facts.typographicTitle === null ? "" : `, title by typography`));
    } catch (error) {
      trail.push(`pdf: unreadable (${error instanceof Error ? error.message : String(error)})`);
    }
  }

  const base = embedded(facts, input);

  // --- 1 & 2: identifiers, from the metadata first and then the glyphs ----
  const identifiers: Identifiers = {};
  // A hand-typed identifier is the user's instruction, so it outranks
  // everything the file says and nothing else is read off the page.
  const typed = input.identifier === undefined ? {} : classifyIdentifier(input.identifier);
  if (Object.keys(typed).length > 0) {
    Object.assign(identifiers, typed);
    trail.push(`identifier: ${Object.keys(typed).join(", ")}, as typed`);
  }
  const xmpDoi = facts?.info.XmpDoi;
  if (xmpDoi !== undefined && input.identifier === undefined) {
    const doi = findDoi(xmpDoi);
    if (doi !== null) { identifiers.doi = doi; trail.push("doi: from XMP"); }
  }
  const pageText = (facts?.pages ?? []).join("\n");
  if (pageText !== "" && input.identifier === undefined) {
    const found = findIdentifiers(pageText);
    for (const [key, value] of Object.entries(found)) {
      if (identifiers[key as keyof Identifiers] === undefined) {
        identifiers[key as keyof Identifiers] = value;
      }
    }
    trail.push(`identifiers: ${Object.keys(found).join(", ") || "none on the page"}`);
  }

  /**
   * What the document itself says it is called, when that is worth comparing.
   *
   * Only what the document or the catalog *asserts* — never the typographic
   * guess. Vetoing a resolved arXiv id with a title inferred from font sizes
   * is backwards, and it did exactly that: a cover whose glyphs extracted as
   * "G EX: P D T R - A LLM A" threw away a correct arXiv record.
   *
   * Three words is the bar. "download.pdf" and "2401.01234v1.pdf" carry no
   * claim about the title, and checking a lookup against them would reject
   * correct answers.
   */
  const claimedTitle = ((): string | null => {
    const candidate = facts?.info.XmpTitle ?? facts?.info.Title ?? input.title
      ?? (input.fileName === undefined ? undefined : titleFromFileName(input.fileName));
    if (candidate === undefined) return null;
    return normalizeTitle(candidate).split(" ").filter((w) => w !== "").length >= 3
      ? candidate : null;
  })();

  /**
   * Reject a lookup that resolved to a different document.
   *
   * An identifier printed on a page is not always *this* page's. Technical
   * books list the ISBNs of the others in their series, and a reference list
   * is nothing but other people's DOIs. One such book resolved by ISBN to
   * "Managing iterative software development projects" — a real record, for a
   * real book, that was not the one in hand.
   *
   * The bar is deliberately low. This is not asking "is this the best match",
   * which the search path answers; it is asking "is this plainly something
   * else", and only then putting the answer back.
   */
  const contradicts = (csl: CslItem, label: string): boolean => {
    // Someone who typed an identifier in has overruled the document already.
    if (input.identifier !== undefined) return false;
    if (claimedTitle === null || typeof csl.title !== "string") return false;
    const similarity = titleSimilarity(claimedTitle, csl.title);
    if (similarity >= 0.4) return false;
    trail.push(`${label}: rejected, "${csl.title.slice(0, 40)}" is not this document `
      + `(${similarity.toFixed(2)} similarity)`);
    return true;
  };

  const done = (csl: CslItem, method: Method, confidence: number, provider?: string): Recognized => {
    // Never let a lookup lose a page count the file stated.
    if (csl["number-of-pages"] === undefined && base["number-of-pages"] !== undefined) {
      csl["number-of-pages"] = base["number-of-pages"];
    }
    return { csl, method, confidence, provider, identifiers, trail };
  };

  if (input.offline === true) {
    trail.push("offline: lookups skipped");
    return done(base, base.title === undefined ? "filename" : "embedded", 0.3);
  }

  if (identifiers.doi !== undefined) {
    const viaCrossRef = await attempt(trail, "crossref", () => crossRefByDoi(identifiers.doi!));
    if (viaCrossRef !== null && !contradicts(viaCrossRef, "crossref")) {
      return done(viaCrossRef, "doi", 1, "CrossRef");
    }
    const viaDataCite = await attempt(trail, "datacite", () => dataCiteByDoi(identifiers.doi!));
    if (viaDataCite !== null && !contradicts(viaDataCite, "datacite")) {
      return done(viaDataCite, "doi", 0.95, "DataCite");
    }
  }

  if (identifiers.arxiv !== undefined) {
    const record = await attempt(trail, "arxiv", () => arxivById(identifiers.arxiv!));
    if (record !== null) {
      // A preprint that became a paper should file itself as the paper.
      if (record.publishedDoi !== null) {
        const published = await attempt(trail, "crossref (arXiv's published DOI)",
          () => crossRefByDoi(record.publishedDoi!));
        if (published !== null) return done(published, "arxiv", 1, "arXiv → CrossRef");
      }
      if (!contradicts(record.item, "arxiv")) return done(record.item, "arxiv", 0.95, "arXiv");
    }
  }

  if (identifiers.isbn !== undefined) {
    const viaOpenLibrary = await attempt(trail, "open library",
      () => openLibraryByIsbn(identifiers.isbn!));
    if (viaOpenLibrary !== null && !contradicts(viaOpenLibrary, "open library")) {
      return done(viaOpenLibrary, "isbn", 0.95, "Open Library");
    }
    const viaGoogle = await attempt(trail, "google books",
      () => googleBooksByIsbn(identifiers.isbn!));
    if (viaGoogle !== null && !contradicts(viaGoogle, "google books")) {
      return done(viaGoogle, "isbn", 0.9, "Google Books");
    }
  }

  if (identifiers.pmid !== undefined) {
    const viaPubMed = await attempt(trail, "pubmed", () => pubMedByPmid(identifiers.pmid!));
    if (viaPubMed !== null) {
      // PubMed's record names the DOI; CrossRef's is fuller.
      const doi = viaPubMed.DOI;
      if (typeof doi === "string") {
        const fuller = await attempt(trail, "crossref (PubMed's DOI)", () => crossRefByDoi(doi));
        if (fuller !== null) return done(fuller, "pmid", 1, "PubMed → CrossRef");
      }
      if (!contradicts(viaPubMed, "pubmed")) return done(viaPubMed, "pmid", 0.95, "PubMed");
    }
  }

  // --- 3: no identifier, so search on what the document looks like -------
  // `base.title` already prefers XMP, then the Info dictionary, then the
  // typography. Reaching for the typography first here searched for
  // "INTERPRETER" — one word off a book cover — while the Info dictionary
  // beside it said "Writing An Interpreter In Go".
  const searchTitle = base.title as string | undefined;
  if (typeof searchTitle === "string" && searchTitle.length >= 6) {
    const family = firstFamily(base);
    trail.push(`search: "${searchTitle}"${family === undefined ? "" : ` + ${family}`}`);

    const papers = await attempt(trail, "crossref search",
      () => crossRefSearch(searchTitle, family, 5));
    const paper = papers === null ? null : bestMatch(papers, searchTitle, base.author);
    if (paper !== null) {
      trail.push(`crossref search: accepted at ${paper.similarity.toFixed(2)} similarity`);
      return done(paper.item, "title-search", 0.5 + paper.similarity / 2, "CrossRef");
    }

    const books = await attempt(trail, "open library search",
      () => openLibrarySearch(searchTitle, family, 5));
    const book = books === null ? null : bestMatch(books, searchTitle, base.author);
    if (book !== null) {
      trail.push(`open library search: accepted at ${book.similarity.toFixed(2)} similarity`);
      return done(book.item, "title-search", 0.5 + book.similarity / 2, "Open Library");
    }
    trail.push("search: nothing cleared the similarity bar");
  }

  // --- 4 & 5: what the document says about itself ------------------------
  if (base.title !== undefined) return done(base, "embedded", 0.4);
  if (input.fileName !== undefined) {
    base.title = titleFromFileName(input.fileName);
    return done(base, "filename", 0.2);
  }
  return done(base, "filename", 0.1);
}
