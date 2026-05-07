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
        sendResponse(toLegacyPayload(result));
        return true;
      }

      if (request.action === "extractMarkdown") {
        try {
          const result = new Defuddle(document).parse();
          const markdown = createMarkdownContent(result.content);
          sendResponse({ markdown });
        } catch {
          sendResponse({ markdown: null });
        }
        return true;
      }
    });
  },
});
