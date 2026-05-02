import { useState, useRef, useEffect } from "react";
import { ChevronDown, Inbox, Folder } from "lucide-react";
import type { CollectionInfo } from "@/src/lib/types";

interface CollectionPickerProps {
  collections: CollectionInfo[];
  value: string;
  onChange: (value: string) => void;
}

interface TreeNode {
  collection: CollectionInfo | null; // null for Inbox
  id: string;
  name: string;
  depth: number;
  children: TreeNode[];
}

function buildTree(collections: CollectionInfo[]): TreeNode[] {
  const inbox: TreeNode = {
    collection: null,
    id: "__inbox__",
    name: "Inbox",
    depth: 0,
    children: [],
  };

  // Map id → children
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

  return [inbox, ...buildNodes(null, 0)];
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
      <button
        type="button"
        className="flex w-full items-center gap-2 rounded-lg bg-white px-3 py-2.5 text-left shadow-sm border border-border"
        onClick={() => setOpen(!open)}
      >
        {selected.id === "__inbox__" ? (
          <Inbox className="size-4 text-muted-foreground shrink-0" />
        ) : (
          <Folder className="size-4 text-muted-foreground shrink-0" />
        )}
        <span className="flex-1 text-[13px] font-medium text-foreground truncate">
          {selected.name}
        </span>
        <ChevronDown
          className={`size-3.5 text-muted-foreground shrink-0 transition-transform ${open ? "rotate-180" : ""}`}
        />
      </button>

      {open && (
        <div className="absolute left-0 right-0 top-full z-50 mt-1 max-h-48 overflow-y-auto rounded-lg bg-white border border-border shadow-lg">
          {flat.map((node) => (
            <button
              key={node.id}
              type="button"
              className={`flex w-full items-center gap-2 px-3 py-2 text-left hover:bg-muted ${
                node.id === value ? "bg-muted" : ""
              }`}
              style={{ paddingLeft: `${12 + node.depth * 16}px` }}
              onClick={() => {
                onChange(node.id);
                setOpen(false);
              }}
            >
              {node.id === "__inbox__" ? (
                <Inbox className="size-3.5 text-muted-foreground shrink-0" />
              ) : (
                <Folder className="size-3.5 text-muted-foreground shrink-0" />
              )}
              <span className="flex-1 text-[12px] text-foreground truncate">
                {node.name}
              </span>
              {node.id === value && (
                <svg className="size-3.5 text-primary shrink-0" viewBox="0 0 16 16" fill="currentColor">
                  <path d="M13.78 4.22a.75.75 0 010 1.06l-7.25 7.25a.75.75 0 01-1.06 0L2.22 9.28a.75.75 0 011.06-1.06L6 10.94l6.72-6.72a.75.75 0 011.06 0z" />
                </svg>
              )}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
