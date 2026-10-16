import { z } from "zod";
import type { Message, UserMessage } from "@earendil-works/pi-ai";
export type { FileEntry } from "@earendil-works/pi-coding-agent";

/**
 * Hand-written wire types shared by both directions.
 *
 * The command and event surface is generated from protocol/schema.ts into
 * protocol.generated.ts; these stay hand-written because their Swift and TS
 * representations are genuinely different shapes.
 *
 * Protocol v2: JSONL over stdio, LF-delimited (never split on U+2028/U+2029).
 * The Swift mirror lives in app/Services/Backend/BackendProtocol.swift —
 * keep the two in sync. Chat history is pi's own session format, so it has
 * no Swift mirror: the shell carries messages and entries as raw JSON.
 *
 * v2 moves provider/credential resolution into the backend: requests carry an
 * OakReader providerId + model id; keys, OAuth tokens, endpoint overrides and
 * the model catalog live here. The agentic `chat` loop also runs here, calling
 * back into the client for tool execution (`tool_exec` → `tool_result`).
 *
 * Every nullable field on a type the shell SENDS is `.nullable().default(null)`.
 * Swift's synthesized Encodable omits a nil key rather than writing null, and a
 * bare `.nullable()` rejects the missing key — which silently dropped every new
 * item, library chat and loose word lookup.
 */

// ---------------------------------------------------------------------------
// Transcript messages (shell <-> backend)

/**
 * A pi `Message` the shell sends: the user turn of a chat, or the messages of
 * a one-shot completion.
 *
 * Only the role and the fields pi itself requires are checked. Everything
 * else passes through untouched, including any field a later pi adds. Chat
 * history never crosses this way: the core reads it from the session file.
 * System messages never cross: the core writes them into the session.
 */
const Block = z.looseObject({ type: z.string() });
const UserShape = z.looseObject({
  role: z.literal("user"),
  content: z.union([z.string(), z.array(Block)]),
  timestamp: z.number(),
});
export const PiUserMessage = UserShape;
export type PiUserMessage = UserMessage;
export const PiMessage = z.discriminatedUnion("role", [
  UserShape,
  z.looseObject({
    role: z.literal("assistant"),
    content: z.array(Block),
    api: z.string(),
    provider: z.string(),
    model: z.string(),
    usage: z.looseObject({}),
    stopReason: z.string(),
    timestamp: z.number(),
  }),
  z.looseObject({
    role: z.literal("toolResult"),
    toolCallId: z.string(),
    toolName: z.string(),
    content: z.array(Block),
    isError: z.boolean(),
    timestamp: z.number(),
  }),
]);
/** The validated shape is pi's own; zod only guards the border. */
export type PiMessage = Message;

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
  /** Defined by the user's models.json rather than shipped with the build. */
  custom: boolean;
  baseUrlOverride?: string;
  localUrl?: string;
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
  itemId: z.string().nullable().default(null),
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
  authorName: z.string().nullable().default(null),
  text: z.string().nullable().default(null),
  comment: z.string().nullable().default(null),
  color: z.string(),
  pageLabel: z.string().nullable().default(null),
  sortIndex: z.string(),
  positionKind: z.string(),
  positionJson: z.string(),
  styleJson: z.string().nullable().default(null),
  source: z.string(),
  sourceKey: z.string().nullable().default(null),
  createdAt: z.string(),
  updatedAt: z.string(),
  /** Tombstone marker; null while live. */
  deletedAt: z.string().nullable().default(null),
});
export type Annotation = z.infer<typeof Annotation>;

/** A chat session's metadata. The transcript itself is a JSONL file the shell owns. */
export const Conversation = z.object({
  id: z.string(),
  /** Null for chats not about one document. */
  itemId: z.string().nullable().default(null),
  /** The collection a library chat is scoped to; null for the whole library. */
  collectionId: z.string().nullable().default(null),
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
  parentId: z.string().nullable().default(null),
  isSmart: z.boolean(),
  isSystem: z.boolean(),
  filterRules: z.string().nullable().default(null),
  source: z.string().nullable().default(null),
  sourceKey: z.string().nullable().default(null),
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
  sourceUrl: z.string().nullable().default(null),
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
  optionId: z.string().nullable().default(null),
  optionName: z.string().nullable().default(null),
  optionColorHex: z.string().nullable().default(null),
  textValue: z.string().nullable().default(null),
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
  lastOpenedAt: z.string().nullable().default(null),
  lastPosition: z.number().nullable().default(null),
  citeKey: z.string().nullable().default(null),
  source: z.string().nullable().default(null),
  sourceKey: z.string().nullable().default(null),
  extra: z.string().nullable().default(null),
  processingStatus: z.string(),
  /** Tombstone while in the trash. */
  deletedAt: z.string().nullable().default(null),
  createdAt: z.string(),
  updatedAt: z.string(),
  attachments: z.array(Attachment),
  collectionIds: z.array(z.string()),
  citationJson: z.string().nullable().default(null),
  propertyValues: z.array(PropertyValue),
});
export type Item = z.infer<typeof Item>;

/** One allowed value of a select-type property. */
export const PropertyOption = z.object({
  id: z.string(),
  propertyId: z.string(),
  name: z.string(),
  colorHex: z.string(),
  position: z.number().int(),
});
export type PropertyOption = z.infer<typeof PropertyOption>;

/** A tag or status column. `type` is "select" or "text". */
export const Property = z.object({
  id: z.string(),
  name: z.string(),
  type: z.string(),
  icon: z.string(),
  position: z.number().int(),
  /** Built in; the UI refuses to delete these. */
  isSystem: z.boolean(),
  options: z.array(PropertyOption),
});
export type Property = z.infer<typeof Property>;

/** A required binary, and where it was found. */
export const SkillBin = z.object({
  name: z.string(),
  description: z.string().optional(),
  /** Absolute path, or null when the tool is not installed. */
  path: z.string().nullable(),
  install: z.record(z.string(), z.string()).optional(),
});
export type SkillBin = z.infer<typeof SkillBin>;

/** An environment variable a skill needs, held in the shell's keychain. */
export const SkillEnv = z.object({
  name: z.string(),
  description: z.string().optional(),
  required: z.boolean(),
});
export type SkillEnv = z.infer<typeof SkillEnv>;

/** A skill as the settings UI needs to show it. */
export const Skill = z.object({
  name: z.string(),
  /** Display name from the frontmatter's `title`, falling back to `name`. */
  title: z.string(),
  description: z.string(),
  /** How much of the document to attach while this skill is active. */
  contextMode: z.string(),
  /** Sort position in the chat picker; 99 when unstated. */
  order: z.number().int(),
  filePath: z.string(),
  baseDir: z.string(),
  /** "bundled" or "user". */
  source: z.string(),
  enabled: z.boolean(),
  /** Invoked only on request; kept out of the model's listing. */
  disableModelInvocation: z.boolean(),
  version: z.string().nullable(),
  /** "symbol" (an SF Symbol) or "url". */
  iconType: z.string().nullable(),
  iconValue: z.string().nullable(),
  authorName: z.string().nullable(),
  bins: z.array(SkillBin),
  envs: z.array(SkillEnv),
});
export type Skill = z.infer<typeof Skill>;

export const SkillAdvisory = z.object({ path: z.string(), message: z.string() });
export type SkillAdvisory = z.infer<typeof SkillAdvisory>;

/** A tool the core implements, as the shell must declare it to the model. */
export const ToolDefinition = z.object({
  name: z.string(),
  description: z.string(),
  /** "readOnly", "write" or "dangerous" — what the permission level gates on. */
  category: z.string(),
  /** JSON Schema for the tool's arguments, passed through untouched. */
  inputSchema: z.record(z.string(), z.unknown()),
});
export type ToolDefinition = z.infer<typeof ToolDefinition>;
