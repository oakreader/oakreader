/**
 * The sidecar protocol: JSON-RPC 2.0 over newline-delimited stdio.
 *
 * Both sides are generated from this file. The wire format follows the
 * JSON-RPC 2.0 spec, which is also what MCP and Codex's app-server use over
 * the same transport -- the shape here (bidirectional calls plus streaming
 * notifications) is exactly what that spec exists for.
 *
 * Run `pnpm protocol:generate` after editing; `pnpm protocol:check` in CI
 * fails if the committed output is stale.
 */

export const PROTOCOL_VERSION = 4;

export type FieldType =
  | { k: "string" }
  | { k: "int" }
  | { k: "bool" }
  | { k: "enum"; values: string[] }
  | { k: "json" }
  | { k: "array"; of: FieldType; min?: number }
  | { k: "ref"; ts: string; swift: string };

export interface Field {
  name: string;
  type: FieldType;
  optional?: boolean;
  nullable?: boolean;
  default?: string;
  doc?: string;
}

export interface Method {
  /** Wire method name. Namespaced with "/" like MCP and LSP. */
  name: string;
  /** PascalCase base for generated type names. */
  type: string;
  /** A request expects a result or an error; a notification expects nothing. */
  kind: "request" | "notification";
  /** Who initiates. Reverse calls are ordinary requests in the other direction. */
  from: "client" | "server";
  doc?: string;
  params: Field[];
  /** Requests only. Empty means "no payload, success is the absence of error". */
  result?: Field[];
}

const str: FieldType = { k: "string" };
const int: FieldType = { k: "int" };
const bool: FieldType = { k: "bool" };
const json: FieldType = { k: "json" };
const wireMessage: FieldType = { k: "ref", ts: "WireMessage", swift: "WireMessage" };
const wireToolDef: FieldType = { k: "ref", ts: "WireToolDef", swift: "WireToolDef" };

/**
 * Progress notifications carry the id of the request they belong to. JSON-RPC
 * notifications have no `id` of their own by design, so the association is an
 * explicit param -- the same thing MCP does with a progress token.
 */
const token: Field = { name: "token", type: str, doc: "Id of the request this belongs to." };

export const METHODS: Method[] = [
  // --- client -> server requests -----------------------------------------
  {
    name: "ping", type: "Ping", kind: "request", from: "client",
    doc: "Handshake. The shell refuses to proceed on a protocol mismatch.",
    params: [],
    result: [
      { name: "protocol", type: int },
      { name: "backend", type: str },
    ],
  },
  {
    name: "complete", type: "Complete", kind: "request", from: "client",
    doc: "One-shot completion. Streams chat/delta, resolves when finished.",
    params: [
      { name: "providerId", type: str },
      { name: "model", type: str },
      { name: "system", type: str, optional: true },
      { name: "messages", type: { k: "array", of: wireMessage, min: 1 } },
      { name: "maxTokens", type: int, default: "4096" },
      { name: "apiKey", type: str, optional: true,
        doc: "Explicit key for Test Connection, before anything is saved." },
      { name: "baseUrl", type: str, optional: true },
    ],
    result: [{ name: "stopReason", type: str }],
  },
  {
    name: "chat", type: "Chat", kind: "request", from: "client",
    doc: "The agentic loop. Streams chat/* notifications and calls tool/execute back.",
    params: [
      { name: "providerId", type: str },
      { name: "model", type: str },
      { name: "system", type: str, optional: true },
      { name: "messages", type: { k: "array", of: wireMessage, min: 1 } },
      { name: "tools", type: { k: "array", of: wireToolDef }, default: "[]" },
      { name: "maxTokens", type: int, default: "8192" },
      { name: "reasoning",
        type: { k: "enum", values: ["minimal", "low", "medium", "high", "xhigh", "max"] },
        optional: true },
      { name: "maxIterations", type: int, default: "10" },
    ],
    result: [{ name: "stopReason", type: str }],
  },
  {
    name: "providers/list", type: "ProvidersList", kind: "request", from: "client",
    params: [],
    result: [{ name: "providers",
      type: { k: "array", of: { k: "ref", ts: "ProviderSummary", swift: "BackendProviderSummary" } } }],
  },
  {
    name: "credentials/set", type: "CredentialsSet", kind: "request", from: "client",
    params: [{ name: "providerId", type: str }, { name: "key", type: str }],
    result: [],
  },
  {
    name: "credentials/get", type: "CredentialsGet", kind: "request", from: "client",
    params: [{ name: "providerId", type: str }],
    result: [{ name: "apiKey", type: str, optional: true, nullable: true,
      doc: "null when the provider has no key stored." }],
  },
  {
    name: "credentials/delete", type: "CredentialsDelete", kind: "request", from: "client",
    params: [{ name: "providerId", type: str }],
    result: [],
  },
  {
    name: "oauth/login", type: "OAuthLogin", kind: "request", from: "client",
    doc: "Streams oauth/notify and calls oauth/prompt back for user input.",
    params: [{ name: "providerId", type: str }],
    result: [],
  },
  {
    name: "config/setBaseUrl", type: "ConfigSetBaseUrl", kind: "request", from: "client",
    params: [
      { name: "providerId", type: str },
      { name: "baseUrl", type: str, optional: true, doc: "Absent clears the override." },
    ],
    result: [],
  },
  {
    name: "config/setLocalUrl", type: "ConfigSetLocalUrl", kind: "request", from: "client",
    params: [
      { name: "providerId", type: { k: "enum", values: ["ollama", "lmstudio"] } },
      { name: "baseUrl", type: str },
    ],
    result: [],
  },
  {
    name: "models/refresh", type: "ModelsRefresh", kind: "request", from: "client",
    params: [{ name: "providerId", type: str, optional: true }],
    result: [{ name: "message", type: str, optional: true }],
  },

  // --- catalog (phase 1) --------------------------------------------------
  {
    name: "catalog/wordLookups/list", type: "WordLookupsList", kind: "request", from: "client",
    doc: "One document's lookups, or every one when itemId is absent. Newest first.",
    params: [{ name: "itemId", type: str, optional: true }],
    result: [{ name: "lookups",
      type: { k: "array", of: { k: "ref", ts: "WordLookup", swift: "CatalogWordLookup" } } }],
  },
  {
    name: "catalog/wordLookups/save", type: "WordLookupsSave", kind: "request", from: "client",
    doc: "Insert, replacing any prior lookup of the same word in the same document.",
    params: [{ name: "lookup", type: { k: "ref", ts: "WordLookup", swift: "CatalogWordLookup" } }],
    result: [],
  },
  {
    name: "catalog/wordLookups/delete", type: "WordLookupsDelete", kind: "request", from: "client",
    params: [{ name: "id", type: str }],
    result: [],
  },
  {
    name: "catalog/wordLookups/clear", type: "WordLookupsClear", kind: "request", from: "client",
    doc: "Clear one document's history, or all of it when itemId is absent.",
    params: [{ name: "itemId", type: str, optional: true }],
    result: [],
  },

  // --- client -> server notifications ------------------------------------
  {
    name: "$/cancelRequest", type: "CancelRequest", kind: "notification", from: "client",
    doc: "LSP's spelling. The peer fails the named request and anything it spawned.",
    params: [{ name: "id", type: str }],
  },

  // --- server -> client requests (reverse calls) -------------------------
  {
    name: "tool/execute", type: "ToolExecute", kind: "request", from: "server",
    doc: "The shell runs the tool and answers. Tools read local app state, so they " +
         "cannot run in the sidecar.",
    params: [
      token,
      { name: "name", type: str },
      { name: "args", type: json },
    ],
    result: [
      { name: "content", type: str },
      { name: "isError", type: bool, default: "false" },
    ],
  },
  {
    name: "oauth/prompt", type: "OAuthPrompt", kind: "request", from: "server",
    doc: "Asks the shell for one piece of user input during a login.",
    params: [
      token,
      { name: "promptType", type: { k: "enum", values: ["text", "secret", "select", "manual_code"] } },
      { name: "message", type: str },
      { name: "placeholder", type: str, optional: true },
      { name: "options",
        type: { k: "array", of: { k: "ref", ts: "PromptOption", swift: "BackendPromptOption" } },
        optional: true },
    ],
    result: [{ name: "value", type: str, optional: true, doc: "Absent means cancelled." }],
  },

  // --- server -> client notifications ------------------------------------
  {
    name: "chat/delta", type: "ChatDelta", kind: "notification", from: "server",
    params: [token, { name: "text", type: str }],
  },
  {
    name: "chat/thinking", type: "ChatThinking", kind: "notification", from: "server",
    params: [token, { name: "text", type: str }],
  },
  {
    name: "chat/assistant", type: "ChatAssistant", kind: "notification", from: "server",
    doc: "Authoritative snapshot of one iteration's assistant message.",
    params: [
      token,
      { name: "text", type: str },
      { name: "thinking", type: str, optional: true },
      { name: "toolCalls",
        type: { k: "array", of: { k: "ref", ts: "EventToolCall", swift: "BackendToolCall" } } },
    ],
  },
  {
    name: "oauth/notify", type: "OAuthNotify", kind: "notification", from: "server",
    params: [
      token,
      { name: "kind", type: { k: "enum", values: ["info", "auth_url", "device_code", "progress"] } },
      { name: "message", type: str, optional: true },
      { name: "url", type: str, optional: true },
      { name: "userCode", type: str, optional: true },
      { name: "verificationUri", type: str, optional: true },
    ],
  },
];

/**
 * Error codes. -32768..-32000 is reserved by the spec; everything below that
 * is ours. The point of these is that the shell can branch -- "re-authenticate"
 * is a different affordance from "retry in 30s", and the old protocol's single
 * `{type:"error", message}` string could not tell them apart.
 */
export const ERRORS: { name: string; code: number; doc: string }[] = [
  { name: "parseError",         code: -32700, doc: "Malformed JSON (spec)." },
  { name: "invalidRequest",     code: -32600, doc: "Not a valid Request object (spec)." },
  { name: "methodNotFound",     code: -32601, doc: "Unknown method (spec)." },
  { name: "invalidParams",      code: -32602, doc: "Params failed validation (spec)." },
  { name: "internalError",      code: -32603, doc: "Unhandled failure (spec)." },
  { name: "providerAuth",       code: -31001, doc: "Rejected credentials; offer re-authentication." },
  { name: "providerRateLimit",  code: -31002, doc: "Throttled; offer retry, `data.retryAfter` when known." },
  { name: "providerUnavailable", code: -31003, doc: "Unreachable or failing; offer another provider." },
  { name: "cancelled",          code: -31004, doc: "Ended by $/cancelRequest." },
  { name: "toolFailed",         code: -31005, doc: "The shell could not run the tool." },
  { name: "notConfigured",      code: -31006, doc: "No credential or model configured for the provider." },
];
