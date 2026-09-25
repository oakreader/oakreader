import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type {
  AuthOperationOptions,
  Credential,
  CredentialInfo,
  CredentialStore,
} from "@earendil-works/pi-ai";

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

export function dataPaths(dataDir: string): { config: string } {
  return { config: join(dataDir, "config.json") };
}

/**
 * Credential store backed by the shell's Keychain, over the protocol.
 *
 * The secrets never live in this process's data dir: every read and write is
 * a round-trip to the shell, which owns the platform keystore (the macOS
 * data-protection keychain, scoped to a team-stable access group). That keeps
 * the property an on-disk auth.json gave up -- such a file is
 * readable by anything running as the user and lands in backups -- while
 * leaving the sidecar the one that *uses* the credential, so pi-ai's OAuth
 * refresh still happens inside `modify`.
 *
 * Writes stay serialized per provider exactly as the file store did, so a
 * concurrent refresh cannot interleave a read-modify-write.
 */
export class IPCCredentialStore implements CredentialStore {
  private chains = new Map<string, Promise<unknown>>();

  /**
   * @param request Issues one credential op to the shell and resolves with its
   *   reply. Rejects on transport failure or timeout; `Models` wraps such
   *   rejections as a "auth" ModelsError, which is the honest outcome -- an
   *   unreachable keystore is a storage failure, not an absent credential.
   */
  constructor(
    private request: (op: CredentialOp, providerId?: string, credential?: Credential) => Promise<CredentialReply>,
  ) {}

  private enqueue<T>(providerId: string, task: () => Promise<T>): Promise<T> {
    const prev = this.chains.get(providerId) ?? Promise.resolve();
    const next = prev.then(task, task);
    this.chains.set(providerId, next.catch(() => {}));
    return next;
  }

  async read(providerId: string, _options?: AuthOperationOptions): Promise<Credential | undefined> {
    return (await this.request("read", providerId)).credential;
  }

  async list(_options?: AuthOperationOptions): Promise<readonly CredentialInfo[]> {
    return (await this.request("list")).credentials ?? [];
  }

  async modify(
    providerId: string,
    fn: (current: Credential | undefined) => Promise<Credential | undefined>,
    _options?: AuthOperationOptions,
  ): Promise<Credential | undefined> {
    return this.enqueue(providerId, async () => {
      const current = (await this.request("read", providerId)).credential;
      const next = await fn(current);
      if (next) {
        await this.request("write", providerId, next);
      } else if (current) {
        await this.request("delete", providerId);
      }
      return next;
    });
  }

  async delete(providerId: string, _options?: AuthOperationOptions): Promise<void> {
    await this.enqueue(providerId, () => this.request("delete", providerId));
  }
}

export type CredentialOp = "read" | "list" | "write" | "delete";

export interface CredentialReply {
  credential?: Credential;
  credentials?: CredentialInfo[];
}
