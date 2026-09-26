/**
 * Turning what someone typed into exactly one row.
 *
 * Every identifier is tried from most specific to least — id, then exact name,
 * then prefix — and the first rung that matches at all is the answer. That
 * ordering is what lets a short title win over a longer one it is a prefix of;
 * without it, `oak items show Attention` would be ambiguous against every
 * paper whose title merely starts that way.
 *
 * Two matches is an error rather than a guess, and the error names them: the
 * cost of picking wrong is an edit to the wrong document.
 */
import type { Collection, Item, PropertyOption, Queries } from "./queries.ts";

export class OakError extends Error {
  constructor(message: string, readonly code = "error") {
    super(message);
  }
}

export function notFound(kind: string, input: string): OakError {
  return new OakError(`No ${kind} found matching '${input}'.`, "not_found");
}

function ambiguous(kind: string, input: string, options: string[]): OakError {
  return new OakError(
    `Ambiguous ${kind} '${input}'. Did you mean one of:\n`
    + options.map((o) => `  - ${o}\n`).join(""),
    "ambiguous");
}

function one<T>(matches: T[], kind: string, input: string, label: (v: T) => string): T {
  if (matches.length === 0) throw notFound(kind, input);
  if (matches.length > 1) throw ambiguous(kind, input, matches.map(label));
  return matches[0]!;
}

export class Resolver {
  constructor(private readonly q: Queries) {}

  item(input: string): Item {
    return one(this.q.findItems(input), "item", input,
      (i) => `${i.title} [${i.id.slice(0, 8)}]`);
  }

  collection(input: string): Collection {
    return one(this.q.findCollections(input), "collection", input,
      (c) => `${c.name} [${c.id.slice(0, 8)}]`);
  }

  tag(input: string): PropertyOption {
    return one(this.q.findTags(input), "tag", input,
      (t) => `${t.name} [${t.id.slice(0, 8)}]`);
  }

  /**
   * A status is chosen from a fixed, short list, so an unknown one is worth a
   * better error than "not found": it names what is valid.
   */
  status(input: string): PropertyOption {
    const statuses = this.q.listOptions("Status");
    const needle = input.toLowerCase();

    const exact = statuses.find((s) => s.name.toLowerCase() === needle);
    if (exact !== undefined) return exact;

    const prefix = statuses.filter((s) => s.name.toLowerCase().startsWith(needle));
    if (prefix.length === 0) {
      throw new OakError(
        `Invalid status '${input}'. Valid values: ${statuses.map((s) => s.name).join(", ")}`,
        "invalid_status");
    }
    if (prefix.length > 1) {
      throw ambiguous("status", input, prefix.map((s) => s.name));
    }
    return prefix[0]!;
  }
}
