import type {
  Api,
  AssistantMessage,
  Context,
  Message,
  Model,
  Models,
  ThinkingLevel,
  Tool,
  ToolCall,
} from "@earendil-works/pi-ai";
import type { Event, WireMessage } from "./protocol.js";

/** Convert Swift wire history into pi-ai Context messages. */
export function toPiMessages(wire: WireMessage[], model: Model<Api>): Message[] {
  const messages: Message[] = [];
  for (const m of wire) {
    switch (m.role) {
      case "user":
        messages.push({
          role: "user",
          content: m.parts.map((p) =>
            p.type === "text"
              ? { type: "text" as const, text: p.text }
              : { type: "image" as const, data: p.data, mimeType: p.mimeType },
          ),
          timestamp: Date.now(),
        });
        break;
      case "assistant": {
        const content: AssistantMessage["content"] = [];
        if (m.thinking) content.push({ type: "thinking", thinking: m.thinking });
        if (m.text) content.push({ type: "text", text: m.text });
        for (const call of m.toolCalls) {
          content.push({ type: "toolCall", id: call.id, name: call.name, arguments: call.args });
        }
        // Replayed history — synthesize the bookkeeping fields pi requires.
        messages.push({
          role: "assistant",
          content,
          api: model.api,
          provider: model.provider,
          model: model.id,
          usage: emptyUsage(),
          stopReason: m.toolCalls.length > 0 ? "toolUse" : "stop",
          timestamp: Date.now(),
        });
        break;
      }
      case "toolResult":
        messages.push({
          role: "toolResult",
          toolCallId: m.callId,
          toolName: m.name,
          content: [{ type: "text", text: m.content }],
          isError: m.isError,
          timestamp: Date.now(),
        });
        break;
    }
  }
  return messages;
}

function emptyUsage(): AssistantMessage["usage"] {
  return {
    input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
  };
}

export interface ChatRun {
  id: string;
  model: Model<Api>;
  system?: string;
  messages: WireMessage[];
  tools: { name: string; description: string; inputSchema: Record<string, unknown> }[];
  maxTokens: number;
  reasoning?: ThinkingLevel;
  maxIterations: number;
}

export interface ChatCallbacks {
  emit(event: Event): void;
  /** Ask the client to execute one tool call; resolves with its result. */
  executeTool(callId: string, name: string, args: Record<string, unknown>): Promise<{ content: string; isError: boolean }>;
}

/**
 * The agentic loop: stream an assistant message, hand any tool calls back to
 * the client for execution, feed results into the context, repeat. Emits the
 * same event stream shape the Swift BackendChatEngine consumes.
 */
export async function runChat(
  models: Models,
  run: ChatRun,
  signal: AbortSignal,
  callbacks: ChatCallbacks,
): Promise<void> {
  const { emit } = callbacks;
  const context: Context = {
    ...(run.system ? { systemPrompt: run.system } : {}),
    messages: toPiMessages(run.messages, run.model),
    ...(run.tools.length > 0
      ? {
          tools: run.tools.map(
            (t): Tool => ({
              name: t.name,
              description: t.description,
              parameters: t.inputSchema as Tool["parameters"],
            }),
          ),
        }
      : {}),
  };

  for (let iteration = 0; iteration < run.maxIterations; iteration++) {
    const stream = models.streamSimple(run.model, context, {
      signal,
      maxTokens: run.maxTokens,
      ...(run.reasoning ? { reasoning: run.reasoning } : {}),
    });

    for await (const event of stream) {
      switch (event.type) {
        case "text_delta":
          emit({ id: run.id, type: "delta", text: event.delta });
          break;
        case "thinking_delta":
          emit({ id: run.id, type: "thinking", text: event.delta });
          break;
        default:
          break;
      }
    }

    const message = await stream.result();
    if (message.stopReason === "aborted") {
      emit({ id: run.id, type: "done", stopReason: "aborted" });
      return;
    }
    if (message.stopReason === "error") {
      emit({ id: run.id, type: "error", message: message.errorMessage ?? "provider error" });
      return;
    }

    context.messages.push(message);
    const text = message.content
      .filter((b): b is { type: "text"; text: string } => b.type === "text")
      .map((b) => b.text)
      .join("");
    const thinking = message.content
      .filter((b): b is { type: "thinking"; thinking: string } => b.type === "thinking")
      .map((b) => b.thinking)
      .join("");
    const toolCalls = message.content.filter((b): b is ToolCall => b.type === "toolCall");

    // Authoritative snapshot of this iteration's assistant message.
    emit({
      id: run.id,
      type: "assistant",
      text,
      ...(thinking ? { thinking } : {}),
      toolCalls: toolCalls.map((c) => ({ id: c.id, name: c.name, args: c.arguments })),
    });

    if (toolCalls.length === 0) {
      emit({ id: run.id, type: "done", stopReason: message.stopReason });
      return;
    }

    // Sequential execution preserves the existing confirmation UX.
    for (const call of toolCalls) {
      if (signal.aborted) {
        emit({ id: run.id, type: "done", stopReason: "aborted" });
        return;
      }
      const result = await callbacks.executeTool(call.id, call.name, call.arguments);
      context.messages.push({
        role: "toolResult",
        toolCallId: call.id,
        toolName: call.name,
        content: [{ type: "text", text: result.content }],
        isError: result.isError,
        timestamp: Date.now(),
      });
    }
  }

  emit({ id: run.id, type: "done", stopReason: "max_iterations" });
}
