import {
  createModels,
  createProvider,
  type Api,
  type Model,
  type Models,
  type MutableModels,
  type Provider,
  type ProviderStreams,
} from "@earendil-works/pi-ai";
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";
import { openaiProvider } from "@earendil-works/pi-ai/providers/openai";
import { googleProvider } from "@earendil-works/pi-ai/providers/google";
import { deepseekProvider } from "@earendil-works/pi-ai/providers/deepseek";
import { groqProvider } from "@earendil-works/pi-ai/providers/groq";
import { xaiProvider } from "@earendil-works/pi-ai/providers/xai";
import { openrouterProvider } from "@earendil-works/pi-ai/providers/openrouter";
import { mistralProvider } from "@earendil-works/pi-ai/providers/mistral";
import { moonshotaiProvider } from "@earendil-works/pi-ai/providers/moonshotai";
import { fireworksProvider } from "@earendil-works/pi-ai/providers/fireworks";
import { cerebrasProvider } from "@earendil-works/pi-ai/providers/cerebras";
import { huggingfaceProvider } from "@earendil-works/pi-ai/providers/huggingface";
import { togetherProvider } from "@earendil-works/pi-ai/providers/together";
import { minimaxProvider } from "@earendil-works/pi-ai/providers/minimax";
import { zaiProvider } from "@earendil-works/pi-ai/providers/zai";
import { xiaomiProvider } from "@earendil-works/pi-ai/providers/xiaomi";
import { openaiCodexProvider } from "@earendil-works/pi-ai/providers/openai-codex";
import { githubCopilotProvider } from "@earendil-works/pi-ai/providers/github-copilot";
import { openAICompletionsApi } from "@earendil-works/pi-ai/api/openai-completions.lazy";
import { openAIResponsesApi } from "@earendil-works/pi-ai/api/openai-responses.lazy";
import { anthropicMessagesApi } from "@earendil-works/pi-ai/api/anthropic-messages.lazy";
import { googleGenerativeAIApi } from "@earendil-works/pi-ai/api/google-generative-ai.lazy";
import type { ConfigStore, FileCredentialStore } from "./store.js";
import {
  ModelsConfig, expandEnv,
  type ModelDefinition, type ModelOverride, type ProviderConfig as ModelsProviderConfig,
} from "./modelsConfig.js";

/**
 * The provider registry: pi-ai `Models` seeded with OakReader's curated
 * provider set. OakReader provider ids stay the app-facing identity; the few
 * that differ from pi-ai ids are mapped here.
 */

/** OakReader provider id → pi-ai provider id (identity unless listed). */
const OAK_TO_PI: Record<string, string> = {
  kimi: "moonshotai",
};
const PI_TO_OAK: Record<string, string> = Object.fromEntries(
  Object.entries(OAK_TO_PI).map(([oak, pi]) => [pi, oak]),
);

export const toPiId = (oakId: string): string => OAK_TO_PI[oakId] ?? oakId;
export const toOakId = (piId: string): string => PI_TO_OAK[piId] ?? piId;

/** Display order + display names, mirroring the old BuiltInProviders curation. */
const PROVIDER_ORDER = [
  "anthropic", "openai", "google", "openai-codex", "github-copilot",
  "ollama", "lmstudio",
  "deepseek", "groq", "xai", "openrouter", "mistral", "kimi", "fireworks",
  "cerebras", "huggingface", "together", "minimax", "zai", "xiaomi",
];

/**
 * Preferred default model per provider — the strong general one, falling back
 * to the catalog's first when the id is not there.
 *
 * That fallback makes a stale entry silent rather than broken, which is how
 * `deepseek-chat` survived here after pi stopped carrying it: the picker just
 * quietly chose something else. Check an id against
 * `node_modules/@earendil-works/pi-ai/dist/providers/data/*.json` when
 * changing one.
 */
const DEFAULT_MODELS: Record<string, string> = {
  anthropic: "claude-fable-5",
  openai: "gpt-5.5",
  google: "gemini-3.1-pro-preview",
  deepseek: "deepseek-v4-pro",
};

const LOCAL_DEFAULTS: Record<string, string> = {
  ollama: "http://localhost:11434/v1",
  lmstudio: "http://localhost:1234/v1",
};

export class ProviderRegistry {
  readonly models: MutableModels;

  /**
   * The providers as the build ships them, before models.json. Composition
   * must always start from these: applying a config file on top of an
   * already-composed provider would stack an edit on an edit, and the second
   * reload would inherit the first one's overrides.
   */
  private readonly baseProviders = new Map<string, Provider>();
  /** Provider ids that exist only because models.json defines them. */
  private customIds = new Set<string>();
  private modelsConfigErrors: string[] = [];

  constructor(
    credentials: FileCredentialStore,
    private config: ConfigStore,
  ) {
    this.models = createModels({ credentials });
    const factories: Provider[] = [
      anthropicProvider(), openaiProvider(), googleProvider(), deepseekProvider(),
      groqProvider(), xaiProvider(), openrouterProvider(), mistralProvider(),
      moonshotaiProvider(), fireworksProvider(), cerebrasProvider(),
      huggingfaceProvider(), togetherProvider(), minimaxProvider(), zaiProvider(),
      xiaomiProvider(), openaiCodexProvider(), githubCopilotProvider(),
    ];
    for (const provider of factories) this.setBaseProvider(provider);
    this.registerLocalProviders();
  }

  private setBaseProvider(provider: Provider): void {
    this.baseProviders.set(provider.id, provider);
    this.models.setProvider(provider);
  }

  /** (Re)register Ollama / LM Studio as keyless dynamic providers. */
  registerLocalProviders(): void {
    for (const id of ["ollama", "lmstudio"]) {
      const baseUrl = this.config.get().localProviders[id] ?? LOCAL_DEFAULTS[id];
      this.setBaseProvider(
        createProvider({
          id,
          name: id === "ollama" ? "Ollama" : "LM Studio",
          baseUrl,
          // Local servers ignore Authorization, but pi's openai-completions
          // impl refuses to send a request with no key and no auth header.
          auth: { apiKey: { name: id, resolve: async () => ({ auth: { apiKey: "local" } }) } },
          models: [],
          fetchModels: async ({ signal }) => fetchLocalModels(id, baseUrl, signal),
          api: openAICompletionsApi(),
        }),
      );
    }
  }

  isLocal(oakId: string): boolean {
    return oakId === "ollama" || oakId === "lmstudio";
  }

  oakProviderIds(): string[] {
    const known = new Set(this.models.getProviders().map((p) => toOakId(p.id)));
    const curated = PROVIDER_ORDER.filter((id) => known.has(id));
    // A provider the user defined in models.json is not in the curated order;
    // it goes after the built-ins rather than nowhere.
    const custom = [...this.customIds].map(toOakId).filter((id) => !curated.includes(id)).sort();
    return [...curated, ...custom];
  }

  /** True for a provider that exists only because models.json defines it. */
  isCustom(oakId: string): boolean {
    return this.customIds.has(toPiId(oakId));
  }

  /** Why the last models.json load produced less than the file asked for. */
  get modelsConfigError(): string | undefined {
    return this.modelsConfigErrors.length ? this.modelsConfigErrors.join("\n\n") : undefined;
  }

  /**
   * Apply a models.json over the shipped providers, replacing any previous
   * application. One bad provider block is reported and skipped; the rest of
   * the file still takes effect, because a typo in one endpoint should not
   * take away the others.
   */
  applyModelsConfig(config: ModelsConfig): void {
    this.modelsConfigErrors = config.error ? [config.error] : [];

    for (const provider of this.baseProviders.values()) this.models.setProvider(provider);
    for (const id of this.customIds) {
      if (!this.baseProviders.has(id)) this.models.deleteProvider(id);
    }
    this.customIds = new Set();

    for (const [rawId, providerConfig] of config.providers) {
      const piId = toPiId(rawId);
      try {
        const base = this.baseProviders.get(piId);
        this.models.setProvider(composeProvider(piId, base, providerConfig));
        if (!base) this.customIds.add(piId);
      } catch (err) {
        this.modelsConfigErrors.push(
          `models.json, provider "${rawId}": ${err instanceof Error ? err.message : String(err)}`,
        );
      }
    }
  }

  provider(oakId: string): Provider | undefined {
    return this.models.getProvider(toPiId(oakId));
  }

  defaultModelId(oakId: string): string | undefined {
    const models = this.models.getModels(toPiId(oakId));
    const preferred = DEFAULT_MODELS[oakId];
    if (preferred && models.some((m) => m.id === preferred)) return preferred;
    return models[0]?.id;
  }

  /**
   * Resolve a request's model, applying the provider's base-URL override when
   * one is set (the override rides on the model object — `Models.stream`
   * dispatches by `model.provider` and reads the endpoint from `model.baseUrl`).
   */
  resolveModel(oakId: string, modelId: string): Model<Api> {
    const piId = toPiId(oakId);
    let model = this.models.getModel(piId, modelId);
    if (!model) {
      const fallback = this.defaultModelId(oakId);
      if (fallback) model = this.models.getModel(piId, fallback);
    }
    if (!model) throw new Error(`Unknown model ${oakId}/${modelId}`);
    const override = this.config.get().baseUrlOverrides[oakId];
    return override ? ({ ...model, baseUrl: applyOverride(override, model.baseUrl) } as Model<Api>) : model;
  }
}

// --- models.json composition ----------------------------------------------

/**
 * The api implementations a models.json file may name. pi's own set is larger;
 * these are the four an OpenAI-, Anthropic- or Google-compatible endpoint
 * actually needs, and each is a lazy wrapper, so naming one here costs nothing
 * until a model of that api streams.
 */
const API_FACTORIES: Record<string, () => ProviderStreams> = {
  "openai-completions": openAICompletionsApi,
  "openai-responses": openAIResponsesApi,
  "anthropic-messages": anthropicMessagesApi,
  "google-generative-ai": googleGenerativeAIApi,
};

/** Fields a model definition may leave out, in pi's defaults. */
const MODEL_DEFAULTS = { contextWindow: 128_000, maxTokens: 16_384 };

type AnyCompat = Record<string, unknown> | undefined;

function mergeCompat(base: AnyCompat, over: AnyCompat): AnyCompat {
  if (!over) return base;
  return { ...base, ...over };
}

/**
 * Build one provider from the file. With a base provider the file edits it —
 * endpoint, headers, extra models, corrected model facts — and everything else
 * about it, auth and streaming included, is left alone. Without one the file
 * defines the provider outright, which is why `api` and `baseUrl` become
 * required there.
 */
function composeProvider(
  piId: string,
  base: Provider | undefined,
  config: ModelsProviderConfig,
): Provider {
  const models = composeModels(piId, base?.getModels() ?? [], config);
  if (!base && models.length === 0) {
    throw new Error('defines no models. Add a "models" array, or use an id OakReader already ships.');
  }

  const headers = resolveHeaders(config.headers);
  if (base) {
    return {
      ...base,
      name: config.name ?? base.name,
      baseUrl: config.baseUrl ?? base.baseUrl,
      auth: composeAuth(piId, base, config, headers),
      getModels: () => composeModels(piId, base.getModels(), config),
    };
  }

  const apis: Record<string, ProviderStreams> = {};
  for (const model of models) {
    const factory = API_FACTORIES[model.api];
    if (!factory) {
      throw new Error(
        `model "${model.id}" asks for api "${model.api}". Supported: ${Object.keys(API_FACTORIES).join(", ")}.`,
      );
    }
    apis[model.api] ??= factory();
  }

  return createProvider({
    id: piId,
    name: config.name ?? piId,
    baseUrl: config.baseUrl,
    auth: composeAuth(piId, undefined, config, headers),
    models,
    api: apis as Partial<Record<Api, ProviderStreams>>,
  });
}

/**
 * Base models with the file applied: the provider's endpoint and compat flags
 * ride onto every model, `models` upserts by id, and `modelOverrides` patches
 * last so it also reaches a model the same file just defined.
 */
function composeModels(
  piId: string,
  baseModels: readonly Model<Api>[],
  config: ModelsProviderConfig,
): Model<Api>[] {
  const models: Model<Api>[] = baseModels.map((model) => ({
    ...model,
    baseUrl: config.baseUrl ?? model.baseUrl,
    compat: mergeCompat(model.compat as AnyCompat, config.compat) as Model<Api>["compat"],
  }));

  for (const definition of config.models ?? []) {
    const model = modelFromDefinition(piId, definition, config, defaultsFor(models, definition, config));
    const existing = models.findIndex((m) => m.id === model.id);
    if (existing >= 0) models[existing] = model;
    else models.push(model);
  }

  return models.map((model) => {
    const override = config.modelOverrides?.[model.id];
    return override ? applyModelOverride(model, override) : model;
  });
}

/**
 * Which existing model a definition inherits its unstated fields from: the
 * same id first, then anything on the same api, then whatever is there. The
 * point is that `{ "id": "qwen3:8b" }` on a known provider is a complete
 * entry.
 */
function defaultsFor(
  models: readonly Model<Api>[],
  definition: ModelDefinition,
  config: ModelsProviderConfig,
): Model<Api> | undefined {
  const api = definition.api ?? config.api;
  return (
    models.find((m) => m.id === definition.id)
    ?? (api ? models.find((m) => m.api === api) : undefined)
    ?? models.find((m) => m.api === "openai-completions")
    ?? models[0]
  );
}

function modelFromDefinition(
  piId: string,
  definition: ModelDefinition,
  config: ModelsProviderConfig,
  defaults: Model<Api> | undefined,
): Model<Api> {
  const api = definition.api ?? config.api ?? defaults?.api;
  if (!api) {
    throw new Error(`model "${definition.id}" has no "api". Set it on the model or the provider.`);
  }
  const baseUrl = definition.baseUrl ?? config.baseUrl ?? defaults?.baseUrl;
  if (!baseUrl) {
    throw new Error(`model "${definition.id}" has no "baseUrl". Set it on the model or the provider.`);
  }
  return {
    id: definition.id,
    name: definition.name ?? definition.id,
    api: api as Api,
    provider: piId,
    baseUrl,
    reasoning: definition.reasoning ?? false,
    input: definition.input ?? ["text"],
    cost: definition.cost ?? { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: definition.contextWindow ?? MODEL_DEFAULTS.contextWindow,
    maxTokens: definition.maxTokens ?? MODEL_DEFAULTS.maxTokens,
    samplingParams: definition.samplingParams,
    compat: mergeCompat(config.compat, definition.compat) as Model<Api>["compat"],
  } as Model<Api>;
}

function applyModelOverride(model: Model<Api>, override: ModelOverride): Model<Api> {
  return {
    ...model,
    name: override.name ?? model.name,
    reasoning: override.reasoning ?? model.reasoning,
    input: override.input ?? model.input,
    cost: override.cost ? { ...model.cost, ...override.cost } : model.cost,
    contextWindow: override.contextWindow ?? model.contextWindow,
    maxTokens: override.maxTokens ?? model.maxTokens,
    samplingParams: override.samplingParams
      ? { ...model.samplingParams, ...override.samplingParams }
      : model.samplingParams,
    compat: mergeCompat(model.compat as AnyCompat, override.compat) as Model<Api>["compat"],
  } as Model<Api>;
}

/** Header values expand `$NAME` the same way `apiKey` does. */
function resolveHeaders(headers: Record<string, string> | undefined): Record<string, string> | undefined {
  if (!headers) return undefined;
  const out: Record<string, string> = {};
  for (const [name, value] of Object.entries(headers)) {
    const resolved = expandEnv(value);
    if (resolved !== undefined) out[name] = resolved;
  }
  return Object.keys(out).length ? out : undefined;
}

/**
 * Credential order, which is pi's: a key the user typed into OakReader wins,
 * then the file's own `apiKey`, then whatever the shipped provider resolves
 * (its environment variables). A file key naming an unset variable resolves to
 * nothing, so the provider reads as unconfigured instead of sending the
 * literal `$MY_KEY` as a token.
 */
function composeAuth(
  piId: string,
  base: Provider | undefined,
  config: ModelsProviderConfig,
  headers: Record<string, string> | undefined,
): Provider["auth"] {
  const inherited = base?.auth.apiKey;
  const configured = () => (config.apiKey === undefined ? undefined : expandEnv(config.apiKey));

  if (config.apiKey === undefined && !headers && inherited) return base.auth;

  const apiKey: NonNullable<Provider["auth"]["apiKey"]> = {
    name: inherited?.name ?? `${config.name ?? piId} API key`,
    login: inherited?.login,
    check: async (input) => {
      if (input.credential?.key) return { type: "api_key", source: "stored credential" };
      if (configured() !== undefined) return { type: "api_key", source: "models.json" };
      if (inherited?.check) return inherited.check(input);
      return (await inherited?.resolve(input)) ? { type: "api_key" } : undefined;
    },
    resolve: async (input) => {
      if (input.credential?.key) {
        return {
          auth: { apiKey: input.credential.key, headers },
          env: input.credential.env,
          source: "stored credential",
        };
      }
      const key = configured();
      if (key !== undefined) return { auth: { apiKey: key, headers }, source: "models.json" };
      if (config.apiKey !== undefined) return undefined;
      const resolved = await inherited?.resolve(input);
      if (resolved) {
        return { ...resolved, auth: { ...resolved.auth, headers: { ...resolved.auth.headers, ...headers } } };
      }
      // A keyless endpoint still has to send something: pi's OpenAI-compatible
      // api refuses a request with neither a key nor an auth header, and a
      // local server ignores whatever arrives.
      return base ? undefined : { auth: { apiKey: "models.json", headers }, source: "no key" };
    },
  };
  return { ...(base?.auth.oauth ? { oauth: base.auth.oauth } : {}), apiKey };
}

/**
 * Cherry-Studio-convention override: a trailing `#` means "use exactly as
 * typed"; otherwise the value is an API base that replaces the default base.
 */
function applyOverride(override: string, _defaultBase: string): string {
  const trimmed = override.trim();
  if (trimmed.endsWith("#")) return trimmed.slice(0, -1).trim();
  return trimmed.replace(/\/+$/, "");
}

async function fetchLocalModels(
  providerId: string,
  baseUrl: string,
  signal: AbortSignal,
): Promise<Model<"openai-completions">[]> {
  const res = await fetch(`${baseUrl.replace(/\/+$/, "")}/models`, { signal });
  if (!res.ok) throw new Error(`GET /models: HTTP ${res.status}`);
  const body = (await res.json()) as { data?: { id: string }[] };
  return (body.data ?? []).map((m) => ({
    id: m.id,
    name: m.id,
    api: "openai-completions" as const,
    provider: providerId,
    baseUrl,
    reasoning: false,
    input: ["text" as const],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 32_768,
    maxTokens: 8_192,
    compat: { supportsDeveloperRole: false, supportsReasoningEffort: false },
  }));
}

export type { Models };
