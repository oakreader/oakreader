/**
 * Properties — the tag and status columns, their options, and per-item values.
 *
 * Three tables with a clear shape: a property is a column definition, an option
 * is one allowed value of a select-type column, and a value binds an item to
 * either an option or free text. A select value carries `option_id`; a text
 * value carries `text_value`; never both.
 *
 * How many values an item may hold is decided by the property's *type*, and
 * that is the rule worth keeping in one place:
 *
 *   - `multi_select` — many, one row per chosen option. Tags work this way.
 *   - `single_select` — one; choosing again replaces.
 *   - `text` / `number` — one, free text.
 *
 * The store reads the type itself rather than taking a flag from the caller,
 * because a caller that guesses wrong turns a second tag into a lost first one.
 * SQLite cannot express any of this as a constraint: `item_property_values` has
 * its own surrogate id, so uniqueness is behavioural either way.
 */
import type { Database } from "bun:sqlite";

export interface PropertyOption {
  id: string;
  propertyId: string;
  name: string;
  colorHex: string;
  position: number;
}

export interface Property {
  id: string;
  name: string;
  /** "select" or "text". */
  type: string;
  icon: string;
  position: number;
  /** Built in; the UI refuses to delete these. */
  isSystem: boolean;
  options: PropertyOption[];
}

export class PropertyStore {
  constructor(private readonly db: Database) {}

  /** Every property with its options, both in display order. */
  list(): Property[] {
    const options = new Map<string, PropertyOption[]>();
    for (const o of this.db.query<any, []>(
      `SELECT id, property_id, name, color_hex, position
         FROM property_options ORDER BY position, name`).all()) {
      const list = options.get(o.property_id) ?? [];
      list.push({
        id: o.id, propertyId: o.property_id, name: o.name,
        colorHex: o.color_hex, position: o.position,
      });
      options.set(o.property_id, list);
    }

    return this.db.query<any, []>(
      `SELECT id, name, type, icon, position, is_system
         FROM properties ORDER BY position, name`).all().map((p) => ({
      id: p.id, name: p.name, type: p.type, icon: p.icon,
      position: p.position, isSystem: p.is_system !== 0,
      options: options.get(p.id) ?? [],
    }));
  }

  upsertOption(o: PropertyOption): void {
    this.db.prepare(
      `INSERT INTO property_options (id, property_id, name, color_hex, position)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         name = excluded.name, color_hex = excluded.color_hex,
         position = excluded.position`,
    ).run(o.id, o.propertyId, o.name, o.colorHex, o.position);
  }

  /** Removes the option and, by cascade, every item value that pointed at it. */
  deleteOption(id: string): void {
    this.db.prepare("DELETE FROM property_options WHERE id = ?").run(id);
  }

  /**
   * Add a select value. Replaces the previous one for a single-select property,
   * appends for a multi-select, and is a no-op if that option is already set.
   */
  addSelectValue(
    valueId: string, itemId: string, propertyId: string, optionId: string,
  ): void {
    const type = this.db.query<{ type: string }, [string]>(
      "SELECT type FROM properties WHERE id = ?").get(propertyId)?.type;
    if (type === undefined) return;

    this.db.transaction(() => {
      if (type === "multi_select") {
        const already = this.db.query<{ n: number }, [string, string, string]>(
          `SELECT count(*) AS n FROM item_property_values
            WHERE item_id = ? AND property_id = ? AND option_id = ?`,
        ).get(itemId, propertyId, optionId)!.n;
        if (already > 0) return;
      } else {
        this.db.prepare(
          "DELETE FROM item_property_values WHERE item_id = ? AND property_id = ?",
        ).run(itemId, propertyId);
      }
      this.db.prepare(
        `INSERT INTO item_property_values (id, item_id, property_id, option_id, text_value)
         VALUES (?, ?, ?, ?, NULL)`,
      ).run(valueId, itemId, propertyId, optionId);
    })();
  }

  /** Remove one chosen option from an item, leaving its other values alone. */
  removeSelectValue(itemId: string, propertyId: string, optionId: string): void {
    this.db.prepare(
      `DELETE FROM item_property_values
        WHERE item_id = ? AND property_id = ? AND option_id = ?`,
    ).run(itemId, propertyId, optionId);
  }
}
