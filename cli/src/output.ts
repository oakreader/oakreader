/**
 * Two audiences, one command.
 *
 * A person reads the human form; an agent reads `--json`, where every answer
 * is the same envelope — `success`, the operation that produced it, and either
 * a result or an error. That shape is a contract: something is parsing it.
 */
export class Output {
  constructor(readonly json: boolean, readonly quiet: boolean) {}

  /** One result. Silent in human mode — the caller prints its own prose. */
  success(operation: string, result: unknown): void {
    if (this.json) this.print({ success: true, operation, result });
  }

  results(operation: string, items: unknown[], meta?: Record<string, number>): void {
    // `meta` is left out when there is none, not written as null.
    if (this.json) {
      this.print({ success: true, operation, results: items, ...(meta === undefined ? {} : { meta }) });
    }
  }

  /** Human-only. Suppressed by --json and by --quiet. */
  message(text: string): void {
    if (!this.json && !this.quiet) console.log(text);
  }

  error(operation: string, message: string, code: string): void {
    if (this.json) this.print({ success: false, operation, error: { message, code } });
    else process.stderr.write(`Error: ${message}\n`);
  }

  /** Keys sorted, so a diff of two runs is about the values. */
  private print(value: unknown): void {
    console.log(JSON.stringify(value, sortedKeys(value), 2));
  }
}

function sortedKeys(_root: unknown) {
  return function (this: unknown, _key: string, value: unknown): unknown {
    if (value === null || typeof value !== "object" || Array.isArray(value)) return value;
    const sorted: Record<string, unknown> = {};
    for (const key of Object.keys(value as object).sort()) {
      sorted[key] = (value as Record<string, unknown>)[key];
    }
    return sorted;
  };
}
