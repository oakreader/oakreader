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
import {
  PROTOCOL_VERSION, RpcError,
  PingParams, ProvidersListParams,
  WordLookupsListParams, WordLookupsSaveParams,
  WordLookupsDeleteParams, WordLookupsClearParams,
  type WordLookupsListResult,
  CompleteParams, ChatParams, OAuthLoginParams,
  CredentialsSetParams, CredentialsGetParams, CredentialsDeleteParams,
  ConfigSetBaseUrlParams, ConfigSetLocalUrlParams, ModelsRefreshParams, CancelRequestParams,
  type CompleteResult, type ChatResult, type ProvidersListResult, type OAuthLoginResult,
  type ProviderSummary,
} from "./protocol.js";
import { RpcPeer, RpcFailure } from "./rpc.js";
import { ConfigStore, FileCredentialStore, dataPaths } from "./store.js";
import { ProviderRegistry, toPiId } from "./providers.js";
import { runChat, toPiMessages } from "./chat.js";
import { Catalog } from "./catalog/db.js";
import { WordLookupStore } from "./catalog/wordLookups.js";

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

/**
 * The catalog, opened lazily.
 *
 * `--library` is where the shell's library lives, which is NOT the sidecar's
 * own data dir: one holds the user's documents, the other holds provider
 * config. Lazy because a shell that never touches the catalog should not pay
 * for opening it, and because a bad path should fail the first catalog call
 * rather than the whole process at startup.
 */
const libraryFlag = process.argv.indexOf("--library");
const libraryPath = libraryFlag !== -1 ? process.argv[libraryFlag + 1] : undefined;
let catalogHandle: Catalog | undefined;

function catalog(): Catalog {
  if (catalogHandle) return catalogHandle;
  if (!libraryPath) {
    throw new RpcFailure(RpcError.notConfigured, "no --library path was given to the sidecar");
  }
  catalogHandle = Catalog.open(libraryPath, { log });
  return catalogHandle;
}

/** `user_id` on every row the Swift app wrote. Kept for wire compatibility. */
const LOCAL_USER = "local";

// --- IO -------------------------------------------------------------------

/**
 * stdout is the protocol channel and nothing else may write to it.
 *
 * A single `console.log` from any dependency injects a non-JSON line into the
 * event stream, and `console.log(obj)` injects *several* — pretty-printed
 * objects span multiple lines, which breaks LF framing, not just one message.
 * The Swift reader logs and skips undecodable lines so this degrades rather
 * than deadlocks, but the noise is untraceable and a logged object that happens
 * to parse as an event with a live request id would be acted on.
 *
 * Route every console method to stderr, which is already the free-form log
 * channel.
 */
for (const method of ["log", "info", "warn", "debug", "trace", "dir"] as const) {
  console[method] = (...args: unknown[]) => {
    process.stderr.write(
      "[console] " + args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" ") + "\n",
    );
  };
}

function log(message: string): void {
  process.stderr.write(`[oak-backend] ${message}\n`);
}

/**
 * The JSON-RPC peer.
 *
 * stdio is the only transport: the shell owns this process, so the channel
 * needs no port, no authentication and no lifecycle of its own, and it is the
 * same on every platform the shell is eventually written for.
 */
const peer = new RpcPeer((line) => process.stdout.write(line), log);

/** In-flight long-running requests, so $/cancelRequest can stop them. */
const aborts = new Map<string, AbortController>();

// --- Handlers -------------------------------------------------------------

async function handleComplete(cmd: CompleteParams, id: string): Promise<CompleteResult> {
  const controller = new AbortController();
  aborts.set(id, controller);
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
      if (event.type === "text_delta") peer.notify("chat/delta", { token: id, text: event.delta });
    }
    const result = await stream.result();
    if (result.stopReason === "error") {
      throw new RpcFailure(classifyProviderError(result.errorMessage), result.errorMessage ?? "provider error");
    }
    return { stopReason: result.stopReason };
  } finally {
    aborts.delete(id);
  }
}

async function handleChat(cmd: ChatParams, id: string): Promise<ChatResult> {
  const controller = new AbortController();
  aborts.set(id, controller);
  try {
    const model = registry.resolveModel(cmd.providerId, cmd.model);
    const stopReason = await runChat(
      registry.models,
      {
        id,
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
        notify: (method, params) => peer.notify(method, params),
        // A reverse request. Correlation is the envelope id, so there is no
        // waiter table to build here and none to scan on the way out.
        executeTool: async (name, args) => {
          const result = await peer.callClient<{ content: string; isError: boolean }>(
            "tool/execute", { token: id, name, args });
          return result;
        },
      },
    );
    return { stopReason };
  } finally {
    aborts.delete(id);
    // Anything still outstanding for this request dies with it.
    peer.failPending(() => false, new Error("request finished"));
  }
}

async function handleListProviders(): Promise<ProvidersListResult> {
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
  return { providers };
}

async function handleOAuthLogin(cmd: OAuthLoginParams, id: string): Promise<OAuthLoginResult> {
  const controller = new AbortController();
  aborts.set(id, controller);
  try {
    await registry.models.login(toPiId(cmd.providerId), "oauth", {
      signal: controller.signal,
      notify: (event: AuthEvent) => {
        if (event.type === "info" || event.type === "progress") {
          peer.notify("oauth/notify", { token: id, kind: event.type, message: event.message });
        } else if (event.type === "auth_url") {
          peer.notify("oauth/notify", { token: id, kind: "auth_url", url: event.url });
        } else {
          peer.notify("oauth/notify", {
            token: id, kind: "device_code",
            userCode: event.userCode, verificationUri: event.verificationUri,
          });
        }
      },
      // Another reverse request. Same machinery as tool/execute -- the whole
      // point of doing this over JSON-RPC is that the second one costs nothing.
      prompt: async (prompt: AuthPrompt) => {
        const answer = await peer.callClient<{ value?: string }>("oauth/prompt", {
          token: id,
          promptType: prompt.type,
          message: prompt.message,
          ...("placeholder" in prompt && prompt.placeholder ? { placeholder: prompt.placeholder } : {}),
          ...(prompt.type === "select"
            ? { options: prompt.options.map((o) => ({ id: o.id, label: o.label })) }
            : {}),
        });
        if (answer.value === undefined) throw new Error("cancelled");
        return answer.value;
      },
    });
    return {};
  } finally {
    aborts.delete(id);
  }
}

/**
 * Register every method. A request handler returns its result or throws; the
 * peer turns either into the response, so there is no per-handler `respond`
 * plumbing and no `success: false` convention.
 */
function registerMethods(): void {
  peer.onRequest("ping", PingParams, () => ({ protocol: PROTOCOL_VERSION, backend: BACKEND_ID }));

  peer.onRequest("complete", CompleteParams, (params, id) => handleComplete(params, id));
  peer.onRequest("chat", ChatParams, (params, id) => handleChat(params, id));
  peer.onRequest("providers/list", ProvidersListParams, () => handleListProviders());
  peer.onRequest("oauth/login", OAuthLoginParams, (params, id) => handleOAuthLogin(params, id));

  peer.onRequest("credentials/set", CredentialsSetParams, async (p) => {
    await credentials.modify(toPiId(p.providerId), async () => ({ type: "api_key", key: p.key }));
    return {};
  });

  peer.onRequest("credentials/get", CredentialsGetParams, async (p) => {
    const auth = await registry.models.getAuth(toPiId(p.providerId));
    return { apiKey: auth?.auth.apiKey ?? null };
  });

  peer.onRequest("credentials/delete", CredentialsDeleteParams, async (p) => {
    await credentials.delete(toPiId(p.providerId));
    return {};
  });

  peer.onRequest("config/setBaseUrl", ConfigSetBaseUrlParams, (p) => {
    config.update((c) => {
      if (p.baseUrl && p.baseUrl.trim() !== "") c.baseUrlOverrides[p.providerId] = p.baseUrl.trim();
      else delete c.baseUrlOverrides[p.providerId];
    });
    return {};
  });

  peer.onRequest("config/setLocalUrl", ConfigSetLocalUrlParams, (p) => {
    config.update((c) => {
      c.localProviders[p.providerId] = p.baseUrl.trim().replace(/\/+$/, "");
    });
    registry.registerLocalProviders();
    return {};
  });

  peer.onRequest("models/refresh", ModelsRefreshParams, async (p) => {
    const result = await registry.models.refresh(
      p.providerId ? { providers: [toPiId(p.providerId)] } : undefined,
    );
    const errors = [...result.errors.entries()].map(([prov, e]) => `${prov}: ${errorMessage(e)}`);
    if (errors.length > 0) throw new RpcFailure(RpcError.providerUnavailable, errors.join("; "));
    return {};
  });

  // --- catalog ----------------------------------------------------------
  // Phase 1: the shell stops opening library.sqlite and asks instead. Exactly
  // one process owns the schema, and it is this one.

  peer.onRequest("catalog/wordLookups/list", WordLookupsListParams, (p): WordLookupsListResult => {
    const store = new WordLookupStore(catalog().db, LOCAL_USER);
    return { lookups: p.itemId === undefined ? store.listAll() : store.list(p.itemId) };
  });

  peer.onRequest("catalog/wordLookups/save", WordLookupsSaveParams, (p) => {
    new WordLookupStore(catalog().db, LOCAL_USER).save(p.lookup);
    return {};
  });

  peer.onRequest("catalog/wordLookups/delete", WordLookupsDeleteParams, (p) => {
    new WordLookupStore(catalog().db, LOCAL_USER).delete(p.id);
    return {};
  });

  peer.onRequest("catalog/wordLookups/clear", WordLookupsClearParams, (p) => {
    new WordLookupStore(catalog().db, LOCAL_USER).clear(p.itemId ?? null);
    return {};
  });

  // LSP's spelling, and the only cancellation mechanism: the abort controller
  // fails the request, which fails anything it spawned.
  peer.onNotification("$/cancelRequest", CancelRequestParams, (p) => {
    aborts.get(p.id)?.abort();
  });
}

/**
 * Map a provider failure onto a code the shell can act on. The old protocol
 * had one error shape carrying only a string, so "re-authenticate" and "retry
 * later" were indistinguishable at the UI layer.
 */
function classifyProviderError(message: string | undefined): number {
  const m = (message ?? "").toLowerCase();
  if (/\b(401|403|unauthor|invalid api key|authentication)\b/.test(m)) return RpcError.providerAuth;
  if (/\b(429|rate.?limit|quota|overloaded)\b/.test(m)) return RpcError.providerRateLimit;
  if (/\b(5\d\d|timeout|econn|network|unavailable)\b/.test(m)) return RpcError.providerUnavailable;
  return RpcError.internalError;
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function handleLine(line: string): void {
  const trimmed = line.endsWith("\r") ? line.slice(0, -1) : line;
  if (trimmed === "") return;
  void peer.handleLine(trimmed);
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

registerMethods();

// Restore any persisted dynamic model lists / warm local discovery, best-effort.
void registry.models.refresh({ allowNetwork: true }).catch(() => {});
log(`started (${BACKEND_ID}, protocol ${PROTOCOL_VERSION}, node ${process.version}, data ${dataDir})`);
