/**
 * Skill loading and the listing it produces for the model.
 *
 * The rules worth pinning are the ones a reader would not guess: what makes a
 * skill invalid but still loadable, what keeps one out of the model's listing,
 * and which copy wins when the same skill is installed twice.
 */
import { test, expect, describe } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  dedupe, loadSkills, parseFrontmatter, promptSection, readBody, userSkillDirectory,
} from "../src/skills.ts";

function withSkills(
  layout: Record<string, { md?: string; json?: string }>,
  body: (directory: string) => void,
): void {
  const directory = mkdtempSync(join(tmpdir(), "oak-skills-"));
  try {
    for (const [name, files] of Object.entries(layout)) {
      mkdirSync(join(directory, name), { recursive: true });
      if (files.md !== undefined) writeFileSync(join(directory, name, "SKILL.md"), files.md);
      if (files.json !== undefined) writeFileSync(join(directory, name, "skill.json"), files.json);
    }
    body(directory);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

const skillFile = (fields: string, body = "Instructions here.") =>
  `---\n${fields}\n---\n\n${body}\n`;

const load = (directory: string) => loadSkills([{ path: directory, source: "user" }]);

describe("frontmatter", () => {
  test("top-level scalars are read, the body is not", () => {
    const fields = parseFrontmatter(
      "---\nname: critique\ndescription: Evaluate reasoning\norder: 7\n---\n\nname: not-a-field\n");
    expect(fields).toEqual({ name: "critique", description: "Evaluate reasoning", order: "7" });
  });

  test("quotes are stripped and comments skipped", () => {
    expect(parseFrontmatter('---\nname: "quoted"\n# a comment\ntitle: \'single\'\n---\n'))
      .toEqual({ name: "quoted", title: "single" });
  });

  test("a file with no frontmatter yields nothing, not an error", () => {
    expect(parseFrontmatter("# Just a heading\n")).toBeNull();
  });
});

describe("loading", () => {
  test("a skill is its directory, named by its frontmatter", () => {
    withSkills({ critique: { md: skillFile("name: critique\ndescription: Test reasoning") } }, (d) => {
      const [skill] = load(d).skills;
      expect(skill).toMatchObject({
        name: "critique", description: "Test reasoning", title: "critique",
        enabled: true, disableModelInvocation: false, order: 99,
      });
    });
  });

  test("a description is the one hard requirement", () => {
    // Without it the model has nothing to choose on, so the skill is dropped —
    // loudly, as an advisory, rather than silently missing from the menu.
    withSkills({ broken: { md: skillFile("name: broken") } }, (d) => {
      const result = load(d);
      expect(result.skills).toHaveLength(0);
      expect(result.advisories[0]!.message).toMatch(/Missing required 'description'/);
    });
  });

  test("a bad name is an advisory, not a rejection", () => {
    // A skill you can see and fix beats one that silently is not there.
    withSkills({ Bad_Name: { md: skillFile("name: Bad_Name\ndescription: Works anyway") } }, (d) => {
      const result = load(d);
      expect(result.skills).toHaveLength(1);
      expect(result.advisories[0]!.message).toMatch(/lowercase alphanumeric/);
    });
  });

  test("skill.json fills in what the frontmatter does not say", () => {
    withSkills({
      quiz: {
        md: skillFile("name: quiz\ndescription: Make quiz cards"),
        json: JSON.stringify({
          version: "2.0.0", enabled: false,
          icon: { type: "symbol", value: "flame.fill" },
          author: { name: "Someone" },
          requires: { bins: [{ name: "jq" }] },
        }),
      },
    }, (d) => {
      const [skill] = load(d).skills;
      expect(skill).toMatchObject({
        version: "2.0.0", enabled: false,
        icon: { type: "symbol", value: "flame.fill" },
      });
      expect(skill!.requirements?.bins?.[0]?.name).toBe("jq");
    });
  });

  test("a skill.json with no SKILL.md loads as metadata alone", () => {
    withSkills({ "pdf-extract": { json: JSON.stringify({ requires: { bins: [{ name: "pdf-oxide" }] } }) } },
      (d) => {
        const [skill] = load(d).skills;
        expect(skill!.name).toBe("pdf-extract");
        expect(skill!.description).toBe("");
        expect(skill!.filePath).toEndWith("skill.json");
      });
  });

  test("the same file reached twice is one skill", () => {
    withSkills({ real: { md: skillFile("name: real\ndescription: A skill") } }, (d) => {
      symlinkSync(join(d, "real"), join(d, "alias"));
      expect(load(d).skills).toHaveLength(1);
    });
  });

  test("duplicates are kept, so the UI can compare their versions", () => {
    // Deduplicating at load time would hide the installed copy of a bundled
    // skill, and comparing the two is how an update is offered.
    withSkills({ summarize: { md: skillFile("name: summarize\ndescription: v1"), json: '{"version":"1.0.0"}' } },
      (bundled) => {
        withSkills({ summarize: { md: skillFile("name: summarize\ndescription: v2"), json: '{"version":"2.0.0"}' } },
          (user) => {
            const all = loadSkills([
              { path: bundled, source: "bundled" }, { path: user, source: "user" },
            ]).skills;
            expect(all.map((s) => s.version)).toEqual(["1.0.0", "2.0.0"]);
            expect(dedupe(all).map((s) => s.source)).toEqual(["bundled"]);
          });
      });
  });
});

describe("the model's listing", () => {
  const fixture = {
    visible: { md: skillFile("name: visible\ndescription: Shown to the model") },
    hidden: { md: skillFile("name: hidden\ndescription: User-invoked\ndisable-model-invocation: true") },
    off: { md: skillFile("name: off\ndescription: Turned off"), json: '{"enabled":false}' },
    bare: { json: '{"requires":{"bins":[{"name":"jq"}]}}' },
  };

  test("only what the model can act on appears", () => {
    withSkills(fixture, (d) => {
      const section = promptSection(load(d).skills, true);
      expect(section).toContain("<name>visible</name>");
      // Hidden by request, disabled by the user, and — `bare` — with no
      // description to choose on.
      expect(section).not.toContain("hidden");
      expect(section).not.toContain("off");
      expect(section).not.toContain("bare");
    });
  });

  test("no read tool means no listing at all", () => {
    // The listing's whole instruction is "read this file when it matches", so
    // without a read tool it does not merely waste context — it asks for
    // something the model cannot do.
    withSkills(fixture, (d) => {
      expect(promptSection(load(d).skills, false)).toBe("");
    });
  });

  test("nothing to list is an empty string, not an empty block", () => {
    withSkills({ hidden: fixture.hidden }, (d) => {
      expect(promptSection(load(d).skills, true)).toBe("");
    });
  });

  test("XML-significant characters in a description are escaped", () => {
    withSkills({ tricky: { md: skillFile('name: tricky\ndescription: Uses <tags> & "quotes"') } }, (d) => {
      expect(promptSection(load(d).skills, true))
        .toContain("<description>Uses &lt;tags&gt; &amp; &quot;quotes&quot;</description>");
    });
  });
});

describe("bodies", () => {
  test("the body is what follows the frontmatter", () => {
    withSkills({ quiz: { md: skillFile("name: quiz\ndescription: Make cards", "Do the thing.") } }, (d) => {
      expect(readBody(load(d).skills, "quiz")).toBe("Do the thing.");
    });
  });

  test("a metadata-only skill has no body to read", () => {
    withSkills({ bare: { json: "{}" } }, (d) => {
      expect(readBody(load(d).skills, "bare")).toBe("");
    });
  });

  test("an unknown name reads as empty rather than throwing", () => {
    withSkills({}, (d) => {
      expect(readBody(load(d).skills, "nope")).toBe("");
    });
  });
});

describe("directories", () => {
  test("a person's skills live beside their library", () => {
    expect(userSkillDirectory("/Users/x/OakReader/library.sqlite"))
      .toBe("/Users/x/OakReader/skills");
  });
});
