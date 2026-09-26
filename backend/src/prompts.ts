/**
 * The static half of the system prompt, loaded from files rather than compiled in.
 *
 * Before this, every word the assistant was told lived in a Swift string
 * literal, so changing one needed a rebuild and a notarized release. Dia ships
 * its prompts as Markdown with composable mixins beside the binary and edits
 * them freely; Codex ships tool schemas as JSON. Same idea here, at the scale
 * this app actually needs.
 *
 * The split is deliberate and worth stating: what lives in files is *policy* —
 * who the assistant is, how it formats maths, what it refuses to do. What stays
 * in the shell is *context* — the open document, the active collection, the tab
 * list. Policy is prose that anyone should be able to edit; context is
 * assembled from live application state and could not be a file if it tried.
 */
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Where the prompt files are.
 *
 * `--prompts` wins so the shell can point at the copy inside its bundle. The
 * fallback walks up from this module, which is what makes `bun src/main.ts`
 * work in a checkout. A compiled binary always gets the flag.
 */
function resolveRoot(): string | undefined {
  const flag = process.argv.indexOf("--prompts");
  if (flag !== -1 && process.argv[flag + 1]) return process.argv[flag + 1];

  try {
    const here = dirname(fileURLToPath(import.meta.url));
    const candidate = join(here, "..", "..", "prompts");
    if (existsSync(join(candidate, "base.md"))) return candidate;
  } catch {
    // A compiled binary has no meaningful import.meta.url path; the flag covers it.
  }
  return undefined;
}

export class PromptLibrary {
  private constructor(private readonly root: string | undefined) {}

  static load(): PromptLibrary {
    return new PromptLibrary(resolveRoot());
  }

  /** True when prompt files were found. False means the shell must supply its own. */
  get available(): boolean {
    return this.root !== undefined && existsSync(join(this.root, "base.md"));
  }

  /** Mixin names available to compose, without the `.md`. */
  list(): string[] {
    if (!this.root) return [];
    const dir = join(this.root, "mixins");
    if (!existsSync(dir)) return [];
    return readdirSync(dir).filter((f) => f.endsWith(".md")).map((f) => f.slice(0, -3)).sort();
  }

  /**
   * `base.md` followed by the named mixins, in the order asked for.
   *
   * A missing mixin is skipped rather than throwing: a shell from a slightly
   * older build asking for a fragment this one does not carry should get a
   * usable prompt, not an error. The names it did use come back so a caller
   * that cares can notice.
   */
  compose(mixins: string[]): { text: string; used: string[] } {
    if (!this.root) return { text: "", used: [] };

    const parts: string[] = [];
    const base = this.read(join(this.root, "base.md"));
    if (base) parts.push(base);

    const used: string[] = [];
    for (const name of mixins) {
      // Names come off the wire; keep them to a single path segment.
      if (!/^[a-z0-9-]+$/i.test(name)) continue;
      const body = this.read(join(this.root, "mixins", `${name}.md`));
      if (!body) continue;
      parts.push(body);
      used.push(name);
    }
    return { text: parts.join("\n\n"), used };
  }

  private read(path: string): string | undefined {
    try {
      const text = readFileSync(path, "utf8").trim();
      return text.length > 0 ? text : undefined;
    } catch {
      return undefined;
    }
  }
}
