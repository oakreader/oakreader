/**
 * The sidecar protocol, declared once.
 *
 * Both sides are generated from this file: the backend's zod schemas and TS
 * types, and the Swift shell's Codable structs. Before this existed the two
 * were hand-written mirrors that said "keep the two in sync" in a comment,
 * and they drifted -- a field added on one side and forgotten on the other
 * is a silent wire bug when the field is optional.
 *
 * Run `pnpm protocol:generate` after editing. CI runs `pnpm protocol:check`,
 * which regenerates and fails if the committed output differs.
 *
 * Deliberately NOT generated: WireMessage / WirePart / WireToolCall /
 * WireToolDef and the small payload structs (ToolCall, PromptOption,
 * ProviderSummary). Their two representations are genuinely different --
 * Swift encodes WireMessage through a custom `Encodable` enum, TS validates
 * it with a discriminated union -- so generating them would fight both
 * languages for no drift benefit. The drift surface is the flat command and
 * event surface below, which is what actually grows over time.
 */

export const PROTOCOL_VERSION = 2;

export type FieldType =
  | { k: "string" }
  | { k: "int" }
  | { k: "bool" }
  | { k: "enum"; values: string[] }
  | { k: "json" }                          // opaque object: Record<string, unknown>
  | { k: "array"; of: FieldType; min?: number }
  | { k: "ref"; ts: string; swift: string } // hand-written type on both sides

export interface Field {
  name: string;
  type: FieldType;
  /** Absent from the wire when not set. */
  optional?: boolean;
  /** Present but explicitly null — distinct from absent (get_api_key: no key stored). */
  nullable?: boolean;
  /** zod `.default(...)`; rendered literally. Swift always treats these as optional. */
  default?: string;
  doc?: string;
}

export interface Message {
  /** Wire discriminator, e.g. "set_api_key". */
  type: string;
  /** PascalCase base for generated names, e.g. "SetApiKey" -> SetApiKeyCommand. */
  name: string;
  doc?: string;
  fields: Field[];
}

const str: FieldType = { k: "string" };
const int: FieldType = { k: "int" };
const bool: FieldType = { k: "bool" };
const json: FieldType = { k: "json" };

const wireMessage: FieldType = { k: "ref", ts: "WireMessage", swift: "WireMessage" };
const wireToolDef: FieldType = { k: "ref", ts: "WireToolDef", swift: "WireToolDef" };

/** Commands: shell -> backend. Every one carries `id`. */
export const COMMANDS: Message[] = [
  { type: "ping", name: "Ping", fields: [] },
  { type: "abort", name: "Abort", fields: [] },
  {
    type: "complete", name: "Complete",
    doc: "One-shot completion (no tool loop).",
    fields: [
      { name: "providerId", type: str },
      { name: "model", type: str },
      { name: "system", type: str, optional: true },
      { name: "messages", type: { k: "array", of: wireMessage, min: 1 } },
      { name: "maxTokens", type: int, default: "4096" },
      { name: "apiKey", type: str, optional: true,
        doc: "Explicit key for Test Connection (verify before saving)." },
      { name: "baseUrl", type: str, optional: true },
    ],
  },
  {
    type: "chat", name: "Chat",
    doc: "The agentic loop; calls back with tool_exec.",
    fields: [
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
  },
  {
    type: "tool_result", name: "ToolResult",
    doc: "Answers a tool_exec event; `id` is the chat request id.",
    fields: [
      { name: "callId", type: str },
      { name: "content", type: str },
      { name: "isError", type: bool, default: "false" },
    ],
  },
  { type: "list_providers", name: "ListProviders", fields: [] },
  {
    type: "set_api_key", name: "SetApiKey",
    fields: [{ name: "providerId", type: str }, { name: "key", type: str }],
  },
  { type: "get_api_key", name: "GetApiKey", fields: [{ name: "providerId", type: str }] },
  { type: "delete_credential", name: "DeleteCredential", fields: [{ name: "providerId", type: str }] },
  { type: "oauth_login", name: "OAuthLogin", fields: [{ name: "providerId", type: str }] },
  {
    type: "oauth_prompt_result", name: "OAuthPromptResult",
    doc: "Answers an oauth_prompt; `id` is the oauth_login request id.",
    fields: [
      { name: "promptId", type: str },
      { name: "value", type: str, optional: true, doc: "Absent = cancelled." },
    ],
  },
  {
    type: "set_base_url", name: "SetBaseUrl",
    fields: [
      { name: "providerId", type: str },
      { name: "baseUrl", type: str, optional: true, doc: "Absent = clear the override." },
    ],
  },
  {
    type: "set_local_url", name: "SetLocalUrl",
    fields: [
      { name: "providerId", type: { k: "enum", values: ["ollama", "lmstudio"] } },
      { name: "baseUrl", type: str },
    ],
  },
  {
    type: "refresh_models", name: "RefreshModels",
    fields: [{ name: "providerId", type: str, optional: true }],
  },
];

/** Events: backend -> shell. Every one carries `id`. */
export const EVENTS: Message[] = [
  {
    type: "response", name: "Response",
    doc: "Terminal reply to a single-response command.",
    fields: [
      { name: "command", type: str },
      { name: "success", type: bool },
      { name: "protocol", type: int, optional: true },
      { name: "backend", type: str, optional: true },
      { name: "message", type: str, optional: true },
      { name: "providers",
        type: { k: "array", of: { k: "ref", ts: "ProviderSummary", swift: "BackendProviderSummary" } },
        optional: true },
      { name: "apiKey", type: str, optional: true, nullable: true,
        doc: "null means the provider has no key stored, as distinct from absent." },
    ],
  },
  { type: "delta", name: "Delta", fields: [{ name: "text", type: str }] },
  { type: "thinking", name: "Thinking", fields: [{ name: "text", type: str }] },
  {
    type: "tool_exec", name: "ToolExec",
    doc: "Asks the shell to run one tool; answered with tool_result.",
    fields: [
      { name: "callId", type: str },
      { name: "name", type: str },
      { name: "args", type: json },
    ],
  },
  {
    type: "assistant", name: "Assistant",
    doc: "Authoritative snapshot of one iteration's assistant message.",
    fields: [
      { name: "text", type: str },
      { name: "thinking", type: str, optional: true },
      { name: "toolCalls",
        type: { k: "array", of: { k: "ref", ts: "EventToolCall", swift: "BackendToolCall" } } },
    ],
  },
  {
    type: "oauth_notify", name: "OAuthNotify",
    fields: [
      { name: "kind", type: { k: "enum", values: ["info", "auth_url", "device_code", "progress"] } },
      { name: "message", type: str, optional: true },
      { name: "url", type: str, optional: true },
      { name: "userCode", type: str, optional: true },
      { name: "verificationUri", type: str, optional: true },
    ],
  },
  {
    type: "oauth_prompt", name: "OAuthPrompt",
    fields: [
      { name: "promptId", type: str },
      { name: "promptType",
        type: { k: "enum", values: ["text", "secret", "select", "manual_code"] } },
      { name: "message", type: str },
      { name: "placeholder", type: str, optional: true },
      { name: "options",
        type: { k: "array", of: { k: "ref", ts: "PromptOption", swift: "BackendPromptOption" } },
        optional: true },
    ],
  },
  { type: "done", name: "Done", fields: [{ name: "stopReason", type: str }] },
  { type: "error", name: "Error", fields: [{ name: "message", type: str }] },
];
