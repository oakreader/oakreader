import { useCallback, useState } from "react";
import { usePopupData } from "@/src/hooks/use-popup-data";
import { postSnapshot } from "@/src/lib/api";
import type { PageCapture, PDFSavePayload } from "@/src/lib/types";
import { PageCard } from "./PageCard";
import { CollectionPicker } from "./CollectionPicker";
import { TagInput } from "./TagInput";
import { SaveButton, type SaveState } from "./SaveButton";
import { Button } from "./ui/button";

type SaveMode = "snapshot" | "link";

export function App() {
  const { pageMeta, tabId, collections, tags, loading, error } = usePopupData();
  const [collectionId, setCollectionId] = useState("__all__");
  const [selectedTagIds, setSelectedTagIds] = useState<Set<string>>(new Set());
  const [newTags, setNewTags] = useState<string[]>([]);
  const [saveState, setSaveState] = useState<SaveState>("idle");
  const [errorMessage, setErrorMessage] = useState("");
  const [saveMode, setSaveMode] = useState<SaveMode>("snapshot");

  const handleTagToggle = useCallback((id: string) => {
    setSelectedTagIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) {
        next.delete(id);
      } else {
        next.add(id);
      }
      return next;
    });
  }, []);

  const handleAddNewTag = useCallback((name: string) => {
    setNewTags((prev) => {
      if (prev.some((t) => t.toLowerCase() === name.toLowerCase())) return prev;
      return [...prev, name];
    });
  }, []);

  const handleRemoveNewTag = useCallback((name: string) => {
    setNewTags((prev) => prev.filter((t) => t !== name));
  }, []);

  const collectionName =
    collectionId === "__all__"
      ? "All Items"
      : collections.find((c) => c.id === collectionId)?.name || "All Items";

  const handleSave = useCallback(async () => {
    if (!pageMeta || tabId === null) return;

    setErrorMessage("");
    const selectedCollection = collectionId === "__all__" ? undefined : collectionId;

    try {
      let payload: PageCapture | PDFSavePayload;

      if (pageMeta.type === "pdf") {
        // PDF: skip page capture, get cookies and post URL directly
        setSaveState("saving");

        const cookieResult = await chrome.runtime.sendMessage({
          method: "getCookiesForURL",
          url: pageMeta.url,
        });

        payload = {
          type: "pdf",
          url: pageMeta.url,
          title: pageMeta.title,
          cookies: cookieResult?.cookies || undefined,
        };
      } else if (saveMode === "link" && pageMeta.type === "html") {
        // "Save as Link" mode: extract lightweight metadata only (no SingleFile)
        setSaveState("capturing");

        try {
          payload = await Promise.race([
            chrome.tabs.sendMessage(tabId, { action: "extractLinkMeta" }),
            new Promise((_resolve, reject) =>
              setTimeout(() => reject(new Error("Capture timed out")), 5000)
            ),
          ]) as PageCapture;
        } catch {
          // Fallback: construct link meta from tab info
          payload = {
            type: "embed",
            url: pageMeta.url,
            title: pageMeta.title,
            embedType: "link",
          };
        }

        setSaveState("saving");
      } else {
        // HTML / embed: capture page content first
        setSaveState("capturing");

        try {
          payload = await Promise.race([
            chrome.tabs.sendMessage(tabId, { action: "capturePageHTML" }),
            new Promise((_resolve, reject) =>
              setTimeout(() => reject(new Error("Capture timed out")), 15000)
            ),
          ]) as PageCapture;
        } catch {
          // Content script not loaded (tab opened before extension install/reload)
          // Fall back to injecting a capture function directly
          const [result] = await chrome.scripting.executeScript({
            target: { tabId },
            func: () => {
              const url = location.href;
              try {
                const u = new URL(url);
                if (
                  (u.hostname === "www.youtube.com" || u.hostname === "youtube.com") &&
                  u.pathname === "/watch" &&
                  u.searchParams.has("v")
                ) {
                  const videoId = u.searchParams.get("v");
                  return {
                    type: "embed" as const,
                    url,
                    title: document.title,
                    videoId,
                    thumbnailURL: videoId
                      ? `https://img.youtube.com/vi/${videoId}/maxresdefault.jpg`
                      : null,
                  };
                }
                // Twitter/X fallback
                if (
                  (u.hostname === "x.com" || u.hostname === "www.x.com" ||
                    u.hostname === "twitter.com" || u.hostname === "www.twitter.com" ||
                    u.hostname === "mobile.twitter.com") &&
                  /^\/[^/]+\/status\/\d+/.test(u.pathname)
                ) {
                  const handle = u.pathname.split("/")[1] || "";
                  return {
                    type: "embed" as const,
                    url,
                    title: document.title,
                    author: `@${handle}`,
                    description: document.querySelector<HTMLMetaElement>('meta[property="og:description"]')?.content ?? null,
                    thumbnailURL: document.querySelector<HTMLMetaElement>('meta[property="og:image"]')?.content ?? null,
                    embedType: "twitter" as const,
                  };
                }
              } catch { /* ignore */ }
              return {
                type: "html" as const,
                url,
                title: document.title || url,
                html: document.documentElement.outerHTML,
              };
            },
          });
          payload = result.result as PageCapture;
        }

        setSaveState("saving");
      }

      const result = await postSnapshot(
        payload,
        selectedCollection,
        Array.from(selectedTagIds),
        newTags
      );

      if (result.status === "ok") {
        setSaveState("saved");
        // Auto-close popup after success
        setTimeout(() => window.close(), 2500);
      } else {
        setSaveState("error");
        setErrorMessage(result.message || "Unknown error");
      }
    } catch (err: unknown) {
      setSaveState("error");
      const msg = err instanceof Error ? err.message : String(err);
      if (msg.includes("Failed to fetch") || msg.includes("NetworkError")) {
        setErrorMessage("OakReader is not running.");
      } else {
        setErrorMessage(msg);
      }
    }
  }, [pageMeta, tabId, collectionId, collections, selectedTagIds, newTags, saveMode]);

  if (loading) {
    return (
      <div className="py-12 text-center text-[12px] text-secondary">
        Loading&hellip;
      </div>
    );
  }

  if (error && !pageMeta) {
    const isNotRunning = error.includes("not running");
    return (
      <>
        <Header />
        <div className="px-3 py-8 text-center space-y-2">
          <p className="text-[20px]">{isNotRunning ? "\u{1F4D6}" : "\u26A0\uFE0F"}</p>
          <p className="text-[13px] font-semibold text-foreground">
            {isNotRunning ? "OakReader is not running" : "Cannot access page"}
          </p>
          <p className="text-[12px] text-secondary">
            {isNotRunning
              ? "Start the app to save pages."
              : error}
          </p>
        </div>
      </>
    );
  }

  return (
    <>
      <Header />
      <div className="flex-1 min-h-0 overflow-y-auto px-3 space-y-2">
        {pageMeta && <PageCard pageMeta={pageMeta} />}

        {pageMeta?.type === "html" && (
          <div className="flex items-center gap-1 rounded-[var(--radius-outer)] bg-grouped p-1"
               style={{ boxShadow: "0 0 0 0.5px rgba(0,0,0,0.06)" }}>
            <Button
              variant={saveMode === "snapshot" ? "secondary" : "ghost"}
              size="xs"
              className="flex-1"
              onClick={() => setSaveMode("snapshot")}
            >
              Snapshot
            </Button>
            <Button
              variant={saveMode === "link" ? "secondary" : "ghost"}
              size="xs"
              className="flex-1"
              onClick={() => setSaveMode("link")}
            >
              Link
            </Button>
          </div>
        )}

        <CollectionPicker
          collections={collections}
          value={collectionId}
          onChange={setCollectionId}
        />

        <TagInput
          tags={tags}
          selectedIds={selectedTagIds}
          newTags={newTags}
          onToggle={handleTagToggle}
          onAddNewTag={handleAddNewTag}
          onRemoveNewTag={handleRemoveNewTag}
        />
      </div>

      <div className="shrink-0 px-3 pt-2 pb-3">
        <SaveButton
          state={saveState}
          label={`Saving to ${collectionName}\u2026`}
          errorMessage={errorMessage}
          onClick={handleSave}
        />
      </div>
    </>
  );
}

function Header() {
  return (
    <div className="px-3 pt-3 pb-2">
      <span className="text-[13px] font-semibold text-secondary">OakReader</span>
    </div>
  );
}
