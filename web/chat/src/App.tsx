import { useCallback, useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState } from "react";
import clsx from "clsx";
import { onShellEvent, postToShell, type InboundEvent, type SerializedTurn } from "./bridge";
import {
  appendOptimisticUserTurn,
  deriveTimelineRows,
  initialState,
  reduce,
  type ChatState,
  type Row,
  type ToolEntry,
} from "./timeline";

const PREVIEW_TURNS = [
  { id: "u1", role: "user" as const, text: "What does this paper claim about flow matching versus diffusion?" },
  {
    id: "a1",
    role: "assistant" as const,
    text: "The paper frames flow matching and diffusion as two views of the same transport problem. Diffusion learns a score function and integrates a reverse SDE; flow matching regresses the velocity field of a probability path directly, which removes the need to simulate the forward process during training.\n\nThe practical consequence is training stability: the flow-matching objective is a plain regression loss, so it does not inherit the variance of score estimates at low noise levels.",
    thinking: "The user is asking for the core distinction. Section 3 sets up the probability path; section 4.2 has the direct comparison. Cite the velocity-field framing rather than the SDE derivation.",
    tools: [
      { id: "t1", name: "search_document", args: '{\n  "query": "flow matching vs diffusion"\n}', result: "4 passages on pages 7, 11, 12, 19", isError: false },
      { id: "t2", name: "read_document", args: '{\n  "pages": "11-12"\n}', result: "…the velocity field u_t(x) is regressed directly…", isError: false },
    ],
  },
  { id: "u2", role: "user" as const, text: "Show me the training loop they use." },
  {
    id: "a2",
    role: "assistant" as const,
    text: "",
    tools: [{ id: "t3", name: "bash", args: '{\n  "command": "grep -n \'def train\' flow.py"\n}', isError: false }],
  },
] as const;

type Action = { kind: "event"; event: InboundEvent } | { kind: "optimistic"; text: string };

const chatReducer = (state: ChatState, action: Action): ChatState =>
  action.kind === "event" ? reduce(state, action.event) : appendOptimisticUserTurn(state, action.text);

export function App() {
  const [state, dispatch] = useReducer(chatReducer, initialState);

  useEffect(() => {
    onShellEvent((event) => {
      if (event.type === "appearance") {
        document.documentElement.dataset.theme = event.theme;
        return;
      }
      dispatch({ kind: "event", event });
    });
    postToShell({ type: "ready" });

    // Outside the WKWebView there is no shell to drive the panel, so seed a
    // representative conversation. This is how the surface gets reviewed in a
    // browser (`pnpm dev`, or opening dist/index.html) instead of blind.
    const inShell = Boolean((window as unknown as { webkit?: { messageHandlers?: unknown } }).webkit?.messageHandlers);
    if (!inShell && new URLSearchParams(location.search).get("preview") !== "0") {
      dispatch({ kind: "event", event: { type: "reset", turns: PREVIEW_TURNS as unknown as SerializedTurn[] } });
    }
  }, []);

  const rows = useMemo(() => deriveTimelineRows(state), [state]);
  const streaming = state.activeTurnId !== null;

  const send = useCallback((text: string) => {
    dispatch({ kind: "optimistic", text });
    postToShell({ type: "send", text });
  }, []);

  return (
    <div className="flex h-full flex-col bg-background text-foreground">
      <MessagesTimeline rows={rows} streaming={streaming} />
      <ChatComposer onSend={send} streaming={streaming} onAbort={() => postToShell({ type: "abort" })} />
    </div>
  );
}

/* ------------------------------------------------------------------ timeline */

function MessagesTimeline({ rows, streaming }: { rows: Row[]; streaming: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const pinned = useRef(true);

  const onScroll = () => {
    const el = ref.current;
    if (!el) return;
    pinned.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
  };
  useLayoutEffect(() => {
    if (pinned.current && ref.current) ref.current.scrollTop = ref.current.scrollHeight;
  }, [rows]);

  return (
    <div ref={ref} onScroll={onScroll} className="flex-1 overflow-y-auto px-4 py-3">
      {rows.length === 0 ? (
        <p className="mt-10 text-center text-[13px] text-secondary-label">Ask anything about this document.</p>
      ) : (
        // Dense and flush, the way t3code's timeline reads: rows are not cards.
        <div className="flex flex-col gap-1">
          {rows.map((row) => (
            <TimelineRow key={row.id} row={row} />
          ))}
          {streaming && rows.at(-1)?.kind !== "message" && (
            <p className="px-0.5 text-[13px] text-secondary-label">Working…</p>
          )}
        </div>
      )}
    </div>
  );
}

function TimelineRow({ row }: { row: Row }) {
  if (row.kind === "thinking") return <ThinkingRow text={row.text} />;
  if (row.kind === "tool") return <ToolRow tool={row.tool} />;
  if (row.kind === "error")
    return (
      <div className="selectable max-w-[80%] rounded-2xl border border-dashed border-border p-3 text-sm text-message-foreground/80">
        {row.message}
      </div>
    );

  const { turn } = row;
  if (turn.role === "user")
    return (
      <div className="flex justify-end py-1">
        <div className="selectable max-w-[85%] rounded-2xl bg-muted px-3 py-1.5 text-[13px] leading-[1.55] whitespace-pre-wrap">
          {turn.text}
        </div>
      </div>
    );

  return (
    <div className="selectable px-0.5 text-[13px] leading-[1.6] whitespace-pre-wrap">
      {turn.text}
      {turn.streaming && <Caret />}
    </div>
  );
}

/** Shared shape for the collapsible rows: flush, hover-highlighted, no chrome. */
const disclosureRow =
  "group relative flex min-h-6 w-full cursor-pointer items-center gap-1.5 rounded-md px-0.5 py-0.5 " +
  "text-left text-[13px] leading-[1.55] transition-colors duration-150 hover:bg-accent/20 " +
  "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring/70";

function Chevron({ open }: { open: boolean }) {
  return (
    <svg
      viewBox="0 0 12 12"
      className={clsx(
        "size-2.5 shrink-0 text-secondary-label/60 transition-transform duration-150",
        open && "rotate-90",
      )}
      aria-hidden
    >
      <path d="M4.75 3.25L7.5 6l-2.75 2.75" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function ThinkingRow({ text }: { text: string }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="mb-1">
      <button type="button" onClick={() => setOpen((v) => !v)} className={disclosureRow}>
        <Chevron open={open} />
        <span className="text-secondary-label">Reasoning</span>
      </button>
      {open && (
        <div className="selectable mt-0.5 border-l border-border pl-2.5 text-[13px] text-secondary-label whitespace-pre-wrap">
          {text}
        </div>
      )}
    </div>
  );
}

const PHASE_DOT: Record<ToolEntry["phase"], string> = {
  running: "bg-primary animate-pulse",
  pending: "bg-amber-500",
  done: "bg-emerald-500",
  failed: "bg-red-500",
};

function ToolRow({ tool }: { tool: ToolEntry }) {
  const [open, setOpen] = useState(false);
  return (
    <div>
      <button type="button" onClick={() => setOpen((v) => !v)} className={disclosureRow}>
        <Chevron open={open} />
        <span className={clsx("size-1.5 shrink-0 rounded-full", PHASE_DOT[tool.phase])} />
        <span className="truncate">{tool.name}</span>
        {tool.phase === "pending" && <span className="ml-auto text-xs text-amber-600">Needs approval</span>}
      </button>

      {open && (tool.args || tool.result) && (
        <div className="selectable mt-0.5 space-y-1 border-l border-border pl-2.5 text-[13px]">
          {tool.args && (
            <pre className="overflow-x-auto whitespace-pre-wrap text-secondary-label">{tool.args}</pre>
          )}
          {tool.result && <pre className="overflow-x-auto whitespace-pre-wrap">{tool.result}</pre>}
        </div>
      )}

      {tool.phase === "pending" && (
        <div className="mt-1 flex gap-1.5 pl-5">
          <button
            type="button"
            className="h-7 rounded-full bg-message-action px-3 text-xs font-medium text-message-action-foreground hover:bg-message-action-hover"
            onClick={() => postToShell({ type: "approveTool", toolId: tool.id, approved: true })}
          >
            Allow
          </button>
          <button
            type="button"
            className="h-7 rounded-full border border-border px-3 text-xs hover:bg-accent/40"
            onClick={() => postToShell({ type: "approveTool", toolId: tool.id, approved: false })}
          >
            Deny
          </button>
        </div>
      )}
    </div>
  );
}

const Caret = () => (
  <span className="ml-0.5 inline-block h-[1em] w-[2px] animate-pulse bg-current align-text-bottom" />
);

/* ------------------------------------------------------------------ composer */

function ChatComposer({
  onSend,
  streaming,
  onAbort,
}: {
  onSend: (text: string) => void;
  streaming: boolean;
  onAbort: () => void;
}) {
  const [text, setText] = useState("");
  const [focused, setFocused] = useState(false);
  const ref = useRef<HTMLTextAreaElement>(null);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 200)}px`;
  }, [text]);

  const submit = () => {
    const value = text.trim();
    if (!value || streaming) return;
    onSend(value);
    setText("");
  };

  const resting = !focused && text.length === 0;

  return (
    <div className="px-3 pb-3">
      {/* Surface: t3code's 20px radius, colour-transitioned, ring on focus. */}
      <div
        className={clsx(
          "rounded-[20px] border bg-card transition-[background-color,border-color,box-shadow] duration-200",
          focused ? "border-ring/60 ring-2 ring-ring/25" : "border-border",
        )}
      >
        <div className={clsx("relative px-3 sm:px-4", resting ? "py-2" : "pt-3.5 pb-2 sm:pt-4")}>
          <textarea
            ref={ref}
            rows={1}
            value={text}
            placeholder="Ask about this document…"
            onFocus={() => setFocused(true)}
            onBlur={() => setFocused(false)}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                submit();
              }
              if (e.key === "Escape" && streaming) {
                e.preventDefault();
                onAbort();
              }
            }}
            className="selectable block max-h-[200px] w-full resize-none bg-transparent text-[13px] leading-[1.55] outline-none placeholder:text-placeholder"
          />
        </div>

        {!resting && (
        <div className="flex items-center justify-between gap-2 px-3 pb-2.5 sm:px-4">
          <span className="text-[11px] text-secondary-label/80">
            {streaming ? "Esc to stop" : "⏎ send · ⇧⏎ newline"}
          </span>

          {streaming ? (
            <button
              type="button"
              onClick={onAbort}
              className="flex h-8 items-center gap-1.5 rounded-full border border-border px-3 text-xs font-medium hover:bg-accent/40"
            >
              <span className="size-2 rounded-[2px] bg-current" />
              Stop
            </button>
          ) : (
            /* Split pill, matching ComposerPrimaryActions: the action and its
               menu are two halves of one control. */
            <div className="flex items-center">
              <button
                type="button"
                onClick={submit}
                disabled={!text.trim()}
                className="h-8 rounded-l-full rounded-r-none bg-message-action px-4 text-xs font-medium text-message-action-foreground transition-colors hover:bg-message-action-hover disabled:opacity-30"
              >
                Send
              </button>
              <button
                type="button"
                disabled={!text.trim()}
                aria-label="Send options"
                className="h-8 rounded-l-none rounded-r-full border-l border-l-message-action-foreground/20 bg-message-action px-2 text-message-action-foreground transition-colors hover:bg-message-action-hover disabled:opacity-30"
              >
                <svg viewBox="0 0 12 12" className="size-3" aria-hidden>
                  <path d="M3 4.5L6 8l3-3.5" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
                </svg>
              </button>
            </div>
          )}
        </div>
        )}
      </div>
    </div>
  );
}
