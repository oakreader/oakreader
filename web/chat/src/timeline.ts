/**
 * Timeline derivation, modelled on t3code's chat pipeline:
 *
 *   deriveTimelineEntries   merge messages + tool activity chronologically
 *     -> deriveTimelineRows  flatten to rows with STABLE identity
 *
 * Stable identity is the point. React reconciles the list by row id, so a
 * streaming turn must keep the same ids across every delta or the whole list
 * remounts 30 times a second and selection, scroll anchoring and any open
 * disclosure all reset.
 *
 * Reducing events to state also keeps this surface replaceable: nothing here
 * knows about React, so the same derivation can back a different renderer.
 */
import type { InboundEvent, SerializedTurn, ToolRecord } from "./bridge";

export type ToolPhase = "running" | "pending" | "done" | "failed";

export interface ToolEntry extends ToolRecord {
  phase: ToolPhase;
}

/** One turn as the UI needs it. Mutated in place while streaming. */
export interface Turn {
  id: string;
  role: "user" | "assistant";
  text: string;
  thinking: string;
  tools: ToolEntry[];
  /** Still receiving events. */
  streaming: boolean;
  error?: string;
}

export interface ChatState {
  turns: Turn[];
  /** The turn currently streaming, if any. */
  activeTurnId: string | null;
}

export const initialState: ChatState = { turns: [], activeTurnId: null };

function emptyTurn(id: string, role: Turn["role"]): Turn {
  return { id, role, text: "", thinking: "", tools: [], streaming: role === "assistant" };
}

function upsertTool(turn: Turn, tool: ToolRecord, phase: ToolPhase): ToolEntry[] {
  const i = turn.tools.findIndex((t) => t.id === tool.id);
  const merged: ToolEntry = { ...(i >= 0 ? turn.tools[i] : {}), ...tool, phase };
  if (i < 0) return [...turn.tools, merged];
  const next = turn.tools.slice();
  next[i] = merged;
  return next;
}

/** Locate a turn, creating it if the shell streams before announcing it. */
function withTurn(state: ChatState, turnId: string, fn: (t: Turn) => Turn): ChatState {
  const i = state.turns.findIndex((t) => t.id === turnId);
  if (i < 0) {
    return { ...state, turns: [...state.turns, fn(emptyTurn(turnId, "assistant"))], activeTurnId: turnId };
  }
  const turns = state.turns.slice();
  turns[i] = fn(turns[i]);
  return { ...state, turns };
}

export function reduce(state: ChatState, event: InboundEvent): ChatState {
  switch (event.type) {
    case "reset":
      return { turns: event.turns.map(fromSerialized), activeTurnId: null };

    case "turnStarted":
      return {
        ...state,
        turns: [...state.turns, emptyTurn(event.turnId, "assistant")],
        activeTurnId: event.turnId,
      };

    case "delta":
      return withTurn(state, event.turnId, (t) => ({ ...t, text: t.text + event.text }));

    case "thinkingDelta":
      return withTurn(state, event.turnId, (t) => ({ ...t, thinking: t.thinking + event.text }));

    case "toolUseStarted":
      return withTurn(state, event.turnId, (t) => ({ ...t, tools: upsertTool(t, event.tool, "running") }));

    case "toolUsePending":
      return withTurn(state, event.turnId, (t) => ({ ...t, tools: upsertTool(t, event.tool, "pending") }));

    case "toolUseCompleted":
      return withTurn(state, event.turnId, (t) => ({
        ...t,
        tools: upsertTool(t, event.tool, event.tool.isError ? "failed" : "done"),
      }));

    case "finished": {
      const next = withTurn(state, event.turnId, (t) => ({ ...t, streaming: false }));
      return { ...next, activeTurnId: null };
    }

    case "error": {
      if (!event.turnId) return state;
      const next = withTurn(state, event.turnId, (t) => ({ ...t, streaming: false, error: event.message }));
      return { ...next, activeTurnId: null };
    }

    default:
      return state;
  }
}

/**
 * Append the user's message before the shell has acknowledged it, the way
 * t3code's composer does: the row appears instantly and is replaced when the
 * canonical turn arrives.
 */
export function appendOptimisticUserTurn(state: ChatState, text: string): ChatState {
  const id = `local-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const turn: Turn = { ...emptyTurn(id, "user"), text, streaming: false };
  return { ...state, turns: [...state.turns, turn] };
}

function fromSerialized(t: SerializedTurn): Turn {
  return {
    id: t.id,
    role: t.role,
    text: t.text,
    thinking: t.thinking ?? "",
    tools: (t.tools ?? []).map((tool) => ({ ...tool, phase: tool.isError ? "failed" : "done" })),
    streaming: false,
    ...(t.isError ? { error: "This turn ended with an error." } : {}),
  };
}

/** Row = one rendered unit, with an id stable across the whole stream. */
export type Row =
  | { kind: "message"; id: string; turn: Turn }
  | { kind: "tool"; id: string; turnId: string; tool: ToolEntry }
  | { kind: "error"; id: string; turnId: string; message: string };

export function deriveTimelineRows(state: ChatState): Row[] {
  const rows: Row[] = [];
  for (const turn of state.turns) {
    // Thinking and tool activity belong above the prose they produced, which
    // is the order they actually happened in.
    for (const tool of turn.tools) rows.push({ kind: "tool", id: `${turn.id}:tool:${tool.id}`, turnId: turn.id, tool });
    if (turn.text || turn.thinking || turn.streaming)
      rows.push({ kind: "message", id: `${turn.id}:msg`, turn });
    if (turn.error) rows.push({ kind: "error", id: `${turn.id}:err`, turnId: turn.id, message: turn.error });
  }
  return rows;
}
