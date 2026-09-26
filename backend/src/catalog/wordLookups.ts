/**
 * Word-lookup history — the first store to move out of Swift.
 *
 * Chosen first because it is the smallest complete one: five operations, one
 * table, no joins. What it proves is the whole path, not the table —
 * Swift call → JSON-RPC → core → SQLite → typed result — so every store after
 * it is repetition rather than design.
 *
 * Dedupe rule carried over verbatim from WordLookupStore: `dedupe_key` is
 * `"<itemId|global>|<lowercased word>"`, and a save deletes any row with the
 * same key first, so re-looking up a word in the same document replaces its
 * card instead of piling up duplicates.
 */
import type { Database } from "bun:sqlite";

export interface WordLookup {
  id: string;
  /** Nullable, with ON DELETE SET NULL: history outlives the document. */
  itemId: string | null;
  /** Denormalised so the global view shows a source without a join. */
  itemTitle: string;
  word: string;
  sentence: string;
  /** Saved Markdown explanation. */
  explanation: string;
  /** ISO 8601, as stored. Formatting is the shell's business. */
  createdAt: string;
}

interface Row {
  id: string;
  item_id: string | null;
  item_title: string;
  word: string;
  sentence: string;
  explanation: string;
  created_at: string;
}

const SELECT = `SELECT id, item_id, item_title, word, sentence, explanation, created_at FROM word_lookups`;

function toDomain(r: Row): WordLookup {
  return {
    id: r.id,
    itemId: r.item_id,
    itemTitle: r.item_title,
    word: r.word,
    sentence: r.sentence,
    explanation: r.explanation,
    createdAt: r.created_at,
  };
}

export function dedupeKey(itemId: string | null | undefined, word: string): string {
  return `${itemId ?? "global"}|${word.toLowerCase()}`;
}

export class WordLookupStore {
  constructor(private readonly db: Database, private readonly userId: string) {}

  /** One document's lookups, newest first. */
  list(itemId: string): WordLookup[] {
    return this.db
      .query<Row, [string]>(`${SELECT} WHERE item_id = ? ORDER BY created_at DESC`)
      .all(itemId).map(toDomain);
  }

  /** Every lookup, newest first. */
  listAll(): WordLookup[] {
    return this.db.query<Row, []>(`${SELECT} ORDER BY created_at DESC`).all().map(toDomain);
  }

  /** Insert, replacing any prior lookup of the same word in the same document. */
  save(lookup: WordLookup): void {
    const key = dedupeKey(lookup.itemId, lookup.word);
    this.db.transaction(() => {
      this.db.prepare("DELETE FROM word_lookups WHERE dedupe_key = ?").run(key);
      this.db.prepare(
        `INSERT INTO word_lookups
           (id, user_id, item_id, item_title, word, sentence, explanation, dedupe_key, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).run(
        lookup.id, this.userId, lookup.itemId, lookup.itemTitle,
        lookup.word, lookup.sentence, lookup.explanation, key, lookup.createdAt,
      );
    })();
  }

  delete(id: string): void {
    this.db.prepare("DELETE FROM word_lookups WHERE id = ?").run(id);
  }

  /** Clear one document's history, or all of it when `itemId` is null. */
  clear(itemId: string | null): void {
    if (itemId === null) this.db.prepare("DELETE FROM word_lookups").run();
    else this.db.prepare("DELETE FROM word_lookups WHERE item_id = ?").run(itemId);
  }
}
