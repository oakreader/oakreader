/**
 * Deciding whether a search result is actually this document.
 *
 * A provider's own relevance score cannot answer that. CrossRef scored the
 * correct match 39 for one query and 37 for another, and scored three wrong
 * answers 22–30 for a third — the number tracks the query, not the truth. Used
 * as a threshold it would accept "Path Signature Features vs. Raw Inputs" as
 * *Understanding Deep Learning*.
 *
 * So acceptance is decided here, by comparing the candidate's title with the
 * one read off the document. That comparison is answerable from the two
 * strings alone, which is exactly what a threshold should be.
 */

/** Lowercase, unpunctuated, unspaced — what two titles have in common. */
export function normalizeTitle(title: string): string {
  return title
    .toLowerCase()
    .replace(/[‐-―]/g, "-")
    .replace(/['‘’"“”]/g, "")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

/** Words that carry no identity, so a subtitle's absence is not a mismatch. */
const NOISE = new Set(["a", "an", "the", "of", "for", "and", "on", "in", "to", "with"]);

function contentWords(title: string): string[] {
  return normalizeTitle(title).split(" ").filter((w) => w !== "" && !NOISE.has(w));
}

/**
 * How alike two titles are, 0 to 1.
 *
 * Plain containment is not enough, and the way it fails is instructive.
 * *Understanding Deep Learning* has three content words, and all three appear
 * in "Learning Deep Representations: Toward a better new understanding of the
 * deep learning paradigm" — a different work by a different author. Pure
 * containment scored that 1.00 and filed the textbook as someone's thesis.
 *
 * So two measures, and the better one wins:
 *
 *   - Dice overlap, which is symmetric and punishes the length gap that made
 *     the thesis match look perfect.
 *   - A prefix test, which rescues the one case Dice is too harsh on: the same
 *     work recorded with its subtitle. A subtitle extends a title from the
 *     front, so the shorter string is the longer one's opening words. The
 *     thesis fails this — it opens on "learning deep representations".
 */
export function titleSimilarity(a: string, b: string): number {
  const left = contentWords(a);
  const right = contentWords(b);
  if (left.length === 0 || right.length === 0) return 0;

  const [shorter, longer] = left.length <= right.length ? [left, right] : [right, left];
  const pool = new Map<string, number>();
  for (const word of longer) pool.set(word, (pool.get(word) ?? 0) + 1);

  let hits = 0;
  for (const word of shorter) {
    const remaining = pool.get(word) ?? 0;
    if (remaining > 0) { pool.set(word, remaining - 1); hits++; }
  }

  // One word in common is coincidence, not a match.
  if (hits < 2 && shorter.length > 1) return 0;

  const dice = (2 * hits) / (left.length + right.length);
  const isPrefix = shorter.every((word, i) => longer[i] === word);
  if (!isPrefix) return dice;

  // How much the prefix is worth depends on how much it says. "Deep Learning"
  // opens a shelf of different books, so on its own it is a lead, not an
  // identification — it clears the bar only when an author name agrees too.
  // A gap of more than threefold is not a subtitle, it is a different work.
  if (longer.length > shorter.length * 3) return dice;
  const prefixScore = shorter.length >= 3 ? 0.95 : shorter.length === 2 ? 0.75 : 0.5;
  return Math.max(dice, prefixScore);
}

/** Family names, lowercased, for the weaker author check. */
function families(names: Array<{ family?: string; literal?: string }> | undefined): Set<string> {
  const out = new Set<string>();
  for (const name of names ?? []) {
    const family = name.family ?? name.literal?.split(/[\s,]+/).pop();
    if (family !== undefined && family !== "") out.add(family.toLowerCase());
  }
  return out;
}

/** True when the two author lists name anyone in common. */
export function sharesAuthor(
  a: Array<{ family?: string; literal?: string }> | undefined,
  b: Array<{ family?: string; literal?: string }> | undefined,
): boolean {
  const left = families(a);
  if (left.size === 0) return false;
  for (const family of families(b)) if (left.has(family)) return true;
  return false;
}

/**
 * The bar a searched-for match has to clear.
 *
 * 0.82 on titles alone; 0.65 when an author name also agrees, because two
 * independent signals agreeing is stronger evidence than either alone. Below
 * that the recogniser keeps what the document says about itself, which is
 * always honest even when it is thin.
 */
export const TITLE_ONLY_THRESHOLD = 0.82;
export const WITH_AUTHOR_THRESHOLD = 0.65;

export function accepts(similarity: number, authorAgrees: boolean): boolean {
  return similarity >= (authorAgrees ? WITH_AUTHOR_THRESHOLD : TITLE_ONLY_THRESHOLD);
}
