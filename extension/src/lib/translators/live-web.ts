import type { Translator, TranslatorResult } from "./types";
import { isLiveWebHost } from "./url-utils";
import { extractLinkMetadata } from "./link";

/**
 * Video & social sites (YouTube, bilibili, X, …). An offline HTML snapshot of these is
 * meaningless, so they are always clipped as a `link` bookmark — never offered the
 * "Archive" snapshot option in the popup. Detection lives in `isLiveWebHost`.
 */
export const liveWebTranslator: Translator = {
  id: "live-web",
  label: "Bookmark",
  contentKind: "link",
  priority: 10, // above scholarly (5) so video/social hosts always win

  detect(url: string): boolean {
    return isLiveWebHost(url);
  },

  async extract(doc: Document, url: string): Promise<TranslatorResult> {
    return extractLinkMetadata(doc, url);
  },
};
