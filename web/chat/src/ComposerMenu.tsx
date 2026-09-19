import { useEffect, useRef } from "react";
import clsx from "clsx";
import type { CompletionItem, ModelOption } from "./bridge";

/**
 * The popup that `/`, `@` and `/model` open above the composer.
 *
 * Trigger detection is t3code's `detectComposerTrigger` (vendored); this is
 * only the list. Keyboard ownership matters: while the menu is open the
 * composer must not treat Enter as "send" or the arrows as caret movement,
 * so the composer asks the menu first and the menu reports whether it
 * consumed the key.
 */

export interface MenuRow {
  id: string;
  label: string;
  detail?: string;
  insert: string;
}

export const modelRows = (options: ModelOption[]): MenuRow[] =>
  options.map((o) => ({
    id: `${o.providerId}/${o.modelId}`,
    label: o.modelName,
    detail: o.providerName,
    insert: "",
  }));

export const completionRows = (items: CompletionItem[]): MenuRow[] =>
  items.map((i) => ({ id: i.id, label: i.label, detail: i.detail, insert: i.insert ?? i.label }));

export function ComposerMenu({
  title,
  rows,
  activeIndex,
  onPick,
  onHover,
}: {
  title: string;
  rows: MenuRow[];
  activeIndex: number;
  onPick: (row: MenuRow) => void;
  onHover: (index: number) => void;
}) {
  const listRef = useRef<HTMLDivElement>(null);

  // Keep the highlighted row visible when arrowing past the fold.
  useEffect(() => {
    const el = listRef.current?.children[activeIndex] as HTMLElement | undefined;
    el?.scrollIntoView({ block: "nearest" });
  }, [activeIndex]);

  if (rows.length === 0) return null;

  return (
    <div className="mb-1.5 overflow-hidden rounded-xl border border-border bg-card shadow-lg">
      <div className="border-b border-border px-2.5 py-1.5 text-[11px] font-medium text-secondary-label">
        {title}
      </div>
      <div ref={listRef} className="max-h-56 overflow-y-auto py-1">
        {rows.map((row, i) => (
          <button
            key={row.id}
            type="button"
            // Pointer-down would blur the textarea and close the menu before
            // the click lands, so commit on mousedown and keep focus.
            onMouseDown={(e) => {
              e.preventDefault();
              onPick(row);
            }}
            onMouseEnter={() => onHover(i)}
            className={clsx(
              "flex w-full items-baseline gap-2 px-2.5 py-1 text-left text-[13px] transition-colors",
              i === activeIndex ? "bg-accent/40" : "hover:bg-accent/20",
            )}
          >
            <span className="truncate">{row.label}</span>
            {row.detail && (
              <span className="ml-auto shrink-0 truncate text-[11px] text-secondary-label">{row.detail}</span>
            )}
          </button>
        ))}
      </div>
    </div>
  );
}

/** Arrow/Enter/Tab/Escape handling shared by every menu kind. */
export function menuKeyAction(key: string): "up" | "down" | "commit" | "dismiss" | null {
  switch (key) {
    case "ArrowUp":
      return "up";
    case "ArrowDown":
      return "down";
    case "Enter":
    case "Tab":
      return "commit";
    case "Escape":
      return "dismiss";
    default:
      return null;
  }
}
