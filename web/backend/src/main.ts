/**
 * OakReader AI sidecar, protocol v2. JSONL over stdio: commands in on stdin,
 * events out on stdout, free-form logging on stderr. Owns the provider
 * catalog, credentials (auth.json), OAuth flows, endpoint overrides, and the
 * agentic chat loop; the Swift shell owns UI, sessions, and tool execution.
 *
 * See src/protocol.ts and docs/architecture/node-backend-migration.md.
 */
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import type { AuthEvent, AuthPrompt, ThinkingLevel } from "@earendil-works/pi-ai";
import { Command, PROTOCOL_VERSION, type Event, type ProviderSummary } from "./protocol.js";
import { ConfigStore, FileCredentialStore, dataPaths } from "./store.js";
import { ProviderRegistry, toPiId } from "./providers.js";
import { runChat, toPiMessages } from "./chat.js";

const BACKEND_ID = "oak-backend 0.2.0";

// --- Data dir -------------------------------------------------------------

function resolveDataDir(): string {
  const flag = process.argv.indexOf("--data-dir");
  if (flag !== -1 && process.argv[flag + 1]) return process.argv[flag + 1];
  return join(homedir(), "OakReader", "backend");
}

const dataDir = resolveDataDir();
mkdirSync(dataDir, { recursive: true });
const paths = dataPaths(dataDir);
const credentials = new FileCredentialStore(paths.auth);
const config = new ConfigStore(paths.config);
const registry = new ProviderRegistry(credentials, config);

// --- IO -------------------------------------------------------------------

function emit(event: Event): void {
  process.stdout.write(JSON.stringify(event) + "\n");
}

function log(message: string): void {
  process.stderr.write(`[oak-backend] ${message}\n`);
}

function respond(id: string, command: string, success: boolean, extra: Partial<Extract<Event, { type: "response" }>> = {}): void {
  emit({ id, type: "response", command, success, ...extra });
}

// --- Request state --------------------------------------------------------

const aborts = new Map<string, AbortController>();

interface ToolWaiter {
  resolve(result: { content: string; isError: boolean }): void;
}
/** chatId:callId → waiter for the client's tool_result. */
const toolWaiters = new Map<string, ToolWaiter>();

interface PromptWaiter {
  resolve(value: string | undefined): void;
}
/** loginId:promptId → waiter for the client's oauth_prompt_result. */
const promptWaiters = new Map<string, PromptWaiter>();

// --- Handlers -------------------------------------------------------------

async function handleComplete(cmd: Extract<Command, { type: "complete" }>): Promise<void> {
  const controller = new AbortController();
  aborts.set(cmd.id, controller);
  try {
    let model = registry.resolveModel(cmd.providerId, cmd.model);
    if (cmd.baseUrl) {
      const trimmed = cmd.baseUrl.trim();
      model = { ...model, baseUrl: trimmed.endsWith("#") ? trimmed.slice(0, -1).trim() : trimmed.replace(/\/+$/, "") };
    }
    const context = {
      ...(cmd.system ? { systemPrompt: cmd.system } : {}),
      messages: toPiMessages(cmd.messages, model),
    };
    const stream = registry.models.streamSimple(model, context, {
      signal: controller.signal,
      maxTokens: cmd.maxTokens,
      ...(cmd.apiKey ? { apiKey: cmd.apiKey } : {}),
    });
    for await (const event of stream) {
      if (event.type === "text_delta") emit({ id: cmd.id, type: "delta", text: event.delta });
    }
    const result = await stream.result();
    if (result.stopReason === "error") {
      emit({ id: cmd.id, type: "error", message: result.errorMessage ?? "provider error" });
    } else {
      emit({ id: cmd.id, type: "done", stopReason: result.stopReason });
    }
  } catch (err) {
    emit({ id: cmd.id, type: "error", message: errorMessage(err) });
  } finally {
    aborts.delete(cmd.id);
  }
}

async function handleChat(cmd: Extract<Command, { type: "chat" }>): Promise<void> {
  const controller = new AbortController();
  aborts.set(cmd.id, controller);
  try {
    const model = registry.resolveModel(cmd.providerId, cmd.model);
    await runChat(
      registry.models,
      {
        id: cmd.id,
        model,
        system: cmd.system,
        messages: cmd.messages,
        tools: cmd.tools,
        maxTokens: cmd.maxTokens,
        reasoning: cmd.reasoning as ThinkingLevel | undefined,
        maxIterations: cmd.maxIterations,
      },
      controller.signal,
      {
        emit,
        executeTool: (callId, name, args) =>
          new Promise((resolve) => {
            toolWaiters.set(`${cmd.id}:${callId}`, { resolve });
            emit({ id: cmd.id, type: "tool_exec", callId, name, args });
            controller.signal.addEventListener("abort", () => {
              if (toolWaiters.delete(`${cmd.id}:${callId}`)) {
                resolve({ content: "aborted", isError: true });
              }
            });
          }),
      },
    );
  } catch (err) {
    emit({ id: cmd.id, type: "error", message: errorMessage(err) });
  } finally {
    aborts.delete(cmd.id);
    for (const key of toolWaiters.keys()) {
      if (key.startsWith(`${cmd.id}:`)) toolWaiters.delete(key);
    }
  }
}

async function handleListProviders(id: string): Promise<void> {
  const providers: ProviderSummary[] = [];
  for (const oakId of registry.oakProviderIds()) {
    const provider = registry.provider(oakId);
    if (!provider) continue;
    const piId = toPiId(oakId);
    let configured = false;
    let source: string | undefined;
    try {
      const check = await registry.models.checkAuth(piId);
      configured = check !== undefined;
      source = check?.source;
    } catch {
      // OAuth refresh failure etc. — still "configured", needs re-login to use.
      configured = true;
      source = "OAuth (needs re-login)";
    }
    const oauthAvailable = provider.auth.oauth !== undefined;
    const isLocal = registry.isLocal(oakId);
    providers.push({
      id: oakId,
      name: provider.name,
      models: registry.models.getModels(piId).map((m) => ({
        id: m.id,
        name: m.name,
        reasoning: m.reasoning,
        contextWindow: m.contextWindow,
        maxTokens: m.maxTokens,
        vision: m.input.includes("image"),
      })),
      defaultModel: registry.defaultModelId(oakId),
      auth: {
        kind: isLocal ? "none" : oauthAvailable && provider.auth.apiKey === undefined ? "oauth" : "api-key",
        oauthAvailable,
        configured: isLocal ? true : configured,
        source,
      },
      isLocal,
      baseUrlOverride: config.get().baseUrlOverrides[oakId],
      localUrl: isLocal ? (config.get().localProviders[oakId] ?? provider.baseUrl) : undefined,
    });
  }
  respond(id, "list_providers", true, { providers });
}

async function handleOAuthLogin(cmd: Extract<Command, { type: "oauth_login" }>): Promise<void> {
  const controller = new AbortController();
  aborts.set(cmd.id, controller);
  let promptCounter = 0;
  try {
    await registry.models.login(toPiId(cmd.providerId), "oauth", {
      signal: controller.signal,
      notify: (event: AuthEvent) => {
        if (event.type === "info" || event.type === "progress") {
          emit({ id: cmd.id, type: "oauth_notify", kind: event.type, message: event.message });
        } else if (event.type === "auth_url") {
          emit({ id: cmd.id, type: "oauth_notify", kind: "auth_url", url: event.url });
        } else {
          emit({
            id: cmd.id, type: "oauth_notify", kind: "device_code",
            userCode: event.userCode, verificationUri: event.verificationUri,
          });
        }
      },
      prompt: (prompt: AuthPrompt) =>
        new Promise<string>((resolve, reject) => {
          const promptId = `p${++promptCounter}`;
          promptWaiters.set(`${cmd.id}:${promptId}`, {
            resolve: (value) => {
              if (value === undefined) reject(new Error("cancelled"));
              else resolve(value);
            },
          });
          emit({
            id: cmd.id, type: "oauth_prompt", promptId,
            promptType: prompt.type, message: prompt.message,
            ...("placeholder" in prompt && prompt.placeholder ? { placeholder: prompt.placeholder } : {}),
            ...(prompt.type === "select"
              ? { options: prompt.options.map((o) => ({ id: o.id, label: o.label })) }
              : {}),
          });
          prompt.signal?.addEventListener("abort", () => {
            if (promptWaiters.delete(`${cmd.id}:${promptId}`)) reject(new Error("superseded"));
          });
        }),
    });
    respond(cmd.id, "oauth_login", true);
  } catch (err) {
    respond(cmd.id, "oauth_login", false, { message: errorMessage(err) });
  } finally {
    aborts.delete(cmd.id);
    for (const key of promptWaiters.keys()) {
      if (key.startsWith(`${cmd.id}:`)) promptWaiters.delete(key);
    }
  }
}

async function dispatch(cmd: Command): Promise<void> {
  switch (cmd.type) {
    case "ping":
      respond(cmd.id, "ping", true, { protocol: PROTOCOL_VERSION, backend: BACKEND_ID });
      return;

    case "abort":
      aborts.get(cmd.id)?.abort();
      return;

    case "complete":
      void handleComplete(cmd);
      return;

    case "chat":
      void handleChat(cmd);
      return;

    case "tool_result": {
      const waiter = toolWaiters.get(`${cmd.id}:${cmd.callId}`);
      toolWaiters.delete(`${cmd.id}:${cmd.callId}`);
      waiter?.resolve({ content: cmd.content, isError: cmd.isError });
      return;
    }

    case "list_providers":
      await handleListProviders(cmd.id);
      return;

    case "set_api_key":
      await credentials.modify(toPiId(cmd.providerId), async () => ({ type: "api_key", key: cmd.key }));
      respond(cmd.id, "set_api_key", true);
      return;

    case "get_api_key": {
      try {
        const auth = await registry.models.getAuth(toPiId(cmd.providerId));
        respond(cmd.id, "get_api_key", true, { apiKey: auth?.auth.apiKey ?? null });
      } catch (err) {
        respond(cmd.id, "get_api_key", false, { message: errorMessage(err) });
      }
      return;
    }

    case "delete_credential":
      await credentials.delete(toPiId(cmd.providerId));
      respond(cmd.id, "delete_credential", true);
      return;

    case "oauth_login":
      void handleOAuthLogin(cmd);
      return;

    case "oauth_prompt_result": {
      const waiter = promptWaiters.get(`${cmd.id}:${cmd.promptId}`);
      promptWaiters.delete(`${cmd.id}:${cmd.promptId}`);
      waiter?.resolve(cmd.value);
      return;
    }

    case "set_base_url":
      config.update((c) => {
        if (cmd.baseUrl && cmd.baseUrl.trim() !== "") c.baseUrlOverrides[cmd.providerId] = cmd.baseUrl.trim();
        else delete c.baseUrlOverrides[cmd.providerId];
      });
      respond(cmd.id, "set_base_url", true);
      return;

    case "set_local_url":
      config.update((c) => {
        c.localProviders[cmd.providerId] = cmd.baseUrl.trim().replace(/\/+$/, "");
      });
      registry.registerLocalProviders();
      respond(cmd.id, "set_local_url", true);
      return;

    case "refresh_models": {
      const result = await registry.models.refresh(
        cmd.providerId ? { providers: [toPiId(cmd.providerId)] } : undefined,
      );
      const errors = [...result.errors.entries()].map(([p, e]) => `${p}: ${errorMessage(e)}`);
      respond(cmd.id, "refresh_models", errors.length === 0, {
        message: errors.length > 0 ? errors.join("; ") : undefined,
      });
      return;
    }
  }
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function handleLine(line: string): void {
  const trimmed = line.endsWith("\r") ? line.slice(0, -1) : line;
  if (trimmed === "") return;
  let raw: unknown;
  try {
    raw = JSON.parse(trimmed);
  } catch {
    log(`unparseable line: ${trimmed.slice(0, 200)}`);
    return;
  }
  const parsed = Command.safeParse(raw);
  if (!parsed.success) {
    const id = typeof (raw as { id?: unknown })?.id === "string" ? (raw as { id: string }).id : "";
    emit({ id, type: "error", message: `invalid command: ${parsed.error.message}` });
    return;
  }
  void dispatch(parsed.data).catch((err) => {
    emit({ id: parsed.data.id, type: "error", message: errorMessage(err) });
  });
}

// Strict JSONL framing: split on LF bytes only. Node's readline also splits on
// U+2028/U+2029, which are legal inside JSON strings (and OakReader ships
// arbitrary document text), so it is not protocol-safe here.
let buffer: Buffer = Buffer.alloc(0);
process.stdin.on("data", (chunk: Buffer) => {
  buffer = buffer.length === 0 ? chunk : Buffer.concat([buffer, chunk]);
  let newline: number;
  while ((newline = buffer.indexOf(0x0a)) !== -1) {
    const line = buffer.subarray(0, newline).toString("utf8");
    buffer = buffer.subarray(newline + 1);
    handleLine(line);
  }
});
process.stdin.on("end", () => {
  for (const controller of aborts.values()) controller.abort();
  process.exit(0);
});

// Restore any persisted dynamic model lists / warm local discovery, best-effort.
void registry.models.refresh({ allowNetwork: true }).catch(() => {});
log(`started (${BACKEND_ID}, protocol ${PROTOCOL_VERSION}, node ${process.version}, data ${dataDir})`);
