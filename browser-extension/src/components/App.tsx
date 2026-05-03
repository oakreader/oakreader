import { useCallback, useState } from "react";
import { usePopupData } from "@/src/hooks/use-popup-data";
import { postSnapshot } from "@/src/lib/api";
import type { PageCapture, PDFSavePayload } from "@/src/lib/types";
import { PageCard } from "./PageCard";
import { CollectionPicker } from "./CollectionPicker";
import { TagInput } from "./TagInput";
import { SaveButton, type SaveState } from "./SaveButton";

export function App() {
  const { pageMeta, tabId, collections, tags, loading, error } = usePopupData();
  const [collectionId, setCollectionId] = useState("__all__");
  const [selectedTagIds, setSelectedTagIds] = useState<Set<string>>(new Set());
  const [newTags, setNewTags] = useState<string[]>([]);
  const [saveState, setSaveState] = useState<SaveState>("idle");
  const [errorMessage, setErrorMessage] = useState("");

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
      } else {
        // HTML / embed: capture page content first
        setSaveState("capturing");

        payload = await Promise.race([
          chrome.tabs.sendMessage(tabId, { action: "capturePageHTML" }),
          new Promise((_resolve, reject) =>
            setTimeout(() => reject(new Error("Capture timed out")), 15000)
          ),
        ]) as PageCapture;

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
  }, [pageMeta, tabId, collectionId, collections, selectedTagIds, newTags]);

  if (loading) {
    return (
      <div className="py-12 text-center text-[12px] text-secondary">
        Loading&hellip;
      </div>
    );
  }

  if (error && !pageMeta) {
    return (
      <>
        <Header />
        <div className="px-3 py-8 text-center text-[12px] text-destructive">
          {error}
        </div>
      </>
    );
  }

  return (
    <>
      <Header />
      <div className="px-3 pb-3 space-y-3">
        {pageMeta && <PageCard pageMeta={pageMeta} />}

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
