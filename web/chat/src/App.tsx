import { useCallback, useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState } from "react";
import clsx from "clsx";
import { onShellEvent, postToShell, type InboundEvent } from "./bridge";
import {
  appendOptimisticUserTurn,
  deriveTimelineRows,
  initialState,
  reduce,
  type ChatState,
  type Row,
  type ToolEntry,
} from "./timeline";

type Action = { kind: "event"; event: InboundEvent } | { kind: "optimistic"; text: string };

function chatReducer(state: ChatState, action: Action): ChatState {
  return action.kind === "event"
    ? reduce(state, action.event)
    : appendOptimisticUserTurn(state, action.text);
}

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
  }, []);

  const rows = useMemo(() => deriveTimelineRows(state), [state]);
  const streaming = state.activeTurnId !== null;

  const send = useCallback((text: string) => {
    dispatch({ kind: "optimistic", text });
    postToShell({ type: "send", text });
  }, []);

  return (
    <div className="flex h-full flex-col bg-[var(--color-surface)]">
      <MessagesTimeline rows={rows} streaming={streaming} />
      <ChatComposer onSend={send} streaming={streaming} onAbort={() => postToShell({ type: "abort" })} />
    </div>
  );
}

function MessagesTimeline({ rows, streaming }: { rows: Row[]; streaming: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const pinned = useRef(true);

  // Stay pinned to the bottom while streaming, but stop fighting the user the
  // moment they scroll up to read something.
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
      {rows.length === 0 && (
        <p className="mt-8 text-center text-[var(--color-ink-muted)]">Ask anything about this document.</p>
      )}
      <div className="flex flex-col gap-3">
        {rows.map((row) => (
          <TimelineRow key={row.id} row={row} />
        ))}
        {streaming && rows.at(-1)?.kind !== "message" && <Thinking />}
      </div>
    </div>
  );
}

function TimelineRow({ row }: { row: Row }) {
  if (row.kind === "tool") return <ToolRow tool={row.tool} />;
  if (row.kind === "error")
    return (
      <div className="selectable rounded-md border border-red-500/30 bg-red-500/10 px-3 py-2 text-red-600 dark:text-red-400">
        {row.message}
      </div>
    );

  const { turn } = row;
  if (turn.role === "user")
    return (
      <div className="flex justify-end">
        <div className="selectable max-w-[85%] rounded-2xl bg-[var(--color-surface-raised)] px-3 py-2 whitespace-pre-wrap">
          {turn.text}
        </div>
      </div>
    );

  return (
    <div className="selectable whitespace-pre-wrap">
      {turn.thinking && <ThinkingBlock text={turn.thinking} />}
      {turn.text}
      {turn.streaming && <Caret />}
    </div>
  );
}

function ThinkingBlock({ text }: { text: string }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="mb-2 rounded-md border border-[var(--color-line)]">
      <button
        onClick={() => setOpen((v) => !v)}
        className="w-full px-2 py-1 text-left text-[11px] text-[var(--color-ink-muted)]"
      >
        {open ? "▾" : "▸"} Reasoning
      </button>
      {open && <div className="selectable px-2 pb-2 text-[12px] text-[var(--color-ink-muted)]">{text}</div>}
    </div>
  );
}

const PHASE_LABEL: Record<ToolEntry["phase"], string> = {
  running: "Running",
  pending: "Needs approval",
  done: "Done",
  failed: "Failed",
};

function ToolRow({ tool }: { tool: ToolEntry }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="rounded-md border border-[var(--color-line)] bg-[var(--color-surface-raised)]">
      <button onClick={() => setOpen((v) => !v)} className="flex w-full items-center gap-2 px-2.5 py-1.5 text-left">
        <span
          className={clsx(
            "size-1.5 shrink-0 rounded-full",
            tool.phase === "running" && "animate-pulse bg-[var(--color-accent)]",
            tool.phase === "pending" && "bg-amber-500",
            tool.phase === "done" && "bg-emerald-500",
            tool.phase === "failed" && "bg-red-500",
          )}
        />
        <span className="font-medium">{tool.name}</span>
        <span className="ml-auto text-[11px] text-[var(--color-ink-muted)]">{PHASE_LABEL[tool.phase]}</span>
      </button>
      {open && (
        <div className="selectable border-t border-[var(--color-line)] px-2.5 py-2 text-[12px]">
          {tool.args && <pre className="overflow-x-auto whitespace-pre-wrap text-[var(--color-ink-muted)]">{tool.args}</pre>}
          {tool.result && <pre className="mt-1 overflow-x-auto whitespace-pre-wrap">{tool.result}</pre>}
        </div>
      )}
      {tool.phase === "pending" && (
        <div className="flex gap-2 border-t border-[var(--color-line)] px-2.5 py-1.5">
          <button
            className="rounded bg-[var(--color-accent)] px-2 py-0.5 text-white"
            onClick={() => postToShell({ type: "approveTool", toolId: tool.id, approved: true })}
          >
            Allow
          </button>
          <button
            className="rounded border border-[var(--color-line)] px-2 py-0.5"
            onClick={() => postToShell({ type: "approveTool", toolId: tool.id, approved: false })}
          >
            Deny
          </button>
        </div>
      )}
    </div>
  );
}

const Caret = () => <span className="ml-0.5 inline-block w-[2px] animate-pulse bg-current align-text-bottom h-[1em]" />;
const Thinking = () => <p className="text-[var(--color-ink-muted)]">Thinking…</p>;

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
  const ref = useRef<HTMLTextAreaElement>(null);

  // Grow with content instead of scrolling inside a fixed box.
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 180)}px`;
  }, [text]);

  const submit = () => {
    const value = text.trim();
    if (!value || streaming) return;
    onSend(value);
    setText("");
  };

  return (
    <div className="border-t border-[var(--color-line)] p-2">
      <div className="flex items-end gap-2 rounded-xl border border-[var(--color-line)] bg-[var(--color-surface-raised)] px-2 py-1.5">
        <textarea
          ref={ref}
          rows={1}
          value={text}
          placeholder="Ask about this document…"
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            // Enter sends, Shift+Enter is a newline — the convention every
            // chat surface in the app already uses.
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              submit();
            }
          }}
          className="selectable flex-1 resize-none bg-transparent outline-none placeholder:text-[var(--color-ink-muted)]"
        />
        {streaming ? (
          <button onClick={onAbort} className="shrink-0 rounded-md border border-[var(--color-line)] px-2 py-0.5">
            Stop
          </button>
        ) : (
          <button
            onClick={submit}
            disabled={!text.trim()}
            className="shrink-0 rounded-md bg-[var(--color-accent)] px-2 py-0.5 text-white disabled:opacity-40"
          >
            Send
          </button>
        )}
      </div>
    </div>
  );
}
