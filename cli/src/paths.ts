/**
 * Where the library lives, and which one.
 *
 * Two channels share this machine: a release app under ~/OakReader and a debug
 * build under ~/OakReader-Dev. The Swift CLI picked between them with a `#if
 * DEBUG` baked in at compile time. A single portable binary has no such flag,
 * so the channel is read from the environment — OAK_CHANNEL=dev, or the
 * OAK_DATA_DIR that overrides both — and defaults to the release library.
 *
 * Getting this wrong is not a cosmetic mistake: it points the CLI at a library
 * the running app does not own.
 */
import { homedir } from "node:os";
import { join } from "node:path";

export function dataDirectory(): string {
  const override = process.env.OAK_DATA_DIR;
  if (override !== undefined && override !== "") return override;
  const dev = process.env.OAK_CHANNEL === "dev";
  return join(homedir(), dev ? "OakReader-Dev" : "OakReader");
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
