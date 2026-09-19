/**
 * CJK bigram tokenization — the portable replacement for Swift's
 * `CJKBigramTokenizer` (OakReader/Services/CJKBigramTokenizer.swift).
 *
 * WHY THIS IS NOT A DIRECT PORT
 * -----------------------------
 * The Swift version is a real FTS5 tokenizer: it wraps `unicode61` via GRDB's
 * `FTS5WrapperTokenizer` and re-emits each CJK run as overlapping bigrams, so
 * 机器学习 indexes as 机器 / 器学 / 学习 and a 2-char query matches mid-run.
 * Registering an FTS5 tokenizer requires the SQLite **C API**
 * (`sqlite3_fts5_create_tokenizer`), which neither `node:sqlite` nor
 * better-sqlite3 exposes to JavaScript. Verified: opening the existing
 * search.sqlite from Node reads rows fine (201,707 chunks) but any MATCH fails
 * with `no such tokenizer: cjk_bigram`.
 *
 * So we move the identical expansion into userland and let plain `unicode61`
 * tokenize the result. The emitted token stream is the same, therefore ranking
 * and matching are the same.
 *
 * INVARIANT — apply at BOTH ends.
 * Swift's `accept()` ignores its `FTS5Tokenization` argument, i.e. it behaves
 * identically when indexing and when parsing a query. Userland expansion must
 * therefore run on index text AND on query text, or recall silently breaks.
 * Use `expandForIndex` / `buildMatchQuery` rather than calling `expand` raw.
 *
 * Verified against the real 201,707-chunk corpus: for the 12 most frequent CJK
 * terms (2- and 3-char), FTS results are byte-identical to a `LIKE '%term%'`
 * scan — zero false negatives, zero false positives. See tokenizer.test.mjs.
 */

/** Ranges mirror `CJKBigramTokenizer.isCJK` exactly — keep the two in sync. */
const CJK_RANGES: ReadonlyArray<readonly [number, number]> = [
  [0x4e00, 0x9fff],   // CJK Unified Ideographs
  [0x3400, 0x4dbf],   // CJK Extension A
  [0x20000, 0x2a6df], // CJK Extension B
  [0x2a700, 0x2ebef], // CJK Extensions C–F
  [0xf900, 0xfaff],   // CJK Compatibility Ideographs
  [0x3040, 0x30ff],   // Hiragana + Katakana
  [0xac00, 0xd7af],   // Hangul syllables
];

export function isCJK(codePoint: number): boolean {
  for (const [lo, hi] of CJK_RANGES) if (codePoint >= lo && codePoint <= hi) return true;
  return false;
}

/**
 * Re-emit CJK runs as overlapping bigrams, passing Latin/digits through
 * untouched. A lone CJK character is emitted as itself (matching Swift's
 * `flushCJK` single-character branch).
 */
export function expand(text: string): string {
  const out: string[] = [];
  let latin = "";
  let run: string[] = [];

  const flushLatin = () => { if (latin) { out.push(latin); latin = ""; } };
  const flushCJK = () => {
    if (run.length === 1) out.push(run[0]);
    else for (let j = 0; j < run.length - 1; j++) out.push(run[j] + run[j + 1]);
    run = [];
  };

  for (const ch of text) { // string iteration is by code point, so astral CJK is safe
    if (isCJK(ch.codePointAt(0)!)) { flushLatin(); run.push(ch); }
    else { flushCJK(); latin += ch; }
  }
  flushLatin();
  flushCJK();
  return out.join(" ");
}

/** Text to store in the FTS column. */
export const expandForIndex = (text: string): string => expand(text);

/**
 * Turn a user query into an FTS5 MATCH expression. Each expanded token is
 * quoted (so FTS5 operators inside user text are inert) and AND-ed, which is
 * what makes a 3-char CJK query require both of its bigrams.
 */
export function buildMatchQuery(query: string): string {
  const tokens = expand(query).split(/\s+/).filter(Boolean);
  if (tokens.length === 0) return "";
  return tokens.map((t) => `"${t.replace(/"/g, '""')}"`).join(" AND ");
}
