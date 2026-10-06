/**
 * `models.json`: the user's own endpoints, models and model facts.
 *
 * Deliberately the same file name, location and key names pi uses for
 * `<agent-dir>/models.json`, so a file written for pi loads here unchanged.
 * See pi's `packages/coding-agent/docs/models.md` and `src/core/model-config.ts`.
 *
 * Two differences from pi, both deliberate:
 *
 *   - `apiKey` and header values expand `$NAME` / `${NAME}` from the
 *     environment, but a leading `!command` is NOT run. pi is a terminal
 *     program the user already trusts with a shell; OakReader is a GUI app,
 *     and a config file that silently executes commands is a bigger promise
 *     than this feature needs.
 *   - The per-api `compat` block is carried through to pi-ai unvalidated. The
 *     flags belong to pi-ai's api implementations, so pi-ai is what should
 *     judge them; this layer only has to not lose them.
 *
 * The file is read fresh on every provider listing, so an edit shows up
 * without restarting the app.
 */
import { readFileSync } from "node:fs";
import { z } from "zod";

const Cost = z.object({
  input: z.number(),
  output: z.number(),
  cacheRead: z.number(),
  cacheWrite: z.number(),
});

const CostOverride = Cost.partial();

const Input = z.array(z.enum(["text", "image"]));

/** Anything pi-ai's api implementations understand. Carried through as-is. */
const Compat = z.record(z.string(), z.unknown());

/** A model the file defines outright. Only `id` is required. */
export const ModelDefinition = z.object({
  id: z.string().min(1),
  name: z.string().min(1).optional(),
  api: z.string().min(1).optional(),
  baseUrl: z.string().min(1).optional(),
  reasoning: z.boolean().optional(),
  input: Input.optional(),
  cost: Cost.optional(),
  contextWindow: z.number().positive().optional(),
  maxTokens: z.number().positive().optional(),
  samplingParams: z.record(z.string(), z.unknown()).optional(),
  compat: Compat.optional(),
});
export type ModelDefinition = z.infer<typeof ModelDefinition>;

/** A patch over a model that already exists. Every field optional. */
export const ModelOverride = z.object({
  name: z.string().min(1).optional(),
  reasoning: z.boolean().optional(),
  input: Input.optional(),
  cost: CostOverride.optional(),
  contextWindow: z.number().positive().optional(),
  maxTokens: z.number().positive().optional(),
  samplingParams: z.record(z.string(), z.unknown()).optional(),
  compat: Compat.optional(),
});
export type ModelOverride = z.infer<typeof ModelOverride>;

export const ProviderConfig = z.object({
  name: z.string().min(1).optional(),
  baseUrl: z.string().min(1).optional(),
  apiKey: z.string().min(1).optional(),
  api: z.string().min(1).optional(),
  headers: z.record(z.string(), z.string()).optional(),
  compat: Compat.optional(),
  models: z.array(ModelDefinition).optional(),
  modelOverrides: z.record(z.string(), ModelOverride).optional(),
});
export type ProviderConfig = z.infer<typeof ProviderConfig>;

export const ModelsConfigFile = z.object({
  providers: z.record(z.string(), ProviderConfig),
});

/** One load of models.json. Both an empty file and a missing one are empty. */
export class ModelsConfig {
  private constructor(
    readonly providers: ReadonlyMap<string, ProviderConfig>,
    readonly error: string | undefined,
  ) {}

  static empty(): ModelsConfig {
    return new ModelsConfig(new Map(), undefined);
  }

  static load(path: string): ModelsConfig {
    let text: string;
    try {
      text = readFileSync(path, "utf8");
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === "ENOENT") return ModelsConfig.empty();
      return new ModelsConfig(new Map(), `Could not read models.json: ${message(err)}`);
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(stripComments(stripBom(text)));
    } catch (err) {
      return new ModelsConfig(new Map(), `models.json is not valid JSON: ${message(err)}`);
    }

    const result = ModelsConfigFile.safeParse(parsed);
    if (!result.success) {
      const lines = result.error.issues.map((issue) => {
        const where = issue.path.join(".") || "(root)";
        return `  ${where}: ${issue.message}`;
      });
      return new ModelsConfig(new Map(), `models.json does not match the schema:\n${lines.join("\n")}`);
    }

    return new ModelsConfig(new Map(Object.entries(result.data.providers)), undefined);
  }

  get providerIds(): string[] {
    return [...this.providers.keys()];
  }
}

/**
 * Expand `$NAME` and `${NAME}` from the environment. `$$` is a literal `$`.
 * Returns undefined when a named variable is unset, which is how a provider
 * configured against a missing key reports "not configured" rather than
 * sending the string `$OPENAI_API_KEY` as a bearer token.
 */
export function expandEnv(value: string, env: NodeJS.ProcessEnv = process.env): string | undefined {
  let out = "";
  let index = 0;
  while (index < value.length) {
    const dollar = value.indexOf("$", index);
    if (dollar === -1) {
      out += value.slice(index);
      break;
    }
    out += value.slice(index, dollar);
    const next = value[dollar + 1];
    if (next === "$") {
      out += "$";
      index = dollar + 2;
      continue;
    }
    if (next === "{") {
      const end = value.indexOf("}", dollar + 2);
      const name = end === -1 ? "" : value.slice(dollar + 2, end);
      if (end === -1 || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) {
        out += "$";
        index = dollar + 1;
        continue;
      }
      const resolved = env[name];
      if (resolved === undefined) return undefined;
      out += resolved;
      index = end + 1;
      continue;
    }
    const name = value.slice(dollar + 1).match(/^[A-Za-z_][A-Za-z0-9_]*/)?.[0];
    if (!name) {
      out += "$";
      index = dollar + 1;
      continue;
    }
    const resolved = env[name];
    if (resolved === undefined) return undefined;
    out += resolved;
    index = dollar + 1 + name.length;
  }
  return out;
}

/** The template a first-time file is written from. */
export const MODELS_JSON_TEMPLATE = `{
  // models.json — your own endpoints, models, and model facts.
  //
  // Same file as pi's <agent-dir>/models.json, so a file written for pi works
  // here. Comments and trailing whitespace are allowed; the file is re-read
  // every time OakReader lists providers.
  //
  // 1. Point an existing provider somewhere else, and correct what its models
  //    actually do:
  //
  //   "providers": {
  //     "ollama": {
  //       "baseUrl": "http://127.0.0.1:11434/v1",
  //       "modelOverrides": {
  //         "qwen3-coder:480b": {
  //           "contextWindow": 1000000,
  //           "maxTokens": 384000,
  //           "reasoning": true,
  //           "input": ["text", "image"]
  //         }
  //       }
  //     }
  //   }
  //
  // 2. Define a provider OakReader does not ship, with its own models:
  //
  //   "providers": {
  //     "my-relay": {
  //       "name": "My Relay",
  //       "baseUrl": "https://relay.example.com/v1",
  //       "api": "openai-completions",
  //       "apiKey": "$MY_RELAY_KEY",
  //       "models": [
  //         { "id": "gpt-5.5", "contextWindow": 400000, "maxTokens": 128000,
  //           "input": ["text", "image"], "reasoning": true }
  //       ]
  //     }
  //   }
  //
  // "api" is one of: openai-completions, openai-responses, anthropic-messages,
  // google-generative-ai. "apiKey" may be a literal or $ENV_VAR.

  "providers": {}
}
`;

function stripBom(text: string): string {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

/** Drop `//` and `/* *\/` comments, leaving anything inside a JSON string. */
function stripComments(text: string): string {
  let out = "";
  let inString = false;
  let index = 0;
  while (index < text.length) {
    const char = text[index];
    if (inString) {
      out += char;
      if (char === "\\") {
        out += text[index + 1] ?? "";
        index += 2;
        continue;
      }
      if (char === '"') inString = false;
      index += 1;
      continue;
    }
    if (char === '"') {
      inString = true;
      out += char;
      index += 1;
      continue;
    }
    if (char === "/" && text[index + 1] === "/") {
      const end = text.indexOf("\n", index);
      index = end === -1 ? text.length : end;
      continue;
    }
    if (char === "/" && text[index + 1] === "*") {
      const end = text.indexOf("*/", index + 2);
      index = end === -1 ? text.length : end + 2;
      continue;
    }
    out += char;
    index += 1;
  }
  return out;
}

function message(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
