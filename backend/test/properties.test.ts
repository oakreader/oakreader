/**
 * Properties, options and values. What is worth testing here is the rule SQLite
 * cannot express: how many values an item may hold depends on the property's
 * type, and only the store knows that. Get it wrong and a second tag either
 * silently replaces the first (multi treated as single) or a status column ends
 * up holding two contradictory values (single treated as multi).
 */
import { test, expect, describe } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Catalog } from "../src/catalog/db.ts";
import { PropertyStore } from "../src/catalog/properties.ts";

function withCatalog<T>(body: (s: PropertyStore, c: Catalog) => T): T {
  const dir = mkdtempSync(join(tmpdir(), "oak-properties-"));
  try {
    const catalog = Catalog.open(join(dir, "library.sqlite"));
    try {
      catalog.db.exec(
        `INSERT INTO items (id, user_id, storage_key, title, created_at, updated_at)
         VALUES ('doc-1', 'local', 'sk-1', 'A Paper', '', ''),
                ('doc-2', 'local', 'sk-2', 'Another', '', '')`);
      return body(new PropertyStore(catalog.db), catalog);
    } finally {
      catalog.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/** Tags: the multi-select shape, with two options. */
function seedTags(store: PropertyStore) {
  store.upsertProperty({
    id: "prop-tags", name: "Tags", type: "multi_select", icon: "tag",
    position: 0, isSystem: true,
  });
  store.upsertOption({
    id: "opt-urgent", propertyId: "prop-tags", name: "Urgent",
    colorHex: "ff0000", position: 0,
  });
  store.upsertOption({
    id: "opt-later", propertyId: "prop-tags", name: "Later",
    colorHex: "0000ff", position: 1,
  });
}

/** Status: the single-select shape, with two options. */
function seedStatus(store: PropertyStore) {
  store.upsertProperty({
    id: "prop-status", name: "Status", type: "single_select", icon: "circle",
    position: 1, isSystem: true,
  });
  store.upsertOption({
    id: "opt-reading", propertyId: "prop-status", name: "Reading",
    colorHex: "00ff00", position: 0,
  });
  store.upsertOption({
    id: "opt-done", propertyId: "prop-status", name: "Done",
    colorHex: "888888", position: 1,
  });
}

const valuesOf = (c: Catalog, itemId: string, propertyId: string) =>
  c.db.query<{ option_id: string | null; text_value: string | null }, [string, string]>(
    `SELECT option_id, text_value FROM item_property_values
      WHERE item_id = ? AND property_id = ? ORDER BY option_id`).all(itemId, propertyId);

describe("properties", () => {
  test("round-trips with its options in order", () => {
    withCatalog((store) => {
      seedTags(store);
      const [tags] = store.list();
      expect(tags!.name).toBe("Tags");
      expect(tags!.isSystem).toBe(true);
      expect(tags!.options.map((o) => o.name)).toEqual(["Urgent", "Later"]);
    });
  });

  test("a multi-select item keeps every option it was given", () => {
    withCatalog((store, catalog) => {
      seedTags(store);
      store.addSelectValue("v1", "doc-1", "prop-tags", "opt-urgent");
      store.addSelectValue("v2", "doc-1", "prop-tags", "opt-later");

      expect(valuesOf(catalog, "doc-1", "prop-tags").map((v) => v.option_id))
        .toEqual(["opt-later", "opt-urgent"]);
    });
  });

  test("adding the same option twice changes nothing", () => {
    withCatalog((store, catalog) => {
      seedTags(store);
      store.addSelectValue("v1", "doc-1", "prop-tags", "opt-urgent");
      store.addSelectValue("v2", "doc-1", "prop-tags", "opt-urgent");

      expect(valuesOf(catalog, "doc-1", "prop-tags")).toHaveLength(1);
    });
  });

  test("a single-select item holds only the latest option", () => {
    withCatalog((store, catalog) => {
      seedStatus(store);
      store.addSelectValue("v1", "doc-1", "prop-status", "opt-reading");
      store.addSelectValue("v2", "doc-1", "prop-status", "opt-done");

      const rows = valuesOf(catalog, "doc-1", "prop-status");
      expect(rows).toHaveLength(1);
      expect(rows[0]!.option_id).toBe("opt-done");
    });
  });

  test("removing one option leaves the item's others alone", () => {
    withCatalog((store, catalog) => {
      seedTags(store);
      store.addSelectValue("v1", "doc-1", "prop-tags", "opt-urgent");
      store.addSelectValue("v2", "doc-1", "prop-tags", "opt-later");

      store.removeSelectValue("doc-1", "prop-tags", "opt-urgent");

      expect(valuesOf(catalog, "doc-1", "prop-tags").map((v) => v.option_id))
        .toEqual(["opt-later"]);
    });
  });

  test("different items keep their own values", () => {
    withCatalog((store, catalog) => {
      seedTags(store);
      store.addSelectValue("v1", "doc-1", "prop-tags", "opt-urgent");
      store.addSelectValue("v2", "doc-2", "prop-tags", "opt-later");

      expect(valuesOf(catalog, "doc-1", "prop-tags")).toHaveLength(1);
      expect(valuesOf(catalog, "doc-2", "prop-tags")).toHaveLength(1);
    });
  });

  test("a text value replaces the previous one and carries no option", () => {
    withCatalog((store, catalog) => {
      store.upsertProperty({
        id: "prop-notes", name: "Notes", type: "text", icon: "note",
        position: 1, isSystem: false,
      });
      store.setTextValue("v1", "doc-1", "prop-notes", "read once");
      store.setTextValue("v2", "doc-1", "prop-notes", "read twice");

      const rows = valuesOf(catalog, "doc-1", "prop-notes");
      expect(rows).toHaveLength(1);
      expect(rows[0]!.option_id).toBeNull();
      expect(rows[0]!.text_value).toBe("read twice");
    });
  });

  test("an empty text value clears rather than storing nothing", () => {
    withCatalog((store, catalog) => {
      store.upsertProperty({
        id: "prop-notes", name: "Notes", type: "text", icon: "note",
        position: 1, isSystem: false,
      });
      store.setTextValue("v1", "doc-1", "prop-notes", "read once");
      store.setTextValue("v2", "doc-1", "prop-notes", "");

      expect(valuesOf(catalog, "doc-1", "prop-notes")).toHaveLength(0);
    });
  });

  test("a value for an unknown property is refused, not inserted", () => {
    // The type lookup is what decides replace-vs-append, so a missing property
    // has no answer. Dropping it beats guessing single and losing a tag.
    withCatalog((store, catalog) => {
      store.addSelectValue("v1", "doc-1", "prop-ghost", "opt-ghost");
      expect(catalog.db.query<{ n: number }, []>(
        "SELECT count(*) AS n FROM item_property_values").get()!.n).toBe(0);
    });
  });

  test("deleting an option takes the values that used it", () => {
    withCatalog((store, catalog) => {
      seedTags(store);
      store.addSelectValue("v1", "doc-1", "prop-tags", "opt-urgent");
      store.addSelectValue("v2", "doc-2", "prop-tags", "opt-later");

      store.deleteOption("opt-urgent");

      const remaining = catalog.db.query<{ option_id: string }, []>(
        "SELECT option_id FROM item_property_values").all();
      expect(remaining.map((r) => r.option_id)).toEqual(["opt-later"]);
    });
  });

  test("deleting a property takes its options and values with it", () => {
    withCatalog((store, catalog) => {
      seedTags(store);
      store.addSelectValue("v1", "doc-1", "prop-tags", "opt-urgent");

      store.deleteProperty("prop-tags");

      expect(store.list()).toHaveLength(0);
      expect(catalog.db.query<{ n: number }, []>(
        "SELECT count(*) AS n FROM property_options").get()!.n).toBe(0);
      expect(catalog.db.query<{ n: number }, []>(
        "SELECT count(*) AS n FROM item_property_values").get()!.n).toBe(0);
    });
  });

  test("renaming an option keeps the values pointing at it", () => {
    withCatalog((store) => {
      seedTags(store);
      store.addSelectValue("v1", "doc-1", "prop-tags", "opt-urgent");

      store.upsertOption({
        id: "opt-urgent", propertyId: "prop-tags", name: "Critical",
        colorHex: "ff0000", position: 0,
      });

      expect(store.list()[0]!.options.find((o) => o.id === "opt-urgent")!.name)
        .toBe("Critical");
    });
  });
});
