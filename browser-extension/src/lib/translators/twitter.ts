import type { Translator, TranslatorResult } from "./types";
import { isTwitterStatusURL, extractTwitterHandle } from "./url-utils";

export const twitterTranslator: Translator = {
  id: "twitter",
  label: "Twitter/X",
  contentKind: "twitter",
  priority: 10,

  detect(url: string): boolean {
    return isTwitterStatusURL(url);
  },

  async extract(doc: Document, url: string): Promise<TranslatorResult> {
    const handle = extractTwitterHandle(url);

    // Author from og:title — format is typically "Author Name on X: ..."
    const ogTitle =
      doc.querySelector<HTMLMetaElement>('meta[property="og:title"]')?.content ?? "";
    const authorName = ogTitle.includes(" on X:")
      ? ogTitle.split(" on X:")[0].trim()
      : ogTitle.includes(" on Twitter:")
        ? ogTitle.split(" on Twitter:")[0].trim()
        : handle;

    // Tweet text — prefer DOM (most reliable), fall back to meta tags
    const tweetTextEl = doc.querySelector('[data-testid="tweetText"]');
    const description =
      tweetTextEl?.textContent?.trim() ||
      doc.querySelector<HTMLMetaElement>('meta[property="og:description"]')?.content ||
      doc.querySelector<HTMLMetaElement>('meta[name="description"]')?.content ||
      null;

    // Thumbnail — prefer actual tweet media over generic og:image
    const tweetMediaImg = doc.querySelector<HTMLImageElement>(
      '[data-testid="tweetPhoto"] img, [data-testid="videoPlayer"] video[poster]'
    );
    const tweetMediaURL = tweetMediaImg
      ? (tweetMediaImg as HTMLImageElement).src || (tweetMediaImg as unknown as HTMLVideoElement).poster
      : null;
    const ogImage =
      doc.querySelector<HTMLMetaElement>('meta[property="og:image"]')?.content ?? null;
    // Skip X's default logo
    const isDefaultOg = ogImage?.includes("abs.twimg.com/rweb/ssr/default");
    const thumbnailURL = tweetMediaURL || (isDefaultOg ? null : ogImage);

    const title = authorName || doc.title || `@${handle} post`;

    return {
      kind: "twitter",
      url,
      title,
      author: `@${handle}`,
      handle,
      description,
      thumbnailURL,
    };
  },
};
