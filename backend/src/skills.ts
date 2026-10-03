/**
 * Skills — a directory with a `SKILL.md`, and optionally a `skill.json` beside it.
 *
 * The agent discovers them by name and description in the system prompt and reads
 * the body itself when a task matches, so the body never sits in context unless it
 * is needed. That is why loading belongs here: the prompt is composed here and the
 * loop that consumes it runs here. It used to be loaded in Swift and appended to a
 * prompt the core had just built, which meant two halves of one prompt assembled on
 * two sides of a pipe — and, once the CLI needed skills too, three copies of the
 * same directory walk.
 *
 * Following the Agent Skills convention (agentskills.io): frontmatter carries the
 * name and description, `skill.json` carries everything a UI needs to display and
 * set one up.
 */
import { readdirSync, readFileSync, statSync, existsSync, realpathSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { homedir } from "node:os";

/** Where a skill was found. */
export type SkillSource = "user" | "bundled" | "path";

export interface SkillIcon {
  type: string;
  value: string;
}

export interface SkillAuthor {
  name: string;
  bio?: string;
  links?: Record<string, string>;
}

export interface BinRequirement {
  name: string;
  description?: string;
  searchPaths?: string[];
  versionArgs?: string[];
  install?: Record<string, string>;
}

export interface EnvRequirement {
  name: string;
  description?: string;
  required?: boolean;
}

export interface SkillRequirements {
  bins?: BinRequirement[];
  env?: EnvRequirement[];
}

export interface Skill {
  name: string;
  /** Display name from the frontmatter's `title`, falling back to `name`. */
  title: string;
  description: string;
  /** Sort position in the chat picker; 99 when unstated. */
  order: number;
  /** Absolute path to the SKILL.md the model is told to read. */
  filePath: string;
  /** The directory holding it, which relative paths inside resolve against. */
  baseDir: string;
  /** Invoked only by explicit request; kept out of the prompt listing. */
  disableModelInvocation: boolean;
  enabled: boolean;
  source: SkillSource;
  icon?: SkillIcon;
  author?: SkillAuthor;
  version?: string;
  contextMode?: string;
  requirements?: SkillRequirements;
}

export interface LoadedSkills {
  skills: Skill[];
  /** Non-fatal complaints, so a malformed skill is reported rather than vanishing. */
  advisories: Array<{ path: string; message: string }>;
}

/**
 * Lowercase letters, digits and single inner hyphens, 64 characters at most.
 *
 * A bad name is an advisory rather than a rejection: the skill still loads, because
 * a skill you can see and fix beats one that silently is not there.
 */
function isValidName(name: string): boolean {
  return name !== "" && name.length <= 64
    && !name.startsWith("-") && !name.endsWith("-") && !name.includes("--")
    && /^[a-z0-9-]+$/.test(name);
}

/**
 * The YAML frontmatter of a SKILL.md, as far as this needs it: top-level scalars.
 *
 * Not a YAML parser, and deliberately so — this is the only YAML the core reads,
 * the schema is ours, and the fields that matter are two strings and a boolean.
 */
export function parseFrontmatter(text: string): Record<string, string> | null {
  const match = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text);
  if (match === null) return null;

  const fields: Record<string, string> = {};
  for (const line of match[1]!.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed === "" || trimmed.startsWith("#")) continue;
    const colon = trimmed.indexOf(":");
    if (colon < 0) continue;
    const key = trimmed.slice(0, colon).trim();
    const value = trimmed.slice(colon + 1).trim().replace(/^["'](.*)["']$/, "$1");
    if (value !== "") fields[key] = value;
  }
  return fields;
}

function readManifest(directory: string): Record<string, any> | null {
  const path = join(directory, "skill.json");
  try {
    return JSON.parse(readFileSync(path, "utf8")) as Record<string, any>;
  } catch {
    return null;
  }
}

function skillFrom(
  filePath: string, expectedName: string, source: SkillSource,
): { skill?: Skill; advisory?: string } {
  let text: string;
  try {
    text = readFileSync(filePath, "utf8");
  } catch {
    return { advisory: "Cannot read file" };
  }

  const meta = parseFrontmatter(text);
  if (meta === null) return { advisory: "Missing or invalid YAML frontmatter" };

  const name = meta.name ?? expectedName;
  const description = meta.description;
  // The one hard requirement: a skill with no description cannot be chosen.
  if (description === undefined || description === "") {
    return { advisory: "Missing required 'description' in frontmatter" };
  }

  let advisory: string | undefined;
  if (!isValidName(name)) {
    advisory = `Skill name '${name}' should be lowercase alphanumeric with hyphens (max 64 chars)`;
  } else if (description.length > 1024) {
    advisory = "Description exceeds 1024 characters";
  }

  const baseDir = dirname(filePath);
  const manifest = readManifest(baseDir);

  return {
    advisory,
    skill: {
      name, description, filePath, baseDir, source,
      title: meta.title ?? name,
      order: Number.parseInt(meta.order ?? "", 10) || 99,
      disableModelInvocation: manifest?.disableModelInvocation
        ?? (meta["disable-model-invocation"]?.toLowerCase() === "true"),
      enabled: manifest?.enabled ?? true,
      icon: manifest?.icon,
      author: manifest?.author,
      version: manifest?.version,
      contextMode: manifest?.contextMode ?? meta["context-mode"],
      requirements: manifest?.requires,
    },
  };
}

/** A skill.json with no SKILL.md beside it: metadata, and nothing to read. */
function skillFromManifest(
  path: string, expectedName: string, source: SkillSource,
): { skill?: Skill; advisory?: string } {
  let manifest: Record<string, any>;
  try {
    manifest = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    return { advisory: `Invalid skill.json: ${error instanceof Error ? error.message : error}` };
  }

  const name = manifest.name ?? expectedName;
  return {
    advisory: isValidName(name)
      ? undefined
      : `Skill name '${name}' should be lowercase alphanumeric with hyphens (max 64 chars)`,
    skill: {
      name,
      title: manifest.title ?? name,
      description: manifest.description ?? "",
      order: 99,
      filePath: path,
      baseDir: dirname(path),
      source,
      disableModelInvocation: manifest.disableModelInvocation ?? false,
      enabled: manifest.enabled ?? true,
      icon: manifest.icon,
      author: manifest.author,
      version: manifest.version,
      contextMode: manifest.contextMode,
      requirements: manifest.requires,
    },
  };
}

/**
 * Every skill directly under `directory`.
 *
 * One level, not a recursive walk: both directories that hold skills — the bundled
 * catalog and the user's — are flat by construction, and the recursive version this
 * replaces carried gitignore matching for project-local skill trees that nothing
 * ever created.
 */
function loadFrom(directory: string, source: SkillSource): LoadedSkills {
  const skills: Skill[] = [];
  const advisories: Array<{ path: string; message: string }> = [];

  let entries: string[];
  try {
    entries = readdirSync(directory);
  } catch {
    return { skills, advisories };
  }

  for (const entry of entries.sort()) {
    if (entry.startsWith(".") || entry === "node_modules") continue;
    const path = join(directory, entry);
    if (!statSync(path, { throwIfNoEntry: false })?.isDirectory()) continue;

    const skillFile = join(path, "SKILL.md");
    const manifestFile = join(path, "skill.json");
    const result = existsSync(skillFile) ? skillFrom(skillFile, entry, source)
      : existsSync(manifestFile) ? skillFromManifest(manifestFile, entry, source)
      : null;
    if (result === null) continue;

    if (result.skill !== undefined) skills.push(result.skill);
    if (result.advisory !== undefined) {
      advisories.push({ path: existsSync(skillFile) ? skillFile : manifestFile, message: result.advisory });
    }
  }

  return { skills, advisories };
}

/**
 * Load every skill in the given directories, duplicates included.
 *
 * Deliberately not deduplicated: the settings UI has to see both the bundled
 * copy of a skill and the user's installed one, because comparing their
 * versions is how it decides whether to offer an update. Callers that need one
 * skill per name say so — see `dedupe`.
 *
 * A symlink to a file already loaded is dropped, though: that is the same
 * skill reached twice, not two of them.
 */
export function loadSkills(
  directories: Array<{ path: string; source: SkillSource }>,
): LoadedSkills {
  const skills: Skill[] = [];
  const advisories: Array<{ path: string; message: string }> = [];
  const realPaths = new Set<string>();

  for (const { path, source } of directories) {
    const loaded = loadFrom(path, source);
    advisories.push(...loaded.advisories);

    for (const skill of loaded.skills) {
      let real: string;
      try {
        real = realpathSync(skill.filePath);
      } catch {
        real = skill.filePath;
      }
      if (realPaths.has(real)) continue;
      realPaths.add(real);
      skills.push(skill);
    }
  }

  return { skills, advisories };
}

/** One skill per name, first wins — the order the directories were given in. */
export function dedupe(skills: Skill[]): Skill[] {
  const seen = new Set<string>();
  return skills.filter((s) => {
    if (seen.has(s.name)) return false;
    seen.add(s.name);
    return true;
  });
}

/** Where a required binary actually is, or null when it is missing. */
export function locateBin(bin: BinRequirement): string | null {
  const onPath = Bun.which(bin.name);
  if (onPath !== null) return onPath;

  for (const candidate of bin.searchPaths ?? []) {
    const expanded = candidate.replace(/^~/, homedir());
    // A search path may name the binary itself or the directory holding it.
    const direct = basename(expanded) === bin.name ? expanded : join(expanded, bin.name);
    if (existsSync(direct)) return direct;
  }
  return null;
}

function escapeXML(text: string): string {
  return text
    .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;").replaceAll("'", "&apos;");
}

/**
 * The skills listing appended to the system prompt, or "" when it must be omitted.
 *
 * Gated on there being a read tool, because the listing's whole instruction is
 * "read this file when the task matches" — without one it is not merely useless,
 * it tells the model to do something it cannot.
 */
export function promptSection(skills: Skill[], hasReadTool: boolean): string {
  if (!hasReadTool) return "";

  // A skill with no description is one the model cannot choose — `pdf-extract`
  // is a `skill.json` declaring a required binary and nothing else. Listing it
  // spends context on an entry that answers no question.
  const visible = dedupe(skills).filter(
    (s) => s.enabled && !s.disableModelInvocation && s.description !== "");
  if (visible.length === 0) return "";

  const header = `

The following skills provide specialized instructions for specific tasks.
Use the read tool to load a skill's file when the task matches its description.
When a skill file references a relative path, resolve it against the skill's directory (the parent of its SKILL.md) and use that absolute path in tool commands.

<available_skills>`;

  const entries = visible.map((s) => `  <skill>
    <name>${escapeXML(s.name)}</name>
    <description>${escapeXML(s.description)}</description>
    <location>${escapeXML(s.filePath)}</location>
  </skill>`);

  return [header, ...entries, "</available_skills>"].join("\n");
}

/**
 * Where skills are, without the caller having to say.
 *
 * The bundled catalog is found three ways, in order: the `--skills` flag the
 * app passes its sidecar, the `OAK_SKILLS_DIR` environment variable, and then
 * beside the running executable — which is where it sits in the app bundle,
 * next to `oak` and `oak-backend` in Contents/Resources. The last of those is
 * what makes the CLI work without being told.
 *
 * The user's installed skills sit beside their library — `~/OakReader/skills`
 * next to `~/OakReader/library.sqlite` — which is why this takes the library
 * path and not the sidecar's own data directory; those are different places,
 * and using the wrong one finds no skills at all.
 *
 * The checkout fallback mirrors the prompt library's, so running from source
 * finds the repo's `skills/` without a flag.
 */
export function skillDirectories(libraryPath: string): Array<{ path: string; source: SkillSource }> {
  const flag = process.argv.indexOf("--skills");
  let bundled = flag !== -1 ? process.argv[flag + 1] : process.env.OAK_SKILLS_DIR;

  if (bundled === undefined || bundled === "") {
    const beside = join(dirname(process.execPath), "skills");
    if (existsSync(beside)) bundled = beside;
  }

  if (bundled === undefined) {
    try {
      const here = dirname(Bun.fileURLToPath(import.meta.url));
      const candidate = join(here, "..", "..", "skills");
      if (existsSync(candidate)) bundled = candidate;
    } catch {
      // A compiled binary has no meaningful module path; the others cover it.
    }
  }

  // User first, bundled second, because `dedupe` keeps the first of a name.
  // Installing a bundled skill copies it here to be edited; with bundled first
  // that copy was inert — the menu listed the user's version while the model
  // kept reading the shipped body. Shadowing is what installing means.
  const directories: Array<{ path: string; source: SkillSource }> = [];
  directories.push({ path: userSkillDirectory(libraryPath), source: "user" });
  if (bundled !== undefined) directories.push({ path: bundled, source: "bundled" });
  return directories;
}

/** Where a person's own skills live: beside their library. */
export function userSkillDirectory(libraryPath: string): string {
  return join(dirname(libraryPath), "skills");
}

/**
 * One skill's body — everything after the frontmatter.
 *
 * This is what a user-toggled skill injects into the prompt while it is on, and
 * what the agent reads when it decides a task matches. Read on demand because
 * the bodies are long: listing them would put every skill's full instructions
 * on the wire to show a menu of names.
 */
export function readBody(skills: Skill[], name: string): string {
  const skill = dedupe(skills).find((s) => s.name === name);
  if (skill === undefined || !skill.filePath.endsWith(".md")) return "";

  let text: string;
  try {
    text = readFileSync(skill.filePath, "utf8");
  } catch {
    return "";
  }

  const match = /^---\r?\n[\s\S]*?\r?\n---\r?\n?/.exec(text);
  return (match === null ? text : text.slice(match[0].length)).trim();
}
