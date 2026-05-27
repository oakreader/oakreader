import type { ContentKind, Translator } from "./types";
import { youtubeTranslator } from "./youtube";
import { scholarlyTranslator } from "./scholarly";
import { genericWebpageTranslator } from "./webpage";

const translators: Translator[] = [
  youtubeTranslator,
  scholarlyTranslator,
  genericWebpageTranslator,
].sort((a, b) => b.priority - a.priority);

/**
 * Returns the highest-priority translator whose `detect()` matches the URL.
 * Always returns a translator (genericWebpageTranslator is the catch-all).
 */
export function getTranslator(url: string): Translator {
  return translators.find((t) => t.detect(url)) ?? genericWebpageTranslator;
}

/**
 * Returns the ContentKind for a URL without running full extraction.
 */
export function detectContentKind(url: string): ContentKind {
  return getTranslator(url).contentKind;
}

/**
 * Maps ContentKind to the page type used by the popup and OakServer.
 */
export function contentKindToPageType(kind: ContentKind): "html" | "embed" {
  switch (kind) {
    case "youtube":
      return "embed";
    case "webpage":
    case "scholarly":
    case "link":
      return "html";
  }
}

/**
 * Maps ContentKind to a human-readable label for the popup UI.
 */
export function contentKindToLabel(kind: ContentKind): string {
  switch (kind) {
    case "youtube":
      return "Video";
    case "scholarly":
      return "Article";
    case "link":
      return "Bookmark";
    case "webpage":
      return "Web Page";
  }
}
