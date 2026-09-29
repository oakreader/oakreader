/**
 * Chat-session metadata.
 *
 * Only the metadata: the messages themselves are JSONL files the shell writes
 * and reads, and this table is the index over them. That split predates the
 * migration and is worth keeping — a conversation's transcript is an append-only
 * log, which a row in a relational table is a poor fit for.
 *
 * So the snippet shown in the history list stays shell-side too. It comes from
 * reading a bounded prefix of the JSONL file, which belongs with whoever owns
 * those files, not with whoever owns the catalog.
 */
import type { Database } from "bun:sqlite";

export interface Conversation {
  id: string;
  /** Null for chats that are not about one document. */
  itemId: string | null;
  /** The collection a library chat is scoped to; null for the whole library. */
  collectionId: string | null;
  title: string;
  messageCount: number;
  createdAt: string;
  updatedAt: string;
}

/**
 * What a listing is about.
 *
 * Three cases, not two booleans: a chat belongs to a document, or to a
 * collection, or to the library at large. They are mutually exclusive, and
 * saying so here keeps `list` from having to decide what a request for both
 * at once would even mean.
 */
export type ConversationScope =
  | { kind: "item"; itemId: string }
  | { kind: "collection"; collectionId: string }
  | { kind: "library" };

interface Row {
  id: string;
  item_id: string | null;
  collection_id: string | null;
  title: string;
  message_count: number;
  created_at: string;
  updated_at: string;
}

const SELECT =
  `SELECT id, item_id, collection_id, title, message_count, created_at, updated_at
   FROM conversations`;

function toDomain(r: Row): Conversation {
  return {
    id: r.id,
    itemId: r.item_id,
    collectionId: r.collection_id,
    title: r.title,
    messageCount: r.message_count,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  };
}

export class ConversationStore {
  constructor(private readonly db: Database, private readonly userId: string) {}

  /**
   * Sessions in one scope, most recently updated first.
   *
   * The unscoped case needs its own SQL rather than a bound null, because
   * `item_id = NULL` never matches in SQL — it genuinely needs `IS NULL`. The
   * library scope also excludes collection chats: "not about a document" and
   * "not about anything in particular" are different lists, and merging them
   * would show every collection's chat in the library's history.
   */
  list(scope: ConversationScope): Conversation[] {
    switch (scope.kind) {
      case "item":
        return this.db.query<Row, [string]>(
          `${SELECT} WHERE item_id = ? ORDER BY updated_at DESC`,
        ).all(scope.itemId).map(toDomain);
      case "collection":
        return this.db.query<Row, [string]>(
          `${SELECT} WHERE collection_id = ? ORDER BY updated_at DESC`,
        ).all(scope.collectionId).map(toDomain);
      case "library":
        return this.db.query<Row, []>(
          `${SELECT} WHERE item_id IS NULL AND collection_id IS NULL ORDER BY updated_at DESC`,
        ).all().map(toDomain);
    }
  }

  create(conversation: Conversation): void {
    this.db.prepare(
      `INSERT INTO conversations
         (id, user_id, item_id, collection_id, title, message_count, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      conversation.id, this.userId, conversation.itemId, conversation.collectionId,
      conversation.title, conversation.messageCount,
      conversation.createdAt, conversation.updatedAt,
    );
  }

  /** Title and message count, as the session grows. */
  update(id: string, title: string, messageCount: number, at: string): void {
    this.db.prepare(
      "UPDATE conversations SET title = ?, message_count = ?, updated_at = ? WHERE id = ?",
    ).run(title, messageCount, at, id);
  }

  /**
   * Remove the row. The JSONL transcript is the shell's to delete — this table
   * only indexes it.
   */
  delete(id: string): void {
    this.db.prepare("DELETE FROM conversations WHERE id = ?").run(id);
  }
}
