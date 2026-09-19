// From t3code apps/web/src/lib/utils.ts (MIT) -- trimmed.
// The id factories (ProjectId/ThreadId/DraftId/MessageId) and their
// effect/Encoding + @t3tools/contracts imports are dropped: those identify
// rows in t3code's own store, which this panel does not have.
import { type CxOptions, cx } from "class-variance-authority";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: CxOptions) {
  return twMerge(cx(inputs));
}

export function isMacPlatform(platform: string): boolean {
  return /mac|iphone|ipad|ipod/i.test(platform);
}

export function isWindowsPlatform(platform: string): boolean {
  return /^win(dows)?/i.test(platform);
}

export function normalizeSearchText(value: string): string {
  return value.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase().replace(/\s+/g, " ").trim();
}
