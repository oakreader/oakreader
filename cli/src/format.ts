/**
 * The human-readable side of every command.
 *
 * Widths and separators are copied from the Swift original rather than
 * redesigned: people have these in scripts and in muscle memory, and a
 * rewrite is not an invitation to move the columns.
 */
import type {
  Attachment, Collection, Item, Note, PropertyOption, SearchResult,
} from "./queries.ts";

export function pad(text: string, width: number): string {
  return text.length >= width ? text : text + " ".repeat(width - text.length);
}

export function truncate(text: string, length: number): string {
  return text.length <= length ? text : text.slice(0, length - 1) + "…";
}

export function plural(count: number, word: string): string {
  return `${count} ${word}${count === 1 ? "" : "s"}`;
}

export function fileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const kb = bytes / 1024;
  if (kb < 1024) return `${kb.toFixed(1)} KB`;
  const mb = kb / 1024;
  if (mb < 1024) return `${mb.toFixed(1)} MB`;
  return `${(mb / 1024).toFixed(1)} GB`;
}

/** A stored timestamp as `2026-05-15 11:35` in local time. */
export function date(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return `${isoDay(d)} ${clock(d)}`;
}

function isoDay(d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function clock(d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** The same timestamp, for the denser word and note listings. */
export const shortDate = date;

/**
 * A note's timestamp, which must match the app's `NoteTime.absolute` — the two
 * appear in the same exported Markdown document.
 */
export function noteTimestamp(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "" : `${isoDay(d)} ${clock(d)}`;
}

export function itemList(entries: Array<{ item: Item; attachments: Attachment[] }>): string {
  if (entries.length === 0) return "No items found.";

  const lines = [
    `${pad("TITLE", 40)}  ${pad("AUTHOR", 20)}  ${pad("TYPE", 12)}  CITE KEY`,
    "-".repeat(90),
  ];
  for (const { item, attachments } of entries) {
    lines.push(
      `${pad(truncate(item.title, 38), 40)}  `
      + `${pad(truncate(item.author === "" ? "-" : item.author, 18), 20)}  `
      + `${pad(attachments[0]?.contentType ?? "unknown", 12)}  `
      + `${item.citeKey ?? "-"}`);
  }
  lines.push("", plural(entries.length, "item"));
  return lines.join("\n");
}

export function itemDetail(
  item: Item, attachments: Attachment[], tags: PropertyOption[],
  status: PropertyOption | null, collections: Collection[],
): string {
  const lines = [item.title, "=".repeat(Math.min(item.title.length, 60)), ""];

  if (item.author !== "") lines.push(`Author:      ${item.author}`);
  if (item.citeKey !== null) lines.push(`Cite Key:    ${item.citeKey}`);
  lines.push(`ID:          ${item.id}`);
  lines.push(`Added:       ${date(item.createdAt)}`);
  if (item.lastOpenedAt !== null) lines.push(`Last Opened: ${date(item.lastOpenedAt)}`);
  if (status !== null) lines.push(`Status:      ${status.name}`);
  if (tags.length > 0) lines.push(`Tags:        ${tags.map((t) => t.name).join(", ")}`);
  if (collections.length > 0) {
    lines.push(`Collections: ${collections.map((c) => c.name).join(", ")}`);
  }

  if (attachments.length > 0) {
    lines.push("", "Attachments:");
    for (const a of attachments) {
      const primary = a.isPrimary ? " (primary)" : "";
      const pages = a.pageCount > 0 ? `, ${a.pageCount} pages` : "";
      lines.push(`  - ${a.fileName} [${a.contentType}${primary}, ${fileSize(a.fileSize)}${pages}]`);
      if (a.sourceURL !== null && a.sourceURL !== "") lines.push(`    URL: ${a.sourceURL}`);
    }
  }
  return lines.join("\n");
}

export function collectionTree(
  collections: Collection[], counts: Map<string, number>,
): string {
  if (collections.length === 0) return "No collections.";

  const children = new Map<string, Collection[]>();
  const roots: Collection[] = [];
  for (const c of collections) {
    if (c.parentId === null) roots.push(c);
    else children.set(c.parentId, [...(children.get(c.parentId) ?? []), c]);
  }

  const lines = ["Collections:"];
  const walk = (c: Collection, indent: string, isLast: boolean) => {
    lines.push(`${indent}${isLast ? "└── " : "├── "}${c.name} (${counts.get(c.id) ?? 0})`);
    const kids = children.get(c.id) ?? [];
    const childIndent = indent + (isLast ? "    " : "│   ");
    kids.forEach((kid, i) => walk(kid, childIndent, i === kids.length - 1));
  };
  roots.forEach((root, i) => walk(root, "", i === roots.length - 1));
  return lines.join("\n");
}

export function tagList(tags: Array<{ tag: PropertyOption; count: number }>): string {
  if (tags.length === 0) return "No tags.";
  return ["Tags:", ...tags.map(
    ({ tag, count }) => `  - ${tag.name} (${count} items) #${tag.colorHex}`)].join("\n");
}

export function searchResults(results: SearchResult[], query: string, mode: string): string {
  if (results.length === 0) return `No results found for "${query}" (${mode} search).`;

  const lines = [`Found ${results.length} result(s) for "${query}" (${mode} search):\n`];
  results.forEach((r, i) => {
    lines.push(`${i + 1}. ${r.citeKey !== null ? `[${r.citeKey}] ` : ""}${r.title}`);
    if (r.author !== "") lines.push(`   Authors: ${r.author}`);

    const meta: string[] = [];
    if (r.year !== null) meta.push(`Year: ${r.year}`);
    if (r.contentType !== null && r.pageCount !== null) {
      meta.push(`${r.contentType}, ${r.pageCount} pages`);
    }
    if (meta.length > 0) lines.push(`   ${meta.join(" | ")}`);

    if (r.journal !== null) lines.push(`   Journal: ${r.journal}`);
    if (r.doi !== null) lines.push(`   DOI: ${r.doi}`);
    if (r.tags !== null && r.tags !== "") lines.push(`   Tags: ${r.tags}`);
    if (r.abstract !== null) {
      lines.push(`   Abstract: ${r.abstract.slice(0, 150)}${r.abstract.length > 150 ? "..." : ""}`);
    }
    lines.push("");
  });
  return lines.join("\n");
}

export function stats(s: { items: number; collections: number; tags: number }): string {
  return ["OakReader Library", "-".repeat(20),
    `Items:       ${s.items}`,
    `Collections: ${s.collections}`,
    `Tags:        ${s.tags}`].join("\n");
}

/**
 * Notes as one Markdown document.
 *
 * This must stay byte-identical to the app's `NoteExporter.combinedMarkdown`,
 * so `oak notes --markdown` and the panel's "Export as Single Markdown"
 * produce the same file. Notes arrive newest-first and are emitted oldest-first,
 * because a document reads forwards.
 */
export function notesMarkdown(notes: Note[], title: string): string {
  let out = `# ${title} — Notes\n\n*${plural(notes.length, "note")}*\n`;
  for (const note of [...notes].reverse()) out += `\n---\n\n${noteSection(note)}`;
  return out + "\n";
}

export function noteSection(note: Note): string {
  const stamp = noteTimestamp(note.createdAt);
  let out = stamp === "" ? "## Note\n\n" : `## ${stamp}\n\n`;

  // An anchored note quotes what it was written about; a memo has no source.
  if (note.positionKind !== "memo") {
    const quote = (note.text ?? "").trim();
    if (quote !== "") out += quote.split("\n").map((l) => `> ${l}`).join("\n") + "\n\n";
  }

  const body = note.comment.trim();
  if (body !== "") out += body + "\n";
  return out;
}

export function status(item: Item, value: PropertyOption | null): string {
  return `${item.title}: ${value?.name ?? "None"}`;
}

// --- metadata ------------------------------------------------------------

/** How the recogniser arrived at an answer, in words rather than a slug. */
function methodPhrase(method: string): string {
  switch (method) {
    case "doi": return "DOI";
    case "arxiv": return "arXiv ID";
    case "isbn": return "ISBN";
    case "pmid": return "PubMed ID";
    case "title-search": return "title search";
    case "embedded": return "the document's own metadata";
    default: return "the filename";
  }
}

function year(csl: Record<string, unknown>): string {
  const issued = csl.issued as { "date-parts"?: number[][] } | undefined;
  const value = issued?.["date-parts"]?.[0]?.[0];
  return value === undefined ? "" : String(value);
}

function authorList(csl: Record<string, unknown>): string {
  const authors = csl.author as Array<{ family?: string; given?: string; literal?: string }> | undefined;
  if (authors === undefined || authors.length === 0) return "";
  const names = authors.slice(0, 4).map((a) => {
    if (a.literal !== undefined) return a.literal;
    return [a.given, a.family].filter((p) => p !== undefined && p !== "").join(" ");
  });
  return names.join(", ") + (authors.length > 4 ? ", et al." : "");
}

/** One line per item, for the sweep. */
export function recognitionLine(
  found: { csl: Record<string, unknown>; method: string; confidence: number; provider?: string },
  currentTitle: string,
): string {
  const mark = found.confidence >= 0.5 ? "+" : "?";
  const title = String(found.csl.title ?? currentTitle);
  const via = found.provider ?? methodPhrase(found.method);
  return `${mark} ${pad(title.slice(0, 58), 58)}  ${via}`;
}

/** The full report for one item. */
export function recognition(
  found: {
    csl: Record<string, unknown>; method: string; confidence: number;
    provider?: string; identifiers: Record<string, string | undefined>;
  },
  currentTitle: string,
): string {
  const csl = found.csl;
  const lines: string[] = [];

  const via = found.provider === undefined
    ? `from ${methodPhrase(found.method)}`
    : `from ${methodPhrase(found.method)}, via ${found.provider}`;
  lines.push(found.confidence >= 0.5
    ? `Identified ${via} (confidence ${found.confidence.toFixed(2)}).`
    : `Not identified. Describing it ${via}.`);
  lines.push("");

  const row = (label: string, value: unknown): void => {
    if (value === undefined || value === null || value === "") return;
    lines.push(`  ${pad(label, 14)}${String(value)}`);
  };
  row("Current", currentTitle);
  row("Title", csl.title);
  row("Authors", authorList(csl));
  row("Year", year(csl));
  row("Type", csl.type);
  row("Journal", csl["container-title"]);
  row("Publisher", csl.publisher);
  row("Volume", csl.volume);
  row("Pages", csl.page ?? csl["number-of-pages"]);
  row("DOI", csl.DOI);
  row("ISBN", csl.ISBN);
  row("URL", csl.URL);

  const unresolved = Object.entries(found.identifiers)
    .filter(([, value]) => value !== undefined)
    .map(([key, value]) => `${key}=${String(value)}`);
  if (unresolved.length > 0) {
    lines.push("", `  ${pad("Found on page", 14)}${unresolved.join("  ")}`);
  }
  return lines.join("\n");
}
