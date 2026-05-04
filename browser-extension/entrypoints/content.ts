import { Readability } from "@mozilla/readability";
import TurndownService from "turndown";
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
  markdown?: string | null;
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

function isTwitterURL(url: string): boolean {
  try {
    const u = new URL(url);
    return (
      (u.hostname === "x.com" ||
        u.hostname === "www.x.com" ||
        u.hostname === "twitter.com" ||
        u.hostname === "www.twitter.com" ||
        u.hostname === "mobile.twitter.com") &&
      /^\/[^/]+\/status\/\d+/.test(u.pathname)
    );
  } catch {
    return false;
  }
}

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
  if (isTwitterURL(url)) {
    return "embed";
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

// ─── Combined Fetch (mirrors official SingleFile pattern for Chrome) ─────────────
//
// In Chrome, SingleFile uses the content script's isolation-world fetch() as the
// primary method — it has the extension's host_permissions so it can fetch any
// cross-origin resource. Page-context fetch (MAIN world events) is only primary
// in Firefox. Background fetch via messaging is the last resort.

async function singleFileFetch(
  url: string,
  options: Record<string, unknown> = {}
): Promise<{
  status: number;
  headers: { get(name: string): string | null };
  arrayBuffer(): Promise<ArrayBuffer>;
}> {
  const fetchOptions: RequestInit = {
    cache: (options.cache as RequestCache) || "force-cache",
    headers: options.headers as HeadersInit,
    referrerPolicy:
      (options.referrerPolicy as ReferrerPolicy) ||
      "strict-origin-when-cross-origin",
  };

  // Primary: content script's fetch (isolation world — has extension host_permissions)
  try {
    const response = await fetch(url, fetchOptions);
    // Retry with no-referrer on auth/not-found errors (matches SingleFile behavior)
    if (
      (response.status === 401 ||
        response.status === 403 ||
        response.status === 404) &&
      fetchOptions.referrerPolicy !== "no-referrer"
    ) {
      const retry = await fetch(url, {
        ...fetchOptions,
        referrerPolicy: "no-referrer",
      });
      return retry;
    }
    return response;
  } catch {
    // Fall through to page-context fetch
  }

  // Fallback: page-context fetch (MAIN world — has page's cookies for auth resources)
  try {
    return await pageContextFetch(url, options);
  } catch {
    // Fall through to background
  }

  // Last resort: background service worker fetch via messaging
  return backgroundFetch(url, options);
}

// ─── Markdown Extraction (Readability + Turndown) ───────────────────────────────

function extractMarkdown(): string | null {
  try {
    const clonedDoc = document.cloneNode(true) as Document;
    const article = new Readability(clonedDoc).parse();
    if (!article?.content) return null;
    return new TurndownService({
      headingStyle: "atx",
      codeBlockStyle: "fenced",
      bulletListMarker: "-",
    }).turndown(article.content);
  } catch {
    return null;
  }
}

// ─── SingleFile Capture ─────────────────────────────────────────────────────────

async function extractWebPageWithSingleFile(): Promise<PageCapture> {
  // Extract markdown BEFORE SingleFile (which mutates the DOM)
  const markdown = extractMarkdown();

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
        removeHiddenElements: false,
        removeUnusedStyles: false,
        removeUnusedFonts: true,
        removeSavedDate: true,
        compressCSS: true,
        loadDeferredImagesKeepZoomLevel: false,
        loadDeferredImagesDispatchScrollEvent: true,
        loadDeferredImagesBeforeFrames: false,
        backgroundSave: false,
        insertMetaCSP: false,
        insertMetaNoIndex: false,
        password: "",
        woleetKey: "",
        blockMixedContent: false,
        saveOriginalURLs: false,
        removeAlternativeFonts: false,
        removeAlternativeMedias: false,
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
      markdown,
    };
  } catch (error) {
    console.warn("SingleFile capture failed, falling back to raw HTML:", error);
    return {
      type: "html",
      url: location.href,
      title: document.title || location.href,
      html: document.documentElement.outerHTML,
      markdown,
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

// ─── Twitter/X Extraction ────────────────────────────────────────────────────

function extractTweet(): PageCapture {
  const url = new URL(location.href);
  const handle = url.pathname.split("/")[1] || "";

  // Author from og:title — format is typically "Author Name on X: ..."
  const ogTitle =
    document.querySelector<HTMLMetaElement>('meta[property="og:title"]')?.content ?? "";
  const authorName = ogTitle.includes(" on X:")
    ? ogTitle.split(" on X:")[0].trim()
    : ogTitle.includes(" on Twitter:")
      ? ogTitle.split(" on Twitter:")[0].trim()
      : handle;

  // Tweet text — prefer DOM (most reliable), fall back to meta tags
  const tweetTextEl = document.querySelector('[data-testid="tweetText"]');
  const description =
    tweetTextEl?.textContent?.trim() ||
    document.querySelector<HTMLMetaElement>('meta[property="og:description"]')?.content ||
    document.querySelector<HTMLMetaElement>('meta[name="description"]')?.content ||
    null;

  // Thumbnail
  const thumbnailURL =
    document.querySelector<HTMLMetaElement>('meta[property="og:image"]')?.content ?? null;

  const title = authorName || document.title || `@${handle} post`;

  return {
    type: "embed",
    url: location.href,
    title,
    author: `@${handle}`,
    description,
    thumbnailURL,
    embedType: "twitter",
  };
}

// ─── Generic Link Metadata Extraction ────────────────────────────────────────

function extractLinkMeta(): PageCapture {
  const title = document.title || location.href;
  const description =
    document.querySelector<HTMLMetaElement>('meta[name="description"]')?.content ??
    document.querySelector<HTMLMetaElement>('meta[property="og:description"]')?.content ??
    null;
  const thumbnailURL =
    document.querySelector<HTMLMetaElement>('meta[property="og:image"]')?.content ?? null;
  const author =
    document.querySelector<HTMLMetaElement>('meta[name="author"]')?.content ??
    document.querySelector<HTMLMetaElement>('meta[property="og:site_name"]')?.content ??
    null;

  return {
    type: "embed",
    url: location.href,
    title,
    author,
    description,
    thumbnailURL,
    embedType: "link",
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

      if (request.action === "extractLinkMeta") {
        sendResponse(extractLinkMeta());
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

        if (isTwitterURL(location.href)) {
          sendResponse(extractTweet());
        } else {
          sendResponse(extractYouTube());
        }
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

        if (isTwitterURL(location.href)) {
          sendResponse(extractTweet());
        } else {
          sendResponse(extractYouTube());
        }
        return true;
      }
      // Don't return true for unhandled messages (e.g. singlefile.fetchResponse) —
      // returning true holds the sendResponse port open, which causes
      // chrome.tabs.sendMessage in the background to hang indefinitely.
    });
  },
});
