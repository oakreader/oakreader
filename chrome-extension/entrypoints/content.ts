import { defineContentScript } from "wxt/utils/define-content-script";

interface PageData {
  type: "html" | "youtube" | "podcast";
  url: string;
  title: string | null;
  author?: string | null;
  html?: string | null;
  videoId?: string | null;
  duration?: number | null;
  thumbnailURL?: string | null;
  transcript?: string | null;
  episodeTitle?: string | null;
  feedURL?: string | null;
  audioURL?: string | null;
  description?: string | null;
}

function detectPageType(url: string): "html" | "youtube" | "podcast" {
  try {
    const u = new URL(url);
    if (
      (u.hostname === "www.youtube.com" ||
        u.hostname === "youtube.com" ||
        u.hostname === "m.youtube.com") &&
      u.pathname === "/watch" &&
      u.searchParams.has("v")
    ) {
      return "youtube";
    }
    const podcastHosts = [
      "podcasts.apple.com",
      "open.spotify.com",
      "podcasts.google.com",
      "overcast.fm",
      "pocketcasts.com",
      "castbox.fm",
    ];
    if (podcastHosts.some((h) => u.hostname.includes(h))) {
      return "podcast";
    }
  } catch {
    // ignore
  }
  return "html";
}

function extractWebPage(): PageData {
  return {
    type: "html",
    url: location.href,
    title: document.title || location.href,
    html: document.documentElement.outerHTML,
  };
}

function extractYouTube(): PageData {
  const url = new URL(location.href);
  const videoId = url.searchParams.get("v");

  const title =
    document.querySelector<HTMLMetaElement>('meta[name="title"]')?.content ??
    document.querySelector("h1.ytd-watch-metadata yt-formatted-string")
      ?.textContent ??
    document.title;

  const author =
    document
      .querySelector("#owner #channel-name a")
      ?.textContent?.trim() ??
    document.querySelector<HTMLLinkElement>('link[itemprop="name"]')?.content ??
    null;

  let duration: number | null = null;
  const durationMeta = document.querySelector<HTMLMetaElement>(
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
    const segments = document.querySelectorAll(
      "ytd-transcript-segment-renderer"
    );
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
    type: "youtube",
    url: location.href,
    title,
    author,
    videoId,
    duration,
    thumbnailURL,
    transcript,
  };
}

function extractPodcast(): PageData {
  const title = document.title || location.href;

  const author =
    document.querySelector<HTMLMetaElement>('meta[name="author"]')?.content ??
    document.querySelector<HTMLMetaElement>('meta[property="og:site_name"]')
      ?.content ??
    null;

  const episodeTitle =
    document.querySelector<HTMLMetaElement>('meta[property="og:title"]')
      ?.content ?? title;

  const thumbnailURL =
    document.querySelector<HTMLMetaElement>('meta[property="og:image"]')
      ?.content ?? null;

  const description =
    document.querySelector<HTMLMetaElement>('meta[property="og:description"]')
      ?.content ??
    document.querySelector<HTMLMetaElement>('meta[name="description"]')
      ?.content ??
    null;

  let audioURL: string | null = null;
  const audioEl = document.querySelector<HTMLSourceElement | HTMLAudioElement>(
    "audio source, audio[src]"
  );
  if (audioEl) {
    audioURL = audioEl.src || audioEl.getAttribute("src");
  }

  return {
    type: "podcast",
    url: location.href,
    title,
    author,
    episodeTitle,
    thumbnailURL,
    description,
    audioURL,
  };
}

export default defineContentScript({
  matches: ["<all_urls>"],
  runAt: "document_idle",

  main() {
    chrome.runtime.onMessage.addListener((request, _sender, sendResponse) => {
      if (request.action === "getPageData") {
        const pageType = detectPageType(location.href);
        let data: PageData;
        switch (pageType) {
          case "youtube":
            data = extractYouTube();
            break;
          case "podcast":
            data = extractPodcast();
            break;
          default:
            data = extractWebPage();
            break;
        }
        sendResponse(data);
      }
      return true;
    });
  },
});
