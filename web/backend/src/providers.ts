import {
  createModels,
  createProvider,
  type Api,
  type Model,
  type Models,
  type MutableModels,
  type Provider,
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
import type { ConfigStore, FileCredentialStore } from "./store.js";

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

/** Preferred default model per provider (falls back to the catalog's first). */
const DEFAULT_MODELS: Record<string, string> = {
  anthropic: "claude-fable-5",
  openai: "gpt-5.5",
  google: "gemini-3.1-pro-preview",
  deepseek: "deepseek-chat",
};

const LOCAL_DEFAULTS: Record<string, string> = {
  ollama: "http://localhost:11434/v1",
  lmstudio: "http://localhost:1234/v1",
};

export class ProviderRegistry {
  readonly models: MutableModels;

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
    for (const provider of factories) this.models.setProvider(provider);
    this.registerLocalProviders();
  }

  /** (Re)register Ollama / LM Studio as keyless dynamic providers. */
  registerLocalProviders(): void {
    for (const id of ["ollama", "lmstudio"]) {
      const baseUrl = this.config.get().localProviders[id] ?? LOCAL_DEFAULTS[id];
      this.models.setProvider(
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
    return PROVIDER_ORDER.filter((id) => known.has(id));
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
