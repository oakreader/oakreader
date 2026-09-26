import { z } from "zod";

/**
 * Hand-written wire types shared by both directions.
 *
 * The command and event surface is generated from protocol/schema.ts into
 * protocol.generated.ts; these stay hand-written because their Swift and TS
 * representations are genuinely different shapes.
 *
 * Protocol v2: JSONL over stdio, LF-delimited (never split on U+2028/U+2029).
 * The Swift mirror lives in app/Services/Backend/BackendProtocol.swift —
 * keep the two in sync.
 *
 * v2 moves provider/credential resolution into the backend: requests carry an
 * OakReader providerId + model id; keys, OAuth tokens, endpoint overrides and
 * the model catalog live here. The agentic `chat` loop also runs here, calling
 * back into the client for tool execution (`tool_exec` → `tool_result`).
 */

// ---------------------------------------------------------------------------
// Wire messages (Swift Turn history → backend)

export const WirePart = z.discriminatedUnion("type", [
  z.object({ type: z.literal("text"), text: z.string() }),
  z.object({ type: z.literal("image"), data: z.string(), mimeType: z.string() }),
]);

export const WireToolCall = z.object({
  id: z.string(),
  name: z.string(),
  args: z.record(z.string(), z.any()).default({}),
});

export const WireMessage = z.discriminatedUnion("role", [
  z.object({ role: z.literal("user"), parts: z.array(WirePart).min(1) }),
  z.object({
    role: z.literal("assistant"),
    text: z.string().default(""),
    thinking: z.string().optional(),
    toolCalls: z.array(WireToolCall).default([]),
  }),
  z.object({
    role: z.literal("toolResult"),
    callId: z.string(),
    name: z.string(),
    content: z.string(),
    isError: z.boolean().default(false),
  }),
]);
export type WireMessage = z.infer<typeof WireMessage>;

export const WireToolDef = z.object({
  name: z.string(),
  description: z.string().default(""),
  inputSchema: z.record(z.string(), z.any()),
});

export interface ProviderSummary {
  id: string; // OakReader provider id
  name: string;
  models: {
    id: string;
    name: string;
    reasoning: boolean;
    contextWindow: number;
    maxTokens: number;
    vision: boolean;
  }[];
  defaultModel?: string;
  auth: {
    kind: "api-key" | "oauth" | "none";
    oauthAvailable: boolean;
    configured: boolean;
    source?: string;
  };
  isLocal: boolean;
  baseUrlOverride?: string;
  localUrl?: string;
}

/** One tool call inside an `assistant` event. */
export interface EventToolCall {
  id: string;
  name: string;
  args: Record<string, unknown>;
}

/** One selectable option inside an `oauth_prompt` event. */
export interface PromptOption {
  id: string;
  label: string;
}

/**
 * A saved word lookup, as it crosses the protocol.
 *
 * A zod schema rather than a bare type because this one travels BOTH ways --
 * inbound on `catalog/wordLookups/save`, outbound on `.../list` -- and
 * anything we receive gets validated.
 *
 * Dates stay ISO 8601 strings: formatting is the shell's business, storage is
 * ours, and the rows already hold them in that form.
 */
export const WordLookup = z.object({
  id: z.string(),
  /** Null once the document is deleted: the column is ON DELETE SET NULL. */
  itemId: z.string().nullable(),
  /** Denormalised, so a global list needs no join. */
  itemTitle: z.string(),
  word: z.string(),
  sentence: z.string(),
  explanation: z.string(),
  createdAt: z.string(),
});
export type WordLookup = z.infer<typeof WordLookup>;

/**
 * An annotation on the wire. Two-way, so a zod schema.
 *
 * `sortIndex` is opaque here on purpose: the shell computes it from PDF
 * geometry (`PPPPP|YYYYYY|XXXXXX`) and the core only orders by the string.
 * Page layout is PDFKit's business, not the catalog's.
 */
export const Annotation = z.object({
  id: z.string(),
  itemId: z.string(),
  attachmentId: z.string(),
  key: z.string(),
  type: z.string(),
  authorName: z.string().nullable(),
  text: z.string().nullable(),
  comment: z.string().nullable(),
  color: z.string(),
  pageLabel: z.string().nullable(),
  sortIndex: z.string(),
  positionKind: z.string(),
  positionJson: z.string(),
  styleJson: z.string().nullable(),
  source: z.string(),
  sourceKey: z.string().nullable(),
  createdAt: z.string(),
  updatedAt: z.string(),
  /** Tombstone marker; null while live. */
  deletedAt: z.string().nullable(),
});
export type Annotation = z.infer<typeof Annotation>;

/** A chat session's metadata. The transcript itself is a JSONL file the shell owns. */
export const Conversation = z.object({
  id: z.string(),
  /** Null for library-wide chats not about one document. */
  itemId: z.string().nullable(),
  title: z.string(),
  messageCount: z.number().int(),
  createdAt: z.string(),
  updatedAt: z.string(),
});
export type Conversation = z.infer<typeof Conversation>;

/**
 * A collection on the wire.
 *
 * `filterRules` stays an opaque string: the rule language belongs to whoever
 * evaluates it, and a half-modelled schema would only let the two sides
 * disagree about what a rule means.
 */
export const Collection = z.object({
  id: z.string(),
  name: z.string(),
  icon: z.string(),
  sortOrder: z.number().int(),
  /** Null at the top level. */
  parentId: z.string().nullable(),
  isSmart: z.boolean(),
  isSystem: z.boolean(),
  filterRules: z.string().nullable(),
  source: z.string().nullable(),
  sourceKey: z.string().nullable(),
  createdAt: z.string(),
  updatedAt: z.string(),
});
export type Collection = z.infer<typeof Collection>;

/** One file attached to an item. */
export const Attachment = z.object({
  id: z.string(),
  itemId: z.string(),
  storageKey: z.string(),
  fileName: z.string(),
  contentType: z.string(),
  linkMode: z.string(),
  sourceUrl: z.string().nullable(),
  fileSize: z.number().int(),
  pageCount: z.number().int(),
  isPrimary: z.boolean(),
});
export type Attachment = z.infer<typeof Attachment>;

/** A tag or status value on an item, joined with its property definition. */
export const PropertyValue = z.object({
  id: z.string(),
  propertyId: z.string(),
  propertyName: z.string(),
  propertyType: z.string(),
  optionId: z.string().nullable(),
  optionName: z.string().nullable(),
  optionColorHex: z.string().nullable(),
  textValue: z.string().nullable(),
});
export type PropertyValue = z.infer<typeof PropertyValue>;

/**
 * A library item with everything hanging off it.
 *
 * Covers are absent by design; see catalog/items.ts. `citationJson` is CSL
 * JSON carried opaquely, like a collection's filter rules.
 */
export const Item = z.object({
  id: z.string(),
  storageKey: z.string(),
  title: z.string(),
  author: z.string(),
  lastOpenedAt: z.string().nullable(),
  lastPosition: z.number().nullable(),
  citeKey: z.string().nullable(),
  source: z.string().nullable(),
  sourceKey: z.string().nullable(),
  extra: z.string().nullable(),
  processingStatus: z.string(),
  /** Tombstone while in the trash. */
  deletedAt: z.string().nullable(),
  createdAt: z.string(),
  updatedAt: z.string(),
  attachments: z.array(Attachment),
  collectionIds: z.array(z.string()),
  citationJson: z.string().nullable(),
  propertyValues: z.array(PropertyValue),
});
export type Item = z.infer<typeof Item>;
