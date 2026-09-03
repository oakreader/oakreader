import { z } from "zod";

/**
 * Protocol v2: JSONL over stdio, LF-delimited (never split on U+2028/U+2029).
 * The Swift mirror lives in OakReader/Services/Backend/BackendProtocol.swift —
 * keep the two in sync.
 *
 * v2 moves provider/credential resolution into the backend: requests carry an
 * OakReader providerId + model id; keys, OAuth tokens, endpoint overrides and
 * the model catalog live here. The agentic `chat` loop also runs here, calling
 * back into the client for tool execution (`tool_exec` → `tool_result`).
 */
export const PROTOCOL_VERSION = 2;

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

// ---------------------------------------------------------------------------
// Commands (client → server)

const id = z.string();

export const PingCommand = z.object({ id, type: z.literal("ping") });
export const AbortCommand = z.object({ id, type: z.literal("abort") });

export const CompleteCommand = z.object({
  id,
  type: z.literal("complete"),
  providerId: z.string(),
  model: z.string(),
  system: z.string().optional(),
  messages: z.array(WireMessage).min(1),
  maxTokens: z.number().int().positive().default(4096),
  /** Explicit key for Test Connection (verify before saving); optional base for the same. */
  apiKey: z.string().optional(),
  baseUrl: z.string().optional(),
});

export const ChatCommand = z.object({
  id,
  type: z.literal("chat"),
  providerId: z.string(),
  model: z.string(),
  system: z.string().optional(),
  messages: z.array(WireMessage).min(1),
  tools: z.array(WireToolDef).default([]),
  maxTokens: z.number().int().positive().default(8192),
  reasoning: z.enum(["minimal", "low", "medium", "high", "xhigh", "max"]).optional(),
  maxIterations: z.number().int().positive().default(10),
});

export const ToolResultCommand = z.object({
  id, // the chat request id this result belongs to
  type: z.literal("tool_result"),
  callId: z.string(),
  content: z.string(),
  isError: z.boolean().default(false),
});

export const ListProvidersCommand = z.object({ id, type: z.literal("list_providers") });

export const SetApiKeyCommand = z.object({
  id,
  type: z.literal("set_api_key"),
  providerId: z.string(),
  key: z.string(),
});

export const GetApiKeyCommand = z.object({
  id,
  type: z.literal("get_api_key"),
  providerId: z.string(),
});

export const DeleteCredentialCommand = z.object({
  id,
  type: z.literal("delete_credential"),
  providerId: z.string(),
});

export const OAuthLoginCommand = z.object({
  id,
  type: z.literal("oauth_login"),
  providerId: z.string(),
});

export const OAuthPromptResultCommand = z.object({
  id, // the oauth_login request id
  type: z.literal("oauth_prompt_result"),
  promptId: z.string(),
  value: z.string().optional(), // absent = cancelled
});

export const SetBaseUrlCommand = z.object({
  id,
  type: z.literal("set_base_url"),
  providerId: z.string(),
  baseUrl: z.string().optional(), // absent = clear override
});

export const SetLocalUrlCommand = z.object({
  id,
  type: z.literal("set_local_url"),
  providerId: z.enum(["ollama", "lmstudio"]),
  baseUrl: z.string(),
});

export const RefreshModelsCommand = z.object({
  id,
  type: z.literal("refresh_models"),
  providerId: z.string().optional(),
});

export const Command = z.discriminatedUnion("type", [
  PingCommand,
  AbortCommand,
  CompleteCommand,
  ChatCommand,
  ToolResultCommand,
  ListProvidersCommand,
  SetApiKeyCommand,
  GetApiKeyCommand,
  DeleteCredentialCommand,
  OAuthLoginCommand,
  OAuthPromptResultCommand,
  SetBaseUrlCommand,
  SetLocalUrlCommand,
  RefreshModelsCommand,
]);
export type Command = z.infer<typeof Command>;

// ---------------------------------------------------------------------------
// Events (server → client). `done` / `error` are terminal per request id.

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

export type Event =
  | { id: string; type: "response"; command: string; success: boolean; protocol?: number; backend?: string; message?: string; providers?: ProviderSummary[]; apiKey?: string | null }
  | { id: string; type: "delta"; text: string }
  | { id: string; type: "thinking"; text: string }
  | { id: string; type: "tool_exec"; callId: string; name: string; args: Record<string, unknown> }
  | { id: string; type: "assistant"; text: string; thinking?: string; toolCalls: { id: string; name: string; args: Record<string, unknown> }[] }
  | { id: string; type: "oauth_notify"; kind: "info" | "auth_url" | "device_code" | "progress"; message?: string; url?: string; userCode?: string; verificationUri?: string }
  | { id: string; type: "oauth_prompt"; promptId: string; promptType: "text" | "secret" | "select" | "manual_code"; message: string; placeholder?: string; options?: { id: string; label: string }[] }
  | { id: string; type: "done"; stopReason: string }
  | { id: string; type: "error"; message: string };
