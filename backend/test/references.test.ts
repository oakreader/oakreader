/**
 * Reference metadata. The columns beside the CSL JSON are derived from it, so
 * what is worth testing is that they agree with it — and that saving metadata
 * updates the item the library list actually displays.
 */
import { test, expect, describe } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Catalog } from "../src/catalog/db.ts";
import { ReferenceStore } from "../src/catalog/references.ts";
import { seed } from "./seed.ts";

const NOW = "2026-09-26T00:00:00Z";

function withCatalog<T>(body: (s: ReferenceStore, c: Catalog) => T): T {
  const dir = mkdtempSync(join(tmpdir(), "oak-references-"));
  try {
    const catalog = Catalog.open(join(dir, "library.sqlite"));
    try {
      seed(catalog.db,
        `INSERT INTO items (id, user_id, storage_key, title, author, created_at, updated_at)
         VALUES ('doc-1', 'local', 'sk-1', 'scan_0012.pdf', '', '', '')`);
      return body(new ReferenceStore(catalog.db), catalog);
    } finally {
      catalog.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const ATTENTION = JSON.stringify({
  type: "article-journal",
  title: "Attention Is All You Need",
  author: [{ family: "Vaswani", given: "Ashish" }, { family: "Shazeer", given: "Noam" }],
  issued: { "date-parts": [[2017]] },
  DOI: "10.48550/arXiv.1706.03762",
  "container-title": "NeurIPS",
  abstract: "The dominant sequence transduction models…",
  ISSN: "1234-5678",
});

const row = (c: Catalog) => c.db.query<Record<string, unknown>, []>(
  "SELECT * FROM citations WHERE item_id = 'doc-1'").get()!;

const item = (c: Catalog) => c.db.query<
  { title: string; author: string; cite_key: string | null; extra: string | null }, []
>("SELECT title, author, cite_key, extra FROM items WHERE id = 'doc-1'").get()!;

describe("references", () => {
  test("the derived columns agree with the JSON", () => {
    withCatalog((store, catalog) => {
      store.save("doc-1", ATTENTION, null, NOW);
      expect(row(catalog)).toMatchObject({
        csl_type: "article-journal",
        doi: "10.48550/arXiv.1706.03762",
        year: 2017,
        container_title: "NeurIPS",
        issn: "1234-5678",
      });
    });
  });

  test("saving names the item from its citation", () => {
    withCatalog((store, catalog) => {
      store.save("doc-1", ATTENTION, null, NOW);
      expect(item(catalog)).toMatchObject({
        title: "Attention Is All You Need",
        author: "Vaswani, Ashish, Shazeer, Noam",
        cite_key: "vaswaniAttentionAllYou2017",
      });
    });
  });

  test("a citation missing a field leaves the item's own alone", () => {
    // An absent author means "not recorded here", not "this paper has none".
    withCatalog((store, catalog) => {
      seed(catalog.db, "UPDATE items SET author = 'Known Author' WHERE id = 'doc-1'");
      store.save("doc-1", JSON.stringify({ title: "A Paper" }), null, NOW);
      expect(item(catalog).author).toBe("Known Author");
    });
  });

  test("identifiers come out of extra and the note", () => {
    withCatalog((store, catalog) => {
      store.save("doc-1", JSON.stringify({
        title: "A Paper", note: "arXiv: 1706.03762\nsomething else",
      }), "PMID: 29491377", NOW);

      expect(row(catalog)).toMatchObject({ pmid: "29491377", arxiv_id: "1706.03762" });
      expect(item(catalog).extra).toBe("PMID: 29491377");
    });
  });

  test("extra wins over the note for the same identifier", () => {
    withCatalog((store, catalog) => {
      store.save("doc-1", JSON.stringify({ title: "A Paper", note: "PMID: 111" }),
                 "PMID: 222", NOW);
      expect(row(catalog).pmid).toBe("222");
    });
  });

  test("saving twice updates in place and keeps the original created_at", () => {
    withCatalog((store, catalog) => {
      store.save("doc-1", ATTENTION, null, NOW);
      store.save("doc-1", JSON.stringify({ title: "Corrected Title" }), null,
                 "2026-10-01T00:00:00Z");

      const rows = catalog.db.query<{ n: number }, []>(
        "SELECT count(*) AS n FROM citations").get()!.n;
      expect(rows).toBe(1);
      expect(row(catalog)).toMatchObject({
        created_at: NOW,
        updated_at: "2026-10-01T00:00:00Z",
      });
      expect(item(catalog).title).toBe("Corrected Title");
    });
  });

  test("a cite key assigned once is not rewritten by later metadata", () => {
    withCatalog((store, catalog) => {
      store.save("doc-1", ATTENTION, null, NOW);
      store.save("doc-1", JSON.stringify({
        title: "Something Else Entirely", author: [{ family: "Other" }],
      }), null, NOW);
      expect(item(catalog).cite_key).toBe("vaswaniAttentionAllYou2017");
    });
  });

  test("get returns the JSON as stored, or null", () => {
    withCatalog((store) => {
      expect(store.get("doc-1")).toBeNull();
      store.save("doc-1", ATTENTION, null, NOW);
      expect(JSON.parse(store.get("doc-1")!).title).toBe("Attention Is All You Need");
    });
  });
});
