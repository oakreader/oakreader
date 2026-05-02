/**
 * Page-context hooks — runs in the page's MAIN WORLD.
 * Injected at document_start so IntersectionObserver is hooked before page JS runs.
 *
 * Provides:
 * 1. Fetch proxy — executes fetch from page's origin (with cookies, correct CORS)
 * 2. Lazy image trigger — hooks IntersectionObserver to mark all elements visible
 * 3. Adopted stylesheet capture — hooks CSSStyleSheet.replace/replaceSync
 */
import { defineContentScript } from "wxt/utils/define-content-script";

export default defineContentScript({
  matches: ["<all_urls>"],
  runAt: "document_start",
  world: "MAIN",

  main() {
    // ─── 1. Fetch Proxy ─────────────────────────────────────────────────────────
    // Content script (isolated world) dispatches "singlefile-request-fetch"
    // We execute fetch from page origin and respond with "singlefile-response-fetch"

    document.addEventListener("singlefile-request-fetch", async (event: Event) => {
      const customEvent = event as CustomEvent;
      let detail: { url: string; requestId: number; options: Record<string, unknown> };
      try {
        detail = JSON.parse(customEvent.detail);
      } catch {
        return;
      }

      const { url, requestId, options } = detail;

      try {
        const fetchOptions: RequestInit = {
          cache: (options.cache as RequestCache) || "force-cache",
          credentials: "same-origin",
          referrerPolicy:
            (options.referrerPolicy as ReferrerPolicy) ||
            "strict-origin-when-cross-origin",
        };

        if (options.headers) {
          fetchOptions.headers = options.headers as HeadersInit;
        }

        const response = await fetch(url, fetchOptions);

        if (
          response.status === 401 ||
          response.status === 403 ||
          response.status === 404
        ) {
          throw new Error(`HTTP ${response.status}`);
        }

        const buffer = await response.arrayBuffer();
        const array = Array.from(new Uint8Array(buffer));
        const headers: Record<string, string> = {};
        response.headers.forEach((value, key) => {
          headers[key] = value;
        });

        document.dispatchEvent(
          new CustomEvent("singlefile-response-fetch", {
            detail: JSON.stringify({
              requestId,
              status: response.status,
              headers,
              array,
            }),
          })
        );
      } catch (error: unknown) {
        document.dispatchEvent(
          new CustomEvent("singlefile-response-fetch", {
            detail: JSON.stringify({
              requestId,
              error: error instanceof Error ? error.message : String(error),
            }),
          })
        );
      }
    });

    // ─── 2. Lazy Image Loading Hooks ────────────────────────────────────────────
    // Override IntersectionObserver so all observed elements appear "visible".
    // This forces lazy-loaded images to load their src/srcset.

    const OriginalIntersectionObserver = window.IntersectionObserver;
    if (OriginalIntersectionObserver) {
      const PatchedObserver = function (
        this: IntersectionObserver,
        callback: IntersectionObserverCallback,
        options?: IntersectionObserverInit
      ) {
        const wrappedCallback: IntersectionObserverCallback = (entries, obs) => {
          const faked = entries.map((entry) => {
            if (!entry.isIntersecting) {
              // Create a fake entry that reports as intersecting
              return {
                target: entry.target,
                isIntersecting: true,
                intersectionRatio: 1,
                boundingClientRect: entry.boundingClientRect,
                intersectionRect: entry.boundingClientRect,
                rootBounds: entry.rootBounds,
                time: entry.time,
              } as unknown as IntersectionObserverEntry;
            }
            return entry;
          });
          callback(faked, obs);
        };
        return new OriginalIntersectionObserver(wrappedCallback, options);
      } as unknown as typeof IntersectionObserver;

      PatchedObserver.prototype = OriginalIntersectionObserver.prototype;
      Object.defineProperty(PatchedObserver, "name", { value: "IntersectionObserver" });
      (window as unknown as Record<string, unknown>).IntersectionObserver = PatchedObserver;
    }

    // ─── 3. Adopted Stylesheets Capture ─────────────────────────────────────────
    // Track dynamically created stylesheets (CSS-in-JS frameworks)

    const adoptedSheets: string[] = [];
    const originalReplaceSync = CSSStyleSheet.prototype.replaceSync;
    const originalReplace = CSSStyleSheet.prototype.replace;

    CSSStyleSheet.prototype.replaceSync = function (text: string) {
      adoptedSheets.push(text);
      return originalReplaceSync.call(this, text);
    };

    CSSStyleSheet.prototype.replace = function (text: string) {
      adoptedSheets.push(text);
      return originalReplace.call(this, text);
    };

    // Expose adopted sheets for content script to query
    document.addEventListener("singlefile-get-adopted-sheets", () => {
      document.dispatchEvent(
        new CustomEvent("singlefile-adopted-sheets-response", {
          detail: JSON.stringify(adoptedSheets),
        })
      );
    });
  },
});
