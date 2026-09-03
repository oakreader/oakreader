import { z } from "zod";

/**
 * Protocol v1: JSONL over stdio, LF-delimited (never split on U+2028/U+2029).
 * The Swift mirror lives in OakReader/Services/Backend/BackendProtocol.swift —
 * keep the two in sync.
 */
export const PROTOCOL_VERSION = 1;

/** Maps 1:1 onto OakAI's `APIFormat`; values are pi-ai api ids. */
export const ApiId = z.enum([
  "anthropic-messages",
  "openai-completions",
  "openai-responses",
  "google-generative-ai",
]);
export type ApiId = z.infer<typeof ApiId>;

export const ModelSpec = z.object({
  api: ApiId,
  /** API base (endpoint minus the format-specific suffix); pi-ai appends paths. */
  baseUrl: z.string(),
  id: z.string(),
  headers: z.record(z.string(), z.string()).optional(),
});

export const ChatMessage = z.object({
  role: z.enum(["user", "assistant"]),
  content: z.string(),
});

export const CompleteCommand = z.object({
  id: z.string(),
  type: z.literal("complete"),
  model: ModelSpec,
  auth: z.object({ apiKey: z.string().optional() }).default({}),
  system: z.string().optional(),
  messages: z.array(ChatMessage).min(1),
  maxTokens: z.number().int().positive().default(4096),
});

export const PingCommand = z.object({
  id: z.string(),
  type: z.literal("ping"),
});

export const AbortCommand = z.object({
  id: z.string(),
  type: z.literal("abort"),
});

export const Command = z.discriminatedUnion("type", [
  PingCommand,
  CompleteCommand,
  AbortCommand,
]);
export type Command = z.infer<typeof Command>;

// Server → client events. `done` / `error` are terminal per request id.
export type Event =
  | { id: string; type: "response"; command: string; success: boolean; protocol?: number; backend?: string; message?: string }
  | { id: string; type: "delta"; text: string }
  | { id: string; type: "done"; stopReason: string }
  | { id: string; type: "error"; message: string };
