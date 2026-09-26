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
import { agentLoop } from "@earendil-works/pi-agent-core";
import type {
  AgentContext,
  AgentTool,
  AgentToolResult,
} from "@earendil-works/pi-agent-core";
import type { WireMessage } from "./protocol.js";

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
  /** Emit a progress notification tagged with this run's request id. */
  notify(method: string, params: Record<string, unknown>): void;
  /**
   * Ask the shell to execute one tool call and wait for its answer. This is a
   * reverse JSON-RPC request, so correlation is the envelope's own id -- the
   * caller does not thread a callId through.
   */
  executeTool(name: string, args: Record<string, unknown>): Promise<{ content: string; isError: boolean }>;
}

/**
 * The agentic loop, driven by pi's `agentLoop` rather than a hand-rolled
 * iteration over `streamSimple`.
 *
 * Every tool here is a *client* tool: `execute` hands the call to the Swift
 * shell over the protocol and awaits its `tool_result`, because 8 of the 11
 * tools read local app state (GRDB, the live WebView DOM, the open PDF).
 * pi never runs them itself.
 *
 * Progress is notifications (chat/delta, chat/thinking, chat/assistant) tagged
 * with this run's request id. The stop reason is the RETURN VALUE, not an
 * event: it is the answer to the request that started the loop, and a provider
 * failure throws so it becomes a JSON-RPC error with a code the shell can act on.
 */
export async function runChat(
  models: Models,
  run: ChatRun,
  signal: AbortSignal,
  callbacks: ChatCallbacks,
): Promise<string> {
  const { notify } = callbacks;
  const token = run.id;

  const tools: AgentTool[] = run.tools.map((t) => ({
    name: t.name,
    label: t.name,
    description: t.description,
    parameters: t.inputSchema as AgentTool["parameters"],
    // Sequential so the shell's confirmation UX still sees one call at a time.
    executionMode: "sequential",
    execute: async (_toolCallId, params) => {
      // No callId threaded through: the reverse request's own envelope id
      // correlates the answer.
      const result = await callbacks.executeTool(
        t.name,
        (params ?? {}) as Record<string, unknown>,
      );
      // pi wants a throw on failure; the shell reports errors in-band, and the
      // model is better served seeing the message than an opaque failure.
      return {
        content: [{ type: "text", text: result.content }],
        details: undefined,
        isError: result.isError,
      } as AgentToolResult<unknown>;
    },
  }));

  const context: AgentContext = {
    systemPrompt: run.system ?? "",
    messages: toPiMessages(run.messages, run.model),
    ...(tools.length > 0 ? { tools } : {}),
  };

  let lastStopReason = "stop";

  const stream = agentLoop(
    [],
    context,
    {
      model: run.model,
      // Our AgentMessages are already plain pi Messages.
      convertToLlm: (messages) => messages as Message[],
      maxTokens: run.maxTokens,
      ...(run.reasoning ? { reasoning: run.reasoning } : {}),
    },
    signal,
    (model, ctx, options) => models.streamSimple(model, ctx, options),
  );

  for await (const event of stream) {
    switch (event.type) {
      case "message_update": {
        const inner = event.assistantMessageEvent;
        if (inner.type === "text_delta") notify("chat/delta", { token, text: inner.delta });
        else if (inner.type === "thinking_delta") notify("chat/thinking", { token, text: inner.delta });
        break;
      }
      case "message_end": {
        const message = event.message as AssistantMessage;
        if (message.role !== "assistant") break;
        if (message.stopReason === "error") {
          throw new Error(message.errorMessage ?? "provider error");
        }
        lastStopReason = message.stopReason ?? "stop";
        const text = message.content
          .filter((b): b is { type: "text"; text: string } => b.type === "text")
          .map((b) => b.text)
          .join("");
        const thinking = message.content
          .filter((b): b is { type: "thinking"; thinking: string } => b.type === "thinking")
          .map((b) => b.thinking)
          .join("");
        const toolCalls = message.content.filter((b): b is ToolCall => b.type === "toolCall");
        notify("chat/assistant", {
          token,
          text,
          ...(thinking ? { thinking } : {}),
          toolCalls: toolCalls.map((c) => ({ id: c.id, name: c.name, args: c.arguments })),
        });
        break;
      }
      default:
        break;
    }
  }

  return signal.aborted ? "aborted" : lastStopReason;
}
