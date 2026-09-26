/**
 * Skills: a directory with a SKILL.md at its root.
 *
 * The catalog is what ships beside the binary; installed skills live under the
 * data directory. A skill that is installed but absent from the catalog still
 * shows up — it was installed from somewhere, and hiding it would make
 * `uninstall` impossible to discover.
 *
 * `requirements.bins` names external tools a skill shells out to. None of the
 * bundled skills declare any today, but `oak skills check` exists to tell you
 * when one that does is missing its tool.
 */
import { readdir, readFile, rm, cp, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { skillsDirectory } from "./paths.ts";

export interface SkillBin {
  name: string;
  description?: string;
  searchPaths?: string[];
  versionArgs?: string[];
}

export interface Skill {
  name: string;
  description: string;
  author: string | null;
  baseDir: string;
  bins: SkillBin[];
}

/**
 * Read the YAML frontmatter of a SKILL.md.
 *
 * A deliberate subset — scalars, and `bins` as a list of named tables — rather
 * than a YAML dependency, because this is the only YAML in the program and the
 * schema is ours.
 */
export function parseFrontmatter(text: string): Record<string, unknown> {
  const match = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text);
  if (match === null) return {};

  const fields: Record<string, unknown> = {};
  let bins: SkillBin[] | null = null;
  let current: SkillBin | null = null;

  for (const raw of match[1]!.split(/\r?\n/)) {
    const line = raw.trimEnd();
    if (line.trim() === "" || line.trimStart().startsWith("#")) continue;

    const indent = line.length - line.trimStart().length;
    const body = line.trim();

    if (indent === 0) {
      if (current !== null && bins !== null) { bins.push(current); current = null; }
      const [key, ...rest] = body.split(":");
      const value = rest.join(":").trim();
      if (key === "requirements" || key === "bins") {
        bins = key === "bins" ? [] : bins;
        if (key === "bins") fields.bins = bins;
        continue;
      }
      if (value !== "") fields[key!.trim()] = stripQuotes(value);
      continue;
    }

    if (body.startsWith("bins:")) { bins = []; fields.bins = bins; continue; }
    if (bins === null) continue;

    if (body.startsWith("- ")) {
      if (current !== null) bins.push(current);
      current = { name: "" };
      const [key, ...rest] = body.slice(2).split(":");
      const value = rest.join(":").trim();
      if (value !== "") assignBin(current, key!.trim(), stripQuotes(value));
      continue;
    }
    if (current !== null) {
      const [key, ...rest] = body.split(":");
      assignBin(current, key!.trim(), stripQuotes(rest.join(":").trim()));
    }
  }
  if (current !== null && bins !== null) bins.push(current);
  return fields;
}

function stripQuotes(value: string): string {
  return value.replace(/^["'](.*)["']$/, "$1");
}

function assignBin(bin: SkillBin, key: string, value: string): void {
  if (key === "name") bin.name = value;
  else if (key === "description") bin.description = value;
  else if (key === "searchPaths") bin.searchPaths = splitList(value);
  else if (key === "versionArgs") bin.versionArgs = splitList(value);
}

function splitList(value: string): string[] {
  return value.replace(/^\[|\]$/g, "").split(",")
    .map((v) => stripQuotes(v.trim())).filter((v) => v !== "");
}

async function loadFrom(directory: string): Promise<Skill[]> {
  let entries;
  try {
    entries = await readdir(directory, { withFileTypes: true });
  } catch {
    return [];
  }

  const skills: Skill[] = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith(".")) continue;
    const baseDir = join(directory, entry.name);
    const text = await readFile(join(baseDir, "SKILL.md"), "utf8").catch(() => null);
    if (text === null) continue;

    const fields = parseFrontmatter(text);
    skills.push({
      name: typeof fields.name === "string" ? fields.name : entry.name,
      description: typeof fields.description === "string" ? fields.description : "",
      author: typeof fields.author === "string" ? fields.author : null,
      baseDir,
      bins: Array.isArray(fields.bins) ? fields.bins as SkillBin[] : [],
    });
  }
  return skills.sort((a, b) => a.name.localeCompare(b.name));
}

/** Where the bundled skills are: beside the binary, or up in a checkout. */
function catalogDirectory(): string {
  const beside = join(dirname(process.execPath), "skills");
  const fromSource = join(dirname(dirname(dirname(import.meta.path))), "skills");
  return Bun.env.OAK_SKILLS_DIR ?? (existsSync(beside) ? beside : fromSource);
}

function existsSync(path: string): boolean {
  try {
    return Bun.file(join(path, ".")).size >= 0;
  } catch {
    return false;
  }
}

export async function loadCatalog(): Promise<Skill[]> {
  const catalog = await loadFrom(catalogDirectory());
  const installed = await loadFrom(skillsDirectory());
  const known = new Set(catalog.map((s) => s.name));
  return [...catalog, ...installed.filter((s) => !known.has(s.name))];
}

export async function installedNames(): Promise<Set<string>> {
  const entries = await readdir(skillsDirectory(), { withFileTypes: true }).catch(() => []);
  return new Set(entries.filter((e) => e.isDirectory()).map((e) => e.name));
}

export async function loadInstalled(): Promise<Skill[]> {
  return await loadFrom(skillsDirectory());
}

export async function install(skill: Skill): Promise<string> {
  const destination = join(skillsDirectory(), skill.name);
  await mkdir(skillsDirectory(), { recursive: true });
  await rm(destination, { recursive: true, force: true });
  await cp(skill.baseDir, destination, { recursive: true });
  return destination;
}

export async function uninstall(name: string): Promise<boolean> {
  const destination = join(skillsDirectory(), name);
  const entries = await readdir(destination).catch(() => null);
  if (entries === null) return false;
  await rm(destination, { recursive: true, force: true });
  return true;
}

/** Where a required tool actually is, or null when it is missing. */
export function locateBin(bin: SkillBin): string | null {
  const onPath = Bun.which(bin.name);
  if (onPath !== null) return onPath;
  for (const directory of bin.searchPaths ?? []) {
    const candidate = join(directory.replace(/^~/, Bun.env.HOME ?? "~"), bin.name);
    if (Bun.file(candidate).size > 0) return candidate;
  }
  return null;
}
