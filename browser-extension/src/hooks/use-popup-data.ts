import { useEffect, useState } from "react";
import { fetchCollections, fetchTags } from "@/src/lib/api";
import type { CollectionInfo, PageMeta, TagNodeInfo } from "@/src/lib/types";
import { detectContentKind, contentKindToPageType } from "@/src/lib/translators";

interface PopupData {
  pageMeta: PageMeta | null;
  tabId: number | null;
  collections: CollectionInfo[];
  tags: TagNodeInfo[];
  loading: boolean;
  error: string | null;
}

export function usePopupData(): PopupData {
  const [pageMeta, setPageMeta] = useState<PageMeta | null>(null);
  const [tabId, setTabId] = useState<number | null>(null);
  const [collections, setCollections] = useState<CollectionInfo[]>([]);
  const [tags, setTags] = useState<TagNodeInfo[]>([]);
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
        const pdfCheck = await chrome.runtime.sendMessage({
          method: "isPDFTab",
          tabId: tab.id,
        });

        // Fetch collections/tags in parallel with page meta
        const pageMetaPromise = pdfCheck?.isPDF
          ? Promise.resolve({
              type: "pdf" as const,
              url: pdfCheck.url,
              title: tab.title?.replace(/\.pdf$/i, "") || null,
              favicon: null,
            })
          : Promise.race([
              chrome.tabs.sendMessage(tab.id, { action: "getPageMeta" }),
              new Promise((_resolve, reject) =>
                setTimeout(() => reject(new Error("timeout")), 3000)
              ),
            ]);

        const [collectionsResult, tagsResult, metaResult] =
          await Promise.allSettled([
            fetchCollections(),
            fetchTags(),
            pageMetaPromise,
          ]);

        // If both server calls failed, the app is not running
        if (
          collectionsResult.status === "rejected" &&
          tagsResult.status === "rejected"
        ) {
          setError("OakReader is not running.");
          setLoading(false);
          return;
        }

        if (collectionsResult.status === "fulfilled") {
          setCollections(collectionsResult.value);
        }

        if (tagsResult.status === "fulfilled") {
          setTags(tagsResult.value);
        }

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

  return { pageMeta, tabId, collections, tags, loading, error };
}
