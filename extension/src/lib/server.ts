/**
 * Locating the OakReader clip server.
 *
 * The release build listens on 23119 and the Debug build on 23120, so both can run at
 * the same time (see `app/Services/OakServer.swift`). Probe in that order: when
 * both are up, the installed release app wins; when only a dev build is running, clips
 * still land somewhere instead of failing.
 */

export const RELEASE_PORT = 23119;
export const DEV_PORT = 23120;

const PORTS: readonly number[] = [RELEASE_PORT, DEV_PORT];
const PROBE_TIMEOUT_MS = 2000;

/** Last base that answered, tried first so a session stays pinned to one app. */
let lastKnownBase: string | null = null;

export function baseForPort(port: number): string {
  return `http://127.0.0.1:${port}`;
}

export function isDevBase(base: string | null): boolean {
  return base === baseForPort(DEV_PORT);
}

/** Any HTTP reply means the app is up — `HEAD /clip` itself 404s, which is fine. */
async function isAlive(base: string): Promise<boolean> {
  try {
    await fetch(`${base}/clip`, {
      method: "HEAD",
      signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
    });
    return true;
  } catch {
    return false;
  }
}

/**
 * Resolve the base URL of a running OakReader, or null if none answers.
 * Callers that already resolved a base (the popup) should pass it along rather than
 * re-resolving, so a capture cannot switch apps mid-save.
 */
export async function resolveServerBase(): Promise<string | null> {
  const candidates = lastKnownBase
    ? [lastKnownBase, ...PORTS.map(baseForPort).filter((b) => b !== lastKnownBase)]
    : PORTS.map(baseForPort);

  for (const base of candidates) {
    if (await isAlive(base)) {
      lastKnownBase = base;
      return base;
    }
  }

  lastKnownBase = null;
  return null;
}
