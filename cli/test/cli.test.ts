/**
 * The CLI's own logic — parsing, formatting, extraction — without a library.
 *
 * What the commands do with a real catalog is covered by running them against
 * one; these are the parts where a rewrite is most likely to have changed
 * behaviour quietly.
 */
import { test, expect, describe } from "bun:test";
import { flag, integer, option, parse } from "../src/args.ts";
import { htmlToText, parsePageRange } from "../src/extract.ts";
import { isLikelyPDF, pdfFileName } from "../src/remote.ts";

import * as format from "../src/format.ts";

const BOOLEANS = new Set(["json", "quiet", "today", "csv", "markdown"]);
const TREE: Record<string, string[]> = {
  "": ["items", "tags", "search"],
  "items": ["list", "show", "read"],
  "tags": ["list", "add"],
};
const known = (path: string[]) => new Set(TREE[path.join(" ")] ?? []);
const p = (line: string) => parse(line.split(" ").filter((t) => t !== ""), known, BOOLEANS);

describe("arguments", () => {
  test("a boolean flag does not swallow the subcommand", () => {
    // The bug this exists to prevent: --json took "items" as its value, and
    // the command came out empty.
    const parsed = p("--json items list --limit 3");
    expect(parsed.path).toEqual(["items", "list"]);
    expect(flag(parsed, "json")).toBe(true);
    expect(integer(parsed, "limit")).toBe(3);
  });

  test("an option takes the next token, flags stand alone", () => {
    const parsed = p("items list --sort title --json");
    expect(option(parsed, "sort")).toBe("title");
    expect(flag(parsed, "json")).toBe(true);
  });

  test("--key=value is the same as --key value", () => {
    expect(option(p("items list --sort=author"), "sort")).toBe("author");
  });

  test("descent stops at the first non-command, so values may look like commands", () => {
    // "list" here is a search term, not the `list` subcommand.
    const parsed = p("search list of papers");
    expect(parsed.path).toEqual(["search"]);
    expect(parsed.positionals).toEqual(["list", "of", "papers"]);
  });

  test("a word matching a deeper command stays an argument", () => {
    const parsed = p("items show read");
    expect(parsed.path).toEqual(["items", "show"]);
    expect(parsed.positionals).toEqual(["read"]);
  });

  test("a non-numeric --limit is refused rather than becoming NaN", () => {
    expect(() => integer(p("items list --limit soon"), "limit")).toThrow(/whole number/);
  });
});

describe("page ranges", () => {
  test("ranges and single pages, converted to zero-based indices", () => {
    expect(parsePageRange("1-3", 10)).toEqual([0, 1, 2]);
    expect(parsePageRange("3,7", 10)).toEqual([2, 6]);
    expect(parsePageRange("1-2,9", 10)).toEqual([0, 1, 8]);
  });

  test("clamped to the document, and nonsense dropped rather than thrown", () => {
    expect(parsePageRange("8-99", 10)).toEqual([7, 8, 9]);
    expect(parsePageRange("99", 10)).toEqual([]);
    expect(parsePageRange("5-1", 10)).toEqual([]);
    expect(parsePageRange("banana", 10)).toEqual([]);
  });
});

describe("html to text", () => {
  test("script and style content is not reading matter", () => {
    const text = htmlToText(
      "<p>Kept</p><script>var dropped = 1;</script><style>.dropped{}</style>");
    expect(text).toBe("Kept");
  });

  test("blocks are separated by a blank line, inline text is not", () => {
    // A block tag breaks the line when it opens and again when it closes, so
    // paragraphs end up a blank line apart — the same shape the Swift version
    // produced, and what makes the output readable as prose.
    expect(htmlToText("<h1>Title</h1><p>One</p><p>Two</p>")).toBe("Title\n\nOne\n\nTwo");
    expect(htmlToText("<p>One <em>emphasised</em> word</p>")).toBe("One emphasised word");
  });

  test("entities are decoded", () => {
    expect(htmlToText("<p>A &amp; B &#65; &#x42; &nbsp;C</p>")).toBe("A & B A B  C");
  });
});

describe("formatting", () => {
  test("a note section quotes its source but a memo has none", () => {
    const base = {
      id: "1", itemId: "i", itemTitle: "Doc", text: "the quoted line",
      comment: "my thought", createdAt: "2026-09-26T10:30:00.000Z",
    };
    expect(format.noteSection({ ...base, positionKind: "pdf-overlay" }))
      .toContain("> the quoted line");
    expect(format.noteSection({ ...base, positionKind: "memo" }))
      .not.toContain("> the quoted line");
  });

  test("the combined document is oldest-first, however the rows arrive", () => {
    const note = (id: string, comment: string, createdAt: string) => ({
      id, itemId: "i", itemTitle: "Doc", positionKind: "memo",
      text: null, comment, createdAt,
    });
    // Rows come newest-first from the query; a document reads forwards.
    const markdown = format.notesMarkdown([
      note("2", "second", "2026-09-26T11:00:00.000Z"),
      note("1", "first", "2026-09-26T10:00:00.000Z"),
    ], "Doc");
    expect(markdown.indexOf("first")).toBeLessThan(markdown.indexOf("second"));
    expect(markdown).toStartWith("# Doc — Notes\n\n*2 notes*\n");
  });

  test("sizes and counts read as a person would write them", () => {
    expect(format.fileSize(512)).toBe("512 B");
    expect(format.fileSize(2048)).toBe("2.0 KB");
    expect(format.fileSize(5 * 1024 * 1024)).toBe("5.0 MB");
    expect(format.plural(1, "item")).toBe("1 item");
    expect(format.plural(2, "item")).toBe("2 items");
  });

  test("truncation leaves room for the ellipsis", () => {
    expect(format.truncate("abcdef", 6)).toBe("abcdef");
    expect(format.truncate("abcdefg", 6)).toBe("abcde…");
  });

  test("the collection tree draws nesting", () => {
    const base = {
      icon: "folder", sortOrder: 0, isSmart: false, isSystem: false, createdAt: "",
    };
    const tree = format.collectionTree([
      { ...base, id: "a", name: "Parent", parentId: null },
      { ...base, id: "b", name: "Child", parentId: "a" },
    ], new Map([["a", 3], ["b", 1]]));
    expect(tree).toBe("Collections:\n└── Parent (3)\n    └── Child (1)");
  });
});

/**
 * What a URL actually serves.
 *
 * The rewrite these pin: `oak import` used to decide by `url.endsWith(".pdf")`
 * alone, so `arxiv.org/pdf/2406.08929` — a PDF with no extension, and the most
 * common paper link there is — went down the web-archive path and failed.
 */
describe("recognising a PDF", () => {
  test("a .pdf path is one", () => {
    expect(isLikelyPDF("https://example.com/paper.pdf", null)).toBe(true);
    expect(isLikelyPDF("https://example.com/paper.PDF", null)).toBe(true);
  });

  test("a query string does not hide the extension", () => {
    expect(isLikelyPDF("https://example.com/paper.pdf?download=1", null)).toBe(true);
  });

  test("an extensionless URL is one when the server says so", () => {
    expect(isLikelyPDF("https://arxiv.org/pdf/2406.08929", null)).toBe(false);
    expect(isLikelyPDF("https://arxiv.org/pdf/2406.08929", "application/pdf")).toBe(true);
  });

  test("the content type may carry a charset", () => {
    expect(isLikelyPDF("https://example.com/x", "application/pdf; charset=binary")).toBe(true);
  });

  test("an abstract page is not one", () => {
    expect(isLikelyPDF("https://arxiv.org/abs/2406.08929", "text/html; charset=utf-8")).toBe(false);
  });

  test("a malformed URL is not one, and does not throw", () => {
    expect(isLikelyPDF("not a url", null)).toBe(false);
  });
});

describe("naming a downloaded PDF", () => {
  test("keeps the name the URL gives it", () => {
    expect(pdfFileName("https://example.com/attention.pdf", null)).toBe("attention.pdf");
  });

  test("adds the extension when the URL has none", () => {
    expect(pdfFileName("https://arxiv.org/pdf/2406.08929", null)).toBe("2406.08929.pdf");
  });

  test("falls back to the title for a bare host", () => {
    expect(pdfFileName("https://example.com", "On Attention")).toBe("On Attention.pdf");
  });

  test("a percent-encoded path cannot escape the directory", () => {
    // The name comes off the URL and is joined to a temp directory, so an
    // encoded traversal is the one input that matters. Decoding happens first,
    // sanitising second.
    const name = pdfFileName("https://example.com/%2e%2e%2f%2e%2e%2fetc%2fpasswd", null);
    expect(name).not.toContain("/");
    expect(name).not.toContain("\\");
    expect(name).not.toStartWith(".");
    expect(name).toEndWith(".pdf");
  });
});
