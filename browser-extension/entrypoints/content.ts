import { defineContentScript } from "wxt/utils/define-content-script";
import Defuddle, { createMarkdownContent } from "defuddle/full";
import {
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
  author?: string | null;
  videoId?: string | null;
  duration?: number | null;
  thumbnailURL?: string | null;
  transcript?: string | null;
  description?: string | null;
  embedType?: string;
  biblio?: Record<string, unknown>;
  markdown?: string | null;
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

/** Instant lightweight metadata — no heavy processing. */
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
      };
  }
}

// ─── Content Script Entry ───────────────────────────────────────────────────────

export default defineContentScript({
  matches: ["<all_urls>"],
  runAt: "document_idle",

  main() {
    chrome.runtime.onMessage.addListener((request, _sender, sendResponse) => {
      if (request.action === "getPageMeta") {
        sendResponse(getPageMeta());
        return true;
      }

      if (request.action === "extractLinkMeta") {
        const result = extractLinkMetadata(document, location.href);
        const payload = toLegacyPayload(result);

        // Extract article markdown for AI chat context
        try {
          const defuddled = new Defuddle(document).parse();
          const markdown = createMarkdownContent(defuddled.content, location.href);
          if (markdown) payload.markdown = markdown;
        } catch {
          // Best effort — link save still works without markdown
        }

        sendResponse(payload);
        return true;
      }

      if (request.action === "extractMarkdown") {
        try {
          const result = new Defuddle(document).parse();
          const markdown = createMarkdownContent(result.content, location.href);
          sendResponse({ markdown });
        } catch {
          sendResponse({ markdown: null });
        }
        return true;
      }

      if (request.action === "captureHTML") {
        captureHTML(request.options)
          .then(sendResponse)
          .catch((err) =>
            sendResponse({ html: null, error: err instanceof Error ? err.message : String(err) })
          );
        return true;
      }
    });
  },
});

// ─── SingleFile HTML Capture ────────────────────────────────────────────────────

async function captureHTML(
  options: Record<string, unknown>
): Promise<{ html: string | null; error?: string }> {
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const singlefile = (globalThis as any).singlefile;
    if (!singlefile) {
      return { html: null, error: "SingleFile not loaded" };
    }

    // Fetch proxy: try direct fetch first, fallback to background for cross-origin
    const fetchResource = async (
      url: string,
      fetchOptions?: { referrer?: string; headers?: Record<string, string> }
    ) => {
      try {
        return await globalThis.fetch(url, {
          referrer: fetchOptions?.referrer,
          headers: fetchOptions?.headers,
        });
      } catch {
        // Cross-origin: proxy through background service worker
        const result = await chrome.runtime.sendMessage({
          method: "singlefile.fetch",
          url,
          referrer: fetchOptions?.referrer,
          headers: fetchOptions?.headers,
        });
        if (result.error) throw new Error(result.error);
        return {
          status: result.status,
          headers: { get: (name: string) => result.headers?.[name] ?? null },
          arrayBuffer: async () => new Uint8Array(result.array).buffer,
        };
      }
    };

    // Progress reporting — relay SingleFile's internal progress to the popup
    let resourceIndex = 0;
    let resourceMax = 0;

    options.onprogress = async (event: {
      type: string;
      detail?: { step?: number; max?: number; url?: string };
      PAGE_LOADING: string;
      PAGE_LOADED: string;
      RESOURCES_INITIALIZED: string;
      RESOURCE_LOADED: string;
      STAGE_STARTED: string;
      STAGE_ENDED: string;
      PAGE_ENDED: string;
    }) => {
      if (event.type === event.RESOURCES_INITIALIZED) {
        resourceMax = event.detail?.max ?? 0;
      }
      if (event.type === event.RESOURCE_LOADED) {
        resourceIndex++;
      }
      chrome.runtime.sendMessage({
        method: "singlefile.progress",
        eventType: event.type,
        step: event.detail?.step,
        resourceIndex,
        resourceMax,
      }).catch(() => {});
    };

    if (typeof singlefile.getPageData !== "function") {
      return { html: null, error: `SingleFile loaded but getPageData missing. Keys: ${Object.keys(singlefile).join(", ")}` };
    }

    // Timeout: getPageData can hang if frame communication or deferred images stall
    const CAPTURE_TIMEOUT = 30000;
    const pageData = await Promise.race([
      singlefile.getPageData(options, { fetch: fetchResource }),
      new Promise<never>((_, reject) =>
        AbortSignal.timeout(CAPTURE_TIMEOUT).addEventListener("abort", (e) =>
          reject((e.target as AbortSignal).reason)
        )
      ),
    ]);

    if (!pageData) {
      return { html: null, error: "getPageData returned null/undefined" };
    }
    if (!pageData.content) {
      return { html: null, error: `getPageData returned empty content. Keys: ${Object.keys(pageData).join(", ")}` };
    }
    return { html: pageData.content };
  } catch (err) {
    return { html: null, error: err instanceof Error ? err.message : String(err) };
  }
}
