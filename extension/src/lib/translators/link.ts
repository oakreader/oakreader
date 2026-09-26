import type { TranslatorResult } from "./types";

/**
 * Extracts lightweight link metadata (OG tags only).
 * Not a registered translator — called explicitly when user selects "Save as Link" mode.
 */
export function extractLinkMetadata(doc: Document, url: string): TranslatorResult {
  const title = doc.title || url;

  const description =
    doc.querySelector<HTMLMetaElement>('meta[name="description"]')?.content ??
    doc.querySelector<HTMLMetaElement>('meta[property="og:description"]')?.content ??
    null;

  const thumbnailURL =
    doc.querySelector<HTMLMetaElement>('meta[property="og:image"]')?.content ?? null;

  const author =
    doc.querySelector<HTMLMetaElement>('meta[name="author"]')?.content ??
    doc.querySelector<HTMLMetaElement>('meta[property="og:site_name"]')?.content ??
    null;

  return {
    kind: "link",
    url,
    title,
    author,
    description,
    thumbnailURL,
  };
}
