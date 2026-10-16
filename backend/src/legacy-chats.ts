/**
 * One-time conversion of chat files written before transcripts became pi
 * sessions.
 *
 * Until protocol v14 the shell wrote `<chats>/<id>.jsonl` itself, one Swift
 * `Turn` per line, with captured images in `<chats>/attachments/<id>/`. The
 * core now reads and writes only pi session files, and the shell draws only
 * what is in them, so an unconverted file would open empty and could not be
 * continued.
 *
 * Runs at startup, before the first request is read, so the history list and
 * a reopened chat never see the old format. Each original moves to
 * `<chats>/legacy-v1/` untouched; the attachments directory stays where it is.
 * A file that fails to convert is left in place and logged.
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { AssistantMessage, JsonObject, Message, ToolResultMessage, UserMessage } from "@earendil-works/pi-ai";
import { DISPLAY_ENTRY, SESSION_VERSION } from "./session.js";

/** Where converted originals go. */
export const LEGACY_DIR = "legacy-v1";

/** Stands in for the provider and model of a reply stored without them. */
export const LEGACY_MODEL = "oakreader-legacy";

/** Seconds between the Unix epoch and Swift's `Date` reference date, 2001-01-01. */
const APPLE_EPOCH_OFFSET = 978_307_200;

interface LegacyAttachment {
  id: string;
  type: "textSelection" | "imageCapture";
  label: string;
  textContent?: string | null;
  filePath?: string | null;
  imageData?: string | null;
  pageIndex?: number | null;
}

interface LegacyToolUse {
  id: string;
  name: string;
  input?: JsonObject;
  result?: string | null;
  isError?: boolean;
  status?: string;
}

interface LegacyTurn {
  id: string;
  role: "user" | "assistant" | "system";
  content: string;
  timestamp: number;
  metadata?: Record<string, string>;
  skill?: string;
  error?: string | null;
  attachments?: LegacyAttachment[];
  toolUses?: LegacyToolUse[];
  thinking?: string | null;
  thinkingSeconds?: number | null;
}

/** Converts every old-format file in `dir`. Returns how many it converted. */
export function migrateLegacyChats(dir: string, log: (message: string) => void): number {
  if (!existsSync(dir)) return 0;
  let converted = 0;
  for (const name of readdirSync(dir)) {
    const match = /^([A-Za-z0-9-]+)\.jsonl$/.exec(name);
    if (!match) continue;
    const path = join(dir, name);
    try {
      const text = readFileSync(path, "utf8");
      if (!isLegacy(text)) continue;
      const lines = convert(match[1]!, text, dir);
      const archive = join(dir, LEGACY_DIR);
      mkdirSync(archive, { recursive: true });
      const tmp = `${path}.migrating`;
      writeFileSync(tmp, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
      renameSync(path, join(archive, name));
      renameSync(tmp, path);
      converted++;
    } catch (err) {
      log(`chat ${name} not converted: ${err instanceof Error ? err.message : String(err)}`);
    }
  }
  if (converted > 0) log(`converted ${converted} chat(s) to pi sessions; originals in ${LEGACY_DIR}/`);
  return converted;
}

/** True when the first line is not a pi session header. An empty file is left alone. */
export function isLegacy(text: string): boolean {
  const first = text.split("\n").find((l) => l.trim().length > 0);
  if (first === undefined) return false;
  const header = JSON.parse(first) as { type?: unknown };
  return header.type !== "session";
}

/** The pi session lines for one old file, header first. */
export function convert(sessionId: string, text: string, dir: string): Record<string, unknown>[] {
  const turns = text.split("\n").filter((l) => l.trim().length > 0).map((l) => JSON.parse(l) as LegacyTurn);
  const first = turns[0];
  const lines: Record<string, unknown>[] = [{
    type: "session", version: SESSION_VERSION, id: sessionId,
    timestamp: new Date(first ? unixMs(first.timestamp) : Date.now()).toISOString(), cwd: "",
  }];
  let parentId: string | null = null;
  let counter = 0;
  const append = (fields: Record<string, unknown>, at: number, keepId?: string): string => {
    const id = keepId ?? (counter++).toString(16).padStart(8, "0");
    lines.push({ ...fields, id, parentId, timestamp: new Date(at).toISOString() });
    parentId = id;
    return id;
  };
  // A turn's message keeps the turn's UUID as its entry id, so the shell draws it
  // under the same turn id it had before.
  const appendMessage = (message: Message, turnId?: string): string =>
    append({ type: "message", message }, message.timestamp, turnId);
  const appendDisplay = (data: Record<string, unknown>, at: number): void => {
    append({ type: "custom", customType: DISPLAY_ENTRY, data }, at);
  };

  for (const turn of turns) {
    const at = unixMs(turn.timestamp);
    if (turn.role === "user") {
      const id = appendMessage(userMessage(turn, at, join(dir, "attachments", sessionId)), turn.id);
      const metadata = turn.metadata ?? (turn.skill ? { skill: turn.skill } : undefined);
      const attachments = (turn.attachments ?? []).map((a) => ({
        id: a.id, type: a.type, label: a.label,
        ...(a.textContent != null ? { textContent: a.textContent } : {}),
        ...(a.pageIndex != null ? { pageIndex: a.pageIndex } : {}),
      }));
      appendDisplay({
        targetId: id, content: turn.content,
        ...(metadata && Object.keys(metadata).length > 0 ? { metadata } : {}),
        ...(attachments.length > 0 ? { attachments } : {}),
      }, at);
    } else if (turn.role === "assistant") {
      const message = assistantMessage(turn, at);
      // An empty reply (cancelled before the first token) is not worth a provider error on replay.
      if (message.content.length === 0 && message.stopReason !== "error") continue;
      const id = appendMessage(message, turn.id);
      if (turn.thinkingSeconds != null) appendDisplay({ targetId: id, thinkingSeconds: turn.thinkingSeconds }, at);
      for (const use of turn.toolUses ?? []) {
        if (use.result == null) continue;
        const result: ToolResultMessage = {
          role: "toolResult", toolCallId: use.id, toolName: use.name,
          content: [{ type: "text", text: use.result }],
          isError: use.isError ?? false,
          ...(use.status === "denied" ? { details: { denied: true } } : {}),
          timestamp: at,
        };
        appendMessage(result);
      }
    }
  }
  return lines;
}

function unixMs(appleSeconds: number): number {
  return Math.round((appleSeconds + APPLE_EPOCH_OFFSET) * 1000);
}

/** The message the shell would have sent for this turn: attachments, then the typed text. */
function userMessage(turn: LegacyTurn, at: number, attachmentDir: string): UserMessage {
  const content: UserMessage["content"] = [];
  const pushText = (text: string): void => { content.push({ type: "text", text }); };
  for (const a of turn.attachments ?? []) {
    if (a.type === "textSelection") {
      if (a.textContent != null) pushText(`[${a.label}]\n> ${a.textContent}\n`);
      continue;
    }
    const data = a.imageData ?? readImage(attachmentDir, a.filePath);
    if (data === undefined) continue;
    if (a.textContent != null) {
      let context = `[${a.label}]`;
      if (a.textContent !== "") context += `\nText inside the region:\n> ${a.textContent}`;
      pushText(context + "\n");
    }
    content.push({ type: "image", data, mimeType: "image/png" });
  }
  pushText(modelText(turn.content));
  return { role: "user", content, timestamp: at };
}

function readImage(dir: string, file: string | null | undefined): string | undefined {
  if (!file || file.includes("/") || file.includes("..")) return undefined;
  const path = join(dir, file);
  return existsSync(path) ? readFileSync(path).toString("base64") : undefined;
}

function assistantMessage(turn: LegacyTurn, at: number): AssistantMessage {
  const content: AssistantMessage["content"] = [];
  if (turn.thinking) content.push({ type: "thinking", thinking: turn.thinking });
  if (turn.content) content.push({ type: "text", text: turn.content });
  const calls = turn.toolUses ?? [];
  for (const use of calls) {
    content.push({ type: "toolCall", id: use.id, name: use.name, arguments: use.input ?? {} });
  }
  return {
    role: "assistant", content,
    api: LEGACY_MODEL, provider: LEGACY_MODEL, model: LEGACY_MODEL,
    usage: {
      input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
    stopReason: turn.error ? "error" : calls.length > 0 ? "toolUse" : "stop",
    ...(turn.error ? { errorMessage: turn.error } : {}),
    timestamp: at,
  };
}

/**
 * The shell's `PiMessage.modelText`: leading `[[skill:id]]` markers are UI-only.
 * When the user picked a skill and typed nothing, the skill id is the message.
 */
export function modelText(content: string): string {
  let remaining = content;
  const skills: string[] = [];
  for (;;) {
    const trimmed = remaining.trim();
    if (!trimmed.startsWith("[[skill:")) break;
    const close = trimmed.indexOf("]]");
    if (close === -1) break;
    const skill = trimmed.slice("[[skill:".length, close).trim();
    if (skill) skills.push(skill);
    remaining = trimmed.slice(close + 2);
  }
  const text = remaining.trim();
  if (skills.length === 0) return text === "" ? "Go" : text;
  return text === "" || text === "/" ? skills[0]! : text;
}
