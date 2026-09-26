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
  /** Null for library-wide chats that are not about one document. */
  itemId: string | null;
  title: string;
  messageCount: number;
  createdAt: string;
  updatedAt: string;
}

interface Row {
  id: string;
  item_id: string | null;
  title: string;
  message_count: number;
  created_at: string;
  updated_at: string;
}

const SELECT = `SELECT id, item_id, title, message_count, created_at, updated_at FROM conversations`;

function toDomain(r: Row): Conversation {
  return {
    id: r.id,
    itemId: r.item_id,
    title: r.title,
    messageCount: r.message_count,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  };
}

export class ConversationStore {
  constructor(private readonly db: Database, private readonly userId: string) {}

  /**
   * Sessions for one document, or the library-wide ones when `itemId` is null.
   *
   * Two queries rather than one with a parameter, because `item_id = NULL`
   * never matches in SQL — the library case genuinely needs `IS NULL`.
   */
  list(itemId: string | null): Conversation[] {
    const sql = itemId === null
      ? `${SELECT} WHERE item_id IS NULL ORDER BY updated_at DESC`
      : `${SELECT} WHERE item_id = ? ORDER BY updated_at DESC`;
    const query = this.db.query<Row, any[]>(sql);
    return (itemId === null ? query.all() : query.all(itemId)).map(toDomain);
  }

  create(conversation: Conversation): void {
    this.db.prepare(
      `INSERT INTO conversations
         (id, user_id, item_id, title, message_count, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      conversation.id, this.userId, conversation.itemId, conversation.title,
      conversation.messageCount, conversation.createdAt, conversation.updatedAt,
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
