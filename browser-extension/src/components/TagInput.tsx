import { useState, useMemo, useCallback, useRef, useEffect } from "react";
import { ChevronRight, ChevronDown, Check, Search, X, Plus } from "lucide-react";
import type { TagNodeInfo } from "@/src/lib/types";

interface TagInputProps {
  tags: TagNodeInfo[];
  selectedIds: Set<string>;
  newTags: string[];
  onToggle: (id: string) => void;
  onAddNewTag: (name: string) => void;
  onRemoveNewTag: (name: string) => void;
}

/** Color dot indicator for tags. */
function ColorDot({ colorHex }: { colorHex?: string }) {
  if (!colorHex) return null;
  return (
    <span
      className="size-2 rounded-[2px] shrink-0"
      style={{ backgroundColor: `#${colorHex}` }}
    />
  );
}

/** Collect all selectable leaf tags from the tree. */
function collectLeafTags(nodes: TagNodeInfo[]): TagNodeInfo[] {
  const result: TagNodeInfo[] = [];
  function walk(list: TagNodeInfo[]) {
    for (const node of list) {
      if (node.isTag) result.push(node);
      if (node.children?.length) walk(node.children);
    }
  }
  walk(nodes);
  return result;
}

/** Collect all node IDs that have children. */
function collectExpandableIds(nodes: TagNodeInfo[]): Set<string> {
  const ids = new Set<string>();
  function walk(list: TagNodeInfo[]) {
    for (const node of list) {
      if (node.children?.length) {
        ids.add(node.id);
        walk(node.children);
      }
    }
  }
  walk(nodes);
  return ids;
}

interface VisibleNode {
  tag: TagNodeInfo;
  depth: number;
  isContext: boolean;
}

/** Flatten tree respecting expanded state, adding depth info. */
function flattenVisible(nodes: TagNodeInfo[], expanded: Set<string>): VisibleNode[] {
  const result: VisibleNode[] = [];
  function walk(list: TagNodeInfo[], depth: number) {
    for (const node of list) {
      result.push({ tag: node, depth, isContext: false });
      if (node.children?.length && expanded.has(node.id)) {
        walk(node.children, depth + 1);
      }
    }
  }
  walk(nodes, 0);
  return result;
}

/** Filter tree: matching nodes + ancestor chains for hierarchy context. */
function filterTree(nodes: TagNodeInfo[], query: string): VisibleNode[] {
  const q = query.toLowerCase();

  const matchingIds = new Set<string>();
  function findMatches(list: TagNodeInfo[]) {
    for (const node of list) {
      if (node.name.toLowerCase().includes(q) || node.fullPath.toLowerCase().includes(q)) {
        matchingIds.add(node.id);
      }
      if (node.children?.length) findMatches(node.children);
    }
  }
  findMatches(nodes);

  const contextIds = new Set<string>();
  function markAncestors(list: TagNodeInfo[], ancestors: TagNodeInfo[]) {
    for (const node of list) {
      if (matchingIds.has(node.id)) {
        for (const a of ancestors) contextIds.add(a.id);
      }
      if (node.children?.length) {
        markAncestors(node.children, [...ancestors, node]);
      }
    }
  }
  markAncestors(nodes, []);

  const result: VisibleNode[] = [];
  function collect(list: TagNodeInfo[], depth: number) {
    for (const node of list) {
      if (matchingIds.has(node.id)) {
        result.push({ tag: node, depth, isContext: false });
      } else if (contextIds.has(node.id)) {
        result.push({ tag: node, depth, isContext: true });
      }
      if (node.children?.length) collect(node.children, depth + 1);
    }
  }
  collect(nodes, 0);
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
  const [search, setSearch] = useState("");
  const searchRef = useRef<HTMLInputElement>(null);

  const expandableIds = useMemo(() => collectExpandableIds(tags), [tags]);
  const leafTags = useMemo(() => collectLeafTags(tags), [tags]);

  const [expanded, setExpanded] = useState<Set<string>>(new Set());

  // Expand all nodes when tags first load
  const hasInitialized = useRef(false);
  useEffect(() => {
    if (tags.length === 0 || hasInitialized.current) return;
    hasInitialized.current = true;
    setExpanded(new Set(expandableIds));
  }, [tags, expandableIds]);

  const toggleExpand = useCallback((id: string, e: React.MouseEvent) => {
    e.stopPropagation();
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);

  const isSearching = search.trim().length > 0;

  const visibleNodes = useMemo(() => {
    if (!isSearching) {
      return flattenVisible(tags, expanded);
    }
    return filterTree(tags, search.trim());
  }, [tags, expanded, isSearching, search]);

  // Check if search query matches an existing tag name
  const exactMatch = useMemo(() => {
    if (!search.trim()) return true;
    const q = search.trim().toLowerCase();
    return (
      leafTags.some(
        (t) => t.name.toLowerCase() === q || t.fullPath.toLowerCase() === q
      ) || newTags.some((t) => t.toLowerCase() === q)
    );
  }, [leafTags, newTags, search]);

  const handleCreateTag = useCallback(() => {
    const trimmed = search.trim();
    if (!trimmed) return;
    onAddNewTag(trimmed);
    setSearch("");
    searchRef.current?.focus();
  }, [search, onAddNewTag]);

  const selectedTags = useMemo(
    () => leafTags.filter((t) => selectedIds.has(t.id)),
    [leafTags, selectedIds]
  );

  const showCreateRow = search.trim() && !exactMatch;

  return (
    <div>
      <p className="text-[11px] font-semibold text-secondary mb-1">Tags</p>

      {/* Selected tag pills + new tag pills */}
      {(selectedTags.length > 0 || newTags.length > 0) && (
        <div className="flex flex-wrap gap-1 mb-1.5">
          {selectedTags.map((tag) => (
            <span
              key={tag.id}
              className="inline-flex items-center gap-1 h-6 pl-2 pr-1 rounded-full bg-primary/10 text-[11px] font-medium text-primary"
            >
              <ColorDot colorHex={tag.colorHex} />
              {tag.name}
              <button
                type="button"
                className="size-4 flex items-center justify-center rounded-full hover:bg-primary/20 transition-colors duration-150"
                onClick={() => onToggle(tag.id)}
              >
                <X className="size-2.5" strokeWidth={3} />
              </button>
            </span>
          ))}
          {newTags.map((name) => (
            <span
              key={`new:${name}`}
              className="inline-flex items-center gap-1 h-6 pl-2 pr-1 rounded-full bg-success/10 text-[11px] font-medium text-success"
            >
              {name}
              <button
                type="button"
                className="size-4 flex items-center justify-center rounded-full hover:bg-success/20 transition-colors duration-150"
                onClick={() => onRemoveNewTag(name)}
              >
                <X className="size-2.5" strokeWidth={3} />
              </button>
            </span>
          ))}
        </div>
      )}

      <div
        className="rounded-[var(--radius-outer)] bg-grouped overflow-hidden"
        style={{ boxShadow: "0 0 0 0.5px rgba(0,0,0,0.06)" }}
      >
        {/* Search / create input */}
        <div className="flex items-center gap-1.5 px-2 h-8 border-b border-separator">
          <Search className="size-3 text-tertiary shrink-0" strokeWidth={2} />
          <input
            ref={searchRef}
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && showCreateRow) {
                e.preventDefault();
                handleCreateTag();
              } else if (e.key === "Enter" && isSearching) {
                // If one exact match, toggle it
                const matchingLeafs = visibleNodes.filter(
                  (v) => v.tag.isTag && !v.isContext
                );
                if (matchingLeafs.length === 1) {
                  e.preventDefault();
                  onToggle(matchingLeafs[0].tag.id);
                  setSearch("");
                }
              } else if (e.key === "Escape") {
                setSearch("");
              }
            }}
            placeholder="Search or create\u2026"
            className="flex-1 bg-transparent text-[12px] text-foreground placeholder:text-tertiary outline-none"
          />
          {isSearching && (
            <button
              type="button"
              className="size-4 flex items-center justify-center text-tertiary hover:text-secondary"
              onClick={() => {
                setSearch("");
                searchRef.current?.focus();
              }}
            >
              <svg className="size-3" viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
                <path d="M2 2l8 8M10 2l-8 8" />
              </svg>
            </button>
          )}
        </div>

        {/* Tag tree */}
        <div className="max-h-[140px] overflow-y-auto p-1">
          {visibleNodes.map(({ tag, depth, isContext }) => {
            const hasChildren = expandableIds.has(tag.id);
            const isExpanded = expanded.has(tag.id);
            const isLeaf = !!tag.isTag;
            const isSelected = isLeaf && selectedIds.has(tag.id);

            return (
              <button
                key={tag.id}
                type="button"
                className={`flex w-full items-center gap-1.5 h-7 rounded-[var(--radius-control)] text-left transition-colors duration-150 ${
                  isSelected
                    ? "bg-primary/8"
                    : isLeaf
                      ? "hover:bg-fill-hover"
                      : ""
                }${isContext ? " opacity-50" : ""}`}
                style={{ paddingLeft: `${6 + depth * 16}px`, paddingRight: 6 }}
                onClick={() => {
                  if (isLeaf) onToggle(tag.id);
                }}
              >
                {/* Expand/collapse chevron or spacer */}
                {hasChildren && !isSearching ? (
                  <span
                    className="size-4 flex items-center justify-center shrink-0 cursor-pointer rounded hover:bg-fill-hover"
                    onClick={(e) => toggleExpand(tag.id, e)}
                  >
                    {isExpanded ? (
                      <ChevronDown className="size-3 text-tertiary" strokeWidth={2} />
                    ) : (
                      <ChevronRight className="size-3 text-tertiary" strokeWidth={2} />
                    )}
                  </span>
                ) : (
                  <span className="size-4 shrink-0" />
                )}

                {/* Color dot for leaf tags */}
                {isLeaf ? (
                  <ColorDot colorHex={tag.colorHex} />
                ) : null}

                {/* Name */}
                <span
                  className={`flex-1 text-[12px] truncate ${
                    isLeaf ? "text-foreground" : "text-secondary font-medium"
                  }`}
                >
                  {tag.name}
                </span>

                {/* Selection checkmark */}
                {isSelected && (
                  <Check className="size-3.5 text-primary shrink-0" strokeWidth={2.5} />
                )}
              </button>
            );
          })}

          {visibleNodes.length === 0 && !showCreateRow && (
            <p className="px-2 py-2 text-[11px] text-tertiary text-center">
              No tags found
            </p>
          )}

          {/* Create new tag option */}
          {showCreateRow && (
            <>
              {visibleNodes.length > 0 && (
                <div className="mx-2 my-1 h-px bg-separator" />
              )}
              <button
                type="button"
                className="flex w-full items-center gap-2 h-7 px-2.5 rounded-[var(--radius-control)] text-left transition-colors duration-150 hover:bg-fill-hover"
                onClick={handleCreateTag}
              >
                <Plus className="size-3.5 text-success shrink-0" strokeWidth={2.5} />
                <span className="text-[12px] text-foreground">
                  Create &ldquo;{search.trim()}&rdquo;
                </span>
              </button>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
