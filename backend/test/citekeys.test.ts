/**
 * Cite-key generation. These are the Better BibTeX rules the Swift original
 * implemented, restated as assertions so the port can be checked rather than
 * trusted — the transliteration underneath changed, so agreement on shape is
 * not something to assume.
 */
import { test, expect, describe } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Catalog } from "../src/catalog/db.ts";
import { seed } from "./seed.ts";
import {
  CiteKeyStore, baseKey, baseKeyFromFields, transliterate,
} from "../src/catalog/citekeys.ts";

const NOW = "2026-09-26T00:00:00Z";

function withCatalog<T>(body: (s: CiteKeyStore, c: Catalog) => T): T {
  const dir = mkdtempSync(join(tmpdir(), "oak-citekeys-"));
  try {
    const catalog = Catalog.open(join(dir, "library.sqlite"));
    try {
      return body(new CiteKeyStore(catalog.db), catalog);
    } finally {
      catalog.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function addItem(c: Catalog, id: string, title: string, author: string, citeKey?: string) {
  seed(c.db,
    `INSERT INTO items (id, user_id, storage_key, title, author, cite_key, created_at, updated_at)
     VALUES ('${id}', 'local', 'sk-${id}', '${title}', '${author}',
             ${citeKey === undefined ? "NULL" : `'${citeKey}'`}, '', '')`);
}

describe("generation", () => {
  test("produces the canonical Better BibTeX shape", () => {
    expect(baseKey({
      title: "Attention Is All You Need",
      author: [{ family: "Vaswani", given: "Ashish" }],
      issued: { "date-parts": [[2017, 6, 12]] },
    })).toBe("vaswaniAttentionAllYou2017");
  });

  test("stop words are skipped, not counted toward the three", () => {
    // "Is" and "You" are stop words, so the three significant words run past
    // them — this is what makes the key readable rather than "AttentionIsAll".
    expect(baseKey({
      title: "The Rise of the Machine",
      author: [{ family: "Turing" }],
      issued: { year: 1950 },
    })).toBe("turingRiseMachine1950");
  });

  test("a loose particle is dropped but a declared one is kept", () => {
    expect(baseKey({ title: "Automata", author: [{ family: "van der Waals" }] }))
      .toBe("waalsAutomata");
    expect(baseKey({
      title: "Automata",
      author: [{ family: "Neumann", "non-dropping-particle": "von " }],
    })).toBe("vonneumannAutomata");
  });

  test("a short title wins only while it is genuinely short", () => {
    const long = "A Very Long Short Title That Is Not Short At All Really";
    expect(baseKey({ title: "Deep Learning Methods", "short-title": "Deep Nets" }))
      .toBe("DeepNets");
    expect(baseKey({ title: "Deep Learning Methods", "short-title": long }))
      .toBe("DeepLearningMethods");
  });

  test("reads either shape CSL uses for the year", () => {
    expect(baseKey({ title: "Work", author: [{ family: "Lee" }], issued: { year: 1999 } }))
      .toBe("leeWork1999");
    expect(baseKey({
      title: "Work", author: [{ family: "Lee" }], issued: { "date-parts": [[1999]] },
    })).toBe("leeWork1999");
  });

  test("falls back to a literal name when there is no family name", () => {
    expect(baseKey({ title: "Standards", author: [{ literal: "ISO Committee" }] }))
      .toBe("isocommitteeStandards");
  });

  test("symbols and emoji are dropped rather than spelled out", () => {
    // Checked against the Swift implementation over the real library: 639 of
    // 644 items produce an identical key. These two are among the five that
    // differ, and here the new rule is the better one — AnyAscii renders ® as
    // "R" and 🎙 as "Microphone2", each of which would steal a title slot,
    // while CFStringTransform left an invisible variation selector at the
    // front of the key.
    expect(baseKeyFromFields("", "Apache Kafka® Performance, Latency", null))
      .toBe("ApacheKafkaPerformance");
    expect(baseKeyFromFields("", "🎙️ MacWhisper", null)).toBe("Macwhisper");
  });

  test("nothing to name it after yields an empty key, not a bad one", () => {
    expect(baseKey({})).toBe("");
    expect(baseKeyFromFields("", null, null)).toBe("");
  });

  test("non-Latin metadata still produces an ASCII key", () => {
    // Each ideograph is its own word, so a four-character title yields three
    // of them rather than one long run.
    expect(transliterate("Müller")).toBe("Muller");
    expect(transliterate("Nguyễn")).toBe("Nguyen");
    expect(baseKey({ title: "深度学习", author: [{ family: "北京" }] }))
      .toBe("beijingShenDuXue");
  });
});

describe("assignment", () => {
  test("assigns a key and leaves an existing one alone", () => {
    withCatalog((store, catalog) => {
      // The author here is the item's display string, not a parsed name, so
      // the whole of it flattens into the key — which is what the existing
      // library's keys look like ("brownj" from "Brown, J.").
      addItem(catalog, "a", "Deep Learning", "Ian Goodfellow");
      addItem(catalog, "b", "Deep Learning", "Ian Goodfellow", "chosenByHand");

      expect(store.assign("a", NOW)).toBe("iangoodfellowDeepLearning");
      expect(store.assign("b", NOW)).toBe("chosenByHand");
    });
  });

  test("a second item with the same metadata gets a suffix", () => {
    withCatalog((store, catalog) => {
      addItem(catalog, "a", "Deep Learning", "Ian Goodfellow");
      addItem(catalog, "b", "Deep Learning", "Ian Goodfellow");

      expect(store.assign("a", NOW)).toBe("iangoodfellowDeepLearning");
      expect(store.assign("b", NOW)).toBe("iangoodfellowDeepLearninga");
    });
  });

  test("proposing does not write", () => {
    withCatalog((store, catalog) => {
      addItem(catalog, "a", "Deep Learning", "Ian Goodfellow");

      expect(store.propose("a")).toBe("iangoodfellowDeepLearning");
      expect(catalog.db.query<{ cite_key: string | null }, []>(
        "SELECT cite_key FROM items WHERE id = 'a'").get()!.cite_key).toBeNull();
    });
  });

  test("an item's own key is not a clash with itself", () => {
    withCatalog((store, catalog) => {
      addItem(catalog, "a", "Deep Learning", "Ian Goodfellow", "iangoodfellowDeepLearning");
      expect(store.propose("a")).toBe("iangoodfellowDeepLearning");
    });
  });

  test("the citation's CSL is preferred over the item's plain fields", () => {
    withCatalog((store, catalog) => {
      addItem(catalog, "a", "untitled.pdf", "");
      seed(catalog.db,
        `INSERT INTO citations (item_id, csl_json, year, created_at, updated_at)
         VALUES ('a', '{"title":"Attention Is All You Need","author":[{"family":"Vaswani"}],"issued":{"year":2017}}', 2017, '', '')`);

      expect(store.assign("a", NOW)).toBe("vaswaniAttentionAllYou2017");
    });
  });

  test("unparseable CSL falls back to the item's fields rather than failing", () => {
    withCatalog((store, catalog) => {
      addItem(catalog, "a", "Deep Learning", "Ian Goodfellow");
      seed(catalog.db,
        `INSERT INTO citations (item_id, csl_json, year, created_at, updated_at)
         VALUES ('a', 'not json', 2016, '', '')`);

      expect(store.assign("a", NOW)).toBe("iangoodfellowDeepLearning2016");
    });
  });

  test("an item with no usable metadata gets no key at all", () => {
    withCatalog((store, catalog) => {
      addItem(catalog, "a", "", "");
      expect(store.assign("a", NOW)).toBeNull();
    });
  });

  test("a user-chosen key is rejected when taken, not quietly renamed", () => {
    withCatalog((store, catalog) => {
      addItem(catalog, "a", "One", "Author A", "taken2020");
      addItem(catalog, "b", "Two", "Author B");

      expect(() => store.save("taken2020", "b", NOW)).toThrow();
      store.save("free2021", "b", NOW);
      expect(catalog.db.query<{ cite_key: string }, []>(
        "SELECT cite_key FROM items WHERE id = 'b'").get()!.cite_key).toBe("free2021");
    });
  });
});
