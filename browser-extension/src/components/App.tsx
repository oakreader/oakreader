import { useCallback, useEffect, useState } from "react";
import { usePopupData } from "@/src/hooks/use-popup-data";
import { postSnapshot } from "@/src/lib/api";
import type { PageCapture, PDFSavePayload } from "@/src/lib/types";
import { PageCard } from "./PageCard";
import { CollectionPicker } from "./CollectionPicker";
import { TagInput } from "./TagInput";
import { SaveButton, type SaveState } from "./SaveButton";
import { Button } from "./ui/button";

type SaveMode = "pdf" | "html" | "link";

interface CaptureProgress {
  deferredImages: "loading" | "done" | null;
  resources: { loaded: number; total: number } | null;
  steps: Array<"loading" | "done">;
}

export function App() {
  const { pageMeta, tabId, collections, tags, loading, error } = usePopupData();
  const [collectionId, setCollectionId] = useState("__all__");
  const [selectedTagIds, setSelectedTagIds] = useState<Set<string>>(new Set());
  const [newTags, setNewTags] = useState<string[]>([]);
  const [saveState, setSaveState] = useState<SaveState>("idle");
  const [errorMessage, setErrorMessage] = useState("");
  const [saveMode, setSaveMode] = useState<SaveMode>("html");
  const [captureProgress, setCaptureProgress] = useState<CaptureProgress | null>(null);

  // Listen for SingleFile progress events from the content script
  useEffect(() => {
    const listener = (message: Record<string, unknown>) => {
      if (message.method !== "singlefile.progress") return;

      setCaptureProgress((prev) => {
        const next: CaptureProgress = prev
          ? { ...prev, steps: [...prev.steps] }
          : { deferredImages: null, resources: null, steps: [] };

        const eventType = message.eventType as string;
        const step = message.step as number | undefined;

        if (eventType === "page-loading") {
          next.deferredImages = "loading";
        } else if (eventType === "page-loaded") {
          next.deferredImages = "done";
        } else if (eventType === "resources-initialized") {
          next.resources = { loaded: 0, total: message.resourceMax as number };
        } else if (eventType === "resource-loaded") {
          next.resources = {
            loaded: message.resourceIndex as number,
            total: message.resourceMax as number,
          };
        } else if (eventType === "stage-started" && step !== undefined && step < 3) {
          next.steps[step] = "loading";
        } else if (eventType === "stage-ended" && step !== undefined && step < 3) {
          next.steps[step] = "done";
        }

        return next;
      });
    };

    chrome.runtime.onMessage.addListener(listener);
    return () => chrome.runtime.onMessage.removeListener(listener);
  }, []);

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
        // "Save as Link" mode: extract lightweight metadata only
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
      } else if (saveMode === "html" && pageMeta.type === "html") {
        // HTML save mode: background captures full page via SingleFile and POSTs directly to server
        setCaptureProgress(null);
        setSaveState("capturing");

        const bgResult = await chrome.runtime.sendMessage({
          method: "captureAndSaveHTML",
          tabId,
          payload: {
            url: pageMeta.url,
            title: pageMeta.title,
            collectionId: selectedCollection,
            tagOptionIds: Array.from(selectedTagIds),
            newTags,
          },
        }) as { status: string; message?: string } | undefined;

        if (!bgResult || bgResult.status === "error") {
          throw new Error(bgResult?.message || "Failed to capture HTML");
        }

        // Background already saved — skip postSnapshot below
        setSaveState("saved");
        setTimeout(() => window.close(), 2500);
        return;
      } else if (saveMode === "pdf" && pageMeta.type === "html") {
        // PDF save mode: background generates PDF via debugger and POSTs directly to server
        setSaveState("capturing");

        const bgResult = await chrome.runtime.sendMessage({
          method: "captureAndSavePDF",
          tabId,
          payload: {
            url: pageMeta.url,
            title: pageMeta.title,
            collectionId: selectedCollection,
            tagOptionIds: Array.from(selectedTagIds),
            newTags,
          },
        }) as { status: string; message?: string } | undefined;

        if (!bgResult || bgResult.status === "error") {
          throw new Error(bgResult?.message || "Failed to generate PDF");
        }

        // Background already saved — skip postSnapshot below
        setSaveState("saved");
        setTimeout(() => window.close(), 2500);
        return;
      } else {
        // Embed types (YouTube, Twitter, etc.): extract metadata via content script
        setSaveState("capturing");

        try {
          payload = await Promise.race([
            chrome.tabs.sendMessage(tabId, { action: "extractLinkMeta" }),
            new Promise((_resolve, reject) =>
              setTimeout(() => reject(new Error("Capture timed out")), 10000)
            ),
          ]) as PageCapture;
        } catch {
          payload = {
            type: "embed",
            url: pageMeta.url,
            title: pageMeta.title,
            embedType: "link",
          };
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
              variant={saveMode === "html" ? "secondary" : "ghost"}
              size="xs"
              className="flex-1"
              onClick={() => setSaveMode("html")}
            >
              HTML
            </Button>
            <Button
              variant={saveMode === "pdf" ? "secondary" : "ghost"}
              size="xs"
              className="flex-1"
              onClick={() => setSaveMode("pdf")}
            >
              PDF
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

      <div className="shrink-0 px-3 pt-2 pb-3 space-y-2">
        {saveState === "capturing" && saveMode === "html" && captureProgress && (
          <CaptureProgressSteps progress={captureProgress} />
        )}
        <SaveButton
          state={saveState}
          label={`Saving to ${collectionName}\u2026`}
          capturingLabel={
            saveMode === "pdf"
              ? "Generating PDF\u2026"
              : saveMode === "html"
                ? "Capturing page\u2026"
                : undefined
          }
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

function CaptureProgressSteps({ progress }: { progress: CaptureProgress }) {
  const resourcesDone =
    progress.resources !== null &&
    progress.resources.total > 0 &&
    progress.resources.loaded >= progress.resources.total;

  return (
    <div
      className="rounded-lg bg-grouped px-3 py-2 text-[11px] space-y-0.5"
      style={{ boxShadow: "0 0 0 0.5px rgba(0,0,0,0.06)" }}
    >
      {progress.deferredImages && (
        <ProgressRow label="Deferred images" done={progress.deferredImages === "done"} />
      )}
      {progress.resources && (
        <ProgressRow label="Frame contents" done={resourcesDone} />
      )}
      {progress.steps.map((status, i) => (
        <ProgressRow key={i} label={`Step ${i + 1} / 3`} done={status === "done"} />
      ))}
    </div>
  );
}

function ProgressRow({ label, done }: { label: string; done: boolean }) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-secondary">{label}</span>
      <span className={done ? "text-success font-medium" : "text-tertiary"}>
        {done ? "\u2713" : "\u2026"}
      </span>
    </div>
  );
}
