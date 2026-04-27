import { defineContentScript } from "wxt/utils/define-content-script";

interface PageData {
  type: "html" | "embed";
  url: string;
  title: string | null;
  author?: string | null;
  html?: string | null;
  videoId?: string | null;
  duration?: number | null;
  thumbnailURL?: string | null;
  transcript?: string | null;
  description?: string | null;
}

// Pending background fetch responses
const pendingResponses = new Map<
  number,
  {
    resolve: (value: unknown) => void;
    reject: (reason: unknown) => void;
    array?: number[];
  }
>();
let fetchRequestId = 0;

function detectPageType(url: string): "html" | "embed" {
  try {
    const u = new URL(url);
    if (
      (u.hostname === "www.youtube.com" ||
        u.hostname === "youtube.com" ||
        u.hostname === "m.youtube.com") &&
      u.pathname === "/watch" &&
      u.searchParams.has("v")
    ) {
      return "embed";
    }
  } catch {
    // ignore
  }
  return "html";
}

// SingleFile fetch: try page-context fetch first, fall back to background
async function contentFetch(
  url: string,
  options: Record<string, unknown> = {}
) {
  try {
    const fetchOptions: RequestInit = {
      cache: (options.cache as RequestCache) || "force-cache",
      headers: options.headers as HeadersInit,
      referrerPolicy:
        (options.referrerPolicy as ReferrerPolicy) ||
        "strict-origin-when-cross-origin",
    };
    const response = await fetch(url, fetchOptions);
    if (
      response.status === 401 ||
      response.status === 403 ||
      response.status === 404
    ) {
      throw new Error(`HTTP ${response.status}`);
    }
    return response;
  } catch {
    return backgroundFetch(url, options);
  }
}

async function backgroundFetch(
  url: string,
  options: Record<string, unknown>
): Promise<{
  status: number;
  headers: { get(name: string): string | null };
  arrayBuffer(): Promise<ArrayBuffer>;
}> {
  fetchRequestId++;
  const requestId = fetchRequestId;

  const promise = new Promise<{
    status: number;
    headers: { get(name: string): string | null };
    arrayBuffer(): Promise<ArrayBuffer>;
  }>((resolve, reject) => {
    pendingResponses.set(requestId, { resolve, reject });
  });

  await chrome.runtime.sendMessage({
    method: "singlefile.fetch",
    url,
    requestId,
    referrer: options.referrer,
    headers: options.headers,
  });

  return promise;
}

function handleFetchResponse(message: {
  requestId: number;
  error?: string;
  truncated?: boolean;
  finished?: boolean;
  array?: number[];
  status?: number;
  headers?: Record<string, string>;
}) {
  const pending = pendingResponses.get(message.requestId);
  if (!pending) return;

  if (message.error) {
    pending.reject(new Error(message.error));
    pendingResponses.delete(message.requestId);
    return;
  }

  if (message.truncated) {
    if (pending.array) {
      pending.array = pending.array.concat(message.array || []);
    } else {
      pending.array = message.array || [];
    }
    if (!message.finished) return;
    message.array = pending.array;
  }

  pending.resolve({
    status: message.status || 0,
    headers: {
      get: (headerName: string) =>
        message.headers?.[headerName] ?? null,
    },
    arrayBuffer: async () =>
      new Uint8Array(message.array || []).buffer,
  });
  pendingResponses.delete(message.requestId);
}

async function extractWebPageWithSingleFile(): Promise<PageData> {
  try {
    // Dynamic import — Vite bundles single-file-core, loaded only when needed
    const singlefile = await import("single-file-core/single-file.js");

    singlefile.init({ fetch: contentFetch });

    const pageData = await singlefile.getPageData({
      removeFrames: true,
      blockScripts: true,
      blockVideos: true,
      compressHTML: false,
      loadDeferredImages: true,
      loadDeferredImagesMaxIdleTime: 1500,
      filenameTemplate: "{page-title}",
      infobarContent: "",
      includeInfobar: false,
      removeHiddenElements: true,
      removeUnusedStyles: true,
      removeUnusedFonts: true,
      removeSavedDate: true,
      compressCSS: true,
      loadDeferredImagesKeepZoomLevel: false,
      loadDeferredImagesDispatchScrollEvent: false,
      loadDeferredImagesBeforeFrames: false,
      backgroundSave: false,
      insertMetaCSP: true,
      insertMetaNoIndex: false,
      password: "",
      woleetKey: "",
      blockMixedContent: false,
      saveOriginalURLs: false,
      removeAlternativeFonts: true,
      removeAlternativeMedias: true,
      removeAlternativeImages: true,
      groupDuplicateImages: true,
      maxResourceSize: 10,
      maxResourceSizeEnabled: false,
      url: location.href,
    }, { fetch: contentFetch });

    return {
      type: "html",
      url: location.href,
      title: document.title || location.href,
      html: pageData.content as string,
    };
  } catch (error) {
    console.warn("SingleFile capture failed, falling back to raw HTML:", error);
    return {
      type: "html",
      url: location.href,
      title: document.title || location.href,
      html: document.documentElement.outerHTML,
    };
  }
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
    type: "embed",
    url: location.href,
    title,
    author,
    videoId,
    duration,
    thumbnailURL,
    transcript,
  };
}

export default defineContentScript({
  matches: ["<all_urls>"],
  runAt: "document_idle",

  main() {
    // Listen for background fetch responses (chunked)
    chrome.runtime.onMessage.addListener((message) => {
      if (message.method === "singlefile.fetchResponse") {
        handleFetchResponse(message);
      }
    });

    chrome.runtime.onMessage.addListener((request, _sender, sendResponse) => {
      if (request.action === "getPageData") {
        const pageType = detectPageType(location.href);

        if (pageType === "html") {
          extractWebPageWithSingleFile().then(sendResponse);
          return true;
        }

        // embed (YouTube)
        const data = extractYouTube();
        sendResponse(data);
        return true;
      }
      return true;
    });
  },
});
