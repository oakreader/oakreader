import { useCallback, useEffect, useState } from "react";
import { Archive, CheckCircle2, FileText, Link2, Sparkles } from "lucide-react";
import { usePopupData } from "@/src/hooks/use-popup-data";
import { postSnapshot } from "@/src/lib/api";
import type { PageCapture, PDFSavePayload } from "@/src/lib/types";
import { PageCard } from "./PageCard";
import { CollectionPicker } from "./CollectionPicker";
import { TagInput } from "./TagInput";
import { SaveButton, type SaveState } from "./SaveButton";

type SaveMode = "pdf" | "html" | "link";

const SAVE_MODE_OPTIONS: Array<{
  mode: SaveMode;
  title: string;
  description: string;
}> = [
  { mode: "html", title: "Archive", description: "Full page" },
  { mode: "pdf", title: "PDF", description: "Printable" },
  { mode: "link", title: "Link", description: "Fast save" },
];

const OAKREADER_DEEP_LINK = "oakreader://open";

function openOakReaderApp() {
  try {
    chrome.tabs.create({ url: OAKREADER_DEEP_LINK });
  } catch {
    window.open(OAKREADER_DEEP_LINK, "_blank", "noopener,noreferrer");
  }
}

interface CaptureProgress {
  deferredImages: "loading" | "done" | null;
  resources: { loaded: number; total: number } | null;
  steps: Array<"loading" | "done">;
}

export function App() {
  const { pageMeta, tabId, collections, tags, initialCollectionId, loading, error } = usePopupData();
  const [collectionId, setCollectionId] = useState("__all__");

  // Initialize collectionId from resolved initial value once data loads
  useEffect(() => {
    if (!loading) {
      setCollectionId(initialCollectionId);
    }
  }, [loading, initialCollectionId]);

  // Persist collection changes to chrome.storage.local
  const handleCollectionChange = useCallback((id: string) => {
    setCollectionId(id);
    try {
      chrome.storage.local.set({ selectedCollectionId: id });
    } catch {
      // storage not available — ignore
    }
  }, []);
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
    return <LoadingState />;
  }

  if (error && !pageMeta) {
    const isNotRunning = error.includes("not running");
    return (
      <div className="flex-1 flex flex-col items-center justify-center p-5 text-center">
        <div className="oak-glass-card w-full px-5 py-7 space-y-3">
          {isNotRunning ? (
            <img src="/oakreader-logo.svg" alt="OakReader" className="mx-auto size-16 drop-shadow-sm" />
          ) : (
            <p className="text-[38px]">{"\u26A0\uFE0F"}</p>
          )}
          <p className="text-[16px] font-semibold text-foreground tracking-[-0.02em]">
            {isNotRunning ? "OakReader is not running" : "Cannot access page"}
          </p>
          <p className="text-[13px] text-secondary leading-relaxed">
            {isNotRunning
              ? "Open the Mac app, then come back here to save this page."
              : error}
          </p>
          {isNotRunning && (
            <button
              type="button"
              className="oak-primary-button mx-auto mt-1 inline-flex h-10 items-center justify-center px-5 text-[13px] font-semibold text-primary-foreground transition-all duration-200 hover:brightness-110 active:scale-[0.985]"
              onClick={openOakReaderApp}
            >
              Open OakReader
            </button>
          )}
        </div>
      </div>
    );
  }

  return (
    <>
      <Header />
      <div className="flex-1 min-h-0 overflow-y-auto px-4 pb-2 space-y-3">
        {pageMeta && <PageCard pageMeta={pageMeta} />}

        {pageMeta?.type === "html" && (
          <SaveModePicker value={saveMode} onChange={setSaveMode} />
        )}

        <CollectionPicker
          collections={collections}
          value={collectionId}
          onChange={handleCollectionChange}
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

      <div className="shrink-0 px-4 pt-2 pb-4 space-y-2 oak-sticky-footer">
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
    <div className="px-4 pt-4 pb-3">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2.5">
          <div className="relative flex size-9 items-center justify-center rounded-2xl bg-grouped shadow-[var(--shadow-card)] ring-1 ring-white/80">
            <img src="/oakreader-logo.svg" alt="" className="size-5" />
            <span className="absolute -right-0.5 -top-0.5 size-2.5 rounded-full bg-success ring-2 ring-background" />
          </div>
          <div>
            <p className="text-[15px] font-semibold leading-tight text-foreground tracking-[-0.02em]">OakReader</p>
            <p className="text-[11px] leading-tight text-secondary">Clip into your reading library</p>
          </div>
        </div>
        <div className="inline-flex items-center gap-1 rounded-full bg-primary/8 px-2 py-1 text-[11px] font-medium text-primary">
          <Sparkles className="size-3" strokeWidth={2.4} />
          Ready
        </div>
      </div>
    </div>
  );
}

function SaveModePicker({
  value,
  onChange,
}: {
  value: SaveMode;
  onChange: (value: SaveMode) => void;
}) {
  return (
    <section className="space-y-1.5">
      <p className="text-[11px] font-semibold text-secondary">Capture style</p>
      <div className="grid grid-cols-3 gap-2">
        {SAVE_MODE_OPTIONS.map((option) => {
          const selected = option.mode === value;
          return (
            <button
              key={option.mode}
              type="button"
              className={`oak-mode-card ${selected ? "oak-mode-card-selected" : ""}`}
              onClick={() => onChange(option.mode)}
              aria-pressed={selected}
            >
              <span className="flex items-center justify-between">
                <ModeIcon mode={option.mode} />
                {selected && <CheckCircle2 className="size-3.5 text-primary" strokeWidth={2.4} />}
              </span>
              <span className="mt-2 block text-[12px] font-semibold text-foreground">{option.title}</span>
              <span className="mt-0.5 block text-[10.5px] text-secondary">{option.description}</span>
            </button>
          );
        })}
      </div>
    </section>
  );
}

function ModeIcon({ mode }: { mode: SaveMode }) {
  const className = "size-4 text-primary";
  if (mode === "html") return <Archive className={className} strokeWidth={2.2} />;
  if (mode === "pdf") return <FileText className={className} strokeWidth={2.2} />;
  return <Link2 className={className} strokeWidth={2.2} />;
}

function LoadingState() {
  return (
    <>
      <Header />
      <div className="flex-1 px-4 space-y-3">
        <div className="oak-glass-card p-3 space-y-3">
          <div className="flex items-start gap-3">
            <div className="size-10 rounded-xl bg-fill oak-shimmer" />
            <div className="flex-1 space-y-2 pt-1">
              <div className="h-3 rounded-full bg-fill oak-shimmer" />
              <div className="h-3 w-2/3 rounded-full bg-fill oak-shimmer" />
            </div>
          </div>
          <div className="grid grid-cols-3 gap-2">
            <div className="h-16 rounded-xl bg-fill oak-shimmer" />
            <div className="h-16 rounded-xl bg-fill oak-shimmer" />
            <div className="h-16 rounded-xl bg-fill oak-shimmer" />
          </div>
        </div>
      </div>
    </>
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
