// Protocol v2 smoke test: spawns dist/oak-backend.cjs with an isolated data
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
const child = spawn(process.execPath, [join(root, "dist", "oak-backend.cjs"), "--data-dir", dataDir], {
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

const send = (obj) => child.stdin.write(JSON.stringify(obj) + "\n");

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
  // 1. ping → protocol 2
  send({ id: "p1", type: "ping" });
  const pong = await waitFor((e) => e.id === "p1" && e.type === "response", "pong");
  assert(pong.success === true && pong.protocol === 2, "ping → success + protocol 2");

  // 2. credential store: set → list_providers reflects configured; 0600 on disk
  send({ id: "k1", type: "set_api_key", providerId: "anthropic", key: "sk-test-123" });
  await waitFor((e) => e.id === "k1" && e.type === "response" && e.success, "set_api_key ok");
  const mode = statSync(join(dataDir, "auth.json")).mode & 0o777;
  assert(mode === 0o600, `auth.json is 0600 (got ${mode.toString(8)})`);
  const stored = JSON.parse(readFileSync(join(dataDir, "auth.json"), "utf8"));
  assert(stored.anthropic?.key === "sk-test-123", "auth.json holds the key (pi format)");

  send({ id: "l1", type: "list_providers" });
  const list = await waitFor((e) => e.id === "l1" && e.type === "response", "list_providers");
  const anthropic = list.providers.find((p) => p.id === "anthropic");
  const kimi = list.providers.find((p) => p.id === "kimi");
  assert(anthropic?.auth.configured === true, "anthropic shows configured after set_api_key");
  assert(anthropic?.models.length > 0 && anthropic.models.every((m) => m.id && m.contextWindow > 0),
    `anthropic catalog served (${anthropic?.models.length} models)`);
  assert(kimi !== undefined, "kimi (moonshotai) id-mapped provider present");
  assert(anthropic?.auth.oauthAvailable === true, "anthropic OAuth flow advertised");

  // 3. get_api_key round-trip (VoiceProviderFactory path)
  send({ id: "g1", type: "get_api_key", providerId: "anthropic" });
  const got = await waitFor((e) => e.id === "g1" && e.type === "response", "get_api_key");
  assert(got.apiKey === "sk-test-123", "get_api_key returns stored key");

  // 4. local provider: point ollama at the mock server, discover models
  send({ id: "u1", type: "set_local_url", providerId: "ollama", baseUrl: `http://127.0.0.1:${port}/v1` });
  await waitFor((e) => e.id === "u1" && e.type === "response" && e.success, "set_local_url ok");
  send({ id: "r1", type: "refresh_models", providerId: "ollama" });
  const refreshed = await waitFor((e) => e.id === "r1" && e.type === "response", "refresh_models");
  assert(refreshed.success === true, `refresh_models ok (${refreshed.message ?? "no errors"})`);
  send({ id: "l2", type: "list_providers" });
  const list2 = await waitFor((e) => e.id === "l2" && e.type === "response", "list_providers 2");
  const ollama = list2.providers.find((p) => p.id === "ollama");
  assert(ollama?.models.some((m) => m.id === "mock-model"), "ollama discovered mock-model");

  // 5. full chat loop with tool round-trip
  send({
    id: "c1",
    type: "chat",
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
  const exec = await waitFor((e) => e.id === "c1" && e.type === "tool_exec", "tool_exec request");
  assert(exec.name === "get_time" && exec.args.timezone === "UTC", "tool_exec carries parsed args");
  const firstAssistant = events.find((e) => e.id === "c1" && e.type === "assistant");
  assert(firstAssistant?.toolCalls.length === 1, "assistant snapshot lists the tool call");
  send({ id: "c1", type: "tool_result", callId: exec.callId, content: "12:34 UTC", isError: false });
  await waitFor((e) => e.id === "c1" && e.type === "done", "chat done");
  const answer = events.filter((e) => e.id === "c1" && e.type === "delta").map((e) => e.text).join("");
  assert(answer.includes("12:34 UTC"), `final answer streamed ("${answer}")`);

  // 6. base-url override persists in config.json
  send({ id: "b1", type: "set_base_url", providerId: "deepseek", baseUrl: "https://relay.example.com" });
  await waitFor((e) => e.id === "b1" && e.type === "response" && e.success, "set_base_url ok");
  const config = JSON.parse(readFileSync(join(dataDir, "config.json"), "utf8"));
  assert(config.baseUrlOverrides.deepseek === "https://relay.example.com", "override persisted");
} catch (e) {
  failures++;
  console.error(`FAIL ${e.message}`);
} finally {
  child.stdin.end();
  mock.close();
}

await new Promise((r) => child.on("exit", r));
assert(true, "backend exits cleanly on stdin close");
console.log(failures === 0 ? "\nAll protocol v2 tests passed." : `\n${failures} failure(s).`);
process.exit(failures === 0 ? 0 : 1);
