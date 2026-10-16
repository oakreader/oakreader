// Chat files from before protocol v14 hold one Swift Turn per line. They must
// become pi sessions that pi itself reads, with nothing the shell drew lost.
import { test, expect } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { LEGACY_DIR, LEGACY_MODEL, migrateLegacyChats, modelText } from "../src/legacy-chats.ts";
import { DISPLAY_ENTRY, SessionFile } from "../src/session.ts";

const ID = "CFB8354E-1511-44AC-BBF9-D8E4466854E4";
const USER = "11111111-1111-4111-8111-111111111111";
const REPLY = "22222222-2222-4222-8222-222222222222";
const PNG = Buffer.from("not really a png");

function legacyChat(dir: string): string {
  mkdirSync(join(dir, "attachments", ID), { recursive: true });
  writeFileSync(join(dir, "attachments", ID, "shot.png"), PNG);
  const turns = [
    {
      id: USER, role: "user", content: "[[skill:explain]] What is this?", timestamp: 813841976.5,
      isStreaming: false, metadata: { skill: "explain" }, toolUses: [],
      attachments: [
        { id: "A1", type: "textSelection", label: "p. 3", textContent: "a quote" },
        { id: "A2", type: "imageCapture", label: "p. 4", textContent: "", filePath: "shot.png", pageIndex: 3 },
      ],
    },
    {
      id: REPLY, role: "assistant", content: "It is a figure.", timestamp: 813841980,
      isStreaming: false, metadata: {}, attachments: [], thinking: "Look closer.", thinkingSeconds: 2.5,
      toolUses: [
        { id: "call_1", name: "read_page", input: { page: 4 }, result: "page text", isError: false, status: "completed" },
        { id: "call_2", name: "write_note", input: {}, result: "Denied", isError: true, status: "denied" },
        { id: "call_3", name: "cut_off", input: {}, isError: false, status: "running" },
      ],
    },
    // Cancelled before the first token: dropped.
    { id: "33333333-3333-4333-8333-333333333333", role: "assistant", content: "", timestamp: 813841990,
      isStreaming: false, metadata: {}, attachments: [], toolUses: [] },
  ];
  const path = join(dir, `${ID}.jsonl`);
  writeFileSync(path, turns.map((t) => JSON.stringify(t)).join("\n") + "\n");
  return path;
}

test("an old chat becomes a pi session pi reads, and the original is kept", () => {
  const dir = mkdtempSync(join(tmpdir(), "oak-legacy-"));
  const path = legacyChat(dir);
  const original = readFileSync(path, "utf8");

  expect(migrateLegacyChats(dir, () => {})).toBe(1);
  expect(readFileSync(join(dir, LEGACY_DIR, `${ID}.jsonl`), "utf8")).toBe(original);
  expect(existsSync(join(dir, "attachments", ID, "shot.png"))).toBe(true);

  const pi = SessionManager.open(path);
  expect(pi.getHeader()?.id).toBe(ID);
  const messages = pi.buildSessionContext().messages;
  expect(messages.map((m) => m.role)).toEqual(["user", "assistant", "toolResult", "toolResult"]);

  const [user, reply, read, denied] = messages as any[];
  expect(user.timestamp).toBe((813841976.5 + 978307200) * 1000);
  expect(user.content).toEqual([
    { type: "text", text: "[p. 3]\n> a quote\n" },
    { type: "text", text: "[p. 4]\n" },
    { type: "image", data: PNG.toString("base64"), mimeType: "image/png" },
    { type: "text", text: "What is this?" },
  ]);
  expect(reply.provider).toBe(LEGACY_MODEL);
  expect(reply.stopReason).toBe("toolUse");
  expect(reply.content.map((c: any) => c.type)).toEqual(["thinking", "text", "toolCall", "toolCall", "toolCall"]);
  expect(read).toMatchObject({ toolCallId: "call_1", content: [{ type: "text", text: "page text" }], isError: false });
  expect(denied).toMatchObject({ toolCallId: "call_2", isError: true, details: { denied: true } });

  // Turn UUIDs survive as entry ids, and display data names them.
  const entries = pi.getEntries() as any[];
  expect(entries.filter((e) => e.type === "message").slice(0, 2).map((e) => e.id)).toEqual([USER, REPLY]);
  const displays = entries.filter((e) => e.type === "custom" && e.customType === DISPLAY_ENTRY).map((e) => e.data);
  expect(displays).toEqual([
    {
      targetId: USER, content: "[[skill:explain]] What is this?", metadata: { skill: "explain" },
      attachments: [
        { id: "A1", type: "textSelection", label: "p. 3", textContent: "a quote" },
        { id: "A2", type: "imageCapture", label: "p. 4", textContent: "", pageIndex: 3 },
      ],
    },
    { targetId: REPLY, thinkingSeconds: 2.5 },
  ]);

  // The core can continue it.
  expect(SessionFile.open(dir, ID, () => {}).context().messages).toHaveLength(4);
});

test("a converted or empty file is left alone", () => {
  const dir = mkdtempSync(join(tmpdir(), "oak-legacy-"));
  legacyChat(dir);
  writeFileSync(join(dir, "EMPTY.jsonl"), "");
  expect(migrateLegacyChats(dir, () => {})).toBe(1);
  const after = readFileSync(join(dir, `${ID}.jsonl`), "utf8");
  expect(migrateLegacyChats(dir, () => {})).toBe(0);
  expect(readFileSync(join(dir, `${ID}.jsonl`), "utf8")).toBe(after);
  expect(readFileSync(join(dir, "EMPTY.jsonl"), "utf8")).toBe("");
});

test("a file that does not parse stays where it is", () => {
  const dir = mkdtempSync(join(tmpdir(), "oak-legacy-"));
  writeFileSync(join(dir, "BROKEN.jsonl"), "{not json\n");
  const logs: string[] = [];
  expect(migrateLegacyChats(dir, (m) => logs.push(m))).toBe(0);
  expect(readFileSync(join(dir, "BROKEN.jsonl"), "utf8")).toBe("{not json\n");
  expect(logs[0]).toContain("BROKEN.jsonl not converted");
});

test("skill markers are UI-only, as in the shell", () => {
  expect(modelText("[[skill:summarize]]")).toBe("summarize");
  expect(modelText("[[skill:summarize]] /")).toBe("summarize");
  expect(modelText("[[skill:a]] hello")).toBe("hello");
  expect(modelText("   ")).toBe("Go");
});
