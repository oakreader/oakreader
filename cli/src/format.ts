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

/**
 * Which locale dates are written in.
 *
 * From `LC_ALL` / `LC_TIME` / `LANG`, the POSIX variables that work on every
 * platform, rather than the runtime default — which on a Mac is `en-US` no
 * matter what the system is set to, because Bun does not read macOS's own
 * preferences. The Swift version used those preferences, so a machine set to
 * British English with a `LANG=en_US` terminal will see dates change; setting
 * `LC_TIME` puts them back, and now does so identically everywhere.
 */
function locale(): string | undefined {
  const raw = process.env.LC_ALL ?? process.env.LC_TIME ?? process.env.LANG;
  if (raw === undefined || raw === "" || raw === "C" || raw === "POSIX") return undefined;
  const tag = raw.split(".")[0]!.replace("_", "-");
  try {
    return Intl.DateTimeFormat.supportedLocalesOf([tag]).length > 0 ? tag : undefined;
  } catch {
    return undefined;
  }
}

export function fileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const kb = bytes / 1024;
  if (kb < 1024) return `${kb.toFixed(1)} KB`;
  const mb = kb / 1024;
  if (mb < 1024) return `${mb.toFixed(1)} MB`;
  return `${(mb / 1024).toFixed(1)} GB`;
}

/**
 * A stored timestamp as a medium local date, or unchanged if it will not parse.
 *
 * `dateStyle`/`timeStyle` rather than a field-by-field recipe, because that is
 * what the DateFormatter this replaces used (`.medium` and `.short`) — the two
 * render the same string for the same locale, where spelling the fields out
 * does not.
 */
export function date(iso: string): string {
  const parsed = new Date(iso);
  if (Number.isNaN(parsed.getTime())) return iso;
  return parsed.toLocaleString(locale(), { dateStyle: "medium", timeStyle: "short" });
}

/**
 * "Jul 10, 14:42" — built by hand rather than from a locale.
 *
 * `toLocaleString` renders this as "Jul 10 at 14:42" on a Mac and differently
 * again elsewhere, which would make the same library print differently on two
 * machines. The word-list format is fixed, so the format is fixed here too.
 */
export function shortDate(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d.getMonth()]!;
  const p = (n: number) => String(n).padStart(2, "0");
  return `${month} ${d.getDate()}, ${p(d.getHours())}:${p(d.getMinutes())}`;
}

/**
 * A note's timestamp as the panel's `yyyy-MM-dd HH:mm` in local time, so the
 * CLI and the app agree about when a note was written.
 */
export function noteTimestamp(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} `
    + `${p(d.getHours())}:${p(d.getMinutes())}`;
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
