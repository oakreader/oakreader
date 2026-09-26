/**
 * Argument parsing, small enough to read in one sitting.
 *
 * A dependency would be the obvious move, but the grammar here is fixed and
 * tiny: a subcommand path, long options, boolean flags, and positionals. What
 * a library would add is everything this program does not have — short option
 * clustering, negation, environment binding — at the cost of a parser nobody
 * in this repo can step through.
 */
export interface Parsed {
  path: string[];
  positionals: string[];
  options: Map<string, string>;
  flags: Set<string>;
}

/**
 * Split argv into the command path and its arguments.
 *
 * `known` is the set of subcommand names valid at each level, so that
 * `oak items read paper2512` stops descending at `read` and treats the rest as
 * arguments — a word that merely happens to match a command name later in the
 * line is a value, not a command.
 */
export function parse(
  argv: string[], known: (path: string[]) => Set<string>, booleans: Set<string>,
): Parsed {
  const path: string[] = [];
  const positionals: string[] = [];
  const options = new Map<string, string>();
  const flags = new Set<string>();

  let descending = true;
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i]!;

    if (token.startsWith("--")) {
      const body = token.slice(2);
      const equals = body.indexOf("=");
      if (equals >= 0) {
        options.set(body.slice(0, equals), body.slice(equals + 1));
        continue;
      }
      // Which long tokens are booleans has to be declared. Guessing from
      // whether a value follows swallows the subcommand — `--json items list`
      // would read "items" as the value of --json and then find no command.
      const next = argv[i + 1];
      if (!booleans.has(body) && next !== undefined && !next.startsWith("--")) {
        options.set(body, next);
        i++;
      } else {
        flags.add(body);
      }
      continue;
    }

    if (descending && known(path).has(token)) {
      path.push(token);
      continue;
    }
    descending = false;
    positionals.push(token);
  }

  return { path, positionals, options, flags };
}

/** A long token that is sometimes a flag and sometimes an option. */
export function flag(parsed: Parsed, name: string): boolean {
  if (parsed.flags.has(name)) return true;
  const value = parsed.options.get(name);
  return value === "true" || value === "";
}

export function option(parsed: Parsed, name: string): string | null {
  const value = parsed.options.get(name);
  if (value !== undefined) return value;
  return parsed.flags.has(name) ? "" : null;
}

export function integer(parsed: Parsed, name: string): number | null {
  const raw = option(parsed, name);
  if (raw === null || raw === "") return null;
  const value = Number(raw);
  if (!Number.isInteger(value)) {
    throw new Error(`--${name} expects a whole number, got '${raw}'.`);
  }
  return value;
}
