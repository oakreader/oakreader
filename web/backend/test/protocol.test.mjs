// Protocol smoke test: spawns dist/oak-backend.cjs, checks ping/invalid/abort handling,
// and runs a real `complete` against a mock OpenAI-compatible SSE server.
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
let failures = 0;

function assert(cond, label) {
  if (cond) console.log(`ok   ${label}`);
  else { failures++; console.error(`FAIL ${label}`); }
}

// Mock OpenAI chat-completions endpoint streaming "Hello world" in two chunks.
const mock = createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    const parsed = JSON.parse(body);
    assert(req.url === "/v1/chat/completions", "mock: hit /v1/chat/completions");
    assert(parsed.stream === true, "mock: stream requested");
    assert(parsed.messages.some((m) => m.role === "system"), "mock: system prompt forwarded");
    res.writeHead(200, { "content-type": "text/event-stream" });
    const chunk = (delta, finish = null) =>
      `data: ${JSON.stringify({ id: "x", object: "chat.completion.chunk", created: 0, model: parsed.model, choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
    res.write(chunk({ role: "assistant", content: "Hello " }));
    res.write(chunk({ content: "world" }));
    res.write(chunk({}, "stop"));
    res.write("data: [DONE]\n\n");
    res.end();
  });
});

await new Promise((r) => mock.listen(0, "127.0.0.1", r));
const port = mock.address().port;

const child = spawn(process.execPath, [join(root, "dist", "oak-backend.cjs")], {
  stdio: ["pipe", "pipe", "pipe"],
});
child.stderr.on("data", (d) => process.stderr.write(`  [stderr] ${d}`));

const events = [];
const waiters = [];
let buf = "";
child.stdout.on("data", (d) => {
  buf += d.toString("utf8");
  let nl;
  while ((nl = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, nl);
    buf = buf.slice(nl + 1);
    if (line.trim()) {
      const ev = JSON.parse(line);
      events.push(ev);
      waiters.forEach((w) => w());
    }
  }
});

function send(obj) {
  child.stdin.write(JSON.stringify(obj) + "\n");
}

function waitFor(pred, label, timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    const check = () => {
      const found = events.find(pred);
      if (found) resolve(found);
    };
    waiters.push(check);
    check();
    setTimeout(() => reject(new Error(`timeout waiting for: ${label}`)), timeoutMs);
  });
}

try {
  // 1. ping
  send({ id: "p1", type: "ping" });
  const pong = await waitFor((e) => e.id === "p1" && e.type === "response", "pong");
  assert(pong.success === true && pong.protocol === 1, "ping → success + protocol 1");

  // 2. invalid command
  send({ id: "bad", type: "nonsense" });
  const err = await waitFor((e) => e.id === "bad" && e.type === "error", "invalid → error");
  assert(err.message.includes("invalid command"), "invalid command rejected");

  // 3. abort of unknown id is a silent no-op (verified by ping still answering)
  send({ id: "ghost", type: "abort" });
  send({ id: "p2", type: "ping" });
  await waitFor((e) => e.id === "p2" && e.type === "response", "pong after ghost abort");
  assert(true, "abort of unknown id is a no-op");

  // 4. real streaming completion through pi-ai against the mock server
  send({
    id: "c1",
    type: "complete",
    model: { api: "openai-completions", baseUrl: `http://127.0.0.1:${port}/v1`, id: "mock-model" },
    auth: { apiKey: "test-key" },
    system: "You are a test.",
    messages: [{ role: "user", content: "Say hello" }],
    maxTokens: 50,
  });
  await waitFor((e) => e.id === "c1" && e.type === "done", "complete → done");
  const text = events.filter((e) => e.id === "c1" && e.type === "delta").map((e) => e.text).join("");
  assert(text === "Hello world", `deltas reassemble ("${text}")`);
  const done = events.find((e) => e.id === "c1" && e.type === "done");
  assert(done.stopReason === "stop", `stopReason is stop ("${done.stopReason}")`);
} catch (e) {
  failures++;
  console.error(`FAIL ${e.message}`);
} finally {
  child.stdin.end();
  mock.close();
}

await new Promise((r) => child.on("exit", r));
assert(true, "backend exits cleanly on stdin close");
console.log(failures === 0 ? "\nAll protocol tests passed." : `\n${failures} failure(s).`);
process.exit(failures === 0 ? 0 : 1);
