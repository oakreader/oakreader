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
import { newId } from "../../backend/src/catalog/ids.ts";
import { getDocumentProxy } from "unpdf";
import type { Database } from "bun:sqlite";
import { ItemStore, type Attachment, type Item } from "../../backend/src/catalog/items.ts";
import { CiteKeyStore } from "../../backend/src/catalog/citekeys.ts";
import { htmlToMarkdown } from "../../backend/src/catalog/htmlToMarkdown.ts";
import { Queries } from "./queries.ts";
import { attachmentDirectory, attachmentFile } from "./paths.ts";
import { OakError } from "./resolve.ts";
import { downloadPDF, isLikelyPDF, pdfFileName, remoteInfo, type RemoteInfo } from "./remote.ts";

export interface ImportResult {
  itemId: string;
  title: string;
  isDuplicate: boolean;
}

/**
 * How an attachment relates to its bytes — the app's spellings, which are
 * Swift enum case names and so camelCase.
 *
 * Worth a type rather than a string: this was written `imported_file` here and
 * `importedFile` by the app, and since `LinkMode(rawValue:) ?? .importedFile`
 * swallows an unknown value, every row the terminal imported quietly claimed
 * to be a local file. Harmless for a PDF, wrong for a bookmark — a bookmark
 * that is not `linkedURL` never opens its live URL.
 */
export type LinkMode = "importedFile" | "importedURL" | "linkedURL";

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
    metadata: {
      title: string; author: string; pageCount: number;
      sourceURL: string | null; linkMode?: LinkMode;
    },
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
    const itemId = newId();
    const attachment: Attachment = {
      id: newId(), itemId, storageKey: attachmentKey, fileName,
      contentType, linkMode: metadata.linkMode ?? "importedFile", sourceUrl: metadata.sourceURL,
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

  async importPDF(
    sourcePath: string, titleOverride: string | null, sourceURL: string | null = null,
  ): Promise<ImportResult> {
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

    return await this.place(sourcePath, "pdf", { title, author, pageCount, sourceURL });
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
      sourcePath, "html",
      {
        title, author: "", pageCount: 1, sourceURL: sourcePageURL,
        linkMode: sourcePageURL === null ? "importedFile" : "importedURL",
      });
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
   * Bring a URL into the library, the way the app does.
   *
   * Three outcomes, decided by what the server actually serves rather than by
   * what the URL looks like: a PDF is downloaded, a page is bookmarked, and a
   * page is archived into a single self-contained file only when asked for and
   * when monolith is installed. Bookmarking is the default because archives
   * are what make a library enormous — the same reason the app defaults
   * `archiveWebPages` off.
   */
  async importURL(
    url: string, titleOverride: string | null, options: { archive?: boolean } = {},
  ): Promise<ImportResult> {
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      throw new OakError(`Invalid URL: ${url}`);
    }
    if (!parsed.protocol.startsWith("http")) {
      throw new OakError(`Only http(s) URLs can be imported: ${url}`);
    }

    // Before anything is fetched: a URL already in the library is not worth
    // downloading again.
    const existing = this.q.findItemBySourceURL(url);
    if (existing !== null) {
      return { itemId: existing.id, title: existing.title, isDuplicate: true };
    }

    const info = await remoteInfo(url);
    const temporary = join(process.env.TMPDIR ?? "/tmp", `oak-import-${randomUUID()}`);
    await mkdir(temporary, { recursive: true });

    if (isLikelyPDF(url, info.contentType)) {
      const path = join(temporary, pdfFileName(url, titleOverride ?? info.title));
      try {
        await downloadPDF(url, path);
      } catch (error) {
        throw new OakError(`Download failed: ${(error as Error).message}`);
      }
      return await this.importPDF(path, titleOverride, url);
    }

    if (options.archive === true) {
      const monolith = await resolveTool("monolith");
      if (monolith === null) {
        throw new OakError(
          "monolith is not installed, so the page cannot be archived. "
          + "Install it with `brew install monolith`, or drop --archive to save a bookmark.");
      }
      const slug = parsed.hostname.replaceAll(".", "_");
      const path = join(temporary, `${slug}.html`);
      const run = Bun.spawnSync([monolith, url, "-o", path]);
      if (run.exitCode !== 0) {
        throw new OakError(`monolith failed: ${run.stderr.toString().trim()}`);
      }
      return await this.importHTML(path, titleOverride ?? info.title, url);
    }

    return await this.importBookmark(url, info, titleOverride);
  }

  /**
   * Save a page as a bookmark: the link, what the page says about itself, and
   * its readable text — but not the page.
   *
   * The shape is the app's (`ImportService+Embed.swift`): one attachment whose
   * file is `metadata.json`, marked `linkedURL`, so opening it loads the live
   * page rather than a stale copy. `content.md` beside it is what search and
   * the chat tools read, and is the reason this is worth more than a URL in a
   * text file.
   */
  private async importBookmark(
    url: string, info: RemoteInfo, titleOverride: string | null,
  ): Promise<ImportResult> {
    const host = new URL(url).hostname;
    const title = [titleOverride, info.title, host].find(
      (candidate) => candidate !== null && candidate !== undefined && candidate.trim() !== "")!;
    const author = info.author ?? host;

    const itemKey = storageKey();
    const attachmentKey = storageKey();
    const directory = attachmentDirectory(itemKey, attachmentKey);
    await mkdir(directory, { recursive: true });

    // The app reads this file to render the bookmark, so the field names are
    // its `MediaMetadata`, not a shape of our own.
    await writeFile(join(directory, "metadata.json"), JSON.stringify({
      title,
      author,
      sourceURL: url,
      duration: null,
      thumbnailURL: info.thumbnailURL,
      publishedAt: null,
      description: info.description,
      embedType: "link",
    }, null, 2));

    if (info.html !== null) {
      // Best effort: a page that Defuddle cannot read is still worth
      // bookmarking, it just has nothing to search.
      try {
        const { markdown } = await htmlToMarkdown(info.html, url);
        if (markdown.trim() !== "") {
          await writeFile(join(directory, "content.md"), markdown);
        }
      } catch { /* the bookmark stands without it */ }
    }

    const now = new Date().toISOString();
    const itemId = newId();
    const attachment: Attachment = {
      id: newId(), itemId, storageKey: attachmentKey, fileName: "metadata.json",
      contentType: "link", linkMode: "linkedURL", sourceUrl: url,
      fileSize: 0, pageCount: 0, isPrimary: true,
    };
    this.items.insert({
      id: itemId, storageKey: itemKey, title, author,
      lastOpenedAt: null, lastPosition: null, citeKey: null, source: null,
      sourceKey: null, extra: null, processingStatus: "completed", deletedAt: null,
      createdAt: now, updatedAt: now,
      attachments: [attachment], collectionIds: [], citationJson: null, propertyValues: [],
    });
    this.citeKeys.assign(itemId, now);

    return { itemId, title, isDuplicate: false };
  }

  /**
   * Write the page's readable text beside it as `content.md`.
   *
   * Uses the core's own extractor (Defuddle → Turndown, the same pipeline the
   * browser extension runs in-page) rather than shelling out to an
   * `html-to-markdown` binary. That binary was optional, so in practice a
   * terminal import usually produced no `content.md` at all — and an archived
   * page with no readable text is invisible to search and to the chat tools,
   * which is most of what filing it was for.
   */
  private async writeContentMarkdown(htmlPath: string, itemId: string): Promise<void> {
    const location = this.q.itemFilePath(itemId);
    if (location === null) return;

    try {
      const html = await readFile(htmlPath, "utf8");
      const { markdown } = await htmlToMarkdown(html);
      if (markdown.trim() === "") return;
      await writeFile(
        join(attachmentDirectory(location.itemStorageKey, location.attachmentStorageKey),
             "content.md"),
        markdown);
    } catch { /* structure lost, import kept */ }
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
