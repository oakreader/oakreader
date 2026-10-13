// The shell's Encodable drops nil keys instead of writing null. Every type it
// sends must accept that shape, or the write fails before reaching the store.
import { test, expect } from "bun:test";
import { Annotation, Collection, Conversation, Item, WordLookup } from "../src/protocol.base.ts";

/** What Swift's synthesized Encodable emits: keys with a nil value are absent, at any depth. */
function withoutNulls(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(withoutNulls);
  if (value === null || typeof value !== "object") return value;
  return Object.fromEntries(Object.entries(value)
    .filter(([, v]) => v !== null)
    .map(([k, v]) => [k, withoutNulls(v)]));
}

const now = "2026-10-13T00:00:00Z";

const item = {
  id: "i1", storageKey: "K1", title: "t", author: "", lastOpenedAt: null, lastPosition: null,
  citeKey: null, source: null, sourceKey: null, extra: null, processingStatus: "done",
  deletedAt: null, createdAt: now, updatedAt: now, collectionIds: [], citationJson: null,
  attachments: [{
    id: "a1", itemId: "i1", storageKey: "K1", fileName: "f.pdf", contentType: "pdf",
    linkMode: "imported", sourceUrl: null, fileSize: 1, pageCount: 1, isPrimary: true,
  }],
  propertyValues: [{
    id: "v1", propertyId: "p1", propertyName: "Tags", propertyType: "multiSelect",
    optionId: null, optionName: null, optionColorHex: null, textValue: null,
  }],
};

const cases = {
  Item: [Item, item],
  Collection: [Collection, {
    id: "c1", name: "n", icon: "folder", sortOrder: 0, parentId: null, isSmart: false,
    isSystem: false, filterRules: null, source: null, sourceKey: null, createdAt: now, updatedAt: now,
  }],
  Annotation: [Annotation, {
    id: "n1", itemId: "i1", attachmentId: "a1", key: "k", type: "note", authorName: null, text: null, comment: null,
    color: "#fff", pageLabel: null, sortIndex: "0", positionKind: "pdf", positionJson: "{}",
    styleJson: null, source: "oak", sourceKey: null, createdAt: now, updatedAt: now, deletedAt: null,
  }],
  Conversation: [Conversation, {
    id: "v1", itemId: null, collectionId: null, title: "t", messageCount: 0, createdAt: now, updatedAt: now,
  }],
  WordLookup: [WordLookup, {
    id: "w1", itemId: null, itemTitle: "", word: "w", sentence: "s", explanation: "e", createdAt: now,
  }],
} as const;

for (const [name, [schema, full]] of Object.entries(cases)) {
  test(`${name} accepts nil keys omitted and reads them back as null`, () => {
    const parsed = schema.safeParse(withoutNulls(full));
    expect(parsed.error?.issues).toBeUndefined();
    expect(parsed.data).toEqual(full as never);
  });
}
