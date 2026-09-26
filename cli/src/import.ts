/**
 * Bringing a file into the library.
 *
 * The row-writing half goes through the core's ItemStore and CiteKeyStore
 * rather than its own INSERTs — which is also a fix: the Swift CLI wrote the
 * item itself and never assigned a cite key, so anything imported from the
 * terminal stayed keyless until the app happened to touch it.
 *
 * The file-moving half stays here, because that is what importing is.
 */
import { copyFile, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { basename, extname, join } from "node:path";
import { randomUUID } from "node:crypto";
import { getDocumentProxy } from "unpdf";
import type { Database } from "bun:sqlite";
import { ItemStore, type Attachment, type Item } from "../../backend/src/catalog/items.ts";
import { CiteKeyStore } from "../../backend/src/catalog/citekeys.ts";
import { Queries } from "./queries.ts";
import { attachmentDirectory, attachmentFile } from "./paths.ts";
import { OakError } from "./resolve.ts";

export interface ImportResult {
  itemId: string;
  title: string;
  isDuplicate: boolean;
}

/** Storage keys are 8 characters of the app's alphabet, not UUIDs. */
function storageKey(): string {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  return Array.from({ length: 8 }, () =>
    alphabet[Math.floor(Math.random() * alphabet.length)]).join("");
}

/**
 * The first 64 KB, hashed — the app's own duplicate test.
 *
 * A prefix rather than the whole file because two copies of a paper differ in
 * the first page if they differ at all, and hashing gigabytes to notice that
 * is a poor trade.
 */
async function hashPrefix(path: string): Promise<string | null> {
  try {
    const handle = Bun.file(path);
    const head = await handle.slice(0, 65536).arrayBuffer();
    if (head.byteLength === 0) return null;
    const digest = await crypto.subtle.digest("SHA-256", head);
    return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  } catch {
    return null;
  }
}

export class Importer {
  private readonly items: ItemStore;
  private readonly citeKeys: CiteKeyStore;

  constructor(private readonly db: Database, private readonly q: Queries) {
    this.items = new ItemStore(db, "local");
    this.citeKeys = new CiteKeyStore(db);
  }

  async findDuplicate(sourcePath: string): Promise<{ id: string; title: string } | null> {
    const hash = await hashPrefix(sourcePath);
    if (hash === null) return null;

    for (const path of this.q.attachmentPaths()) {
      const existing = await hashPrefix(
        attachmentFile(path.itemStorageKey, path.attachmentStorageKey, path.fileName));
      if (existing !== hash) continue;
      const item = this.q.itemByStorageKey(path.itemStorageKey);
      if (item !== null) return { id: item.id, title: item.title };
    }
    return null;
  }

  /** Copy the file into storage and write the row. Shared by every type. */
  private async place(
    sourcePath: string, contentType: string,
    metadata: { title: string; author: string; pageCount: number; sourceURL: string | null },
  ): Promise<ImportResult> {
    const itemKey = storageKey();
    const attachmentKey = storageKey();
    const fileName = basename(sourcePath);
    const directory = attachmentDirectory(itemKey, attachmentKey);
    const destination = join(directory, fileName);

    await mkdir(directory, { recursive: true });
    await copyFile(sourcePath, destination);
    const size = (await stat(destination)).size;

    const now = new Date().toISOString();
    const itemId = randomUUID();
    const attachment: Attachment = {
      id: randomUUID(), itemId, storageKey: attachmentKey, fileName,
      contentType, linkMode: "imported_file", sourceUrl: metadata.sourceURL,
      fileSize: size, pageCount: metadata.pageCount, isPrimary: true,
    };
    const item: Item = {
      id: itemId, storageKey: itemKey, title: metadata.title, author: metadata.author,
      lastOpenedAt: null, lastPosition: null, citeKey: null, source: null,
      sourceKey: null, extra: null, processingStatus: "completed", deletedAt: null,
      createdAt: now, updatedAt: now,
      attachments: [attachment], collectionIds: [], citationJson: null, propertyValues: [],
    };

    this.items.insert(item);
    this.citeKeys.assign(itemId, now);

    return { itemId, title: metadata.title, isDuplicate: false };
  }

  async importPDF(sourcePath: string, titleOverride: string | null): Promise<ImportResult> {
    const duplicate = await this.findDuplicate(sourcePath);
    if (duplicate !== null) return { ...duplicate, itemId: duplicate.id, isDuplicate: true };

    let title = titleOverride ?? basename(sourcePath, extname(sourcePath));
    let author = "";
    let pageCount = 0;
    try {
      const pdf = await getDocumentProxy(new Uint8Array(await readFile(sourcePath)));
      pageCount = pdf.numPages;
      const { info } = await pdf.getMetadata() as unknown as
        { info?: Record<string, unknown> };
      if (titleOverride === null && typeof info?.Title === "string" && info.Title !== "") {
        title = info.Title;
      }
      if (typeof info?.Author === "string") author = info.Author;
    } catch {
      // A PDF we cannot parse is still a PDF worth filing: the metadata is a
      // nicety, the file is the point.
    }

    return await this.place(sourcePath, "pdf", { title, author, pageCount, sourceURL: null });
  }

  async importHTML(
    sourcePath: string, titleOverride: string | null, sourcePageURL: string | null,
  ): Promise<ImportResult> {
    const duplicate = await this.findDuplicate(sourcePath);
    if (duplicate !== null) return { ...duplicate, itemId: duplicate.id, isDuplicate: true };

    let title = titleOverride ?? basename(sourcePath, extname(sourcePath));
    if (titleOverride === null) {
      const html = await readFile(sourcePath, "utf8").catch(() => "");
      const match = /<title>([^<]+)<\/title>/i.exec(html);
      const extracted = match?.[1]?.trim();
      if (extracted !== undefined && extracted !== "") title = extracted;
    }

    const result = await this.place(
      sourcePath, "html", { title, author: "", pageCount: 1, sourceURL: sourcePageURL });
    await this.writeContentMarkdown(sourcePath, result.itemId);
    return result;
  }

  async importMarkdown(sourcePath: string, titleOverride: string | null): Promise<ImportResult> {
    const duplicate = await this.findDuplicate(sourcePath);
    if (duplicate !== null) return { ...duplicate, itemId: duplicate.id, isDuplicate: true };

    let title = titleOverride ?? basename(sourcePath, extname(sourcePath));
    if (titleOverride === null) {
      const text = await readFile(sourcePath, "utf8").catch(() => "");
      for (const line of text.split(/\r?\n/)) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("# ")) continue;
        const heading = trimmed.slice(2).trim();
        if (heading !== "") title = heading;
        break;
      }
    }

    return await this.place(
      sourcePath, "markdown", { title, author: "", pageCount: 1, sourceURL: null });
  }

  /**
   * A downloadable PDF is fetched; anything else is archived with monolith,
   * which inlines the page's own assets into one file.
   */
  async importURL(url: string, titleOverride: string | null): Promise<ImportResult> {
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      throw new OakError(`Invalid URL: ${url}`);
    }

    const temporary = join(
      process.env.TMPDIR ?? "/tmp", `oak-import-${randomUUID()}`);
    await mkdir(temporary, { recursive: true });

    if (url.toLowerCase().endsWith(".pdf")) {
      const response = await fetch(url);
      if (!response.ok) {
        throw new OakError(`Download failed: ${response.status} ${response.statusText}`);
      }
      const name = basename(parsed.pathname) || "download.pdf";
      const path = join(temporary, name);
      await writeFile(path, new Uint8Array(await response.arrayBuffer()));
      return await this.importPDF(path, titleOverride);
    }

    const monolith = await resolveTool("monolith");
    if (monolith === null) {
      throw new OakError("monolith is not installed. Install with: brew install monolith");
    }

    const slug = parsed.hostname.replaceAll(".", "_");
    const path = join(temporary, `${slug}.html`);
    const run = Bun.spawnSync([monolith, url, "-o", path]);
    if (run.exitCode !== 0) {
      throw new OakError(`monolith failed: ${run.stderr.toString().trim()}`);
    }

    return await this.importHTML(path, titleOverride, url);
  }

  /**
   * Convert the archived page to `content.md`, when the tool for it is
   * installed. Optional by design — a missing converter costs structure, not
   * the import.
   */
  private async writeContentMarkdown(htmlPath: string, itemId: string): Promise<void> {
    const tool = await resolveTool("html-to-markdown");
    if (tool === null) return;

    const location = this.q.itemFilePath(itemId);
    if (location === null) return;

    const run = Bun.spawnSync([tool, htmlPath], { stderr: "ignore" });
    if (run.exitCode !== 0) return;
    const markdown = run.stdout.toString();
    if (markdown === "") return;

    await writeFile(
      join(attachmentDirectory(location.itemStorageKey, location.attachmentStorageKey),
           "content.md"),
      markdown);
  }
}

/** Find a tool on PATH or in an installed skill's bin directory. */
async function resolveTool(name: string): Promise<string | null> {
  const onPath = Bun.which(name);
  if (onPath !== null) return onPath;

  const { skillsDirectory } = await import("./paths.ts");
  const candidate = join(skillsDirectory(), name, "bin", name);
  return await Bun.file(candidate).exists() ? candidate : null;
}
