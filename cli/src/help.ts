/** The command tree, which is both the help text and what the parser descends. */
export interface CommandSpec {
  name: string;
  summary: string;
  usage?: string;
  subcommands?: CommandSpec[];
  /** The subcommand run when none is named. */
  defaultSubcommand?: string;
  options?: Array<[string, string]>;
}

export const GLOBAL_OPTIONS: Array<[string, string]> = [
  ["--json", "Output results as JSON."],
  ["--quiet", "Suppress non-essential output."],
  ["--db <path>", "Path to database (default: the app's library.sqlite)."],
  ["--version", "Show the version."],
  ["-h, --help", "Show help information."],
];

export const TREE: CommandSpec = {
  name: "oak",
  summary: "OakReader CLI",
  subcommands: [
    {
      name: "items", summary: "Manage library items.", defaultSubcommand: "list",
      subcommands: [
        {
          name: "list", summary: "List items.",
          options: [
            ["--collection <name>", "Filter by collection name."],
            ["--tag <name>", "Filter by tag name."],
            ["--type <type>", "Filter by type (pdf, web, video, note)."],
            ["--search <query>", "Search query."],
            ["--sort <field>", "Sort by: title, author, date."],
            ["--limit <n>", "Maximum number of results."],
          ],
        },
        { name: "show", summary: "Show item detail.", usage: "oak items show <item>" },
        {
          name: "read", summary: "Read item content (extract text).",
          usage: "oak items read <item> [--pages <range>]",
          options: [["--pages <range>", 'Page range for PDFs (e.g. "1-5", "3,7,12").']],
        },
        { name: "open", summary: "Open item in OakReader.app.", usage: "oak items open <item>" },
      ],
    },
    {
      name: "collections", summary: "Manage collections.", defaultSubcommand: "list",
      subcommands: [
        { name: "list", summary: "List collections." },
        {
          name: "create", summary: "Create a collection.",
          usage: "oak collections create <name> [--parent <name>]",
          options: [["--parent <name>", "Parent collection name."]],
        },
        { name: "rename", summary: "Rename a collection.", usage: "oak collections rename <current> <new>" },
        { name: "add", summary: "Add item to collection.", usage: "oak collections add <collection> <item>" },
        { name: "remove", summary: "Remove item from collection.", usage: "oak collections remove <collection> <item>" },
      ],
    },
    {
      name: "tags", summary: "Manage tags.", defaultSubcommand: "list",
      subcommands: [
        { name: "list", summary: "List tags." },
        {
          name: "create", summary: "Create a tag.", usage: "oak tags create <name> [--color <hex>]",
          options: [["--color <hex>", "Color hex code (e.g. FF5733)."]],
        },
        { name: "rename", summary: "Rename a tag.", usage: "oak tags rename <current> <new>" },
        { name: "add", summary: "Tag an item.", usage: "oak tags add <tag> <item>" },
        { name: "remove", summary: "Untag an item.", usage: "oak tags remove <tag> <item>" },
      ],
    },
    {
      name: "import", summary: "Import PDF, HTML, Markdown, or URL.",
      usage: "oak import <source> [--title <title>] [--collection <name>] [--tag <name>] [--archive]",
      options: [
        ["--title <title>", "Override title."],
        ["--collection <name>", "Add to collection after import."],
        ["--tag <name>", "Tag after import."],
        ["--archive", "Save a web page offline (needs monolith) instead of bookmarking it."],
      ],
    },
    {
      name: "search", summary: "Search library.", usage: "oak search <query> [--limit <n>]",
      options: [["--limit <n>", "Maximum results (default: 20)."]],
    },
    {
      name: "status", summary: "Show or set item status.",
      usage: "oak status <item> [<value>]",
    },
    { name: "open", summary: "Open file in OakReader (no import).", usage: "oak open <file>" },
    {
      name: "skills", summary: "Manage agent skills.", defaultSubcommand: "list",
      subcommands: [
        { name: "list", summary: "List all skills." },
        { name: "show", summary: "Show skill detail.", usage: "oak skills show <name>" },
        { name: "install", summary: "Install a skill.", usage: "oak skills install <name>" },
        { name: "uninstall", summary: "Uninstall a skill.", usage: "oak skills uninstall <name>" },
        { name: "check", summary: "Verify installed skill dependencies." },
      ],
    },
    {
      name: "words", summary: "List words you looked up while reading (newest first).",
      options: [
        ["--today", "Only words looked up today."],
        ["--since <date>", "Only words looked up on or after this date (YYYY-MM-DD)."],
        ["--limit <n>", "Maximum number of results (default 100)."],
        ["--csv", "Output as CSV (Word, Sentence, Explanation, Document, Created At)."],
      ],
    },
    {
      name: "notes", summary: "List or export the notes you wrote while reading.",
      options: [
        ["--item <item>", "Only notes for this item (title, cite key, or ID)."],
        ["--since <date>", "Only notes created on or after this date (YYYY-MM-DD)."],
        ["--limit <n>", "Maximum number of notes (newest first)."],
        ["--markdown", "Output one combined Markdown document (pipeable to pbcopy)."],
      ],
    },
  ],
};

export function findCommand(path: string[]): CommandSpec | null {
  let node: CommandSpec = TREE;
  for (const segment of path) {
    const next = node.subcommands?.find((c) => c.name === segment);
    if (next === undefined) return null;
    node = next;
  }
  return node;
}

export function childNames(path: string[]): Set<string> {
  return new Set(findCommand(path)?.subcommands?.map((c) => c.name) ?? []);
}

export function helpText(path: string[]): string {
  const node = findCommand(path) ?? TREE;
  const full = ["oak", ...path.slice(node === TREE ? 1 : 0)].join(" ");

  const lines = [`OVERVIEW: ${node.summary}`, ""];
  lines.push(`USAGE: ${node.usage ?? usageFor(node, path)}`, "");

  const options = [...(node.options ?? []), ...GLOBAL_OPTIONS];
  lines.push("OPTIONS:");
  for (const [name, description] of options) {
    lines.push(`  ${name.padEnd(22)}  ${description}`);
  }

  if (node.subcommands !== undefined && node.subcommands.length > 0) {
    lines.push("", "SUBCOMMANDS:");
    for (const child of node.subcommands) {
      lines.push(`  ${child.name.padEnd(22)}  ${child.summary}`);
    }
    lines.push("", `  See '${full} <subcommand> --help' for detailed help.`);
  }
  return lines.join("\n");
}

function usageFor(node: CommandSpec, path: string[]): string {
  const prefix = ["oak", ...path].join(" ");
  if (node.subcommands !== undefined && node.subcommands.length > 0) {
    return `${prefix} [--json] [--quiet] [--db <db>] <subcommand>`;
  }
  return `${prefix} [--json] [--quiet] [--db <db>]`;
}
