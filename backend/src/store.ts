import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type {
  AuthOperationOptions,
  Credential,
  CredentialInfo,
  CredentialStore,
} from "@earendil-works/pi-ai";

/**
 * File-backed pi-ai CredentialStore: one auth.json (0600) in the backend data
 * dir, same shape as pi's own auth.json ({ providerId: Credential }). Writes
 * are serialized per provider and land via temp-file + rename.
 */
export class FileCredentialStore implements CredentialStore {
  private chains = new Map<string, Promise<unknown>>();

  constructor(private path: string) {}

  private load(): Record<string, Credential> {
    try {
      return JSON.parse(readFileSync(this.path, "utf8"));
    } catch {
      return {};
    }
  }

  private save(all: Record<string, Credential>): void {
    mkdirSync(dirname(this.path), { recursive: true });
    const tmp = `${this.path}.tmp`;
    writeFileSync(tmp, JSON.stringify(all, null, 2) + "\n", { mode: 0o600 });
    renameSync(tmp, this.path);
  }

  private enqueue<T>(providerId: string, task: () => Promise<T>): Promise<T> {
    const prev = this.chains.get(providerId) ?? Promise.resolve();
    const next = prev.then(task, task);
    this.chains.set(providerId, next.catch(() => {}));
    return next;
  }

  async read(providerId: string, _options?: AuthOperationOptions): Promise<Credential | undefined> {
    return this.load()[providerId];
  }

  async list(_options?: AuthOperationOptions): Promise<readonly CredentialInfo[]> {
    return Object.entries(this.load()).map(([providerId, cred]) => ({
      providerId,
      type: cred.type,
    }));
  }

  async modify(
    providerId: string,
    fn: (current: Credential | undefined) => Promise<Credential | undefined>,
    _options?: AuthOperationOptions,
  ): Promise<Credential | undefined> {
    return this.enqueue(providerId, async () => {
      const all = this.load();
      const next = await fn(all[providerId]);
      if (next !== undefined) {
        all[providerId] = next;
        this.save(all);
      }
      return all[providerId];
    });
  }

  async delete(providerId: string, _options?: AuthOperationOptions): Promise<void> {
    await this.enqueue(providerId, async () => {
      const all = this.load();
      if (providerId in all) {
        delete all[providerId];
        this.save(all);
      }
    });
  }
}

/** Non-secret backend settings: endpoint overrides and local-provider URLs. */
export interface BackendConfig {
  /** Per-OakReader-provider-id API base URL overrides (proxies / 中转站). */
  baseUrlOverrides: Record<string, string>;
  /** Local OpenAI-compatible servers, keyed "ollama" / "lmstudio" → API base. */
  localProviders: Record<string, string>;
}

export class ConfigStore {
  private config: BackendConfig;

  constructor(private path: string) {
    let loaded: Partial<BackendConfig> = {};
    try {
      loaded = JSON.parse(readFileSync(path, "utf8"));
    } catch {
      // first run
    }
    this.config = {
      baseUrlOverrides: loaded.baseUrlOverrides ?? {},
      localProviders: loaded.localProviders ?? {},
    };
  }

  get(): BackendConfig {
    return this.config;
  }

  update(fn: (config: BackendConfig) => void): void {
    fn(this.config);
    mkdirSync(dirname(this.path), { recursive: true });
    const tmp = `${this.path}.tmp`;
    writeFileSync(tmp, JSON.stringify(this.config, null, 2) + "\n");
    renameSync(tmp, this.path);
  }
}

export function dataPaths(dataDir: string): { auth: string; config: string } {
  return {
    auth: join(dataDir, "auth.json"),
    config: join(dataDir, "config.json"),
  };
}
