/**
 * Two audiences, one command.
 *
 * A person reads the human form; an agent reads `--json`, where every answer
 * is the same envelope — `success`, the operation that produced it, and either
 * a result or an error.
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

  private print(value: unknown): void {
    console.log(JSON.stringify(value, null, 2));
  }
}
