/**
 * OakReader AI sidecar. JSONL over stdio: commands in on stdin, events out on
 * stdout, free-form logging on stderr. See src/protocol.ts and
 * docs/architecture/node-backend-migration.md.
 */
import type { Api, Context, Model } from "@earendil-works/pi-ai";
import { stream as anthropicStream } from "@earendil-works/pi-ai/api/anthropic-messages";
import { stream as openaiCompletionsStream } from "@earendil-works/pi-ai/api/openai-completions";
import { stream as openaiResponsesStream } from "@earendil-works/pi-ai/api/openai-responses";
import { stream as googleStream } from "@earendil-works/pi-ai/api/google-generative-ai";
import { Command, PROTOCOL_VERSION, type Event } from "./protocol.js";

const BACKEND_ID = "oak-backend 0.1.0";

const streams: Record<string, (model: any, context: Context, options: any) => any> = {
  "anthropic-messages": anthropicStream,
  "openai-completions": openaiCompletionsStream,
  "openai-responses": openaiResponsesStream,
  "google-generative-ai": googleStream,
};

const inflight = new Map<string, AbortController>();

function emit(event: Event): void {
  process.stdout.write(JSON.stringify(event) + "\n");
}

function log(message: string): void {
  process.stderr.write(`[oak-backend] ${message}\n`);
}

async function handleComplete(cmd: Extract<Command, { type: "complete" }>): Promise<void> {
  if (inflight.has(cmd.id)) {
    emit({ id: cmd.id, type: "error", message: `duplicate request id: ${cmd.id}` });
    return;
  }
  const controller = new AbortController();
  inflight.set(cmd.id, controller);
  try {
    // Ephemeral model: the shell resolves provider/endpoint/credential; we only transport.
    const model: Model<Api> = {
      id: cmd.model.id,
      name: cmd.model.id,
      api: cmd.model.api,
      provider: "oakreader",
      baseUrl: cmd.model.baseUrl,
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 200_000,
      maxTokens: cmd.maxTokens,
      ...(cmd.model.headers ? { headers: cmd.model.headers } : {}),
      // OpenAI-compatible relays/local servers often reject `developer` role
      // and `reasoning_effort`; plain completions never need either.
      ...(cmd.model.api === "openai-completions"
        ? { compat: { supportsDeveloperRole: false, supportsReasoningEffort: false } }
        : {}),
    } as Model<Api>;

    const context: Context = {
      ...(cmd.system ? { systemPrompt: cmd.system } : {}),
      messages: cmd.messages.map((m) => ({
        role: m.role,
        content: m.content,
        timestamp: Date.now(),
      })),
    } as Context;

    const s = streams[cmd.model.api](model, context, {
      apiKey: cmd.auth.apiKey,
      signal: controller.signal,
    });

    let failed: string | undefined;
    for await (const event of s) {
      switch (event.type) {
        case "text_delta":
          emit({ id: cmd.id, type: "delta", text: event.delta });
          break;
        case "error":
          failed = event.error?.errorMessage ?? "provider error";
          break;
        default:
          break;
      }
    }
    if (controller.signal.aborted) {
      emit({ id: cmd.id, type: "done", stopReason: "aborted" });
    } else if (failed !== undefined) {
      emit({ id: cmd.id, type: "error", message: failed });
    } else {
      const result = await s.result();
      emit({ id: cmd.id, type: "done", stopReason: result.stopReason ?? "stop" });
    }
  } catch (err) {
    emit({ id: cmd.id, type: "error", message: err instanceof Error ? err.message : String(err) });
  } finally {
    inflight.delete(cmd.id);
  }
}

function handleLine(line: string): void {
  // Tolerate CRLF input by stripping a trailing \r.
  const trimmed = line.endsWith("\r") ? line.slice(0, -1) : line;
  if (trimmed === "") return;

  let raw: unknown;
  try {
    raw = JSON.parse(trimmed);
  } catch {
    log(`unparseable line: ${trimmed.slice(0, 200)}`);
    return;
  }
  const parsed = Command.safeParse(raw);
  if (!parsed.success) {
    const id = typeof (raw as any)?.id === "string" ? (raw as any).id : "";
    emit({ id, type: "error", message: `invalid command: ${parsed.error.message}` });
    return;
  }
  const cmd = parsed.data;
  switch (cmd.type) {
    case "ping":
      emit({
        id: cmd.id, type: "response", command: "ping", success: true,
        protocol: PROTOCOL_VERSION, backend: BACKEND_ID,
      });
      break;
    case "abort":
      // Unknown ids are a no-op: the request may have just finished.
      inflight.get(cmd.id)?.abort();
      break;
    case "complete":
      void handleComplete(cmd);
      break;
  }
}

// Strict JSONL framing: split on LF bytes only. Node's readline also splits on
// U+2028/U+2029, which are legal inside JSON strings (and OakReader ships
// arbitrary document text), so it is not protocol-safe here.
let buffer: Buffer = Buffer.alloc(0);
process.stdin.on("data", (chunk: Buffer) => {
  buffer = buffer.length === 0 ? chunk : Buffer.concat([buffer, chunk]);
  let newline: number;
  while ((newline = buffer.indexOf(0x0a)) !== -1) {
    const line = buffer.subarray(0, newline).toString("utf8");
    buffer = buffer.subarray(newline + 1);
    handleLine(line);
  }
});
process.stdin.on("end", () => {
  for (const controller of inflight.values()) controller.abort();
  process.exit(0);
});
log(`started (${BACKEND_ID}, protocol ${PROTOCOL_VERSION}, node ${process.version})`);
