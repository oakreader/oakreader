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
  PromptsComposeParams, SkillsListParams, type SkillsListResult,
  SkillsBodyParams, type SkillsBodyResult,
  ToolsListParams, ToolsRunParams,
  type ToolsListResult, type ToolsRunResult, type PromptsComposeResult,
  CatalogValidateParams, type CatalogValidateResult,
  ReferencesGetParams, ReferencesSaveParams, type ReferencesGetResult,
  CiteKeysProposeParams, CiteKeysSaveParams, CiteKeysAssignParams,
  type CiteKeysProposeResult, type CiteKeysAssignResult,
  PropertiesListParams, PropertiesUpsertOptionParams, PropertiesDeleteOptionParams,
  PropertiesAddSelectValueParams, PropertiesRemoveSelectValueParams,
  type PropertiesListResult,
  ItemsListParams, ItemsMergeParams, ItemsInsertParams,
  ItemsUpdateFieldParams, ItemsSetTrashedParams, ItemsRemoveParams,
  type ItemsListResult, CollectionsListParams, CollectionsFindBySourceParams, CollectionsUpsertParams,
  CollectionsDeleteParams, CollectionsSetMembershipParams,
  type CollectionsListResult, type CollectionsFindBySourceResult,
  ConversationsListParams, ConversationsCreateParams,
  ConversationsUpdateParams, ConversationsDeleteParams,
  type ConversationsListResult,
  AnnotationsListParams, AnnotationsGetParams,
  AnnotationsUpsertParams, AnnotationsDeleteParams,
  type AnnotationsListResult, type AnnotationsGetResult,
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
import { ConfigStore, FileCredentialStore, dataPaths, migrateLegacyLayout } from "./store.js";
import { ProviderRegistry, toPiId } from "./providers.js";
import { runChat, toPiMessages } from "./chat.js";
import { PromptLibrary } from "./prompts.js";
import { PORTABLE_TOOLS, runTool } from "./tools.js";
import {
  loadSkills, locateBin, promptSection, readBody, skillDirectories, userSkillDirectory,
} from "./skills.js";
import { Catalog } from "./catalog/db.js";
import { MIGRATIONS } from "./catalog/schema.js";
import { WordLookupStore } from "./catalog/wordLookups.js";
import { AnnotationStore } from "./catalog/annotations.js";
import { ConversationStore, type ConversationScope } from "./catalog/conversations.js";
import { CollectionStore } from "./catalog/collections.js";
import { ItemStore } from "./catalog/items.js";
import { PropertyStore } from "./catalog/properties.js";
import { ReferenceStore } from "./catalog/references.js";
import { CiteKeyStore } from "./catalog/citekeys.js";

const BACKEND_ID = "oak-backend 0.2.0";

// --- Data dir -------------------------------------------------------------

function resolveDataDir(): string {
  const flag = process.argv.indexOf("--data-dir");
  if (flag !== -1 && process.argv[flag + 1]) return process.argv[flag + 1];
  return join(homedir(), "OakReader", "agent");
}

const dataDir = resolveDataDir();
mkdirSync(dataDir, { recursive: true });
migrateLegacyLayout(dataDir);
const paths = dataPaths(dataDir);
const credentials = new FileCredentialStore(paths.credentials);
const config = new ConfigStore(paths.settings);
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

/** Prompt files, resolved once at startup. */
const prompts = PromptLibrary.load();

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
  peer.onRequest("ping", PingParams, () => ({
    protocol: PROTOCOL_VERSION, backend: BACKEND_ID,
    schemaVersion: MIGRATIONS.length,
  }));

  peer.onRequest("complete", CompleteParams, (params, id) => handleComplete(params, id));
  peer.onRequest("chat", ChatParams, (params, id) => handleChat(params, id));
  peer.onRequest("providers/list", ProvidersListParams, () => handleListProviders());
  peer.onRequest("oauth/login", OAuthLoginParams, (params, id) => handleOAuthLogin(params, id));

  peer.onRequest("credentials/set", CredentialsSetParams, async (p) => {
    await credentials.modify(toPiId(p.providerId), async () => ({ type: "api_key", key: p.key }));
    return {};
  });

  peer.onRequest("credentials/get", CredentialsGetParams, async (p) => {
    // The registry answers for providers it knows, which is how an OAuth
    // provider's key gets resolved. It knows nothing about a provider with no
    // models — ElevenLabs and Fish Audio only do voice — so the store itself
    // is the fallback, and it is the thing actually holding the key either way.
    const auth = await registry.models.getAuth(toPiId(p.providerId));
    if (auth?.auth.apiKey !== undefined) return { apiKey: auth.auth.apiKey };

    const stored = await credentials.read(toPiId(p.providerId));
    return { apiKey: stored?.type === "api_key" ? stored.key : null };
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

  peer.onRequest("tools/list", ToolsListParams, (): ToolsListResult => ({
    tools: PORTABLE_TOOLS,
  }));

  peer.onRequest("tools/run", ToolsRunParams, async (p): Promise<ToolsRunResult> => {
    // Arguments arrive as the model wrote them; every portable tool reads
    // strings, so anything else is stringified rather than refused.
    const args: Record<string, string> = {};
    for (const [key, value] of Object.entries(p.args)) {
      args[key] = typeof value === "string" ? value : JSON.stringify(value);
    }
    return await runTool(p.name, args, p.workingDirectory, p.allowedPaths);
  });

  peer.onRequest("skills/body", SkillsBodyParams, (p): SkillsBodyResult => {
    const { skills } = loadSkills(skillDirectories(libraryPath ?? join(dataDir, "library.sqlite")));
    return { body: readBody(skills, p.name) };
  });

  peer.onRequest("skills/list", SkillsListParams, (): SkillsListResult => {
    const { skills, advisories } = loadSkills(skillDirectories(libraryPath ?? join(dataDir, "library.sqlite")));
    return {
      skills: skills.map((s) => ({
        name: s.name, title: s.title, description: s.description,
        // The default matches what the loader this replaces assumed when a
        // skill did not say: the whole document.
        contextMode: s.contextMode ?? "fullDocument",
        order: s.order, filePath: s.filePath,
        baseDir: s.baseDir, source: s.source, enabled: s.enabled,
        disableModelInvocation: s.disableModelInvocation,
        version: s.version ?? null,
        iconType: s.icon?.type ?? null,
        iconValue: s.icon?.value ?? null,
        authorName: s.author?.name ?? null,
        // Resolved here rather than by the caller: whether a tool is installed
        // is a fact about this machine, and the settings row and the agent
        // should not be able to disagree about it.
        bins: (s.requirements?.bins ?? []).map((b) => ({
          name: b.name,
          ...(b.description === undefined ? {} : { description: b.description }),
          path: locateBin(b),
          ...(b.install === undefined ? {} : { install: b.install }),
        })),
        envs: (s.requirements?.env ?? []).map((e) => ({
          name: e.name,
          ...(e.description === undefined ? {} : { description: e.description }),
          // Absent means required, which is the safer reading of a manifest
          // that did not say.
          required: e.required ?? true,
        })),
      })),
      advisories,
    };
  });

  peer.onRequest("prompts/compose", PromptsComposeParams, (p): PromptsComposeResult => {
    const { text, used } = prompts.compose(p.mixins);
    // The skills listing is part of the prompt, so it is composed with it. It
    // used to be appended by the shell, which meant one prompt assembled on two
    // sides of a pipe from two different readings of the same directory.
    //
    // Installed skills only, which is what the shell listed: the bundled
    // catalog is a place to install *from*, and its entries are marked
    // `disable-model-invocation` precisely because they are user-invoked.
    const { skills } = loadSkills([
      { path: userSkillDirectory(libraryPath ?? join(dataDir, "library.sqlite")), source: "user" },
    ]);
    return { text: text + promptSection(skills, p.hasReadTool), used, available: prompts.list() };
  });

  // --- catalog ----------------------------------------------------------
  // Phase 1: the shell stops opening library.sqlite and asks instead. Exactly
  // one process owns the schema, and it is this one.

  peer.onRequest("catalog/items/merge", ItemsMergeParams, (p) => {
    new ItemStore(catalog().db, LOCAL_USER).merge(p.keeperId, p.duplicateIds, p.at);
    return {};
  });

  peer.onRequest("catalog/validate", CatalogValidateParams,
    (p): CatalogValidateResult => {
      try {
        // Opening applies anything missing, so a backup that survives this is
        // also left migrated — the next launch finds nothing to do.
        Catalog.open(p.path).close();
        return { ok: true, error: null };
      } catch (error) {
        return { ok: false, error: error instanceof Error ? error.message : String(error) };
      }
    });

  peer.onRequest("catalog/references/get", ReferencesGetParams,
    (p): ReferencesGetResult => ({
      cslJson: new ReferenceStore(catalog().db).get(p.itemId),
    }));

  peer.onRequest("catalog/references/save", ReferencesSaveParams, (p) => {
    new ReferenceStore(catalog().db).save(p.itemId, p.cslJson, p.extra ?? null, p.at);
    return {};
  });

  peer.onRequest("catalog/citeKeys/propose", CiteKeysProposeParams,
    (p): CiteKeysProposeResult => ({
      key: new CiteKeyStore(catalog().db).propose(p.itemId),
    }));

  peer.onRequest("catalog/citeKeys/assign", CiteKeysAssignParams,
    (p): CiteKeysAssignResult => ({
      key: new CiteKeyStore(catalog().db).assign(p.itemId, p.at),
    }));

  peer.onRequest("catalog/citeKeys/save", CiteKeysSaveParams, (p) => {
    new CiteKeyStore(catalog().db).save(p.key, p.itemId, p.at);
    return {};
  });

  peer.onRequest("catalog/properties/list", PropertiesListParams,
    (): PropertiesListResult => ({
      properties: new PropertyStore(catalog().db).list(),
    }));

  peer.onRequest("catalog/properties/upsertOption", PropertiesUpsertOptionParams, (p) => {
    new PropertyStore(catalog().db).upsertOption(p.option);
    return {};
  });

  peer.onRequest("catalog/properties/deleteOption", PropertiesDeleteOptionParams, (p) => {
    new PropertyStore(catalog().db).deleteOption(p.id);
    return {};
  });

  peer.onRequest("catalog/properties/addSelectValue", PropertiesAddSelectValueParams, (p) => {
    new PropertyStore(catalog().db)
      .addSelectValue(p.valueId, p.itemId, p.propertyId, p.optionId);
    return {};
  });

  peer.onRequest("catalog/properties/removeSelectValue",
    PropertiesRemoveSelectValueParams, (p) => {
      new PropertyStore(catalog().db)
        .removeSelectValue(p.itemId, p.propertyId, p.optionId);
      return {};
    });

  peer.onRequest("catalog/items/list", ItemsListParams, (p): ItemsListResult => {
    const store = new ItemStore(catalog().db, LOCAL_USER);
    return { items: p.trashed ? store.listTrashed() : store.list() };
  });

  peer.onRequest("catalog/items/insert", ItemsInsertParams, (p) => {
    new ItemStore(catalog().db, LOCAL_USER).insert(p.item);
    return {};
  });

  peer.onRequest("catalog/items/updateField", ItemsUpdateFieldParams, (p) => {
    // One of the two value slots carries the payload; which one depends on the
    // column, and typing them separately beats a union on the wire.
    const value = p.numberValue ?? p.stringValue ?? null;
    new ItemStore(catalog().db, LOCAL_USER).updateField(p.id, p.field, value, p.at);
    return {};
  });

  peer.onRequest("catalog/items/setTrashed", ItemsSetTrashedParams, (p) => {
    const store = new ItemStore(catalog().db, LOCAL_USER);
    if (p.trashed) store.trash(p.ids, p.at);
    else store.restore(p.ids, p.at);
    return {};
  });

  peer.onRequest("catalog/items/remove", ItemsRemoveParams, (p) => {
    new ItemStore(catalog().db, LOCAL_USER).remove(p.ids);
    return {};
  });

  peer.onRequest("catalog/collections/list", CollectionsListParams,
    (): CollectionsListResult => ({
      collections: new CollectionStore(catalog().db, LOCAL_USER).list(),
    }));

  peer.onRequest("catalog/collections/findBySource", CollectionsFindBySourceParams,
    (p): CollectionsFindBySourceResult => {
      const found = new CollectionStore(catalog().db, LOCAL_USER)
        .findBySource(p.source, p.sourceKey);
      return found ? { collection: found } : {};
    });

  peer.onRequest("catalog/collections/upsert", CollectionsUpsertParams, (p) => {
    new CollectionStore(catalog().db, LOCAL_USER).upsert(p.collection);
    return {};
  });

  peer.onRequest("catalog/collections/delete", CollectionsDeleteParams, (p) => {
    new CollectionStore(catalog().db, LOCAL_USER).delete(p.id);
    return {};
  });

  peer.onRequest("catalog/collections/setMembership", CollectionsSetMembershipParams, (p) => {
    const store = new CollectionStore(catalog().db, LOCAL_USER);
    if (p.member) store.addItem(p.itemId, p.collectionId, p.at ?? new Date().toISOString());
    else store.removeItem(p.itemId, p.collectionId);
    return {};
  });

  peer.onRequest("catalog/conversations/list", ConversationsListParams,
    (p): ConversationsListResult => {
      const store = new ConversationStore(catalog().db, LOCAL_USER);
      const scope: ConversationScope = p.itemId
        ? { kind: "item", itemId: p.itemId }
        : p.collectionId
          ? { kind: "collection", collectionId: p.collectionId }
          : { kind: "library" };
      return { conversations: store.list(scope) };
    });

  peer.onRequest("catalog/conversations/create", ConversationsCreateParams, (p) => {
    new ConversationStore(catalog().db, LOCAL_USER).create(p.conversation);
    return {};
  });

  peer.onRequest("catalog/conversations/update", ConversationsUpdateParams, (p) => {
    new ConversationStore(catalog().db, LOCAL_USER)
      .update(p.id, p.title, p.messageCount, p.at);
    return {};
  });

  peer.onRequest("catalog/conversations/delete", ConversationsDeleteParams, (p) => {
    new ConversationStore(catalog().db, LOCAL_USER).delete(p.id);
    return {};
  });

  peer.onRequest("catalog/annotations/list", AnnotationsListParams, (p): AnnotationsListResult => {
    const store = new AnnotationStore(catalog().db, LOCAL_USER);
    return { annotations: store.listForAttachment(p.attachmentId) };
  });

  peer.onRequest("catalog/annotations/get", AnnotationsGetParams, (p): AnnotationsGetResult => {
    const found = new AnnotationStore(catalog().db, LOCAL_USER).get(p.id);
    return found ? { annotation: found } : {};
  });

  peer.onRequest("catalog/annotations/upsert", AnnotationsUpsertParams, (p) => {
    new AnnotationStore(catalog().db, LOCAL_USER).upsert(p.annotation);
    return {};
  });

  peer.onRequest("catalog/annotations/delete", AnnotationsDeleteParams, (p) => {
    const store = new AnnotationStore(catalog().db, LOCAL_USER);
    if (p.hard) store.hardDelete(p.id);
    else if (p.at) store.softDelete(p.id, p.at);
    else throw new RpcFailure(RpcError.invalidParams, "a soft delete needs `at`");
    return {};
  });

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
