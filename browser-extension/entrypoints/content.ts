import { Readability } from "@mozilla/readability";
import TurndownService from "turndown";
import { defineContentScript } from "wxt/utils/define-content-script";
import {
  getTranslator,
  detectContentKind,
  contentKindToPageType,
  extractLinkMetadata,
} from "@/src/lib/translators";
import type { TranslatorResult } from "@/src/lib/translators";

interface PageMeta {
  type: "html" | "embed" | "pdf";
  url: string;
  title: string | null;
  favicon: string | null;
  contentKind?: string;
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
  embedType?: string;
  biblio?: Record<string, unknown>;
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

// ─── Page Meta ──────────────────────────────────────────────────────────────────

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

  const kind = detectContentKind(location.href);
  return {
    type: contentKindToPageType(kind),
    url: location.href,
    title: document.title || null,
    favicon: getFavicon(),
    contentKind: kind,
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

async function captureWithSingleFile(): Promise<string> {
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

    return pageData.content as string;
  } catch (error) {
    console.warn("SingleFile capture failed, falling back to raw HTML:", error);
    return document.documentElement.outerHTML;
  }
}

// ─── Translator → Legacy Payload Bridge ─────────────────────────────────────────

function toLegacyPayload(result: TranslatorResult): PageCapture {
  switch (result.kind) {
    case "youtube":
      return {
        type: "embed",
        url: result.url,
        title: result.title,
        author: result.author,
        videoId: result.videoId,
        duration: result.duration,
        thumbnailURL: result.thumbnailURL,
        transcript: result.transcript,
      };

    case "twitter":
      return {
        type: "embed",
        url: result.url,
        title: result.title,
        author: result.author,
        description: result.description,
        thumbnailURL: result.thumbnailURL,
        embedType: "twitter",
      };

    case "link":
      return {
        type: "embed",
        url: result.url,
        title: result.title,
        author: result.author,
        description: result.description,
        thumbnailURL: result.thumbnailURL,
        embedType: "link",
      };

    case "scholarly":
      return {
        type: "html",
        url: result.url,
        title: result.title,
        author: result.author,
        description: result.description,
        thumbnailURL: result.thumbnailURL,
        html: result.html,
        markdown: result.markdown,
        biblio: result.biblio as unknown as Record<string, unknown>,
      };

    case "webpage":
    default:
      return {
        type: "html",
        url: result.url,
        title: result.title,
        author: result.author,
        description: result.description,
        thumbnailURL: result.thumbnailURL,
        html: result.html,
        markdown: result.markdown,
      };
  }
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
        const result = extractLinkMetadata(document, location.href);
        sendResponse(toLegacyPayload(result));
        return true;
      }

      if (request.action === "capturePageHTML" || request.action === "getPageData") {
        const translator = getTranslator(location.href);

        if (translator.contentKind === "webpage" || translator.contentKind === "scholarly") {
          // HTML-based pages: extract markdown first, then SingleFile capture, then translator metadata
          const timeout = new Promise<PageCapture>((_, reject) =>
            setTimeout(() => reject(new Error("extraction timeout")), 15000)
          );

          const capturePromise = (async (): Promise<PageCapture> => {
            const markdown = extractMarkdown();
            const html = await captureWithSingleFile();
            const result = await translator.extract(document, location.href);
            return toLegacyPayload({ ...result, html, markdown });
          })();

          Promise.race([capturePromise, timeout])
            .catch(() => ({
              type: "html" as const,
              url: location.href,
              title: document.title || location.href,
              html: document.documentElement.outerHTML,
            }))
            .then(sendResponse);
          return true;
        }

        // Embed types (YouTube, Twitter): no SingleFile needed
        translator.extract(document, location.href)
          .then((result) => sendResponse(toLegacyPayload(result)));
        return true;
      }

      // Don't return true for unhandled messages (e.g. singlefile.fetchResponse) —
      // returning true holds the sendResponse port open, which causes
      // chrome.tabs.sendMessage in the background to hang indefinitely.
    });
  },
});
