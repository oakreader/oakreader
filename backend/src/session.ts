/**
 * A chat transcript in pi's own session format.
 *
 * One file per conversation, `<chats>/<sessionId>.jsonl`, written the way
 * pi's coding agent writes `~/.pi/agent/sessions/*.jsonl` (version 3): a
 * `session` header, then entries chained by `parentId`. The types are pi's,
 * imported from `@earendil-works/pi-coding-agent`, so a drift from pi's format
 * is a compile error here rather than a silent difference on disk.
 *
 * The core is the only writer, as pi's SessionManager is. Every entry it
 * appends also goes to the shell on `chat/entry`, byte for byte the same
 * object, so the file and the pipe cannot disagree. The shell reads the file
 * to draw a conversation and never writes it.
 *
 * Only the entry types OakReader writes are understood. The tree is a single
 * branch: there is no branching or compaction UI, so the leaf is always the
 * last entry.
 */
import { randomUUID } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type {
  CustomEntry,
  FileEntry,
  ModelChangeEntry,
  SessionEntry,
  SessionHeader,
  SessionMessageEntry,
  ThinkingLevelChangeEntry,
} from "@earendil-works/pi-coding-agent";
import type { Message, SystemMessage } from "@earendil-works/pi-ai";

/** pi's CURRENT_SESSION_VERSION. */
export const SESSION_VERSION = 3;

/**
 * The one `custom` entry type OakReader writes: what the shell draws that pi
 * has no field for. `targetId` names the message entry it belongs to.
 */
export const DISPLAY_ENTRY = "oakreader.display";

export interface DisplayData {
  targetId: string;
  [key: string]: unknown;
}

/** The section of the system message that holds OakReader's prompt. */
export const PROMPT_SECTION = "prompt";

/** Entry fields the session fills in itself. */
type NewEntry<T extends SessionEntry> = Omit<T, "id" | "parentId" | "timestamp">;

export class SessionFile {
  private readonly byId = new Set<string>();
  private leafId: string | null = null;
  private readonly entries: SessionEntry[] = [];

  private constructor(
    private readonly path: string,
    readonly header: SessionHeader,
    private readonly emit: (entry: FileEntry) => void,
  ) {}

  /**
   * Open `<dir>/<id>.jsonl`, creating it with a header when it does not exist.
   * `emit` sees every line this session writes, the header included.
   */
  static open(dir: string, id: string, emit: (entry: FileEntry) => void): SessionFile {
    if (!/^[A-Za-z0-9-]+$/.test(id)) throw new Error(`invalid session id: ${id}`);
    const path = join(dir, `${id}.jsonl`);
    if (!existsSync(path)) {
      mkdirSync(dir, { recursive: true });
      const header: SessionHeader = {
        type: "session", version: SESSION_VERSION, id, timestamp: new Date().toISOString(), cwd: "",
      };
      const session = new SessionFile(path, header, emit);
      session.write(header);
      return session;
    }
    const lines = readFileSync(path, "utf8").split("\n").filter((l) => l.trim().length > 0);
    const header = JSON.parse(lines[0] ?? "{}") as SessionHeader;
    if (header.type !== "session" || header.version !== SESSION_VERSION) {
      throw new Error(`${path} is not a pi session (version ${SESSION_VERSION})`);
    }
    const session = new SessionFile(path, header, emit);
    for (const line of lines.slice(1)) session.track(JSON.parse(line) as SessionEntry);
    return session;
  }

  static delete(dir: string, id: string): void {
    if (!/^[A-Za-z0-9-]+$/.test(id)) return;
    rmSync(join(dir, `${id}.jsonl`), { force: true });
  }

  /** Append one entry after the current leaf. */
  append<T extends SessionEntry>(fields: NewEntry<T>): T {
    const entry = {
      ...fields, id: this.newId(), parentId: this.leafId, timestamp: new Date().toISOString(),
    } as T;
    this.track(entry);
    this.write(entry);
    return entry;
  }

  appendMessage(message: AgentMessage): SessionMessageEntry {
    return this.append<SessionMessageEntry>({ type: "message", message });
  }

  appendDisplay(data: DisplayData): CustomEntry<DisplayData> {
    return this.append<CustomEntry<DisplayData>>({ type: "custom", customType: DISPLAY_ENTRY, data });
  }

  /**
   * What pi's buildSessionContext returns for a single-branch session: the
   * messages on the path from the root to the leaf, and the latest model and
   * thinking level. Custom entries carry no context.
   */
  context(): { messages: Message[]; model: { provider: string; modelId: string } | null; thinkingLevel: string } {
    const byId = new Map(this.entries.map((e) => [e.id, e]));
    const path: SessionEntry[] = [];
    for (let e = this.leafId ? byId.get(this.leafId) : undefined; e; e = e.parentId ? byId.get(e.parentId) : undefined) {
      path.unshift(e);
    }
    const messages: Message[] = [];
    let model: { provider: string; modelId: string } | null = null;
    let thinkingLevel = "off";
    for (const entry of path) {
      switch (entry.type) {
        case "message": messages.push(entry.message as Message); break;
        case "model_change": model = { provider: entry.provider, modelId: entry.modelId }; break;
        case "thinking_level_change": thinkingLevel = entry.thinkingLevel; break;
        case "custom": break;
        default: throw new Error(`session entry type ${entry.type} is not supported`);
      }
    }
    return { messages, model, thinkingLevel };
  }

  /** Record the model and thinking level this run uses, when they changed. */
  noteSettings(provider: string, modelId: string, thinkingLevel: string): void {
    const now = this.context();
    if (now.model?.provider !== provider || now.model?.modelId !== modelId) {
      this.append<ModelChangeEntry>({ type: "model_change", provider, modelId });
    }
    if (now.thinkingLevel !== thinkingLevel || this.entries.every((e) => e.type !== "thinking_level_change")) {
      this.append<ThinkingLevelChangeEntry>({ type: "thinking_level_change", thinkingLevel });
    }
  }

  /**
   * A system message that sets the prompt, or undefined when the transcript
   * already holds this prompt. pi patches prompt sections by name, so a new
   * prompt replaces the old one on replay instead of adding to it. Tool
   * declarations are not set here: pi's loop adds them to this message.
   */
  static promptUpdate(messages: Message[], prompt: string): SystemMessage | undefined {
    let current: string | undefined;
    for (const m of messages) {
      if (m.role !== "system") continue;
      const section = m.sections?.[PROMPT_SECTION];
      if (section !== undefined) current = section ?? undefined;
    }
    if (current === prompt) return undefined;
    return { role: "system", content: "", sections: { [PROMPT_SECTION]: prompt }, timestamp: Date.now() };
  }

  private track(entry: SessionEntry): void {
    this.entries.push(entry);
    this.byId.add(entry.id);
    this.leafId = entry.id;
  }

  private write(entry: FileEntry): void {
    appendFileSync(this.path, JSON.stringify(entry) + "\n");
    this.emit(entry);
  }

  /** pi's id scheme: 8 hex characters, a full UUID after repeated collisions. */
  private newId(): string {
    for (let i = 0; i < 100; i++) {
      const id = randomUUID().slice(0, 8);
      if (!this.byId.has(id)) return id;
    }
    return randomUUID();
  }
}
