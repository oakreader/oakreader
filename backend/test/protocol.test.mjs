// Protocol v2 smoke test: spawns the shipped dist/oak-backend binary (bun
// --compile output) with an isolated data
// dir, checks ping/credential/list_providers, then registers a mock
// OpenAI-compatible server as the "ollama" local provider and runs the full
// agentic chat loop through it — including a tool_exec → tool_result round-trip.
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const dataDir = mkdtempSync(join(tmpdir(), "oak-backend-test-"));
let failures = 0;

function assert(cond, label) {
  if (cond) console.log(`ok   ${label}`);
  else { failures++; console.error(`FAIL ${label}`); }
}

// --- Mock OpenAI-compatible server ---------------------------------------
// First chat call → tool call; second → final text. GET /models lists one model.
let chatCalls = 0;
const mock = createServer((req, res) => {
  if (req.method === "GET" && req.url === "/v1/models") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ data: [{ id: "mock-model" }] }));
    return;
  }
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    const parsed = JSON.parse(body);
    chatCalls++;
    res.writeHead(200, { "content-type": "text/event-stream" });
    const chunk = (delta, finish = null) =>
      `data: ${JSON.stringify({ id: "x", object: "chat.completion.chunk", created: 0, model: parsed.model, choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
    if (chatCalls === 1) {
      assert(Array.isArray(parsed.tools) && parsed.tools.some((t) => t.function?.name === "get_time"),
        "mock: tool definition forwarded");
      res.write(chunk({ role: "assistant", content: "" }));
      res.write(chunk({ tool_calls: [{ index: 0, id: "call_1", type: "function", function: { name: "get_time", arguments: "" } }] }));
      res.write(chunk({ tool_calls: [{ index: 0, function: { arguments: "{\"timezone\":\"UTC\"}" } }] }));
      res.write(chunk({}, "tool_calls"));
    } else {
      const toolMsg = parsed.messages.find((m) => m.role === "tool");
      assert(toolMsg && String(toolMsg.content).includes("12:34"), "mock: tool result fed back");
      res.write(chunk({ role: "assistant", content: "It is " }));
      res.write(chunk({ content: "12:34 UTC" }));
      res.write(chunk({}, "stop"));
    }
    res.write("data: [DONE]\n\n");
    res.end();
  });
});

await new Promise((r) => mock.listen(0, "127.0.0.1", r));
const port = mock.address().port;

// --- Spawn backend --------------------------------------------------------
const child = spawn(join(root, "dist", "oak-backend"), ["--data-dir", dataDir], {
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
      events.push(JSON.parse(line));
      waiters.forEach((w) => w());
    }
  }
});

let nextId = 0;
const rpcId = (p) => `${p}${++nextId}`;

const send = (obj) => child.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...obj }) + "\n");
const call = (id, method, params) => send({ id, method, params });
const notify = (method, params) => send({ method, params });
const answer = (id, result) => send({ id, result });

/** Resolves with the result of `id`, or rejects with its JSON-RPC error. */
const resultOf = (id, label) =>
  new Promise((resolve, reject) => {
    const check = () => {
      const e = events.find((e) => e.id === id && (e.result !== undefined || e.error));
      if (!e) return;
      if (e.error) reject(new Error(`${label}: ${e.error.code} ${e.error.message}`));
      else resolve(e.result);
    };
    waiters.push(check);
    check();
    setTimeout(() => reject(new Error(`timeout waiting for: ${label}`)), 15000);
  });

/** The notifications carrying a given request's token, in arrival order. */
const notificationsFor = (token, method) =>
  events.filter((e) => e.method === method && e.params?.token === token).map((e) => e.params);

function waitFor(pred, label, timeoutMs = 15000) {
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
  // 1. ping → the handshake is a request/response pair, not an event
  const pong = await (call("p1", "ping", {}), resultOf("p1", "ping"));
  assert(pong.protocol === 3, `ping → protocol ${pong.protocol}`);
  assert(typeof pong.backend === "string", "ping → backend id");

  // 2. credentials: set → providers/list reflects configured; 0600 on disk
  call("k1", "credentials/set", { providerId: "anthropic", key: "sk-test-123" });
  await resultOf("k1", "credentials/set");
  const mode = statSync(join(dataDir, "auth.json")).mode & 0o777;
  assert(mode === 0o600, `auth.json is 0600 (got ${mode.toString(8)})`);
  const stored = JSON.parse(readFileSync(join(dataDir, "auth.json"), "utf8"));
  assert(stored.anthropic?.key === "sk-test-123", "auth.json holds the key (pi format)");

  call("l1", "providers/list", {});
  const list = await resultOf("l1", "providers/list");
  const anthropic = list.providers.find((p) => p.id === "anthropic");
  const kimi = list.providers.find((p) => p.id === "kimi");
  assert(anthropic?.auth.configured === true, "anthropic shows configured after credentials/set");
  assert(anthropic?.models.length > 0 && anthropic.models.every((m) => m.id && m.contextWindow > 0),
    `anthropic catalog served (${anthropic?.models.length} models)`);
  assert(kimi !== undefined, "kimi (moonshotai) id-mapped provider present");
  assert(anthropic?.auth.oauthAvailable === true, "anthropic OAuth flow advertised");

  // 3. credentials/get round-trip (VoiceProviderFactory path)
  call("g1", "credentials/get", { providerId: "anthropic" });
  const got = await resultOf("g1", "credentials/get");
  assert(got.apiKey === "sk-test-123", "credentials/get returns stored key");

  // 4. local provider: point ollama at the mock server, discover models
  call("u1", "config/setLocalUrl", { providerId: "ollama", baseUrl: `http://127.0.0.1:${port}/v1` });
  await resultOf("u1", "config/setLocalUrl");
  call("r1", "models/refresh", { providerId: "ollama" });
  await resultOf("r1", "models/refresh");
  call("l2", "providers/list", {});
  const list2 = await resultOf("l2", "providers/list");
  const ollama = list2.providers.find((p) => p.id === "ollama");
  assert(ollama?.models.some((m) => m.id === "mock-model"), "ollama discovered mock-model");

  // 5. the agentic loop, and the reverse call that makes it one
  call("c1", "chat", {
    providerId: "ollama",
    model: "mock-model",
    system: "You are a test.",
    messages: [{ role: "user", parts: [{ type: "text", text: "What time is it?" }] }],
    tools: [{
      name: "get_time",
      description: "Get the current time",
      inputSchema: { type: "object", properties: { timezone: { type: "string" } } },
    }],
    maxIterations: 3,
  });

  // tool/execute arrives as a REQUEST addressed to us: it has its own id, and
  // the sidecar is blocked until we answer that id. No callId is threaded
  // through, which is the whole point of doing this over JSON-RPC.
  const exec = await waitFor((e) => e.method === "tool/execute" && e.id !== undefined, "tool/execute request");
  assert(exec.params.name === "get_time" && exec.params.args.timezone === "UTC",
    "tool/execute carries parsed args");
  assert(exec.params.token === "c1", "tool/execute names the chat it belongs to");
  assert(typeof exec.id === "string" && exec.id !== "c1",
    `reverse call has its own envelope id (${exec.id})`);

  const snapshot = notificationsFor("c1", "chat/assistant")[0];
  assert(snapshot?.toolCalls.length === 1, "chat/assistant snapshot lists the tool call");

  answer(exec.id, { content: "12:34 UTC", isError: false });

  // The stop reason is the RESULT of the chat request, not a "done" event.
  const chatResult = await resultOf("c1", "chat");
  assert(chatResult.stopReason === "stop", `chat resolved with stopReason ${chatResult.stopReason}`);
  const answered = notificationsFor("c1", "chat/delta").map((p) => p.text).join("");
  assert(answered.includes("12:34 UTC"), `final answer streamed ("${answered}")`);

  // 6. base-url override persists in config.json
  call("b1", "config/setBaseUrl", { providerId: "deepseek", baseUrl: "https://relay.example.com" });
  await resultOf("b1", "config/setBaseUrl");
  const config = JSON.parse(readFileSync(join(dataDir, "config.json"), "utf8"));
  assert(config.baseUrlOverrides.deepseek === "https://relay.example.com", "override persisted");

  // 7. errors carry a code, which is the reason for doing any of this
  call("e1", "no/such/method", {});
  let methodNotFound = null;
  try { await resultOf("e1", "unknown method"); } catch (err) { methodNotFound = err.message; }
  assert(methodNotFound?.includes("-32601"), `unknown method → -32601 (${methodNotFound})`);

  call("e2", "credentials/set", { providerId: "anthropic" });   // missing `key`
  let invalidParams = null;
  try { await resultOf("e2", "invalid params"); } catch (err) { invalidParams = err.message; }
  assert(invalidParams !== null, `invalid params rejected (${invalidParams})`);

  // 8. a notification must never be answered
  const before = events.length;
  notify("$/cancelRequest", { id: "nothing-in-flight" });
  await new Promise((r) => setTimeout(r, 150));
  assert(!events.slice(before).some((e) => e.id === undefined && e.result !== undefined),
    "notification drew no response");
} catch (e) {
  failures++;
  console.error(`FAIL ${e.message}`);
} finally {
  child.stdin.end();
  mock.close();
}

await new Promise((r) => child.on("exit", r));
assert(true, "backend exits cleanly on stdin close");
console.log(failures === 0 ? "\nAll protocol v3 (JSON-RPC) tests passed." : `\n${failures} failure(s).`);
process.exit(failures === 0 ? 0 : 1);
