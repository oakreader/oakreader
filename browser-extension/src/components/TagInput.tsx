import { useState, useRef, useEffect, useMemo } from "react";
import { X, Plus } from "lucide-react";
import type { TagNodeInfo } from "@/src/lib/types";

/** Flat tag for the combobox — derived from hierarchical TagNodeInfo. */
interface FlatTag {
  id: string;
  name: string;       // leaf name (e.g., "AI")
  fullPath: string;   // full path (e.g., "Research/AI")
  colorHex?: string;
}

interface TagInputProps {
  tags: TagNodeInfo[];
  selectedIds: Set<string>;
  newTags: string[];
  onToggle: (id: string) => void;
  onAddNewTag: (name: string) => void;
  onRemoveNewTag: (name: string) => void;
}

/** Flatten hierarchical TagNodeInfo into selectable leaf tags. */
function flattenTags(nodes: TagNodeInfo[]): FlatTag[] {
  const result: FlatTag[] = [];
  function walk(list: TagNodeInfo[]) {
    for (const node of list) {
      if (node.isTag) {
        result.push({
          id: node.id,
          name: node.name,
          fullPath: node.fullPath,
        });
      }
      if (node.children) walk(node.children);
    }
  }
  walk(nodes);
  return result;
}

export function TagInput({
  tags,
  selectedIds,
  newTags,
  onToggle,
  onAddNewTag,
  onRemoveNewTag,
}: TagInputProps) {
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const flatTags = useMemo(() => flattenTags(tags), [tags]);

  const selectedTags = useMemo(
    () => flatTags.filter((t) => selectedIds.has(t.id)),
    [flatTags, selectedIds]
  );

  // Filter tags by query
  const filtered = useMemo(() => {
    if (!query.trim()) return flatTags;
    const q = query.toLowerCase();
    return flatTags.filter(
      (t) =>
        t.name.toLowerCase().includes(q) ||
        t.fullPath.toLowerCase().includes(q)
    );
  }, [flatTags, query]);

  // Check if query exactly matches an existing tag
  const exactMatch = useMemo(() => {
    if (!query.trim()) return true;
    const q = query.trim().toLowerCase();
    return flatTags.some(
      (t) => t.name.toLowerCase() === q || t.fullPath.toLowerCase() === q
    ) || newTags.some((t) => t.toLowerCase() === q);
  }, [flatTags, newTags, query]);

  // Close on outside click
  useEffect(() => {
    if (!open) return;
    function handleClick(e: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    document.addEventListener("mousedown", handleClick);
    return () => document.removeEventListener("mousedown", handleClick);
  }, [open]);

  const handleSelect = (tag: FlatTag) => {
    onToggle(tag.id);
    setQuery("");
    inputRef.current?.focus();
  };

  const handleCreateTag = () => {
    const trimmed = query.trim();
    if (!trimmed) return;
    onAddNewTag(trimmed);
    setQuery("");
    inputRef.current?.focus();
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && query.trim()) {
      e.preventDefault();
      // If there's one filtered result and it's unselected, toggle it
      if (filtered.length === 1 && !selectedIds.has(filtered[0].id)) {
        handleSelect(filtered[0]);
      } else if (!exactMatch) {
        handleCreateTag();
      }
    }
    if (e.key === "Backspace" && !query) {
      // Remove last selected tag or new tag
      if (newTags.length > 0) {
        onRemoveNewTag(newTags[newTags.length - 1]);
      } else if (selectedTags.length > 0) {
        onToggle(selectedTags[selectedTags.length - 1].id);
      }
    }
    if (e.key === "Escape") {
      setOpen(false);
      setQuery("");
    }
  };

  const hasSelections = selectedTags.length > 0 || newTags.length > 0;

  return (
    <div ref={containerRef} className="relative">
      <p className="text-[11px] font-semibold text-secondary mb-1.5">Tags</p>

      {/* Input area with pills */}
      <div
        className="flex flex-wrap items-center gap-1 min-h-[36px] rounded-[var(--radius-outer)] bg-grouped px-2 py-1.5 cursor-text"
        style={{ boxShadow: "0 0 0 0.5px rgba(0,0,0,0.06)" }}
        onClick={() => {
          inputRef.current?.focus();
          setOpen(true);
        }}
      >
        {/* Selected existing tag pills */}
        {selectedTags.map((tag) => (
          <span
            key={tag.id}
            className="inline-flex items-center gap-1 h-6 pl-2 pr-1 rounded-full bg-primary/10 text-[11px] font-medium text-primary"
          >
            {tag.fullPath}
            <button
              type="button"
              className="size-4 flex items-center justify-center rounded-full hover:bg-primary/20 transition-colors duration-150"
              onClick={(e) => {
                e.stopPropagation();
                onToggle(tag.id);
              }}
            >
              <X className="size-2.5" strokeWidth={3} />
            </button>
          </span>
        ))}

        {/* New tag pills */}
        {newTags.map((name) => (
          <span
            key={`new:${name}`}
            className="inline-flex items-center gap-1 h-6 pl-2 pr-1 rounded-full bg-success/10 text-[11px] font-medium text-success"
          >
            {name}
            <button
              type="button"
              className="size-4 flex items-center justify-center rounded-full hover:bg-success/20 transition-colors duration-150"
              onClick={(e) => {
                e.stopPropagation();
                onRemoveNewTag(name);
              }}
            >
              <X className="size-2.5" strokeWidth={3} />
            </button>
          </span>
        ))}

        {/* Text input */}
        <input
          ref={inputRef}
          type="text"
          value={query}
          onChange={(e) => {
            setQuery(e.target.value);
            if (!open) setOpen(true);
          }}
          onFocus={() => setOpen(true)}
          onKeyDown={handleKeyDown}
          placeholder={hasSelections ? "" : "Add tags\u2026"}
          className="flex-1 min-w-[60px] h-6 bg-transparent text-[12px] text-foreground placeholder:text-tertiary outline-none"
        />
      </div>

      {/* Dropdown */}
      {open && (filtered.length > 0 || (query.trim() && !exactMatch)) && (
        <div
          className="absolute left-0 right-0 top-full z-50 mt-1 max-h-40 overflow-y-auto rounded-[var(--radius-outer)] bg-grouped p-1"
          style={{ boxShadow: "0 0 0 0.5px rgba(0,0,0,0.06), 0 8px 24px rgba(0,0,0,0.12)" }}
        >
          {filtered.map((tag) => {
            const isSelected = selectedIds.has(tag.id);
            return (
              <button
                key={tag.id}
                type="button"
                className={`flex w-full items-center gap-2 px-2.5 h-7 rounded-[var(--radius-control)] text-left transition-colors duration-150 ${
                  isSelected ? "bg-primary/8" : "hover:bg-fill-hover"
                }`}
                onClick={() => handleSelect(tag)}
              >
                {/* Checkmark or empty space */}
                <span className="size-3.5 shrink-0 flex items-center justify-center">
                  {isSelected && (
                    <svg className="size-3 text-primary" viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                      <path d="M2 6l3 3 5-5" />
                    </svg>
                  )}
                </span>
                <span className="flex-1 text-[12px] text-foreground truncate">
                  {tag.fullPath}
                </span>
              </button>
            );
          })}

          {/* Create new tag option */}
          {query.trim() && !exactMatch && (
            <>
              {filtered.length > 0 && (
                <div className="mx-2 my-1 h-px bg-separator" />
              )}
              <button
                type="button"
                className="flex w-full items-center gap-2 px-2.5 h-7 rounded-[var(--radius-control)] text-left transition-colors duration-150 hover:bg-fill-hover"
                onClick={handleCreateTag}
              >
                <Plus className="size-3.5 text-success shrink-0" strokeWidth={2.5} />
                <span className="text-[12px] text-foreground">
                  Create &ldquo;{query.trim()}&rdquo;
                </span>
              </button>
            </>
          )}
        </div>
      )}
    </div>
  );
}
