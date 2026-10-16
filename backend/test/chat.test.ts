// History is a pi session file: what the core appends to it must be exactly
// what it sends on chat/entry, and what is in it must reach the model unchanged.
import { test, expect } from "bun:test";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createAssistantMessageEventStream,
  type Api, type AssistantMessage, type Context, type Model, type Models, type UserMessage,
} from "@earendil-works/pi-ai";
import { SessionManager, type FileEntry, type SessionMessageEntry } from "@earendil-works/pi-coding-agent";
import { runChat } from "../src/chat.ts";
import { PiMessage, PiUserMessage } from "../src/protocol.base.ts";
import { DISPLAY_ENTRY, SessionFile } from "../src/session.ts";

function model(id: string): Model<Api> {
  return {
    id, name: id, api: "anthropic-messages", provider: "anthropic",
    baseUrl: "http://127.0.0.1:1", reasoning: true, input: ["text", "image"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1000, maxTokens: 100,
  } as unknown as Model<Api>;
}

const usage = {
  input: 12, output: 34, cacheRead: 5, cacheWrite: 0, totalTokens: 51,
  cost: { input: 0.1, output: 0.2, cacheRead: 0, cacheWrite: 0, total: 0.3 },
};

function reply(m: Model<Api>, over: Partial<AssistantMessage> = {}): AssistantMessage {
  return {
    role: "assistant",
    content: [
      { type: "thinking", thinking: "fine", thinkingSignature: "sig-new" },
      { type: "text", text: "You're welcome." },
    ],
    api: m.api, provider: m.provider, model: m.id,
    usage, stopReason: "stop", timestamp: Date.now(),
    ...over,
  };
}

function user(text: string): UserMessage {
  return { role: "user", content: [{ type: "text", text }], timestamp: Date.now() };
}

/** A Models stub: records each context it is given and answers with the next reply. */
function stubModels(answers: AssistantMessage[]) {
  const contexts: Context[] = [];
  const models = {
    streamSimple(_m: Model<Api>, context: Context) {
      contexts.push(structuredClone(context));
      const answer = answers.shift()!;
      const stream = createAssistantMessageEventStream();
      queueMicrotask(() => {
        stream.push({ type: "start", partial: answer });
        const thinking = answer.content.findIndex((b) => b.type === "thinking");
        if (thinking !== -1) {
          stream.push({ type: "thinking_delta", contentIndex: thinking, delta: "fine", partial: answer });
        }
        if (answer.stopReason === "error" || answer.stopReason === "aborted") {
          stream.push({ type: "error", reason: answer.stopReason, error: answer });
        } else {
          stream.push({ type: "done", reason: answer.stopReason === "toolUse" ? "toolUse" : "stop", message: answer });
        }
      });
      return stream;
    },
  } as unknown as Models;
  return { models, contexts };
}

const tool = { name: "get_time", description: "The time.", inputSchema: { type: "object", properties: {} } };

async function run(dir: string, opts: {
  answers: AssistantMessage[];
  m?: Model<Api>;
  system?: string;
  text?: string;
  display?: Record<string, unknown>;
  denied?: boolean;
}) {
  const { models, contexts } = stubModels(opts.answers);
  const sent: FileEntry[] = [];
  const session = SessionFile.open(dir, "s1", (entry) => sent.push(structuredClone(entry)));
  let error: unknown;
  try {
    await runChat(models, {
      id: "c1", model: opts.m ?? model("m-now"), system: opts.system ?? "You are a test.",
      session, user: user(opts.text ?? "What time is it?"),
      ...(opts.display ? { display: opts.display } : {}),
      tools: [tool], maxTokens: 100, maxIterations: 3,
    }, new AbortController().signal, {
      notify: () => {},
      executeTool: async () => opts.denied
        ? { content: "User denied tool execution.", isError: true, denied: true }
        : { content: "12:34", isError: false },
    });
  } catch (e) {
    error = e;
  }
  return { contexts, sent, error };
}

function fileLines(dir: string): FileEntry[] {
  return readFileSync(join(dir, "s1.jsonl"), "utf8").trim().split("\n").map((l) => JSON.parse(l));
}

test("a new session is written in pi's format, and chat/entry sends the same lines", async () => {
  const dir = mkdtempSync(join(tmpdir(), "oak-session-"));
  const { sent, error } = await run(dir, { answers: [reply(model("m-now"))], display: { content: "[[skill:x]] What time is it?" } });
  expect(error).toBeUndefined();

  const lines = fileLines(dir);
  expect(sent).toEqual(lines);
  expect(lines.map((e) => e.type === "message" ? `message:${e.message.role}` : e.type)).toEqual([
    "session", "model_change", "thinking_level_change",
    "message:system", "message:user", "custom", "message:assistant", "custom",
  ]);

  const [header, ...entries] = lines;
  expect(header).toMatchObject({ type: "session", version: 3, id: "s1", cwd: "" });
  // A single branch: each entry's parent is the one before it.
  entries.forEach((e, i) => {
    if (e.type === "session") throw new Error("second header");
    expect(e.id).toMatch(/^[0-9a-f]{8}$/);
    expect(e.parentId).toBe(i === 0 ? null : (entries[i - 1] as { id: string }).id);
    expect(Number.isNaN(Date.parse(e.timestamp))).toBe(false);
  });
  expect(entries[0]).toMatchObject({ type: "model_change", provider: "anthropic", modelId: "m-now" });
  expect(entries[1]).toMatchObject({ type: "thinking_level_change", thinkingLevel: "off" });
  // The prompt and the tools live in the transcript, as pi keeps them.
  expect(entries[2]).toMatchObject({
    type: "message",
    message: { role: "system", content: "", sections: { prompt: "You are a test." }, toolsAdded: [{ name: "get_time" }] },
  });
  const userEntry = entries[3] as SessionMessageEntry;
  expect(entries[4]).toMatchObject({
    type: "custom", customType: DISPLAY_ENTRY,
    data: { targetId: userEntry.id, content: "[[skill:x]] What time is it?" },
  });
  const assistant = entries[5] as SessionMessageEntry;
  expect(assistant.message).toMatchObject({
    role: "assistant", model: "m-now", usage,
    content: [{ type: "thinking", thinkingSignature: "sig-new" }, { type: "text", text: "You're welcome." }],
  });
  expect(entries[6]).toMatchObject({ type: "custom", customType: DISPLAY_ENTRY, data: { targetId: assistant.id } });
  expect(typeof (entries[6] as { data: { thinkingSeconds: unknown } }).data.thinkingSeconds).toBe("number");
});

test("pi's own SessionManager reads the file as written, and builds the same context", async () => {
  const dir = mkdtempSync(join(tmpdir(), "oak-session-"));
  const m = model("m-now");
  const call = reply(m, {
    content: [{ type: "toolCall", id: "call_1", name: "get_time", arguments: {} }], stopReason: "toolUse",
  });
  await run(dir, { answers: [call, reply(m)], display: { content: "hi" } });
  const path = join(dir, "s1.jsonl");
  const before = readFileSync(path, "utf8");

  const pi = SessionManager.open(path);
  const lines = fileLines(dir);
  expect(pi.getHeader()).toEqual(lines[0] as never);
  expect(pi.getEntries()).toEqual(lines.slice(1) as never);
  const context = pi.buildSessionContext();
  expect(context.messages).toEqual(lines.flatMap((e) => e.type === "message" ? [e.message] : []) as never);
  expect(context.model).toEqual({ provider: "anthropic", modelId: "m-now" });
  // pi found nothing to migrate.
  expect(readFileSync(path, "utf8")).toBe(before);
});

test("the next run sends the stored messages unchanged and adds only what changed", async () => {
  const dir = mkdtempSync(join(tmpdir(), "oak-session-"));
  await run(dir, { answers: [reply(model("m-old"))], m: model("m-old") });
  const before = fileLines(dir);
  const stored = before.flatMap((e) => e.type === "message" ? [e.message] : []);

  const { contexts, sent } = await run(dir, { answers: [reply(model("m-now"))], text: "Thanks" });
  // Signatures, usage, the old model's name and real timestamps all survive.
  expect(contexts[0]!.messages.slice(0, stored.length)).toEqual(stored as never);
  expect(contexts[0]!.messages[stored.length]).toMatchObject({ role: "user", content: [{ text: "Thanks" }] });
  // Same prompt and tools: no new system message. New model: a model_change.
  expect(sent.map((e) => e.type === "message" ? `message:${e.message.role}` : e.type)).toEqual([
    "model_change", "message:user", "message:assistant", "custom",
  ]);
  expect(fileLines(dir)).toEqual([...before, ...sent]);
});

test("a changed prompt is a system message that replaces the prompt section", async () => {
  const dir = mkdtempSync(join(tmpdir(), "oak-session-"));
  await run(dir, { answers: [reply(model("m-now"))] });
  const { sent } = await run(dir, { answers: [reply(model("m-now"))], system: "You are new." });
  expect(sent[0]).toMatchObject({ type: "message", message: { role: "system", sections: { prompt: "You are new." } } });
  expect((sent[0] as SessionMessageEntry).message).not.toHaveProperty("toolsAdded");
});

test("a tool call and its result are stored, and a denial is in the result's details", async () => {
  const dir = mkdtempSync(join(tmpdir(), "oak-session-"));
  const m = model("m-now");
  const call = reply(m, {
    content: [{ type: "toolCall", id: "call_1", name: "get_time", arguments: {} }], stopReason: "toolUse",
  });
  await run(dir, { answers: [call, reply(m)], denied: true });
  const results = fileLines(dir).flatMap((e) => e.type === "message" && e.message.role === "toolResult" ? [e.message] : []);
  expect(results).toHaveLength(1);
  expect(results[0]).toMatchObject({ toolCallId: "call_1", isError: true, details: { denied: true } });
});

test("a failed reply is stored before the request fails", async () => {
  const dir = mkdtempSync(join(tmpdir(), "oak-session-"));
  const { error } = await run(dir, {
    answers: [reply(model("m-now"), { stopReason: "error", errorMessage: "overloaded", content: [] })],
  });
  expect((error as Error)?.message).toBe("overloaded");
  const last = fileLines(dir).at(-1) as SessionMessageEntry;
  expect(last.message).toMatchObject({ role: "assistant", stopReason: "error", errorMessage: "overloaded" });
});

test("the border keeps fields it does not know and rejects what pi cannot use", () => {
  const withFuture = { ...user("hi"), somethingPiAddsLater: { x: 1 } };
  expect(PiUserMessage.parse(withFuture)).toEqual(withFuture as never);
  expect(PiUserMessage.safeParse({ role: "assistant", content: [], timestamp: 1 }).success).toBe(false);
  expect(PiMessage.safeParse({ role: "system", content: "x", timestamp: 1 }).success).toBe(false);
});
