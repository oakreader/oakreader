import type {
  Api,
  AssistantMessage,
  Message,
  Model,
  Models,
  ThinkingLevel,
  UserMessage,
} from "@earendil-works/pi-ai";
import { agentLoop } from "@earendil-works/pi-agent-core";
import type {
  AgentContext,
  AgentTool,
  AgentToolResult,
} from "@earendil-works/pi-agent-core";
import { SessionFile } from "./session.js";

export interface ChatRun {
  id: string;
  model: Model<Api>;
  system?: string;
  /** The conversation's pi session file. History comes from it; every new message goes to it. */
  session: SessionFile;
  /** The message the user just sent. */
  user: UserMessage;
  /** What the shell draws for `user` beyond the message: stored as a display entry. */
  display?: Record<string, unknown>;
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
  executeTool(
    name: string, args: Record<string, unknown>, callId: string,
  ): Promise<{ content: string; isError: boolean; denied?: boolean }>;
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
 * Progress is notifications (chat/delta, chat/thinking, chat/toolcall) tagged
 * with this run's request id. History is the session file: every message pi's
 * loop finishes, the user's included, is appended to it as a pi message entry,
 * and the session sends each entry to the shell on chat/entry. Nothing pi
 * recorded is rebuilt or lost between turns. The stop reason is the RETURN VALUE, not an
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
    execute: async (toolCallId, params) => {
      // The reverse request's envelope id correlates the answer. The model's
      // call id goes along so the shell can match it to the chat/toolcall
      // preview it has been drawing.
      const result = await callbacks.executeTool(
        t.name,
        (params ?? {}) as Record<string, unknown>,
        toolCallId,
      );
      // pi wants a throw on failure; the shell reports errors in-band, and the
      // model is better served seeing the message than an opaque failure.
      return {
        content: [{ type: "text", text: result.content }],
        // pi's record of what happened beyond the text: the shell draws a
        // denied call differently from a failed one.
        details: result.denied ? { denied: true } : undefined,
        isError: result.isError,
      } as AgentToolResult<unknown>;
    },
  }));

  // pi keeps the prompt and the tool declarations in the transcript as system
  // messages. A new prompt goes in as a system message ahead of the user's;
  // pi's loop adds any tool change to it, or adds one of its own.
  const { session } = run;
  session.noteSettings(run.model.provider, run.model.id, run.reasoning ?? "off");
  const history = session.context().messages;
  const promptUpdate = SessionFile.promptUpdate(history, run.system ?? "");
  const prompts: Message[] = promptUpdate ? [promptUpdate, run.user] : [run.user];
  const context: AgentContext = {
    messages: history,
    ...(tools.length > 0 ? { tools } : {}),
  };

  // Thinking time of the reply being streamed: from its first thinking token
  // to its first answer token or tool call.
  let thinkingStart: number | undefined;
  let thinkingSeconds: number | undefined;
  const endThinking = () => {
    if (thinkingStart === undefined) return;
    thinkingSeconds = (performance.now() - thinkingStart) / 1000;
    thinkingStart = undefined;
  };

  let lastStopReason = "stop";
  // Partial-args updates, at most one per call per interval. pi re-parses the
  // whole argument JSON on every delta, so sending each one would ship a
  // long `write` body to the shell hundreds of times.
  const toolcallInterval = 80;
  const lastToolcallSent = new Map<string, number>();
  const sendToolcall = (partial: AssistantMessage, index: number, done: boolean) => {
    const block = partial.content[index];
    if (!block || block.type !== "toolCall" || !block.id) return;
    const now = Date.now();
    if (!done && now - (lastToolcallSent.get(block.id) ?? 0) < toolcallInterval) return;
    lastToolcallSent.set(block.id, now);
    notify("chat/toolcall", {
      token, callId: block.id, name: block.name, args: block.arguments ?? {}, done,
    });
  };

  const stream = agentLoop(
    prompts,
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
        if (inner.type === "text_delta") {
          endThinking();
          notify("chat/delta", { token, text: inner.delta });
        } else if (inner.type === "thinking_delta") {
          if (thinkingStart === undefined && thinkingSeconds === undefined) thinkingStart = performance.now();
          notify("chat/thinking", { token, text: inner.delta });
        } else if (inner.type === "toolcall_start" || inner.type === "toolcall_delta") {
          endThinking();
          sendToolcall(inner.partial, inner.contentIndex, false);
        } else if (inner.type === "toolcall_end") {
          sendToolcall(inner.partial, inner.contentIndex, true);
        }
        break;
      }
      case "message_start":
        thinkingStart = undefined;
        thinkingSeconds = undefined;
        break;
      case "message_end": {
        const message = event.message as Message;
        // Stored before the error check: a failed reply is history too, and
        // pi skips it on replay.
        const entry = session.appendMessage(message);
        if (message.role === "user" && run.display) {
          session.appendDisplay({ ...run.display, targetId: entry.id });
        }
        if (message.role !== "assistant") break;
        endThinking();
        if (thinkingSeconds !== undefined) session.appendDisplay({ targetId: entry.id, thinkingSeconds });
        if (message.stopReason === "error") {
          throw new Error(message.errorMessage ?? "provider error");
        }
        lastStopReason = message.stopReason ?? "stop";
        break;
      }
      default:
        break;
    }
  }

  return signal.aborted ? "aborted" : lastStopReason;
}
