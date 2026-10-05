/**
 * Where metadata comes from, once the document has said what it is.
 *
 * Six sources against Zotero's effective four, and the two extra ones are not
 * padding. DataCite holds what CrossRef does not — Zenodo records, figshare
 * datasets, a great many theses — and resolving an arXiv id all the way to its
 * published version means a preprint files itself as the paper it became,
 * which Zotero's arXiv translator does not do.
 *
 * Every provider returns CSL JSON or null. None of them throws for "no match":
 * a recogniser runs several in sequence and a 404 from one is an ordinary step,
 * not an error to surface. A network failure is logged by the caller and
 * treated the same way, because the fallback chain is the error handling.
 */
import type { CslItem, CslName } from "../catalog/citekeys.js";

/** Identify the client. CrossRef gives politer service to requests that do. */
const UA = "OakReader/1.0 (https://oakreader.com; mailto:hello@oakreader.com)";

const TIMEOUT_MS = 12_000;

async function getJson(url: string, accept = "application/json"): Promise<unknown | null> {
  const response = await fetch(url, {
    headers: { "User-Agent": UA, Accept: accept },
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!response.ok) return null;
  return await response.json() as unknown;
}

async function getText(url: string): Promise<string | null> {
  const response = await fetch(url, {
    headers: { "User-Agent": UA },
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!response.ok) return null;
  return await response.text();
}

/** A year, from whichever of CSL's several date shapes arrived. */
function dateParts(year?: number, month?: number, day?: number): CslItem["issued"] | undefined {
  if (year === undefined || !Number.isFinite(year)) return undefined;
  const parts = [year];
  if (month !== undefined && Number.isFinite(month)) parts.push(month);
  if (day !== undefined && Number.isFinite(day)) parts.push(day);
  return { "date-parts": [parts] };
}

/**
 * "LeCun Y" → {family: "LeCun", given: "Y"}.
 *
 * PubMed writes the family name first with the initials after and no comma,
 * which is the exact reverse of the order `splitName` assumes. Taking the last
 * token as the family name there turns Yann LeCun into "Y LeCun".
 */
export function splitPubMedName(full: string): CslName {
  const name = full.trim().replace(/\s+/g, " ");
  const match = /^(.+?)\s+([A-Z]{1,3})$/.exec(name);
  if (match !== null) return { family: match[1]!, given: match[2]! };
  return splitName(name);
}

/** "Simon J.D. Prince" → {family: "Prince", given: "Simon J.D."}. */
export function splitName(full: string): CslName {
  const name = full.trim().replace(/\s+/g, " ");
  if (name === "") return { literal: full };
  // "Prince, Simon J.D." — already the way CSL wants it.
  const comma = name.indexOf(",");
  if (comma > 0) {
    return { family: name.slice(0, comma).trim(), given: name.slice(comma + 1).trim() };
  }
  const parts = name.split(" ");
  if (parts.length === 1) return { literal: name };
  return { family: parts[parts.length - 1]!, given: parts.slice(0, -1).join(" ") };
}

// --- CrossRef ------------------------------------------------------------

interface CrossRefWork {
  DOI?: string; type?: string; title?: string[]; "container-title"?: string[];
  publisher?: string; volume?: string; issue?: string; page?: string;
  ISSN?: string[]; ISBN?: string[]; URL?: string; language?: string;
  abstract?: string; edition?: string; score?: number;
  author?: Array<{ family?: string; given?: string; name?: string }>;
  editor?: Array<{ family?: string; given?: string; name?: string }>;
  issued?: { "date-parts"?: Array<Array<number | null>> };
  "published-print"?: { "date-parts"?: Array<Array<number | null>> };
}

/** CrossRef's own vocabulary for what a work is, in CSL's. */
const CROSSREF_TYPE: Record<string, string> = {
  "journal-article": "article-journal",
  "proceedings-article": "paper-conference",
  "book-chapter": "chapter",
  "posted-content": "article",
  monograph: "book",
  "reference-book": "book",
  dissertation: "thesis",
  dataset: "dataset",
  report: "report",
  book: "book",
};

function crossRefToCsl(work: CrossRefWork): CslItem {
  const names = (list: CrossRefWork["author"]): CslName[] | undefined =>
    list === undefined || list.length === 0
      ? undefined
      : list.map((p) => (p.family !== undefined
        ? { family: p.family, given: p.given }
        : splitName(p.name ?? "")));

  const parts = (work.issued ?? work["published-print"])?.["date-parts"]?.[0] ?? [];
  const item: CslItem = {
    type: CROSSREF_TYPE[work.type ?? ""] ?? "document",
    title: work.title?.[0],
    "container-title": work["container-title"]?.[0],
    publisher: work.publisher,
    volume: work.volume,
    issue: work.issue,
    page: work.page,
    DOI: work.DOI,
    ISSN: work.ISSN?.[0],
    ISBN: work.ISBN?.[0],
    URL: work.URL,
    language: work.language,
    edition: work.edition,
    // CrossRef ships JATS tags inside the abstract.
    abstract: work.abstract?.replace(/<[^>]+>/g, "").trim(),
    author: names(work.author),
    editor: names(work.editor),
    issued: dateParts(parts[0] ?? undefined, parts[1] ?? undefined, parts[2] ?? undefined),
    source: "CrossRef",
  };
  for (const key of Object.keys(item)) if (item[key] === undefined) delete item[key];
  return item;
}

export async function crossRefByDoi(doi: string): Promise<CslItem | null> {
  const body = await getJson(`https://api.crossref.org/works/${encodeURIComponent(doi)}`);
  const work = (body as { message?: CrossRefWork } | null)?.message;
  return work === undefined || work === null ? null : crossRefToCsl(work);
}

/** One scored candidate from a bibliographic search. */
export interface Candidate { item: CslItem; score: number }

/**
 * Search CrossRef by what the document looks like.
 *
 * This is the step Zotero performs by posting the first page to its own
 * recogniser server. `query.bibliographic` takes the same ingredients — title,
 * authors, year — against the public API, so an identifier-free paper still
 * resolves and the page never leaves the machine.
 */
export async function crossRefSearch(
  title: string, author?: string, rows = 5,
): Promise<Candidate[]> {
  const query = new URLSearchParams({
    "query.bibliographic": title,
    rows: String(rows),
    select: "DOI,title,author,issued,container-title,type,publisher,volume,issue,page,ISSN,ISBN,URL,abstract,score",
  });
  if (author !== undefined && author !== "") query.set("query.author", author);
  const body = await getJson(`https://api.crossref.org/works?${query.toString()}`);
  const items = (body as { message?: { items?: CrossRefWork[] } } | null)?.message?.items ?? [];
  return items.map((work) => ({ item: crossRefToCsl(work), score: work.score ?? 0 }));
}

// --- DataCite ------------------------------------------------------------

/**
 * The half of the DOI space CrossRef does not register.
 *
 * Zenodo, figshare, Dryad, and most university thesis repositories mint
 * DataCite DOIs. Zotero resolves these through a generic DOI translator that
 * often lands on the landing page instead of the record, so this is a place
 * where asking the right registry outright does better.
 */
export async function dataCiteByDoi(doi: string): Promise<CslItem | null> {
  const body = await getJson(`https://api.datacite.org/dois/${encodeURIComponent(doi)}`);
  const a = (body as { data?: { attributes?: Record<string, unknown> } } | null)?.data?.attributes;
  if (a === undefined) return null;

  const titles = a.titles as Array<{ title?: string }> | undefined;
  const creators = a.creators as Array<{ name?: string; familyName?: string; givenName?: string }> | undefined;
  const item: CslItem = {
    type: "document",
    title: titles?.[0]?.title,
    DOI: a.doi as string | undefined,
    publisher: a.publisher as string | undefined,
    URL: a.url as string | undefined,
    issued: dateParts(a.publicationYear as number | undefined),
    author: creators?.map((c) => (c.familyName !== undefined
      ? { family: c.familyName, given: c.givenName }
      : splitName(c.name ?? ""))),
    abstract: (a.descriptions as Array<{ description?: string }> | undefined)?.[0]?.description,
    source: "DataCite",
  };
  for (const key of Object.keys(item)) if (item[key] === undefined) delete item[key];
  return item.title === undefined ? null : item;
}

// --- arXiv ---------------------------------------------------------------

function tag(xml: string, name: string): string | null {
  const match = new RegExp(`<${name}[^>]*>([\\s\\S]*?)</${name}>`, "i").exec(xml);
  return match === null ? null : match[1]!.replace(/\s+/g, " ").trim();
}

export interface ArxivRecord { item: CslItem; publishedDoi: string | null }

/**
 * An arXiv id, resolved — and told where it was published.
 *
 * `publishedDoi` is the reason this returns a record rather than an item. A
 * preprint that became a paper carries the journal DOI in its Atom entry, and
 * a reference should name the version of record. The recogniser follows it.
 */
export async function arxivById(id: string): Promise<ArxivRecord | null> {
  const bare = id.replace(/v\d+$/, "");
  const xml = await getText(`https://export.arxiv.org/api/query?id_list=${encodeURIComponent(bare)}&max_results=1`);
  if (xml === null) return null;
  const entry = /<entry>([\s\S]*?)<\/entry>/i.exec(xml)?.[1];
  if (entry === undefined) return null;

  const title = tag(entry, "title");
  if (title === null || title === "") return null;
  const published = tag(entry, "published");
  const year = published === null ? undefined : Number(published.slice(0, 4));

  const authors: CslName[] = [];
  for (const match of entry.matchAll(/<author>[\s\S]*?<name>([^<]+)<\/name>[\s\S]*?<\/author>/gi)) {
    authors.push(splitName(match[1]!.trim()));
  }

  const item: CslItem = {
    type: "article",
    title,
    author: authors.length > 0 ? authors : undefined,
    issued: dateParts(year),
    abstract: tag(entry, "summary") ?? undefined,
    "container-title": "arXiv",
    number: `arXiv:${bare}`,
    DOI: `10.48550/arXiv.${bare}`,
    URL: `https://arxiv.org/abs/${bare}`,
    source: "arXiv",
  };
  for (const key of Object.keys(item)) if (item[key] === undefined) delete item[key];

  return { item, publishedDoi: tag(entry, "arxiv:doi") };
}

// --- books: Open Library, then Google Books ------------------------------

/**
 * A book, by its ISBN.
 *
 * This is the gap that sent *Understanding Deep Learning* — a book with no
 * DOI — to its own filename. Open Library first because it is open data and
 * needs no key; Google Books second because it has the long tail Open Library
 * does not, especially non-English editions.
 */
export async function openLibraryByIsbn(isbn: string): Promise<CslItem | null> {
  const body = await getJson(
    `https://openlibrary.org/api/books?bibkeys=ISBN:${isbn}&format=json&jscmd=data`);
  const record = (body as Record<string, Record<string, unknown>> | null)?.[`ISBN:${isbn}`];
  if (record === undefined) return null;

  const year = Number(/\b(1[5-9]\d{2}|20\d{2})\b/.exec(String(record.publish_date ?? ""))?.[1]);
  const item: CslItem = {
    type: "book",
    title: record.title as string | undefined,
    "title-short": record.subtitle as string | undefined,
    author: (record.authors as Array<{ name?: string }> | undefined)
      ?.map((a) => splitName(a.name ?? "")),
    publisher: (record.publishers as Array<{ name?: string }> | undefined)?.[0]?.name,
    "publisher-place": (record.publish_places as Array<{ name?: string }> | undefined)?.[0]?.name,
    "number-of-pages": record.number_of_pages === undefined
      ? undefined : String(record.number_of_pages),
    ISBN: isbn,
    URL: record.url as string | undefined,
    issued: dateParts(Number.isFinite(year) ? year : undefined),
    source: "Open Library",
  };
  for (const key of Object.keys(item)) if (item[key] === undefined) delete item[key];
  return item.title === undefined ? null : item;
}

/**
 * A book with no ISBN on the page, found the way CrossRef finds a paper.
 *
 * CrossRef indexes almost no trade or university-press books, so a book
 * without a printed ISBN has nowhere to go there — which is how a 541-page
 * textbook ends up named after its file. Open Library's search is the
 * equivalent index for books, and it is open data with no key and no quota.
 */
export async function openLibrarySearch(
  title: string, author?: string, rows = 5,
): Promise<Candidate[]> {
  const query = new URLSearchParams({
    q: author === undefined || author === "" ? title : `${title} ${author}`,
    limit: String(rows),
    fields: "title,subtitle,author_name,first_publish_year,publisher,isbn,number_of_pages_median,key",
  });
  const body = await getJson(`https://openlibrary.org/search.json?${query.toString()}`);
  const docs = (body as { docs?: Array<Record<string, unknown>> } | null)?.docs ?? [];
  return docs
    .filter((doc) => typeof doc.title === "string")
    .map((doc) => {
      const item: CslItem = {
        type: "book",
        title: doc.title as string,
        "title-short": doc.subtitle as string | undefined,
        author: (doc.author_name as string[] | undefined)?.map(splitName),
        publisher: (doc.publisher as string[] | undefined)?.[0],
        ISBN: (doc.isbn as string[] | undefined)?.find((i) => i.length === 13)
          ?? (doc.isbn as string[] | undefined)?.[0],
        "number-of-pages": doc.number_of_pages_median === undefined
          ? undefined : String(doc.number_of_pages_median),
        URL: doc.key === undefined ? undefined : `https://openlibrary.org${String(doc.key)}`,
        issued: dateParts(doc.first_publish_year as number | undefined),
        source: "Open Library",
      };
      for (const key of Object.keys(item)) if (item[key] === undefined) delete item[key];
      // Open Library ranks by its own relevance and reports no score, so
      // ordering is all it offers. The caller scores by title similarity.
      return { item, score: 0 };
    });
}

export async function googleBooksByIsbn(isbn: string): Promise<CslItem | null> {
  const body = await getJson(
    `https://www.googleapis.com/books/v1/volumes?q=isbn:${encodeURIComponent(isbn)}&maxResults=1`);
  const info = (body as { items?: Array<{ volumeInfo?: Record<string, unknown> }> } | null)
    ?.items?.[0]?.volumeInfo;
  if (info === undefined) return null;

  const year = Number(String(info.publishedDate ?? "").slice(0, 4));
  const item: CslItem = {
    type: "book",
    title: info.title as string | undefined,
    "title-short": info.subtitle as string | undefined,
    author: (info.authors as string[] | undefined)?.map(splitName),
    publisher: info.publisher as string | undefined,
    "number-of-pages": info.pageCount === undefined ? undefined : String(info.pageCount),
    abstract: info.description as string | undefined,
    language: info.language as string | undefined,
    ISBN: isbn,
    issued: dateParts(Number.isFinite(year) ? year : undefined),
    source: "Google Books",
  };
  for (const key of Object.keys(item)) if (item[key] === undefined) delete item[key];
  return item.title === undefined ? null : item;
}

// --- PubMed --------------------------------------------------------------

export async function pubMedByPmid(pmid: string): Promise<CslItem | null> {
  const body = await getJson(
    `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed&id=${encodeURIComponent(pmid)}&retmode=json`);
  const record = (body as { result?: Record<string, Record<string, unknown>> } | null)
    ?.result?.[pmid];
  if (record === undefined || record.title === undefined) return null;

  const year = Number(String(record.pubdate ?? "").slice(0, 4));
  const ids = record.articleids as Array<{ idtype?: string; value?: string }> | undefined;
  const item: CslItem = {
    type: "article-journal",
    title: String(record.title).replace(/\.$/, ""),
    "container-title": record.fulljournalname as string | undefined ?? record.source as string | undefined,
    volume: record.volume as string | undefined,
    issue: record.issue as string | undefined,
    page: record.pages as string | undefined,
    ISSN: record.issn as string | undefined,
    DOI: ids?.find((i) => i.idtype === "doi")?.value,
    author: (record.authors as Array<{ name?: string }> | undefined)
      ?.filter((a) => a.name !== undefined)
      .map((a) => splitName(a.name!)),
    issued: dateParts(Number.isFinite(year) ? year : undefined),
    note: `PMID: ${pmid}`,
    source: "PubMed",
  };
  for (const key of Object.keys(item)) if (item[key] === undefined) delete item[key];
  return item;
}
