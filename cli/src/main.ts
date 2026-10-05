#!/usr/bin/env bun
/**
 * `oak` — the OakReader command line.
 *
 * Reads are this program's own (see `queries.ts`); writes go through the core's
 * stores, the same ones the app's sidecar uses. That split is the reason this
 * was rewritten from Swift: the old CLI carried a second implementation of the
 * catalog, so every rule with two copies — Tags is multi-select, Status is
 * single-select, a cite key must be unique — could drift between them.
 */
import { newId } from "../../backend/src/catalog/ids.ts";
import { existsSync, readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { basename, join as joinPath, resolve as resolvePath } from "node:path";
import { homedir } from "node:os";
import { Catalog } from "../../backend/src/catalog/db.ts";
import { CollectionStore } from "../../backend/src/catalog/collections.ts";
import { LOCAL_USER } from "../../backend/src/catalog/system.ts";
import { PropertyStore } from "../../backend/src/catalog/properties.ts";
import { flag, integer, option, parse, type Parsed } from "./args.ts";
import { childNames, findCommand, helpText } from "./help.ts";
import { Importer, type ImportResult } from "./import.ts";
import { Output } from "./output.ts";
import { attachmentFile, dataDirectory, libraryPath } from "./paths.ts";
import { Queries } from "./queries.ts";
import { OakError, Resolver, notFound } from "./resolve.ts";
import { readDocument } from "./extract.ts";
import * as format from "./format.ts";
import * as skills from "../../backend/src/skills.ts";
import { recognize, type Recognized } from "../../backend/src/metadata/recognize.ts";
import { ReferenceStore } from "../../backend/src/catalog/references.ts";

const VERSION = "1.0.0";

/** Long tokens that never take a value. Everything else expects one. */
const BOOLEANS = new Set([
  "json", "quiet", "version", "help", "h", "today", "csv", "markdown",
  "apply", "all", "explain", "offline", "force",
]);

interface Context {
  parsed: Parsed;
  out: Output;
  catalog: Catalog;
  q: Queries;
  resolver: Resolver;
  now: string;
}

async function main(argv: string[]): Promise<number> {
  const parsed = parse(argv, childNames, BOOLEANS);
  const out = new Output(flag(parsed, "json"), flag(parsed, "quiet"));

  if (flag(parsed, "version")) {
    console.log(VERSION);
    return 0;
  }
  if (flag(parsed, "help") || flag(parsed, "h")) {
    console.log(helpText(parsed.path));
    return 0;
  }

  // A subcommand group with nothing after it runs its default, the way
  // `oak items` has always meant `oak items list`.
  const node = findCommand(parsed.path);
  if (node?.defaultSubcommand !== undefined && parsed.path.length > 0) {
    parsed.path.push(node.defaultSubcommand);
  }

  const command = parsed.path.join(" ");
  const operation = OPERATIONS[command];
  if (command !== "" && operation === undefined) {
    out.error(command, `Unknown command '${command}'.`, "unknown_command");
    if (!out.json) console.error(helpText([]));
    return 1;
  }

  const path = libraryPath(option(parsed, "db") ?? undefined);
  if (!existsSync(path)) {
    out.error(command === "" ? "stats" : command,
      `Database not found at ${path}. Is OakReader installed and has it been launched at least once?`,
      "no_database");
    return 1;
  }

  const catalog = Catalog.open(path);
  try {
    const context: Context = {
      parsed, out, catalog,
      q: new Queries(catalog.db),
      resolver: new Resolver(new Queries(catalog.db)),
      now: new Date().toISOString(),
    };
    await (operation ?? showStats)(context);
    return 0;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const code = error instanceof OakError ? error.code : "error";
    out.error(command === "" ? "stats" : command, message, code);
    return 1;
  } finally {
    catalog.close();
  }
}

// --- root ----------------------------------------------------------------

function showStats({ q, out }: Context): void {
  const stats = q.stats();
  if (out.json) {
    out.success("stats", stats);
    return;
  }
  console.log(format.stats(stats));
  console.log("");
  console.log("Run 'oak --help' for available commands.");
}

// --- items ---------------------------------------------------------------

function itemsList({ parsed, q, out }: Context): void {
  const entries = q.listItems({
    collectionName: option(parsed, "collection") ?? undefined,
    tagName: option(parsed, "tag") ?? undefined,
    type: option(parsed, "type") ?? undefined,
    search: option(parsed, "search") ?? undefined,
    sort: option(parsed, "sort") ?? undefined,
    limit: integer(parsed, "limit") ?? undefined,
  });

  if (out.json) {
    out.results("items.list", entries, { count: entries.length });
    return;
  }
  console.log(format.itemList(entries));
}

function itemsShow({ parsed, q, resolver, out }: Context): void {
  const input = requireArgument(parsed, 0, "item");
  const resolved = resolver.item(input);
  const found = q.findItem(resolved.id);
  if (found === null) throw notFound("item", input);

  const tags = q.itemTags(resolved.id);
  const status = q.itemStatus(resolved.id);
  const collections = q.itemCollections(resolved.id);

  if (out.json) {
    out.success("items.show", { ...found, tags, status, collections });
    return;
  }
  console.log(format.itemDetail(found.item, found.attachments, tags, status, collections));
}

async function itemsRead({ parsed, q, resolver, out }: Context): Promise<void> {
  const resolved = resolver.item(requireArgument(parsed, 0, "item"));
  const location = q.itemFilePath(resolved.id);
  if (location === null) {
    throw new OakError(`No primary attachment found for '${resolved.title}'.`);
  }

  const { attachmentFile } = await import("./paths.ts");
  const path = attachmentFile(
    location.itemStorageKey, location.attachmentStorageKey, location.fileName);
  if (!existsSync(path)) throw new OakError(`File not found: ${path}`);

  const text = await readDocument(path, location.contentType, option(parsed, "pages"));
  // Capped for the same reason the Swift original capped it: this output is
  // usually being read by a model with a context window.
  const content = text.slice(0, 100_000);

  if (out.json) {
    out.success("items.read", {
      title: resolved.title, citeKey: resolved.citeKey,
      contentType: location.contentType, pageCount: location.pageCount, content,
    });
    return;
  }
  console.log(content);
}

function itemsOpen({ parsed, resolver, out }: Context): void {
  const resolved = resolver.item(requireArgument(parsed, 0, "item"));
  Bun.spawnSync(["/usr/bin/open", `oakreader://open/${resolved.id}`]);

  const message = `Opening '${resolved.title}' in OakReader...`;
  if (out.json) out.success("items.open", { id: resolved.id, message });
  else console.log(message);
}

// --- collections ---------------------------------------------------------

function collectionsList({ q, out }: Context): void {
  const collections = q.listCollections();
  const counts = new Map(collections.map((c) => [c.id, q.collectionItemCount(c.id)]));

  if (out.json) {
    out.results("collections.list",
      collections.map((c) => ({ collection: c, count: counts.get(c.id) ?? 0 })),
      { count: collections.length });
    return;
  }
  console.log(format.collectionTree(collections, counts));
}

function collectionsCreate({ parsed, catalog, q, resolver, out, now }: Context): void {
  const name = requireArgument(parsed, 0, "name");
  const parentName = option(parsed, "parent");
  const parentId = parentName === null ? null : resolver.collection(parentName).id;

  const id = newId();
  new CollectionStore(catalog.db, LOCAL_USER).upsert({
    id, name, icon: "folder", sortOrder: q.nextCollectionOrder(), parentId,
    isSmart: false, isSystem: false, filterRules: null, source: null, sourceKey: null,
    createdAt: now, updatedAt: now,
  });

  const message = `Created collection '${name}'`;
  if (out.json) out.success("collections.create", { id, message });
  else console.log(`${message} [${id.slice(0, 8)}]`);
}

function collectionsRename({ parsed, catalog, resolver, out, now }: Context): void {
  const collection = resolver.collection(requireArgument(parsed, 0, "collection"));
  const newName = requireArgument(parsed, 1, "new name");

  if (collection.isSystem) {
    throw new OakError(`Cannot rename system collection '${collection.name}'.`);
  }

  new CollectionStore(catalog.db, LOCAL_USER).upsert({
    ...collection, name: newName, filterRules: null, source: null, sourceKey: null,
    createdAt: collection.createdAt, updatedAt: now,
  });

  const message = `Renamed '${collection.name}' -> '${newName}'`;
  if (out.json) out.success("collections.rename", { id: collection.id, message });
  else console.log(`Renamed collection '${collection.name}' -> '${newName}'`);
}

function collectionsAdd(context: Context): void {
  setMembership(context, true);
}

function collectionsRemove(context: Context): void {
  setMembership(context, false);
}

function setMembership(
  { parsed, catalog, resolver, out, now }: Context, member: boolean,
): void {
  const collection = resolver.collection(requireArgument(parsed, 0, "collection"));
  const item = resolver.item(requireArgument(parsed, 1, "item"));

  if (member && (collection.isSmart || collection.isSystem)) {
    throw new OakError(
      `Cannot manually add items to smart/system collection '${collection.name}'.`);
  }

  const store = new CollectionStore(catalog.db, LOCAL_USER);
  if (member) store.addItem(item.id, collection.id, now);
  else store.removeItem(item.id, collection.id);

  const operation = member ? "collections.add" : "collections.remove";
  const message = member
    ? `Added '${item.title}' to '${collection.name}'`
    : `Removed '${item.title}' from '${collection.name}'`;
  if (out.json) out.success(operation, { id: item.id, message });
  else console.log(member
    ? `Added '${item.title}' to collection '${collection.name}'`
    : `Removed '${item.title}' from collection '${collection.name}'`);
}

// --- tags ----------------------------------------------------------------

function tagsList({ q, out }: Context): void {
  const tags = q.listTags();
  if (out.json) {
    out.results("tags.list",
      tags,
      { count: tags.length });
    return;
  }
  console.log(format.tagList(tags));
}

function tagsCreate({ parsed, catalog, q, out }: Context): void {
  const name = requireArgument(parsed, 0, "name");
  const propertyId = requireProperty(q, "Tags");

  const id = newId();
  new PropertyStore(catalog.db).upsertOption({
    id, propertyId, name, colorHex: option(parsed, "color") ?? "999999",
    position: q.nextOptionPosition(propertyId),
  });

  const message = `Created tag '${name}'`;
  if (out.json) out.success("tags.create", { id, message });
  else console.log(`${message} [${id.slice(0, 8)}]`);
}

function tagsRename({ parsed, catalog, resolver, out }: Context): void {
  const tag = resolver.tag(requireArgument(parsed, 0, "tag"));
  const newName = requireArgument(parsed, 1, "new name");

  new PropertyStore(catalog.db).upsertOption({ ...tag, name: newName });

  const message = `Renamed '${tag.name}' -> '${newName}'`;
  if (out.json) out.success("tags.rename", { id: tag.id, message });
  else console.log(`Renamed tag '${tag.name}' -> '${newName}'`);
}

function tagsAdd({ parsed, catalog, q, resolver, out }: Context): void {
  const tag = resolver.tag(requireArgument(parsed, 0, "tag"));
  const item = resolver.item(requireArgument(parsed, 1, "item"));
  const propertyId = requireProperty(q, "Tags");

  // The core decides whether this appends or replaces, by reading the
  // property's type. Tags is multi-select, so it appends.
  new PropertyStore(catalog.db).addSelectValue(newId(), item.id, propertyId, tag.id);

  const message = `Tagged '${item.title}' with '${tag.name}'`;
  if (out.json) out.success("tags.add", { id: item.id, message });
  else console.log(message);
}

function tagsRemove({ parsed, catalog, q, resolver, out }: Context): void {
  const tag = resolver.tag(requireArgument(parsed, 0, "tag"));
  const item = resolver.item(requireArgument(parsed, 1, "item"));
  const propertyId = requireProperty(q, "Tags");

  new PropertyStore(catalog.db).removeSelectValue(item.id, propertyId, tag.id);

  const message = `Removed tag '${tag.name}' from '${item.title}'`;
  if (out.json) out.success("tags.remove", { id: item.id, message });
  else console.log(`Removed tag '${tag.name}' from '${item.title}'`);
}

// --- status --------------------------------------------------------------

function status({ parsed, catalog, q, resolver, out }: Context): void {
  const item = resolver.item(requireArgument(parsed, 0, "item"));
  const value = parsed.positionals[1];

  if (value === undefined) {
    const current = q.itemStatus(item.id);
    if (out.json) {
      out.success("status.show",
        { itemId: item.id, title: item.title, status: current?.name ?? null });
      return;
    }
    console.log(format.status(item, current));
    return;
  }

  const option_ = resolver.status(value);
  const propertyId = requireProperty(q, "Status");
  // Status is single-select, so the core replaces rather than appends.
  new PropertyStore(catalog.db).addSelectValue(
    newId(), item.id, propertyId, option_.id);

  const message = `Set status of '${item.title}' to '${option_.name}'`;
  if (out.json) out.success("status.set", { id: item.id, message });
  else console.log(message);
}

// --- import and open -----------------------------------------------------

async function importSource(context: Context): Promise<void> {
  const { parsed, catalog, q, resolver, out, now } = context;
  const source = requireArgument(parsed, 0, "source");
  const title = option(parsed, "title");
  const importer = new Importer(catalog.db, q);

  let result: ImportResult;
  if (source.startsWith("http://") || source.startsWith("https://")) {
    result = await importer.importURL(source, title, { archive: flag(parsed, "archive") });
  } else {
    const path = resolvePath(source.replace(/^~/, homedir()));
    if (!existsSync(path)) throw notFound("file", source);

    const extension = basename(path).split(".").pop()?.toLowerCase() ?? "";
    switch (extension) {
      case "pdf": result = await importer.importPDF(path, title); break;
      case "html": case "htm": result = await importer.importHTML(path, title, null); break;
      case "md": case "markdown": result = await importer.importMarkdown(path, title); break;
      default:
        throw new OakError(
          `Unsupported file type: ${extension === "" ? "(none)" : `.${extension}`}`);
    }
  }

  // --collection and --tag are conveniences on top of the import; a failure to
  // apply one is a warning, not a reason to disown the item just filed.
  //
  // But it has to be a *visible* warning. These used to go to stderr only,
  // which is fine for a person watching a terminal and useless to the agent
  // reading the JSON: it saw "Imported 'X'" and reported the paper filed into
  // a collection that had refused it. The outcome is part of the result now.
  let collection: string | null = null;
  let tag: string | null = null;
  const problems: string[] = [];

  const collectionName = option(parsed, "collection");
  if (collectionName !== null) {
    try {
      const resolved = resolver.collection(collectionName);
      new CollectionStore(catalog.db, LOCAL_USER).addItem(result.itemId, resolved.id, now);
      collection = resolved.name;
    } catch (error) {
      const message = `Failed to add to collection '${collectionName}': `
        + (error instanceof Error ? error.message : String(error));
      problems.push(message);
      warn(`Failed to add to collection '${collectionName}'`, error);
    }
  }
  const tagName = option(parsed, "tag");
  if (tagName !== null) {
    try {
      const resolved = resolver.tag(tagName);
      new PropertyStore(catalog.db).addSelectValue(
        newId(), result.itemId, requireProperty(q, "Tags"), resolved.id);
      tag = resolved.name;
    } catch (error) {
      const message = `Failed to tag '${tagName}': `
        + (error instanceof Error ? error.message : String(error));
      problems.push(message);
      warn(`Failed to tag '${tagName}'`, error);
    }
  }

  // A document already in the library is not an error, and not a reason to
  // skip the filing: "add this one too, into X" is a reasonable thing to say
  // about something already imported.
  const message = (result.isDuplicate ? `Already imported '${result.title}'` : `Imported '${result.title}'`)
    + (collection !== null ? ` into '${collection}'` : "");
  if (out.json) {
    out.success("import", {
      id: result.itemId, title: result.title, message,
      isDuplicate: result.isDuplicate, collection, tag, warnings: problems,
    });
  } else {
    console.log(`${message} [${result.itemId.slice(0, 8)}]`);
  }
}

function openFile({ parsed, out }: Context): void {
  const input = requireArgument(parsed, 0, "file");
  const path = resolvePath(input.replace(/^~/, homedir()));
  if (!existsSync(path)) throw notFound("file", path);

  // Target the app this CLI ships inside rather than "OakReader" by name:
  // LaunchServices resolves a name to whichever bundle claims it, so a dev
  // build's `oak` would hand the release app a path from a library it does
  // not own.
  const bundle = process.env.OAK_CHANNEL === "dev"
    ? "com.oakreader.OakReader.dev" : "com.oakreader.OakReader";
  Bun.spawnSync(["/usr/bin/open", "-b", bundle, path]);

  if (out.json) {
    out.success("open", { id: null, message: `Opened '${basename(path)}' in OakReader` });
  }
}

// --- search --------------------------------------------------------------

function search({ parsed, q, out }: Context): void {
  const query = parsed.positionals.join(" ");
  if (query === "") throw new OakError("Search query cannot be empty.");

  const results = q.search(query, integer(parsed, "limit") ?? 20);
  if (out.json) {
    out.results("search", results, { count: results.length });
    return;
  }
  console.log(format.searchResults(results, query, "keyword"));
}

// --- words and notes -----------------------------------------------------

/**
 * `--today` / `--since` as an ISO8601 lower bound.
 *
 * Compared lexically against the stored timestamps, which works because they
 * are all UTC in the same format — and breaks silently if that ever stops
 * being true.
 */
function resolveSince(parsed: Parsed): string | null {
  if (flag(parsed, "today")) {
    const start = new Date();
    start.setHours(0, 0, 0, 0);
    return start.toISOString();
  }
  const since = option(parsed, "since");
  if (since === null) return null;

  if (!/^\d{4}-\d{2}-\d{2}$/.test(since)) {
    throw new OakError(`Invalid --since date '${since}'. Use YYYY-MM-DD.`);
  }
  const [year, month, day] = since.split("-").map(Number) as [number, number, number];
  return new Date(year, month - 1, day, 0, 0, 0, 0).toISOString();
}

/**
 * What was asked through Quick Chat, newest first.
 *
 * Reads the app's own JSONL log rather than a database: the panel appends one
 * line per answer, and the point of a log is that reading it needs no schema.
 * A malformed line is skipped rather than fatal — a half-written final line is
 * the normal state of a file something else is appending to.
 */
function quickchat({ parsed, out }: Context): void {
  const path = joinPath(dataDirectory(), "agent", "quickchat.jsonl");
  if (!existsSync(path)) {
    console.log("No Quick Chat history yet.");
    return;
  }

  const since = resolveSince(parsed);
  const entries: QuickChatEntry[] = [];
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (line.trim() === "") continue;
    try {
      const entry = JSON.parse(line) as QuickChatEntry;
      if (since !== null && entry.at < since) continue;
      entries.push(entry);
    } catch {
      continue;
    }
  }
  entries.reverse();

  const limit = integer(parsed, "limit") ?? 50;
  const shown = entries.slice(0, limit);

  if (out.json) {
    out.results("quickchat.list", shown, { count: shown.length });
    return;
  }
  if (shown.length === 0) {
    console.log(flag(parsed, "today")
      ? "Nothing asked through Quick Chat today."
      : "No Quick Chat history found.");
    return;
  }

  for (const entry of shown) {
    const where = entry.app === null || entry.app === undefined
      ? entry.source
      : entry.app;
    const asked = entry.skill.replaceAll("\n", " ");
    console.log(`${format.shortDate(entry.at)}  ${asked}  ·  ${where}`);
    if (flag(parsed, "full")) {
      if (entry.text !== "") console.log(indent(entry.text, "  > "));
      console.log(indent(entry.reply, "    "));
      console.log("");
    } else {
      console.log(indent(snippet(entry.reply, 160), "    "));
    }
  }
  out.message(`\n${format.plural(shown.length, "exchange")}.`);
}

interface QuickChatEntry {
  at: string;
  source: string;
  app?: string | null;
  appId?: string | null;
  skill: string;
  typed: boolean;
  text: string;
  reply: string;
}

function snippet(text: string, max: number): string {
  const flat = text.replaceAll("\n", " ").trim();
  return flat.length > max ? `${flat.slice(0, max)}…` : flat;
}

function indent(text: string, prefix: string): string {
  return text.split("\n").map((line) => `${prefix}${line}`).join("\n");
}

function words({ parsed, q, out }: Context): void {
  const lookups = q.wordLookups(resolveSince(parsed), integer(parsed, "limit") ?? 100);

  if (out.json) {
    out.results("words.list", lookups, { count: lookups.length });
    return;
  }
  if (flag(parsed, "csv")) {
    console.log(wordsCSV(lookups));
    return;
  }
  if (lookups.length === 0) {
    console.log(flag(parsed, "today") ? "No words looked up today." : "No word lookups found.");
    return;
  }
  for (const l of lookups) {
    const sentence = l.sentence.replaceAll("\n", " ");
    const snippet = sentence.length > 64 ? `${sentence.slice(0, 64)}…` : sentence;
    const document = l.itemTitle === "" ? "" : `  (${l.itemTitle})`;
    console.log(`${l.word}  —  ${snippet}${document}  ·  ${format.shortDate(l.createdAt)}`);
  }
  out.message(`\n${format.plural(lookups.length, "word")}.`);
}

function wordsCSV(lookups: ReturnType<Queries["wordLookups"]>): string {
  const escape = (field: string) => `"${field.replaceAll('"', '""')}"`;
  return ["Word,Sentence,Explanation,Document,Created At",
    ...lookups.map((l) =>
      [l.word, l.sentence, l.explanation, l.itemTitle, l.createdAt].map(escape).join(",")),
  ].join("\n");
}

function notes({ parsed, q, resolver, out }: Context): void {
  const itemInput = option(parsed, "item");
  let itemId: string | null = null;
  let title = "Library";
  if (itemInput !== null) {
    const item = resolver.item(itemInput);
    itemId = item.id;
    title = item.title;
  }

  const found = q.notes(itemId, resolveSince(parsed), integer(parsed, "limit"));

  // Markdown wins over --json: it is the copy-into-your-notes path, and a
  // caller that asked for a document does not want an envelope around it.
  if (flag(parsed, "markdown")) {
    console.log(format.notesMarkdown(found, title));
    return;
  }
  if (out.json) {
    out.results("notes.list", found, { count: found.length });
    return;
  }
  if (found.length === 0) {
    console.log(itemInput === null ? "No notes yet." : `No notes for '${title}'.`);
    return;
  }
  for (const note of found) {
    const preview = format.truncate(note.comment.replaceAll("\n", " "), 72);
    const document = itemInput === null && note.itemTitle !== "" ? `  (${note.itemTitle})` : "";
    console.log(`${format.noteTimestamp(note.createdAt)}  —  ${preview}${document}`);
  }
  out.message(`\n${format.plural(found.length, "note")}.`);
}

// --- skills --------------------------------------------------------------

/**
 * Where this CLI looks for skills.
 *
 * The same two places the app uses, read by the same module — this used to be
 * a third copy of the directory walk, after the app's and the core's.
 */
function skillDirectories(): Array<{ path: string; source: skills.SkillSource }> {
  return skills.skillDirectories(libraryPath());
}

function installedSkills(): skills.Skill[] {
  return skills.loadSkills(
    [{ path: skills.userSkillDirectory(libraryPath()), source: "user" }]).skills;
}

/** Copy a skill into the user's directory, replacing any previous copy. */
async function installSkill(skill: skills.Skill): Promise<string> {
  const { cp, mkdir, rm } = await import("node:fs/promises");
  const directory = skills.userSkillDirectory(libraryPath());
  const destination = joinPath(directory, skill.name);
  await mkdir(directory, { recursive: true });
  await rm(destination, { recursive: true, force: true });
  await cp(skill.baseDir, destination, { recursive: true });
  return destination;
}

async function uninstallSkill(name: string): Promise<boolean> {
  const { rm, stat } = await import("node:fs/promises");
  const destination = joinPath(skills.userSkillDirectory(libraryPath()), name);
  if (await stat(destination).catch(() => null) === null) return false;
  await rm(destination, { recursive: true, force: true });
  return true;
}


async function skillsList({ out }: Context): Promise<void> {
  const catalog = skills.loadSkills(skillDirectories()).skills;
  const installed = new Set(installedSkills().map((s) => s.name));

  if (out.json) {
    out.results("skills.list", catalog.map((s) => ({
      name: s.name, description: s.description, installed: installed.has(s.name),
    })), { count: catalog.length });
    return;
  }
  if (catalog.length === 0) {
    console.log("No skills found.");
    return;
  }

  console.log("SKILLS");
  console.log("─".repeat(80));
  console.log(`${format.pad("NAME", 20)}${format.pad("STATUS", 12)}`
    + `${format.pad("DESCRIPTION", 32)}BINS`);
  console.log("─".repeat(80));
  for (const skill of catalog) {
    const required = skill.requirements?.bins ?? [];
    const missing = required.filter((b) => skills.locateBin(b) === null).length;
    const bins = required.length === 0 ? "—"
      : missing === 0 ? `${required.length} ok`
      : `${missing}/${required.length} missing`;
    console.log(
      `${format.pad(skill.name, 20)}`
      + `${format.pad(installed.has(skill.name) ? "installed" : "available", 12)}`
      + `${format.pad(skill.description.slice(0, 30), 32)}${bins}`);
  }
}

async function skillsShow({ parsed, out }: Context): Promise<void> {
  const name = requireArgument(parsed, 0, "name");
  const skill = skills.loadSkills(skillDirectories()).skills.find((s) => s.name === name);
  if (skill === undefined) {
    throw new OakError(
      `Skill '${name}' not found. Run 'oak skills' to see available skills.`, "not_found");
  }
  const installed = installedSkills().some((s) => s.name === name);

  if (out.json) {
    out.success("skills.show", {
      name: skill.name, description: skill.description,
      installed, author: skill.author, baseDir: skill.baseDir,
    });
    return;
  }

  console.log(`${skill.name} (${installed ? "installed" : "not installed"})`);
  if (skill.description !== "") console.log(skill.description);
  if (skill.author !== null) console.log(`Author: ${skill.author}`);
  console.log("");

  const bins = skill.requirements?.bins ?? [];
  if (bins.length > 0) {
    console.log("DEPENDENCIES");
    console.log("─".repeat(60));
    for (const bin of bins) {
      const path = skills.locateBin(bin);
      console.log(`  ${path !== null ? "✓" : "✗"} ${bin.name}`);
      if (bin.description !== undefined) console.log(`    ${bin.description}`);
      console.log(`    ${path ?? "not found"}`);
    }
    console.log("");
  }

  console.log(`Location: ${skill.baseDir}`);
}

async function skillsInstall({ parsed, out }: Context): Promise<void> {
  const name = requireArgument(parsed, 0, "name");
  const skill = skills.loadSkills(skillDirectories()).skills.find((s) => s.name === name);
  if (skill === undefined) {
    throw new OakError(
      `Skill '${name}' not found. Run 'oak skills' to see available skills.`, "not_found");
  }

  const destination = await installSkill(skill);
  const message = `Installed '${name}' to ${destination}`;
  if (out.json) out.success("skills.install", { id: null, message });
  else console.log(message);
}

async function skillsUninstall({ parsed, out }: Context): Promise<void> {
  const name = requireArgument(parsed, 0, "name");
  if (!await uninstallSkill(name)) {
    throw new OakError(`Skill '${name}' is not installed.`, "not_found");
  }

  const message = `Uninstalled '${name}'.`;
  if (out.json) out.success("skills.uninstall", { id: null, message });
  else console.log(message);
}

async function skillsCheck({ out }: Context): Promise<void> {
  const installed = installedSkills();
  if (installed.length === 0) {
    const message = "No skills installed.";
    if (out.json) out.success("skills.check", { id: null, message });
    else console.log("No skills installed. Run 'oak skills install <name>' to install one.");
    return;
  }

  const issues = installed.flatMap((skill) =>
    (skill.requirements?.bins ?? []).filter((b) => skills.locateBin(b) === null)
      .map((b) => `${skill.name}: ${b.name} not found`));

  if (out.json) {
    if (issues.length === 0) {
      out.success("skills.check",
        { id: null, message: "All installed skill dependencies are satisfied." });
    } else {
      out.error("skills.check", issues.join("; "), "missing_deps");
    }
    return;
  }
  if (issues.length === 0) console.log("All installed skill dependencies are satisfied.");
  else for (const issue of issues) console.log(`WARNING: ${issue}`);
}


// --- metadata ------------------------------------------------------------

/**
 * Work out what a document is, and optionally write it down.
 *
 * The same recogniser the app uses, which is the point: a library curated
 * from the terminal and one curated in the window agree about what a document
 * is, because there is one implementation of "what is this" and both call it.
 *
 * `--all` is the sweep. A library imported before the recogniser existed is
 * full of items named after their files; this is how they get their real
 * names without opening each one.
 */
async function metadata(ctx: Context): Promise<void> {
  const { parsed, out } = ctx;
  if (flag(parsed, "all")) return await metadataSweep(ctx);

  const target = requireArgument(parsed, 0, "item");
  const found = await recognizeItem(ctx, target);

  if (flag(parsed, "apply")) await applyRecognition(ctx, found);

  if (out.json) {
    out.success("metadata", {
      item: found.title, csl: found.recognized.csl,
      method: found.recognized.method, confidence: found.recognized.confidence,
      provider: found.recognized.provider ?? null,
      identifiers: found.recognized.identifiers,
      applied: flag(parsed, "apply"),
      trail: flag(parsed, "explain") ? found.recognized.trail : undefined,
    });
    return;
  }

  console.log(format.recognition(found.recognized, found.title));
  if (flag(parsed, "explain")) {
    console.log("\nHow:");
    for (const step of found.recognized.trail) console.log(`  ${step}`);
  }
  if (flag(parsed, "apply")) console.log("\nSaved.");
  else console.log("\nRun again with --apply to save it.");
}

/** Every item the recogniser could improve, sweep. */
async function metadataSweep(ctx: Context): Promise<void> {
  const { parsed, catalog, out } = ctx;
  const apply = flag(parsed, "apply");
  const limit = Number(option(parsed, "limit") ?? "50");
  const onlyMissing = !flag(parsed, "force");

  const rows = catalog.db.query<{ id: string; title: string }, []>(
    `SELECT i.id, i.title FROM items i
      WHERE i.deleted_at IS NULL
        ${onlyMissing ? "AND i.id NOT IN (SELECT item_id FROM citations)" : ""}
      ORDER BY i.created_at DESC`).all().slice(0, Math.max(1, limit));

  if (rows.length === 0) {
    if (out.json) out.success("metadata.sweep", { considered: 0, resolved: 0, items: [] });
    else console.log("Every item already has reference metadata.");
    return;
  }

  const results: Array<Record<string, unknown>> = [];
  let resolved = 0;
  for (const row of rows) {
    let found;
    try {
      found = await recognizeItem(ctx, row.id);
    } catch (error) {
      results.push({ item: row.title, error: error instanceof Error ? error.message : String(error) });
      continue;
    }
    if (found.recognized.confidence >= 0.5) resolved++;
    if (apply) await applyRecognition(ctx, found);
    results.push({
      item: row.title, title: found.recognized.csl.title,
      method: found.recognized.method, confidence: found.recognized.confidence,
      provider: found.recognized.provider ?? null,
    });
    if (!out.json) console.log(format.recognitionLine(found.recognized, row.title));
  }

  if (out.json) {
    out.success("metadata.sweep", {
      considered: rows.length, resolved, applied: apply, items: results });
    return;
  }
  console.log(`\n${resolved}/${rows.length} identified.`
    + (apply ? " Saved." : " Run again with --apply to save them."));
}

/** Recognise one item, by whatever the user named it with. */
async function recognizeItem(
  { parsed, q, resolver }: Context, target: string,
): Promise<{ id: string; title: string; recognized: Recognized }> {
  const item = resolver.item(target);
  const identifier = option(parsed, "identifier");

  let data: Uint8Array | undefined;
  let fileName: string | undefined;
  if (identifier === null) {
    const location = q.itemFilePath(item.id);
    if (location !== null && location.contentType === "pdf") {
      const path = attachmentFile(
        location.itemStorageKey, location.attachmentStorageKey, location.fileName);
      fileName = location.fileName;
      if (existsSync(path)) data = new Uint8Array(await readFile(path));
    }
  }

  const recognized = await recognize({
    data, fileName,
    title: item.title === "" ? undefined : item.title,
    author: item.author === "" ? undefined : item.author,
    identifier: identifier ?? undefined,
    offline: flag(parsed, "offline"),
  });
  return { id: item.id, title: item.title, recognized };
}

/** Write a recognition into the catalog, the way the app would. */
async function applyRecognition(
  { catalog, now }: Context,
  found: { id: string; recognized: Recognized },
): Promise<void> {
  new ReferenceStore(catalog.db).save(
    found.id, JSON.stringify(found.recognized.csl), null, now);
}

// --- plumbing ------------------------------------------------------------

const OPERATIONS: Record<string, (c: Context) => void | Promise<void>> = {
  "items list": itemsList,
  "items show": itemsShow,
  "items read": itemsRead,
  "items open": itemsOpen,
  "collections list": collectionsList,
  "collections create": collectionsCreate,
  "collections rename": collectionsRename,
  "collections add": collectionsAdd,
  "collections remove": collectionsRemove,
  "tags list": tagsList,
  "tags create": tagsCreate,
  "tags rename": tagsRename,
  "tags add": tagsAdd,
  "tags remove": tagsRemove,
  "import": importSource,
  "search": search,
  "status": status,
  "open": openFile,
  "words": words,
  "quickchat": quickchat,
  "notes": notes,
  "skills list": skillsList,
  "skills show": skillsShow,
  "skills install": skillsInstall,
  "skills uninstall": skillsUninstall,
  "skills check": skillsCheck,
  "metadata": metadata,
};

function requireArgument(parsed: Parsed, index: number, name: string): string {
  const value = parsed.positionals[index];
  if (value === undefined) throw new OakError(`Missing required argument <${name}>.`, "usage");
  return value;
}

/** A library without its system properties is a corrupted one, not an empty one. */
function requireProperty(q: Queries, name: string): string {
  const id = q.propertyId(name);
  if (id === null) {
    throw new OakError(
      `${name} property not found in database. The database may be corrupted.`);
  }
  return id;
}

function warn(context: string, error: unknown): void {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`Warning: ${context}: ${message}\n`);
}

process.exit(await main(process.argv.slice(2)));
