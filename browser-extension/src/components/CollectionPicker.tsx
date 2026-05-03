import { useState, useRef, useEffect } from "react";
import { ChevronDown, BookOpen, Folder, Check } from "lucide-react";
import type { CollectionInfo } from "@/src/lib/types";

interface CollectionPickerProps {
  collections: CollectionInfo[];
  value: string;
  onChange: (value: string) => void;
}

interface TreeNode {
  collection: CollectionInfo | null; // null for "All Items"
  id: string;
  name: string;
  depth: number;
  children: TreeNode[];
}

function buildTree(collections: CollectionInfo[]): TreeNode[] {
  const allItems: TreeNode = {
    collection: null,
    id: "__all__",
    name: "All Items",
    depth: 0,
    children: [],
  };

  // Map id -> children
  const childrenMap = new Map<string | null, CollectionInfo[]>();
  for (const c of collections) {
    const key = c.parentId;
    if (!childrenMap.has(key)) childrenMap.set(key, []);
    childrenMap.get(key)!.push(c);
  }

  function buildNodes(parentId: string | null, depth: number): TreeNode[] {
    const children = childrenMap.get(parentId) || [];
    return children.map((c) => ({
      collection: c,
      id: c.id,
      name: c.name,
      depth,
      children: buildNodes(c.id, depth + 1),
    }));
  }

  return [allItems, ...buildNodes(null, 0)];
}

function flattenTree(nodes: TreeNode[]): TreeNode[] {
  const result: TreeNode[] = [];
  function walk(list: TreeNode[]) {
    for (const node of list) {
      result.push(node);
      walk(node.children);
    }
  }
  walk(nodes);
  return result;
}

export function CollectionPicker({
  collections,
  value,
  onChange,
}: CollectionPickerProps) {
  const [open, setOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);

  const tree = buildTree(collections);
  const flat = flattenTree(tree);
  const selected = flat.find((n) => n.id === value) || flat[0];

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

  return (
    <div ref={containerRef} className="relative">
      {/* Section label */}
      <p className="text-[11px] font-semibold text-secondary mb-1.5">Collection</p>

      {/* Trigger — Apple popup button style */}
      <button
        type="button"
        className="flex w-full items-center gap-2 rounded-[var(--radius-outer)] bg-grouped px-3 h-9 text-left transition-colors duration-200 hover:bg-fill-hover"
        style={{ boxShadow: "0 0 0 0.5px rgba(0,0,0,0.06)" }}
        onClick={() => setOpen(!open)}
      >
        {selected.id === "__all__" ? (
          <BookOpen className="size-[15px] text-secondary shrink-0" strokeWidth={1.8} />
        ) : (
          <Folder className="size-[15px] text-secondary shrink-0" strokeWidth={1.8} />
        )}
        <span className="flex-1 text-[13px] font-medium text-foreground truncate">
          {selected.name}
        </span>
        <ChevronDown
          className={`size-3 text-tertiary shrink-0 transition-transform duration-200 ${open ? "rotate-180" : ""}`}
          strokeWidth={2.5}
        />
      </button>

      {/* Dropdown menu */}
      {open && (
        <div
          className="absolute left-0 right-0 top-full z-50 mt-1 max-h-48 overflow-y-auto rounded-[var(--radius-outer)] bg-grouped p-1"
          style={{ boxShadow: "0 0 0 0.5px rgba(0,0,0,0.06), 0 8px 24px rgba(0,0,0,0.12)" }}
        >
          {flat.map((node) => (
            <button
              key={node.id}
              type="button"
              className={`flex w-full items-center gap-2 px-2.5 h-8 rounded-[var(--radius-control)] text-left transition-colors duration-150 ${
                node.id === value
                  ? "bg-primary/8"
                  : "hover:bg-fill-hover"
              }`}
              style={{ paddingLeft: `${10 + node.depth * 20}px` }}
              onClick={() => {
                onChange(node.id);
                setOpen(false);
              }}
            >
              {node.id === "__all__" ? (
                <BookOpen className="size-[14px] text-secondary shrink-0" strokeWidth={1.8} />
              ) : (
                <Folder className="size-[14px] text-secondary shrink-0" strokeWidth={1.8} />
              )}
              <span className="flex-1 text-[12px] text-foreground truncate">
                {node.name}
              </span>
              {node.id === value && (
                <Check className="size-3.5 text-primary shrink-0" strokeWidth={2.5} />
              )}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
