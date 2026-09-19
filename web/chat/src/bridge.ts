/**
 * The Swift <-> WebView contract.
 *
 * Mirrors `SessionEvent` as `ChatViewModel` already consumes it
 * (delta / thinkingDelta / toolUseStarted / toolUsePending / toolUseCompleted /
 * finished / error), so the shell keeps one event vocabulary whether the
 * surface is SwiftUI or this panel. Keep the two in sync: the Swift side is
 * OakReader/Views/RightPanel/ChatWebView.swift.
 *
 * Inbound  (Swift -> JS): window.oakChat.receive(event)
 * Outbound (JS -> Swift): window.webkit.messageHandlers.oakChat.postMessage(msg)
 */

/** One tool invocation as the shell reports it. */
export interface ToolRecord {
  id: string;
  name: string;
  /** Pretty-printed arguments, already stringified by the shell. */
  args?: string;
  /** Result text once completed. */
  result?: string;
  isError?: boolean;
}

/** One row in the `/` or `@` menu, supplied by the shell. */
export interface CompletionItem {
  id: string;
  label: string;
  detail?: string;
  /** Text substituted into the prompt; defaults to `label`. */
  insert?: string;
}

export interface ModelOption {
  providerId: string;
  providerName: string;
  modelId: string;
  modelName: string;
}

export type InboundEvent =
  | { type: "reset"; turns: SerializedTurn[] }
  | { type: "turnStarted"; turnId: string }
  | { type: "delta"; turnId: string; text: string }
  | { type: "thinkingDelta"; turnId: string; text: string }
  | { type: "toolUseStarted"; turnId: string; tool: ToolRecord }
  | { type: "toolUsePending"; turnId: string; tool: ToolRecord }
  | { type: "toolUseCompleted"; turnId: string; tool: ToolRecord }
  | { type: "finished"; turnId: string }
  | { type: "error"; turnId?: string; message: string }
  | { type: "appearance"; theme: "light" | "dark" }
  /** Answer to requestCompletions; `kind` echoes the request. */
  | { type: "completions"; kind: "slash" | "mention"; query: string; items: CompletionItem[] }
  | { type: "models"; options: ModelOption[]; current?: { providerId: string; modelId: string } };

/** A completed turn as restored from the shell's session store. */
export interface SerializedTurn {
  id: string;
  role: "user" | "assistant";
  text: string;
  thinking?: string;
  tools?: ToolRecord[];
  isError?: boolean;
}

export type OutboundMessage =
  | { type: "ready" }
  | { type: "send"; text: string }
  | { type: "abort" }
  | { type: "approveTool"; toolId: string; approved: boolean }
  | { type: "openCitation"; href: string }
  /** Ask the shell for `/` skills or `@` library references matching `query`. */
  | { type: "requestCompletions"; kind: "slash" | "mention"; query: string }
  | { type: "setModel"; providerId: string; modelId: string }
  /** Surfaced so the shell can log JS failures instead of losing them. */
  | { type: "log"; level: "warn" | "error"; message: string };

interface WebKitBridge {
  messageHandlers?: Record<string, { postMessage(body: unknown): void }>;
}

export function postToShell(message: OutboundMessage): void {
  const webkit = (window as unknown as { webkit?: WebKitBridge }).webkit;
  const handler = webkit?.messageHandlers?.oakChat;
  if (handler) handler.postMessage(message);
  // Running in a browser during `pnpm dev`: log instead of throwing so the UI
  // is still developable without the app.
  else console.info("[oakChat -> shell]", message);
}

export function onShellEvent(handler: (event: InboundEvent) => void): void {
  (window as unknown as { oakChat: { receive(e: InboundEvent): void } }).oakChat = {
    receive: handler,
  };
}
