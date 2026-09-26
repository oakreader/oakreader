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
