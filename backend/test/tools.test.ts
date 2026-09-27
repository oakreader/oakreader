/**
 * The tools that touch the machine. The sandbox is the part worth testing
 * hardest: it is the only thing standing between a model's path argument and
 * the rest of the disk.
 */
import { test, expect, describe } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveInSandbox, runTool, PORTABLE_TOOLS } from "../src/tools.ts";

/**
 * A scratch directory that outlives the work done in it.
 *
 * `await` matters: without it the finally clause runs when the body *returns
 * its promise*, deleting the directory out from under the work it is doing.
 */
async function withDirectory(body: (root: string) => Promise<void>): Promise<void> {
  const root = mkdtempSync(join(tmpdir(), "oak-tools-"));
  try {
    await body(root);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

describe("sandbox", () => {
  test("a sibling whose name merely starts the same way is outside", () => {
    // The Swift version compared string prefixes, so `/x/work-elsewhere`
    // passed a sandbox of `/x/work`. Segments, not characters.
    expect(resolveInSandbox("/x/work-elsewhere/f.txt", "/x/work", ["/x/work"])).toBeNull();
    expect(resolveInSandbox("/x/work/f.txt", "/x/work", ["/x/work"])).toBe("/x/work/f.txt");
  });

  test("the root itself is inside it", () => {
    expect(resolveInSandbox("/x/work", "/x/work", ["/x/work"])).toBe("/x/work");
  });

  test("traversal cannot climb out", () => {
    expect(resolveInSandbox("../../etc/passwd", "/x/work", ["/x/work"])).toBeNull();
    expect(resolveInSandbox("/x/work/../../etc/passwd", "/x/work", ["/x/work"])).toBeNull();
  });

  test("a relative path resolves against the working directory", () => {
    expect(resolveInSandbox("notes.md", "/x/work", ["/x/work"])).toBe("/x/work/notes.md");
  });

  test("no allowed paths means unsandboxed, which is how it is asked for", () => {
    expect(resolveInSandbox("/anywhere/at/all", "/x", [])).toBe("/anywhere/at/all");
  });

  test("any one of several roots will do", () => {
    expect(resolveInSandbox("/b/f", "/a", ["/a", "/b"])).toBe("/b/f");
  });
});

describe("read", () => {
  test("returns numbered lines", async () => {
    await withDirectory(async (root) => {
      writeFileSync(join(root, "f.txt"), "alpha\nbeta\ngamma");
      const result = await runTool("read", { path: "f.txt" }, root, [root]);
      expect(result).toEqual({ content: "1\talpha\n2\tbeta\n3\tgamma", isError: false });
    });
  });

  test("offset and limit select a window, numbered from the file's start", async () => {
    await withDirectory(async (root) => {
      writeFileSync(join(root, "f.txt"), "a\nb\nc\nd\ne");
      const result = await runTool("read", { path: "f.txt", offset: "2", limit: "2" }, root, [root]);
      expect(result.content).toBe("2\tb\n3\tc");
    });
  });

  test("an offset past the end says so rather than returning nothing", async () => {
    await withDirectory(async (root) => {
      writeFileSync(join(root, "f.txt"), "only one line");
      const result = await runTool("read", { path: "f.txt", offset: "9" }, root, [root]);
      expect(result.isError).toBe(true);
      expect(result.content).toMatch(/exceeds file length \(1 lines\)/);
    });
  });

  test("a path outside the sandbox is refused, not read", async () => {
    await withDirectory(async (root) => {
      const outside = join(root, "outside");
      mkdirSync(outside);
      writeFileSync(join(outside, "secret.txt"), "private");
      const inside = join(root, "inside");
      mkdirSync(inside);

      const result = await runTool("read", { path: "../outside/secret.txt" }, inside, [inside]);
      expect(result).toEqual({
        content: "Access denied: path is outside allowed directories", isError: true,
      });
    });
  });

  test("a missing file is an error, not a crash", async () => {
    await withDirectory(async (root) => {
      const result = await runTool("read", { path: "nope.txt" }, root, [root]);
      expect(result.isError).toBe(true);
    });
  });
});

describe("write", () => {
  test("creates parent directories on the way", async () => {
    await withDirectory(async (root) => {
      const result = await runTool(
        "write", { path: "a/b/c.txt", content: "hello" }, root, [root]);
      expect(result.isError).toBe(false);
      expect(readFileSync(join(root, "a/b/c.txt"), "utf8")).toBe("hello");
    });
  });

  test("a path outside the sandbox writes nothing", async () => {
    await withDirectory(async (root) => {
      const inside = join(root, "inside");
      mkdirSync(inside);
      const result = await runTool(
        "write", { path: "../escaped.txt", content: "x" }, inside, [inside]);
      expect(result.isError).toBe(true);
      expect(() => readFileSync(join(root, "escaped.txt"))).toThrow();
    });
  });

  test("missing content is refused rather than writing an empty file", async () => {
    await withDirectory(async (root) => {
      const result = await runTool("write", { path: "f.txt" }, root, [root]);
      expect(result.content).toMatch(/Missing required parameter: content/);
      expect(() => readFileSync(join(root, "f.txt"))).toThrow();
    });
  });
});

describe("bash", () => {
  test("stdout comes back on success", async () => {
    await withDirectory(async (root) => {
      const result = await runTool("bash", { command: "echo hello" }, root, []);
      expect(result).toEqual({ content: "hello", isError: false });
    });
  });

  test("a non-zero exit is an error carrying the code and the output", async () => {
    await withDirectory(async (root) => {
      const result = await runTool("bash", { command: "echo oops >&2; exit 3" }, root, []);
      expect(result.isError).toBe(true);
      expect(result.content).toStartWith("Exit code: 3");
      expect(result.content).toContain("oops");
    });
  });

  test("it runs in the working directory", async () => {
    await withDirectory(async (root) => {
      writeFileSync(join(root, "marker.txt"), "");
      const result = await runTool("bash", { command: "ls" }, root, []);
      expect(result.content).toContain("marker.txt");
    });
  });

  test("a command that hangs is killed by its timeout", async () => {
    await withDirectory(async (root) => {
      const started = performance.now();
      const result = await runTool("bash", { command: "sleep 30", timeout: "1" }, root, []);
      expect(performance.now() - started).toBeLessThan(10_000);
      expect(result.isError).toBe(true);
    });
  });
});

describe("definitions", () => {
  test("every tool declares a category, because that is what gates it", () => {
    expect(PORTABLE_TOOLS.map((t) => [t.name, t.category])).toEqual([
      ["read", "readOnly"], ["write", "write"], ["bash", "dangerous"],
    ]);
  });

  test("an unknown name is refused", async () => {
    expect(await runTool("nonesuch", {}, "/tmp", [])).toEqual({
      content: "Unknown tool: nonesuch", isError: true,
    });
  });
});
