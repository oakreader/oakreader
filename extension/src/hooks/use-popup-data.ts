import { useEffect, useState } from "react";
import type { PageMeta } from "@/src/lib/types";
import { detectContentKind, contentKindToPageType } from "@/src/lib/translators";
import { resolveServerBase } from "@/src/lib/server";

interface PopupData {
  pageMeta: PageMeta | null;
  tabId: number | null;
  appRunning: boolean;
  /** Base URL of the app that answered, carried through the save so it cannot change mid-capture. */
  serverBase: string | null;
  loading: boolean;
  error: string | null;
}

/** Race a promise against AbortSignal.timeout. */
function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  const signal = AbortSignal.timeout(ms);
  return Promise.race([
    promise,
    new Promise<never>((_, reject) => {
      signal.addEventListener("abort", () => reject(signal.reason), { once: true });
    }),
  ]);
}

export function usePopupData(): PopupData {
  const [pageMeta, setPageMeta] = useState<PageMeta | null>(null);
  const [tabId, setTabId] = useState<number | null>(null);
  const [appRunning, setAppRunning] = useState(true);
  const [serverBase, setServerBase] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    async function load() {
      try {
        const [tab] = await chrome.tabs.query({
          active: true,
          currentWindow: true,
        });

        if (!tab?.id) {
          setError("Cannot access this page.");
          setLoading(false);
          return;
        }

        setTabId(tab.id);

        // Check if this tab is a PDF (detected via webRequest in background)
        let pdfCheck: { isPDF: boolean; url?: string } | undefined;
        try {
          pdfCheck = await withTimeout(
            chrome.runtime.sendMessage({ method: "isPDFTab", tabId: tab.id }),
            2000
          );
        } catch {
          pdfCheck = { isPDF: false };
        }

        // Find a running app: release port first, then the dev build's port.
        const pingPromise = resolveServerBase();

        const pageMetaPromise = pdfCheck?.isPDF
          ? Promise.resolve({
              type: "pdf" as const,
              url: pdfCheck.url!,
              title: tab.title?.replace(/\.pdf$/i, "") || null,
              favicon: null,
            })
          : Promise.race([
              chrome.tabs.sendMessage(tab.id, { action: "getPageMeta" }),
              new Promise((_resolve, reject) =>
                setTimeout(() => reject(new Error("timeout")), 3000)
              ),
            ]);

        const [pingResult, metaResult] = await Promise.allSettled([
          pingPromise,
          pageMetaPromise,
        ]);

        // No port answered → the app is not running
        const base = pingResult.status === "fulfilled" ? pingResult.value : null;
        if (!base) {
          setAppRunning(false);
          setError("OakReader is not running.");
          setLoading(false);
          return;
        }
        setServerBase(base);

        if (metaResult.status === "fulfilled" && metaResult.value) {
          setPageMeta(metaResult.value as PageMeta);
        } else {
          // Fallback: construct meta from tab info with URL-based type detection
          const tabUrl = tab.url || "";
          const kind = detectContentKind(tabUrl);
          setPageMeta({
            type: contentKindToPageType(kind),
            url: tabUrl,
            title: tab.title || null,
            favicon: tab.favIconUrl || null,
            contentKind: kind,
          });
        }
      } catch {
        setError("Cannot access this page. Try a regular web page.");
      } finally {
        setLoading(false);
      }
    }

    load();
  }, []);

  return { pageMeta, tabId, appRunning, serverBase, loading, error };
}
