/**
 * Cite keys, in the Better BibTeX default shape: `{auth}{TitleWords}{year}` —
 * `vaswaniAttentionAllYou2017`, `goodfellowDeepLearning2016`.
 *
 *   - auth: first author's family name, transliterated, particles stripped
 *   - TitleWords: the first 3 significant words, each capitalised
 *   - year: four digits
 *
 * Generation lives beside assignment rather than in the shell, because a key
 * has to be unique across the library and only the side holding the rows can
 * guarantee that: computing a candidate in the shell and writing it in a second
 * call leaves a window where two imports pick the same key.
 *
 * Transliteration is the reason this could not simply be lifted. The Swift
 * original called CFStringTransform, which exists only on Apple platforms; this
 * uses AnyAscii, which ships its tables and runs anywhere. The two agree on
 * Latin and Greek, and differ slightly on Cyrillic (Dostoevskij vs Dostoevskiy).
 * Only new keys are affected — assignment never touches an item that already
 * has one.
 */
import type { Database } from "bun:sqlite";
import anyAscii from "any-ascii";

/** Common English words that carry no identity in a title. */
const STOP_WORDS = new Set([
  "a", "an", "the",
  "and", "but", "or", "nor", "for", "yet", "so",
  "at", "by", "in", "of", "on", "to", "up", "as", "from", "into", "with",
  "about", "after", "before", "between", "through", "during", "without",
  "against", "along", "among", "around", "behind", "below", "beneath",
  "beside", "beyond", "down", "near", "off", "over", "past", "toward",
  "under", "upon",
  "is", "are", "was", "were", "be", "been", "being",
  "has", "have", "had", "do", "does", "did",
  "will", "would", "shall", "should", "may", "might", "can", "could",
  "it", "its", "not", "no", "than", "that", "this", "these", "those",
  "what", "which", "who", "whom", "how", "when", "where", "why",
]);

/** Name particles dropped from a family name: "van der Waals" → "waals". */
const NAME_PARTICLES = new Set([
  "von", "van", "de", "del", "della", "der", "di", "du", "el", "la", "le",
  "lo", "ten", "ter", "den", "het", "dos", "das", "do", "da", "af", "av",
]);

/** The slice of CSL JSON a cite key is built from. */
export interface CslName {
  family?: string;
  given?: string;
  literal?: string;
  "non-dropping-particle"?: string;
}

export interface CslItem {
  title?: string;
  "short-title"?: string;
  author?: CslName[];
  issued?: { "date-parts"?: number[][]; year?: number };
  [key: string]: unknown;
}

/**
 * Ideographs and Hangul syllables, each of which is a word on its own.
 *
 * AnyAscii romanises a run of them as one token — 深度学习 becomes
 * "ShenDuXueXi" — which would leave a title with a single "word" in it and a
 * key built from one third of what it should be. Kana are deliberately absent:
 * there a run *is* one word, and splitting こんにちは gives "ko n ni chi ha".
 */
const SYLLABIC = /[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\uAC00-\uD7AF]/gu;

/**
 * Symbols and emoji, which AnyAscii spells out as words.
 *
 * "Apache Kafka®" would otherwise contribute an "R", and "🎙️ MacWhisper" a
 * "Microphone2" — each stealing one of the three title-word slots. Removing
 * them first keeps a key made of words someone actually wrote.
 */
const DECORATIVE = /[\p{S}\p{C}]/gu;

/** Any script to ASCII, then diacritics away. */
export function transliterate(text: string): string {
  const spaced = text.replace(DECORATIVE, " ").replace(SYLLABIC, (char) => ` ${char} `);
  return anyAscii(spaced).normalize("NFD").replace(/[\u0300-\u036f]/g, "");
}

/** ASCII letters and digits only. */
function alphanumericOnly(text: string): string {
  return text.replace(/[^A-Za-z0-9]/g, "");
}

/** The year, from either shape CSL uses to carry it. */
export function cslYear(csl: CslItem): number | null {
  const parts = csl.issued?.["date-parts"]?.[0]?.[0];
  if (typeof parts === "number") return parts;
  return typeof csl.issued?.year === "number" ? csl.issued.year : null;
}

/**
 * The author half. An explicit non-dropping particle is kept and joined to the
 * family name ("von Neumann" → vonneumann), because the person's name includes
 * it; a particle merely sitting loose in the string is dropped.
 */
export function authorKey(csl: CslItem): string {
  const first = csl.author?.[0];
  if (first === undefined) return "";

  const particle = first["non-dropping-particle"];
  if (particle !== undefined && particle !== "") {
    return alphanumericOnly(transliterate(particle + (first.family ?? "")).toLowerCase());
  }
  return processAuthorName(first.family ?? first.literal ?? "");
}

/** Transliterate, lowercase, drop particles, keep alphanumerics. */
export function processAuthorName(name: string): string {
  const words = transliterate(name).toLowerCase().split(/\s+/)
    .filter((w) => w !== "" && !NAME_PARTICLES.has(w));
  return alphanumericOnly(words.join(""));
}

/**
 * The title half: up to three significant words, each capitalised.
 * A short title is preferred when it is genuinely short — five words or fewer.
 */
export function titleWords(csl: CslItem): string {
  const short = csl["short-title"];
  if (short !== undefined && short !== "") {
    const count = short.split(/\s+/).filter((w) => w !== "").length;
    if (count <= 5) return titleWordsFrom(short);
  }
  return csl.title !== undefined && csl.title !== "" ? titleWordsFrom(csl.title) : "";
}

export function titleWordsFrom(title: string): string {
  return transliterate(title)
    .split(/[^A-Za-z0-9]+/)
    .filter((w) => w !== "" && !STOP_WORDS.has(w.toLowerCase()))
    .slice(0, 3)
    .map((w) => w[0]!.toUpperCase() + w.slice(1).toLowerCase())
    .join("");
}

/** The whole key, before any uniqueness suffix. */
export function baseKey(csl: CslItem): string {
  const year = cslYear(csl);
  return authorKey(csl) + titleWords(csl) + (year === null ? "" : String(year));
}

/** The fallback shape, for an item with no citation row to read. */
export function baseKeyFromFields(
  author: string, title: string | null, year: number | null,
): string {
  return processAuthorName(author)
    + (title !== null && title !== "" ? titleWordsFrom(title) : "")
    + (year === null ? "" : String(year));
}

export class CiteKeyStore {
  constructor(private readonly db: Database) {}

  /**
   * Give an item a cite key, unless it already has one.
   *
   * Returns the key it settled on, or null when there was not enough metadata
   * to form one — an untitled item with no author has nothing to name it after.
   */
  assign(itemId: string, at: string): string | null {
    const item = this.db.query<
      { title: string; author: string; cite_key: string | null }, [string]
    >("SELECT title, author, cite_key FROM items WHERE id = ?").get(itemId);
    if (item === null) return null;
    if (item.cite_key !== null && item.cite_key !== "") return item.cite_key;

    const key = this.propose(itemId);
    if (key === null) return null;

    this.db.prepare("UPDATE items SET cite_key = ?, updated_at = ? WHERE id = ?")
      .run(key, at, itemId);
    return key;
  }

  /**
   * The key this item's current metadata would produce, without writing it.
   *
   * The metadata panel offers this as a proposal so a rename can be confirmed
   * before it happens.
   */
  propose(itemId: string): string | null {
    const item = this.db.query<{ title: string; author: string }, [string]>(
      "SELECT title, author FROM items WHERE id = ?").get(itemId);
    if (item === null) return null;

    const citation = this.db.query<{ csl_json: string; year: number | null }, [string]>(
      "SELECT csl_json, year FROM citations WHERE item_id = ?").get(itemId);

    let base = "";
    if (citation !== null) {
      // Prefer the full CSL; fall back to the item's own fields if it won't parse.
      try {
        base = baseKey(JSON.parse(citation.csl_json) as CslItem);
      } catch {
        base = "";
      }
    }
    if (base === "") {
      base = baseKeyFromFields(item.author, item.title, citation?.year ?? null);
    }
    if (base === "") return null;

    return this.unique(base, itemId);
  }

  /**
   * Save a key the user typed. Throws on a clash rather than silently
   * suffixing: they chose this exact key, so picking a different one for them
   * would be answering a question they did not ask.
   */
  save(key: string, itemId: string, at: string): void {
    const taken = this.db.query<{ n: number }, [string, string]>(
      "SELECT count(*) AS n FROM items WHERE cite_key = ? AND id != ?",
    ).get(key, itemId)!.n;
    if (taken > 0) throw new Error(`cite key "${key}" is already used`);

    this.db.prepare("UPDATE items SET cite_key = ?, updated_at = ? WHERE id = ?")
      .run(key, at, itemId);
  }

  /**
   * Append a, b, c… until the key is free. The item itself is excluded, so
   * re-deriving an item's own key is not treated as a clash.
   */
  private unique(base: string, itemId: string): string {
    for (let suffix = 0; suffix < 26; suffix++) {
      const candidate = suffix === 0 ? base : base + String.fromCharCode(97 + suffix - 1);
      const taken = this.db.query<{ n: number }, [string, string]>(
        "SELECT count(*) AS n FROM items WHERE cite_key = ? AND id != ?",
      ).get(candidate, itemId)!.n;
      if (taken === 0) return candidate;
    }
    return base + "z";
  }
}
