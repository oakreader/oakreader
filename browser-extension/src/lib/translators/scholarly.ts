import type { BiblioMetadata, Translator, TranslatorResult } from "./types";
import { isDOIURL, isScholarlyDomain } from "./url-utils";

export const scholarlyTranslator: Translator = {
  id: "scholarly",
  label: "Scholarly Article",
  contentKind: "scholarly",
  priority: 5,

  detect(url: string): boolean {
    return isDOIURL(url) || isScholarlyDomain(url);
  },

  async extract(doc: Document, url: string): Promise<TranslatorResult> {
    const biblio = extractBiblioMetadata(doc, url);

    const title =
      getMeta(doc, 'meta[name="citation_title"]') ??
      getMeta(doc, 'meta[name="DC.title"]') ??
      doc.title;

    const author =
      getMeta(doc, 'meta[name="citation_author"]') ??
      getMeta(doc, 'meta[name="DC.creator"]') ??
      getMeta(doc, 'meta[name="author"]') ??
      null;

    const description =
      getMeta(doc, 'meta[name="description"]') ??
      getMeta(doc, 'meta[property="og:description"]') ??
      null;

    const thumbnailURL =
      getMeta(doc, 'meta[property="og:image"]') ?? null;

    return {
      kind: "scholarly",
      url,
      title,
      author,
      description,
      thumbnailURL,
      biblio,
      // html/markdown left empty — filled by SingleFile pipeline
      html: "",
      markdown: null,
    };
  },
};

function getMeta(doc: Document, selector: string): string | undefined {
  const el = doc.querySelector<HTMLMetaElement>(selector);
  return el?.content || undefined;
}

function getAllMeta(doc: Document, selector: string): string[] {
  return Array.from(doc.querySelectorAll<HTMLMetaElement>(selector))
    .map((el) => el.content)
    .filter(Boolean);
}

function extractBiblioMetadata(doc: Document, url: string): BiblioMetadata {
  // --- DOI ---
  const doi =
    getMeta(doc, 'meta[name="citation_doi"]') ??
    getMeta(doc, 'meta[name="DC.identifier"][scheme="doi" i]') ??
    getMeta(doc, 'meta[name="prism.doi"]') ??
    extractDOIFromURL(url) ??
    extractDOIFromLinks(doc) ??
    null;

  // --- ISSN ---
  const issn =
    getMeta(doc, 'meta[name="citation_issn"]') ??
    getMeta(doc, 'meta[name="prism.issn"]') ??
    null;

  // --- ISBN ---
  const isbn =
    getMeta(doc, 'meta[name="citation_isbn"]') ?? null;

  // --- Journal / Container title ---
  const journal =
    getMeta(doc, 'meta[name="citation_journal_title"]') ??
    getMeta(doc, 'meta[name="DC.source"]') ??
    getMeta(doc, 'meta[name="prism.publicationName"]') ??
    null;

  // --- Volume ---
  const volume =
    getMeta(doc, 'meta[name="citation_volume"]') ??
    getMeta(doc, 'meta[name="prism.volume"]') ??
    null;

  // --- Issue ---
  const issue =
    getMeta(doc, 'meta[name="citation_issue"]') ??
    getMeta(doc, 'meta[name="prism.number"]') ??
    null;

  // --- Pages ---
  const firstPage = getMeta(doc, 'meta[name="citation_firstpage"]') ??
    getMeta(doc, 'meta[name="prism.startingPage"]');
  const lastPage = getMeta(doc, 'meta[name="citation_lastpage"]');
  const pages = firstPage
    ? lastPage ? `${firstPage}-${lastPage}` : firstPage
    : null;

  // --- Publisher ---
  const publisher =
    getMeta(doc, 'meta[name="citation_publisher"]') ??
    getMeta(doc, 'meta[name="DC.publisher"]') ??
    null;

  // --- Year ---
  const dateStr =
    getMeta(doc, 'meta[name="citation_publication_date"]') ??
    getMeta(doc, 'meta[name="DC.date"]') ??
    getMeta(doc, 'meta[name="prism.publicationDate"]') ??
    getMeta(doc, 'meta[name="citation_date"]');
  let year: number | null = null;
  if (dateStr) {
    const match = dateStr.match(/(\d{4})/);
    if (match) year = parseInt(match[1]);
  }

  // --- Authors ---
  const authorStrings = getAllMeta(doc, 'meta[name="citation_author"]');
  if (authorStrings.length === 0) {
    // Try Dublin Core
    authorStrings.push(...getAllMeta(doc, 'meta[name="DC.creator"]'));
  }
  const authors = authorStrings.length > 0
    ? authorStrings.map(parseAuthorName)
    : undefined;

  // --- CSL Type inference ---
  const cslType = inferCSLType(doc, { journal, isbn });

  return {
    doi,
    issn,
    isbn,
    journal,
    volume,
    issue,
    pages,
    publisher,
    year,
    authors,
    cslType,
  };
}

function extractDOIFromURL(url: string): string | undefined {
  try {
    const u = new URL(url);
    if (u.hostname === "doi.org" || u.hostname === "dx.doi.org") {
      // Path is like /10.1234/something
      const path = u.pathname.replace(/^\//, "");
      if (path.startsWith("10.")) return path;
    }
  } catch { /* ignore */ }
  return undefined;
}

function extractDOIFromLinks(doc: Document): string | undefined {
  const link = doc.querySelector<HTMLAnchorElement>('a[href*="doi.org/10."]');
  if (link) {
    const match = link.href.match(/doi\.org\/(10\.\S+)/);
    if (match) return decodeURIComponent(match[1]);
  }
  return undefined;
}

function parseAuthorName(name: string): { given?: string; family?: string } {
  const trimmed = name.trim();
  // Handle "Family, Given" format
  if (trimmed.includes(",")) {
    const [family, given] = trimmed.split(",", 2);
    return { family: family.trim(), given: given?.trim() };
  }
  // Handle "Given Family" format
  const parts = trimmed.split(/\s+/);
  if (parts.length === 1) return { family: parts[0] };
  const family = parts.pop()!;
  const given = parts.join(" ");
  return { given, family };
}

function inferCSLType(
  doc: Document,
  hints: { journal?: string | null; isbn?: string | null }
): string {
  // Conference proceedings
  if (getMeta(doc, 'meta[name="citation_conference_title"]')) {
    return "paper-conference";
  }
  // Dissertation/thesis
  if (getMeta(doc, 'meta[name="citation_dissertation_institution"]')) {
    return "thesis";
  }
  // Book (ISBN present, no journal)
  if (hints.isbn && !hints.journal) {
    return "book";
  }
  // Journal article (has journal or ISSN)
  if (hints.journal) {
    return "article-journal";
  }
  // Default for scholarly pages
  return "article";
}
