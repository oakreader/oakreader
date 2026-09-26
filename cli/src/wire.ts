/**
 * The JSON shapes `--json` has always emitted.
 *
 * Column names, not the camelCase used inside this program — the Swift CLI
 * decoded straight from the database and encoded what it got, so `cite_key`
 * and `file_name` are what anything parsing this output already expects.
 * Search results are the exception: they were assembled in code rather than
 * decoded, so they came out camelCase. Both are preserved verbatim, because a
 * rewrite that quietly renames keys breaks every script built on the old one.
 */
import type {
  Attachment, Collection, Item, Note, PropertyOption, SearchResult, WordLookup,
} from "./queries.ts";

/**
 * Drop the keys whose value is absent.
 *
 * Swift's JSONEncoder omits a nil struct field rather than writing null, so
 * that is what consumers of this output have been parsing. Dictionaries were
 * the exception — there nil encoded as an explicit null — which is why this is
 * applied per shape instead of to the whole envelope.
 */
function compact<T extends Record<string, unknown>>(value: T): Partial<T> {
  return Object.fromEntries(
    Object.entries(value).filter(([, v]) => v !== null && v !== undefined)) as Partial<T>;
}

export function itemRaw(i: Item) {
  return {
    id: i.id, title: i.title, author: i.author, cite_key: i.citeKey,
    storage_key: i.storageKey, created_at: i.createdAt,
    updated_at: i.updatedAt, last_opened_at: i.lastOpenedAt,
  };
}

export function attachmentRaw(a: Attachment) {
  return {
    id: a.id, item_id: a.itemId, file_name: a.fileName,
    content_type: a.contentType, source_url: a.sourceURL,
    file_size: a.fileSize, page_count: a.pageCount,
    is_primary: a.isPrimary, storage_key: a.storageKey,
  };
}

export function itemResult(entry: { item: Item; attachments: Attachment[] }) {
  return { item: item(entry.item), attachments: entry.attachments.map(attachment) };
}

export function collectionRaw(c: Collection) {
  return {
    id: c.id, name: c.name, icon: c.icon, sort_order: c.sortOrder,
    parent_id: c.parentId, is_smart: c.isSmart, is_system: c.isSystem,
    created_at: c.createdAt,
  };
}

export function optionRaw(o: PropertyOption) {
  return {
    id: o.id, property_id: o.propertyId, name: o.name,
    color_hex: o.colorHex, position: o.position,
  };
}

export function wordLookupRaw(l: WordLookup) {
  return {
    id: l.id, word: l.word, sentence: l.sentence, explanation: l.explanation,
    item_title: l.itemTitle, created_at: l.createdAt,
  };
}

export function noteRaw(n: Note) {
  return {
    id: n.id, item_id: n.itemId, item_title: n.itemTitle,
    position_kind: n.positionKind, text: n.text, comment: n.comment,
    created_at: n.createdAt,
  };
}

export const item = (i: Item) => compact(itemRaw(i));
export const attachment = (a: Attachment) => compact(attachmentRaw(a));
export const collection = (c: Collection) => compact(collectionRaw(c));
export const option = (o: PropertyOption) => compact(optionRaw(o));
export const wordLookup = (l: WordLookup) => compact(wordLookupRaw(l));
export const note = (n: Note) => compact(noteRaw(n));
export const searchResult = (r: SearchResult) => compact({ ...r });
