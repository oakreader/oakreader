import { defineContentScript } from "wxt/utils/define-content-script";

interface PageMeta {
  type: "html" | "embed" | "pdf";
  url: string;
  title: string | null;
  favicon: string | null;
}

interface PageCapture {
  type: "html" | "embed";
  url: string;
  title: string | null;
  html?: string | null;
  author?: string | null;
  videoId?: string | null;
  duration?: number | null;
  thumbnailURL?: string | null;
  transcript?: string | null;
  description?: string | null;
}

// ─── Background Fetch Plumbing ──────────────────────────────────────────────────

const pendingResponses = new Map<
  number,
  {
    resolve: (value: unknown) => void;
    reject: (reason: unknown) => void;
    array?: number[];
  }
>();
let fetchRequestId = 0;

// ─── Page-Context Fetch Plumbing ────────────────────────────────────────────────

let pageContextRequestId = 0;
const pendingPageFetches = new Map<
  number,
  {
    resolve: (value: {
      status: number;
      headers: { get(name: string): string | null };
      arrayBuffer(): Promise<ArrayBuffer>;
    }) => void;
    reject: (reason: unknown) => void;
  }
>();

// ─── Throttle for background fetches (max 10 concurrent, like Zotero) ───────────

const MAX_CONCURRENT_BG_FETCHES = 10;
let activeBgFetches = 0;
const bgFetchQueue: Array<() => void> = [];

function enqueueBgFetch<T>(fn: () => Promise<T>): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    function run() {
      activeBgFetches++;
      fn()
        .then(resolve)
        .catch(reject)
        .finally(() => {
          activeBgFetches--;
          if (bgFetchQueue.length > 0) {
            const next = bgFetchQueue.shift()!;
            next();
          }
        });
    }

    if (activeBgFetches < MAX_CONCURRENT_BG_FETCHES) {
      run();
    } else {
      bgFetchQueue.push(run);
    }
  });
}

// ─── Page Type Detection ────────────────────────────────────────────────────────

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

function getFavicon(): string | null {
  const link =
    document.querySelector<HTMLLinkElement>('link[rel="icon"]') ??
    document.querySelector<HTMLLinkElement>('link[rel="shortcut icon"]') ??
    document.querySelector<HTMLLinkElement>('link[rel~="icon"]');
  if (link?.href) return link.href;
  try {
    return new URL("/favicon.ico", location.origin).href;
  } catch {
    return null;
  }
}

/** Instant lightweight metadata — no SingleFile, no heavy processing. */
function getPageMeta(): PageMeta {
  // Check if the document is a PDF rendered by browser viewer
  if (
    document.contentType === "application/pdf" ||
    location.href.toLowerCase().endsWith(".pdf")
  ) {
    return {
      type: "pdf",
      url: location.href,
      title: document.title || null,
      favicon: null,
    };
  }

  return {
    type: detectPageType(location.href),
    url: location.href,
    title: document.title || null,
    favicon: getFavicon(),
  };
}

// ─── Page-Context Fetch (primary — uses page's cookies & CORS) ──────────────────

function pageContextFetch(
  url: string,
  options: Record<string, unknown> = {}
): Promise<{
  status: number;
  headers: { get(name: string): string | null };
  arrayBuffer(): Promise<ArrayBuffer>;
}> {
  pageContextRequestId++;
  const requestId = pageContextRequestId;

  const promise = new Promise<{
    status: number;
    headers: { get(name: string): string | null };
    arrayBuffer(): Promise<ArrayBuffer>;
  }>((resolve, reject) => {
    pendingPageFetches.set(requestId, { resolve, reject });
  });

  // Dispatch event to page-context hooks (MAIN world script)
  document.dispatchEvent(
    new CustomEvent("singlefile-request-fetch", {
      detail: JSON.stringify({
        url,
        requestId,
        options: {
          cache: options.cache || "force-cache",
          headers: options.headers,
          referrerPolicy: options.referrerPolicy || "strict-origin-when-cross-origin",
        },
      }),
    })
  );

  // Timeout: if page context doesn't respond in 8s, reject
  setTimeout(() => {
    if (pendingPageFetches.has(requestId)) {
      pendingPageFetches.get(requestId)!.reject(new Error("page fetch timeout"));
      pendingPageFetches.delete(requestId);
    }
  }, 8000);

  return promise;
}

// ─── Background Fetch (fallback — extension has host_permissions) ────────────────

async function backgroundFetch(
  url: string,
  options: Record<string, unknown>
): Promise<{
  status: number;
  headers: { get(name: string): string | null };
  arrayBuffer(): Promise<ArrayBuffer>;
}> {
  return enqueueBgFetch(async () => {
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
      referrer: (options.referrer as string) || location.href,
      headers: options.headers,
    });

    return promise;
  });
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

// ─── Combined Fetch: page context first, background fallback ─────────────────────

async function singleFileFetch(
  url: string,
  options: Record<string, unknown> = {}
) {
  // Try page-context fetch first (has cookies, correct CORS origin)
  try {
    return await pageContextFetch(url, options);
  } catch {
    // Fall through to background
  }

  // Fallback: fetch via background service worker (has host_permissions)
  return backgroundFetch(url, options);
}

// ─── SingleFile Capture ─────────────────────────────────────────────────────────

async function extractWebPageWithSingleFile(): Promise<PageCapture> {
  try {
    // Wait briefly for lazy images triggered by page-hooks IntersectionObserver
    await new Promise((r) => setTimeout(r, 300));

    const singlefile = await import("single-file-core/single-file.js");
    singlefile.init({ fetch: singleFileFetch });

    const pageData = await singlefile.getPageData(
      {
        removeFrames: true,
        blockScripts: true,
        blockVideos: true,
        compressHTML: false,
        loadDeferredImages: true,
        loadDeferredImagesMaxIdleTime: 1200,
        filenameTemplate: "{page-title}",
        infobarContent: "",
        includeInfobar: false,
        removeHiddenElements: true,
        removeUnusedStyles: true,
        removeUnusedFonts: true,
        removeSavedDate: true,
        compressCSS: true,
        loadDeferredImagesKeepZoomLevel: false,
        loadDeferredImagesDispatchScrollEvent: true,
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
      },
      { fetch: singleFileFetch }
    );

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

// ─── YouTube Extraction ─────────────────────────────────────────────────────────

function extractYouTube(): PageCapture {
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

// ─── Content Script Entry ───────────────────────────────────────────────────────

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

    // Listen for page-context fetch responses (from MAIN world script)
    document.addEventListener("singlefile-response-fetch", (event: Event) => {
      const customEvent = event as CustomEvent;
      try {
        const detail = JSON.parse(customEvent.detail);
        const pending = pendingPageFetches.get(detail.requestId);
        if (!pending) return;

        pendingPageFetches.delete(detail.requestId);

        if (detail.error) {
          pending.reject(new Error(detail.error));
          return;
        }

        pending.resolve({
          status: detail.status,
          headers: {
            get: (name: string) => detail.headers?.[name.toLowerCase()] ?? null,
          },
          arrayBuffer: async () => new Uint8Array(detail.array).buffer,
        });
      } catch {
        // Ignore malformed events
      }
    });

    // Message handlers
    chrome.runtime.onMessage.addListener((request, _sender, sendResponse) => {
      if (request.action === "getPageMeta") {
        sendResponse(getPageMeta());
        return true;
      }

      if (request.action === "capturePageHTML") {
        const pageType = detectPageType(location.href);

        if (pageType === "html") {
          const timeout = new Promise<PageCapture>((_, reject) =>
            setTimeout(() => reject(new Error("extraction timeout")), 15000)
          );
          Promise.race([extractWebPageWithSingleFile(), timeout])
            .catch(() => ({
              type: "html" as const,
              url: location.href,
              title: document.title || location.href,
              html: document.documentElement.outerHTML,
            }))
            .then(sendResponse);
          return true;
        }

        sendResponse(extractYouTube());
        return true;
      }

      // Legacy fallback
      if (request.action === "getPageData") {
        const pageType = detectPageType(location.href);

        if (pageType === "html") {
          const timeout = new Promise<PageCapture>((_, reject) =>
            setTimeout(() => reject(new Error("extraction timeout")), 15000)
          );
          Promise.race([extractWebPageWithSingleFile(), timeout])
            .catch(() => ({
              type: "html" as const,
              url: location.href,
              title: document.title || location.href,
              html: document.documentElement.outerHTML,
            }))
            .then(sendResponse);
          return true;
        }

        sendResponse(extractYouTube());
        return true;
      }
      return true;
    });
  },
});
