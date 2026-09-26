/**
 * Reference metadata — the `citations` table, holding CSL JSON.
 *
 * The JSON is canonical; the other columns are derived from it so the catalog
 * can be searched by DOI, year or identifier without parsing every row. That
 * derivation happens here, on save, rather than at the call site, because a
 * column that disagrees with the JSON beside it is worse than no column.
 *
 * Saving also writes back to the item: a citation carries the real author and
 * title, and the item row is what the library list displays.
 */
import type { Database } from "bun:sqlite";
import { CiteKeyStore, cslYear, type CslItem } from "./citekeys.js";

/** The CSL fields the derived columns come from. */
interface CitationFields extends CslItem {
  type?: string;
  DOI?: string;
  ISBN?: string;
  ISSN?: string;
  "container-title"?: string;
  abstract?: string;
  note?: string;
}

/**
 * Pull an identifier out of the `extra` text or the CSL note.
 *
 * Both are free text where a line reads "PMID: 12345" — Zotero's convention
 * for anything CSL has no field for. `extra` wins because the user typed it.
 */
function identifier(prefix: string, extra: string | null, note: string | undefined): string | null {
  for (const source of [extra, note]) {
    if (source === null || source === undefined) continue;
    for (const line of source.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed.toLowerCase().startsWith(prefix)) continue;
      const value = trimmed.slice(prefix.length).trim();
      if (value !== "") return value;
    }
  }
  return null;
}

/** "Smith, J." — how the library list names an item's authors. */
function authorDisplay(csl: CitationFields): string {
  return (csl.author ?? [])
    .map((a) => {
      if (a.literal !== undefined && a.literal !== "") return a.literal;
      const given = a.given !== undefined && a.given !== "" ? `, ${a.given}` : "";
      return (a.family ?? "") + given;
    })
    .filter((name) => name !== "")
    .join(", ");
}

export class ReferenceStore {
  constructor(private readonly db: Database) {}

  /** The stored CSL JSON, or null if this item has no citation. */
  get(itemId: string): string | null {
    return this.db.query<{ csl_json: string }, [string]>(
      "SELECT csl_json FROM citations WHERE item_id = ?").get(itemId)?.csl_json ?? null;
  }

  /**
   * Save an item's metadata: the citation row, the derived columns, the item's
   * own author and title, and a cite key if it had none.
   *
   * One transaction, because these are one fact about the item. The cite key is
   * assigned inside it too — it is derived from this very metadata, and a key
   * computed from a half-written row would be wrong.
   */
  save(itemId: string, cslJson: string, extra: string | null, at: string): void {
    const csl = JSON.parse(cslJson) as CitationFields;
    const year = cslYear(csl);

    this.db.transaction(() => {
      const existing = this.db.query<{ created_at: string }, [string]>(
        "SELECT created_at FROM citations WHERE item_id = ?").get(itemId);

      this.db.prepare(
        `INSERT INTO citations
           (item_id, csl_json, csl_type, doi, year, container_title, abstract,
            pmid, arxiv_id, isbn, issn, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(item_id) DO UPDATE SET
           csl_json = excluded.csl_json, csl_type = excluded.csl_type,
           doi = excluded.doi, year = excluded.year,
           container_title = excluded.container_title,
           abstract = excluded.abstract, pmid = excluded.pmid,
           arxiv_id = excluded.arxiv_id, isbn = excluded.isbn,
           issn = excluded.issn, updated_at = excluded.updated_at`,
      ).run(
        // csl_type is NOT NULL; "document" is the schema's own default.
        itemId, cslJson, csl.type ?? "document", csl.DOI ?? null, year,
        csl["container-title"] ?? null, csl.abstract ?? null,
        identifier("pmid:", extra, csl.note),
        identifier("arxiv:", extra, csl.note),
        csl.ISBN ?? null, csl.ISSN ?? null,
        existing?.created_at ?? at, at,
      );

      // Only overwrite what the citation actually carries: an empty author
      // field means "unknown here", not "the item has no author".
      const author = authorDisplay(csl);
      if (author !== "") {
        this.db.prepare("UPDATE items SET author = ?, updated_at = ? WHERE id = ?")
          .run(author, at, itemId);
      }
      if (csl.title !== undefined && csl.title !== "") {
        this.db.prepare("UPDATE items SET title = ?, updated_at = ? WHERE id = ?")
          .run(csl.title, at, itemId);
      }
      if (extra !== null && extra !== "") {
        this.db.prepare("UPDATE items SET extra = ?, updated_at = ? WHERE id = ?")
          .run(extra, at, itemId);
      }

      new CiteKeyStore(this.db).assign(itemId, at);
    })();
  }
}
