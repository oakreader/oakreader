/**
 * Where the library lives, and which one.
 *
 * Two channels share this machine: a release app under ~/OakReader and a debug
 * build under ~/OakReader-Dev. Pointing at the wrong one is not a cosmetic
 * mistake — it hands the CLI a library the running app does not own — so the
 * channel is decided the same way the Swift version decided it, at build time.
 * `#if DEBUG` became a `--define`, stamped in by the Xcode phase that compiles
 * this; `OAK_CHANNEL` overrides it for a binary run outside a bundle, and
 * `OAK_DATA_DIR` overrides everything, which is how the tests get a scratch
 * library.
 */
import { homedir } from "node:os";
import { join } from "node:path";

/** Stamped in at compile time by `build-binary.sh`; absent in a source run. */
declare const OAK_BUILD_CHANNEL: string | undefined;

function channel(): string {
  const fromEnvironment = process.env.OAK_CHANNEL;
  if (fromEnvironment !== undefined && fromEnvironment !== "") return fromEnvironment;
  return typeof OAK_BUILD_CHANNEL === "undefined" ? "release" : OAK_BUILD_CHANNEL;
}

export function dataDirectory(): string {
  const override = process.env.OAK_DATA_DIR;
  if (override !== undefined && override !== "") return override;
  return join(homedir(), channel() === "dev" ? "OakReader-Dev" : "OakReader");
}

export function libraryPath(override?: string): string {
  if (override !== undefined && override !== "") return override;
  return join(dataDirectory(), "library.sqlite");
}

export function storageDirectory(): string {
  return join(dataDirectory(), "storage");
}

export function skillsDirectory(): string {
  return join(dataDirectory(), "skills");
}

/** A document's attachment directory: storage/{item}/attachments/{attachment}. */
export function attachmentDirectory(itemKey: string, attachmentKey: string): string {
  return join(storageDirectory(), itemKey, "attachments", attachmentKey);
}

export function attachmentFile(itemKey: string, attachmentKey: string, fileName: string): string {
  return join(attachmentDirectory(itemKey, attachmentKey), fileName);
}
