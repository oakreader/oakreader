/**
 * Finding a document's own name for itself.
 *
 * A DOI, an arXiv id, an ISBN and a PMID are the four identifiers a PDF
 * actually carries, and each one turns a guess into a lookup. The previous
 * recogniser knew only the first, and only as a bare regex — so a book, a
 * preprint and a PubMed record all fell through to the filename.
 *
 * Every matcher here validates rather than just matches. An ISBN is four
 * fifths check digit; a DOI picked out of running text drags punctuation and
 * the next word's glyphs with it. A wrong identifier is worse than none: it
 * resolves, and silently names the document something else.
 */

/** What a document calls itself, with the text it was read out of. */
export interface Identifiers {
  doi?: string;
  arxiv?: string;
  isbn?: string;
  pmid?: string;
  /** So callers can list whatever was found without naming each field. */
  [kind: string]: string | undefined;
}

// --- DOI -----------------------------------------------------------------

/**
 * The registrant/suffix shape, deliberately not `[^\s]+`.
 *
 * A DOI in a PDF's text layer runs into whatever follows it, and `[^\s]+`
 * swallows that. The suffix character class here is the one CrossRef's own
 * documentation describes, and the trailing trim handles the sentence
 * punctuation that is legal inside a DOI but almost never ends one.
 */
const DOI_RE = /\b10\.\d{4,9}\/[-._;()[\]:/a-z0-9<>+]+/gi;

/** Punctuation that is legal mid-DOI but is sentence furniture at the end. */
function trimDoi(raw: string): string {
  let doi = raw;
  while (doi.length > 0 && ".,;:)]>'\"".includes(doi[doi.length - 1]!)) {
    doi = doi.slice(0, -1);
  }
  // "10.1000/xyz.pdf" is a filename that happens to contain a DOI.
  return doi.replace(/\.(pdf|html?|xml|epub)$/i, "");
}

export function findDoi(text: string): string | null {
  for (const match of text.matchAll(DOI_RE)) {
    const doi = trimDoi(match[0]);
    // A suffix of one or two characters is nearly always a truncated match.
    if (doi.length > 8 && doi.split("/")[1]!.length >= 3) return doi.toLowerCase();
  }
  return null;
}

// --- arXiv ---------------------------------------------------------------

/** Post-2007 `2401.01234v2`, and the pre-2007 `math.GT/0309136` form. */
const ARXIV_NEW = /arxiv[:\s/]*(\d{4}\.\d{4,5})(v\d+)?/i;
const ARXIV_OLD = /arxiv[:\s/]*([a-z-]+(?:\.[A-Z]{2})?\/\d{7})(v\d+)?/i;
/** A DOI arXiv itself mints: 10.48550/arXiv.2401.01234. */
const ARXIV_DOI = /10\.48550\/arxiv\.(\d{4}\.\d{4,5})/i;

export function findArxiv(text: string): string | null {
  const viaDoi = ARXIV_DOI.exec(text);
  if (viaDoi !== null) return viaDoi[1]!;
  const recent = ARXIV_NEW.exec(text);
  if (recent !== null) return recent[1]! + (recent[2] ?? "");
  const old = ARXIV_OLD.exec(text);
  if (old !== null) return old[1]! + (old[2] ?? "");
  return null;
}

// --- ISBN ----------------------------------------------------------------

/** ISBN-10: the weighted sum mod 11, where the check digit may be X. */
function isbn10Valid(digits: string): boolean {
  let sum = 0;
  for (let i = 0; i < 9; i++) sum += (10 - i) * Number(digits[i]);
  const check = digits[9]!.toUpperCase();
  sum += check === "X" ? 10 : Number(check);
  return sum % 11 === 0;
}

/** ISBN-13: the 1/3 alternating sum mod 10, same as EAN-13. */
function isbn13Valid(digits: string): boolean {
  let sum = 0;
  for (let i = 0; i < 13; i++) sum += Number(digits[i]) * (i % 2 === 0 ? 1 : 3);
  return sum % 10 === 0;
}

/**
 * An ISBN, checksum-verified.
 *
 * The checksum is the whole point. "ISBN" appears beside a page number, a
 * phone number and a catalogue code often enough that an unvalidated match is
 * a coin toss, and a wrong ISBN resolves to a real but different book.
 */
export function findIsbn(text: string): string | null {
  // Only look near the word, which is where a real one is printed.
  const labelled = /isbn(?:-1[03])?:?\s*((?:97[89][-\s]?)?[\d][\d-\s]{8,20}[\dxX])/gi;
  const candidates: string[] = [];
  for (const match of text.matchAll(labelled)) candidates.push(match[1]!);
  // A bare EAN-13 on a copyright page is still an ISBN if it checks out.
  for (const match of text.matchAll(/\b97[89][-\s]?[\d-\s]{10,17}\b/g)) {
    candidates.push(match[0]!);
  }

  for (const candidate of candidates) {
    const digits = candidate.replace(/[-\s]/g, "").toUpperCase();
    if (digits.length === 13 && /^\d{13}$/.test(digits) && isbn13Valid(digits)) return digits;
    if (digits.length === 10 && /^\d{9}[\dX]$/.test(digits) && isbn10Valid(digits)) return digits;
  }
  return null;
}

// --- PMID ----------------------------------------------------------------

export function findPmid(text: string): string | null {
  const match = /\bPMID:?\s*(\d{4,8})\b/i.exec(text);
  return match === null ? null : match[1]!;
}

// --- all of them ---------------------------------------------------------

/** Every identifier the text carries. Absent keys mean "not found here". */
export function findIdentifiers(text: string): Identifiers {
  const found: Identifiers = {};
  const doi = findDoi(text);
  if (doi !== null) found.doi = doi;
  const arxiv = findArxiv(text);
  if (arxiv !== null) found.arxiv = arxiv;
  const isbn = findIsbn(text);
  if (isbn !== null) found.isbn = isbn;
  const pmid = findPmid(text);
  if (pmid !== null) found.pmid = pmid;
  return found;
}
