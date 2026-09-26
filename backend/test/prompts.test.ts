/**
 * Prompts as data. The property under test is not "the file is read" but
 * "editing the file changes what the model is told, with nothing recompiled" —
 * which is the entire reason for moving them out of Swift string literals.
 */
import { test, expect, describe } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PromptLibrary } from "../src/prompts.ts";

/** Run `body` against a library rooted at a throwaway directory. */
function withPrompts<T>(files: Record<string, string>, body: (lib: PromptLibrary) => T): T {
  const dir = mkdtempSync(join(tmpdir(), "oak-prompts-"));
  try {
    mkdirSync(join(dir, "mixins"), { recursive: true });
    for (const [name, content] of Object.entries(files)) {
      writeFileSync(join(dir, name), content);
    }
    const saved = process.argv;
    process.argv = [...saved, "--prompts", dir];
    try {
      return body(PromptLibrary.load());
    } finally {
      process.argv = saved;
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe("prompt composition", () => {
  test("base comes first, mixins follow in the order asked for", () => {
    withPrompts({
      "base.md": "BASE",
      "mixins/alpha.md": "ALPHA",
      "mixins/beta.md": "BETA",
    }, (lib) => {
      const composed = lib.compose(["beta", "alpha"]);
      expect(composed.text).toBe("BASE\n\nBETA\n\nALPHA");
      expect(composed.used).toEqual(["beta", "alpha"]);
    });
  });

  test("an unknown mixin is skipped, not fatal", () => {
    // A shell from an older build may ask for a fragment this one lacks; it
    // should still get a usable prompt rather than an error.
    withPrompts({ "base.md": "BASE", "mixins/alpha.md": "ALPHA" }, (lib) => {
      const { text, used } = lib.compose(["alpha", "not-shipped"]);
      expect(text).toBe("BASE\n\nALPHA");
      expect(used).toEqual(["alpha"]);
    });
  });

  test("a name that is not a plain identifier cannot escape the directory", () => {
    withPrompts({ "base.md": "BASE" }, (lib) => {
      expect(lib.compose(["../../etc/passwd"]).used).toEqual([]);
      expect(lib.compose(["mixins/alpha"]).used).toEqual([]);
    });
  });

  test("editing a file changes the prompt, with nothing recompiled", () => {
    const dir = mkdtempSync(join(tmpdir(), "oak-prompts-"));
    try {
      mkdirSync(join(dir, "mixins"), { recursive: true });
      writeFileSync(join(dir, "base.md"), "FIRST WORDING");
      const saved = process.argv;
      process.argv = [...saved, "--prompts", dir];
      try {
        expect(PromptLibrary.load().compose([]).text).toBe("FIRST WORDING");
        writeFileSync(join(dir, "base.md"), "SECOND WORDING");
        expect(PromptLibrary.load().compose([]).text).toBe("SECOND WORDING");
      } finally {
        process.argv = saved;
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("reports what it carries, so a shell can ask before requesting", () => {
    withPrompts({
      "base.md": "BASE", "mixins/alpha.md": "A", "mixins/beta.md": "B",
    }, (lib) => {
      expect(lib.list()).toEqual(["alpha", "beta"]);
      expect(lib.available).toBe(true);
    });
  });

  test("no prompt files is survivable, not a crash", () => {
    const dir = mkdtempSync(join(tmpdir(), "oak-prompts-"));
    try {
      const saved = process.argv;
      process.argv = [...saved, "--prompts", dir];
      try {
        const lib = PromptLibrary.load();
        expect(lib.available).toBe(false);
        expect(lib.compose(["anything"]).text).toBe("");
      } finally {
        process.argv = saved;
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("the prompts this repo ships", () => {
  test("compose into something the model can actually use", () => {
    const lib = PromptLibrary.load();          // resolves the checked-in prompts/
    expect(lib.available).toBe(true);
    const { text, used } = lib.compose(lib.list());
    expect(used).toEqual(lib.list());
    expect(text).toContain("grounded research assistant");
    expect(text).toContain("<math-formatting>");
  });
});
