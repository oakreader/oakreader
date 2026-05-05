import type { Translator, TranslatorResult } from "./types";
import { isYouTubeWatchURL, extractYouTubeVideoId } from "./url-utils";

export const youtubeTranslator: Translator = {
  id: "youtube",
  label: "YouTube",
  contentKind: "youtube",
  priority: 10,

  detect(url: string): boolean {
    return isYouTubeWatchURL(url);
  },

  async extract(doc: Document, url: string): Promise<TranslatorResult> {
    const videoId = extractYouTubeVideoId(url);

    const title =
      doc.querySelector<HTMLMetaElement>('meta[name="title"]')?.content ??
      doc.querySelector("h1.ytd-watch-metadata yt-formatted-string")
        ?.textContent ??
      doc.title;

    const author =
      doc.querySelector("#owner #channel-name a")?.textContent?.trim() ??
      doc.querySelector<HTMLLinkElement>('link[itemprop="name"]')?.content ??
      null;

    let duration: number | null = null;
    const durationMeta = doc.querySelector<HTMLMetaElement>(
      'meta[itemprop="duration"]'
    )?.content;
    if (durationMeta) {
      const match = durationMeta.match(/PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/);
      if (match) {
        duration =
          (parseInt(match[1] || "0") * 3600) +
          (parseInt(match[2] || "0") * 60) +
          parseInt(match[3] || "0");
      }
    }

    const thumbnailURL = videoId
      ? `https://img.youtube.com/vi/${videoId}/maxresdefault.jpg`
      : null;

    let transcript: string | null = null;
    try {
      const segments = doc.querySelectorAll("ytd-transcript-segment-renderer");
      if (segments.length > 0) {
        transcript = Array.from(segments)
          .map((seg) => {
            const time =
              seg.querySelector(".segment-timestamp")?.textContent?.trim() ?? "";
            const text =
              seg.querySelector(".segment-text")?.textContent?.trim() ?? "";
            return `[${time}] ${text}`;
          })
          .join("\n");
      }
    } catch {
      // best-effort
    }

    return {
      kind: "youtube",
      url,
      title,
      author,
      videoId,
      duration,
      thumbnailURL,
      transcript,
    };
  },
};
