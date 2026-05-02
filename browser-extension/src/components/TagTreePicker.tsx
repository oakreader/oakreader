import { useState } from "react";
import { ChevronRight, Folder, Tag } from "lucide-react";
import { Checkbox } from "@/src/components/ui/checkbox";
import type { TagNodeInfo } from "@/src/lib/types";

interface TagTreePickerProps {
  tags: TagNodeInfo[];
  selectedIds: Set<string>;
  onToggle: (id: string) => void;
}

export function TagTreePicker({
  tags,
  selectedIds,
  onToggle,
}: TagTreePickerProps) {
  const [sectionExpanded, setSectionExpanded] = useState(true);

  if (tags.length === 0) return null;

  return (
    <div>
      <button
        type="button"
        className="flex items-center gap-1.5 mb-2 text-left"
        onClick={() => setSectionExpanded(!sectionExpanded)}
      >
        <ChevronRight
          className={`size-3 text-muted-foreground transition-transform ${
            sectionExpanded ? "rotate-90" : ""
          }`}
        />
        <span className="text-[11px] font-medium text-muted-foreground uppercase tracking-wide">
          Tags
        </span>
      </button>
      {sectionExpanded && (
        <div className="rounded-lg bg-white border border-border p-2 max-h-40 overflow-y-auto">
          <TagNodeList nodes={tags} depth={0} selectedIds={selectedIds} onToggle={onToggle} />
        </div>
      )}
    </div>
  );
}

interface TagNodeListProps {
  nodes: TagNodeInfo[];
  depth: number;
  selectedIds: Set<string>;
  onToggle: (id: string) => void;
}

function TagNodeList({ nodes, depth, selectedIds, onToggle }: TagNodeListProps) {
  return (
    <>
      {nodes.map((node) => (
        <TagNodeItem
          key={node.id}
          node={node}
          depth={depth}
          selectedIds={selectedIds}
          onToggle={onToggle}
        />
      ))}
    </>
  );
}

interface TagNodeItemProps {
  node: TagNodeInfo;
  depth: number;
  selectedIds: Set<string>;
  onToggle: (id: string) => void;
}

function TagNodeItem({ node, depth, selectedIds, onToggle }: TagNodeItemProps) {
  const [expanded, setExpanded] = useState(true);
  const isSelectable = !!node.isTag;
  const hasChildren = node.children && node.children.length > 0;

  return (
    <div>
      <div
        className="flex items-center gap-1.5 py-1 min-w-0"
        style={{ paddingLeft: `${depth * 16}px` }}
      >
        {/* Expand/collapse chevron for group nodes */}
        {hasChildren ? (
          <button
            type="button"
            className="shrink-0 p-0.5 rounded hover:bg-muted"
            onClick={() => setExpanded(!expanded)}
          >
            <ChevronRight
              className={`size-3 text-muted-foreground transition-transform ${
                expanded ? "rotate-90" : ""
              }`}
            />
          </button>
        ) : (
          <span className="w-4 shrink-0" />
        )}

        {/* Icon */}
        {isSelectable ? (
          <Tag className="size-3 text-muted-foreground shrink-0" />
        ) : (
          <Folder className="size-3 text-muted-foreground shrink-0" />
        )}

        {/* Checkbox + Label */}
        {isSelectable ? (
          <label className="flex items-center gap-1.5 min-w-0 cursor-pointer">
            <Checkbox
              checked={selectedIds.has(node.id)}
              onCheckedChange={() => onToggle(node.id)}
              className="size-3.5 rounded border-border"
            />
            <span className="text-[12px] text-foreground truncate">
              {node.name}
            </span>
          </label>
        ) : (
          <span className="text-[12px] font-medium text-muted-foreground truncate">
            {node.name}
          </span>
        )}
      </div>

      {/* Children */}
      {hasChildren && expanded && (
        <TagNodeList
          nodes={node.children!}
          depth={depth + 1}
          selectedIds={selectedIds}
          onToggle={onToggle}
        />
      )}
    </div>
  );
}
