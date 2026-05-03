import { useState } from "react";
import { ChevronRight, Tag } from "lucide-react";
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
      {/* Section header — Apple HIG: semibold, secondary, no uppercase */}
      <button
        type="button"
        className="flex items-center gap-1 mb-1.5 text-left"
        onClick={() => setSectionExpanded(!sectionExpanded)}
      >
        <ChevronRight
          className={`size-3 text-tertiary transition-transform duration-200 ${
            sectionExpanded ? "rotate-90" : ""
          }`}
          strokeWidth={2.5}
        />
        <span className="text-[11px] font-semibold text-secondary">
          Tags
        </span>
      </button>
      {sectionExpanded && (
        <div
          className="rounded-[var(--radius-outer)] bg-grouped p-2 max-h-40 overflow-y-auto"
          style={{ boxShadow: "0 0 0 0.5px rgba(0,0,0,0.06)" }}
        >
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
        className="flex items-center gap-1.5 h-7 min-w-0"
        style={{ paddingLeft: `${depth * 20}px` }}
      >
        {/* Expand/collapse chevron for group nodes */}
        {hasChildren ? (
          <button
            type="button"
            className="shrink-0 size-5 flex items-center justify-center rounded-[var(--radius-control)] transition-colors duration-150 hover:bg-fill-hover"
            onClick={() => setExpanded(!expanded)}
          >
            <ChevronRight
              className={`size-3 text-tertiary transition-transform duration-200 ${
                expanded ? "rotate-90" : ""
              }`}
              strokeWidth={2.5}
            />
          </button>
        ) : (
          <span className="w-5 shrink-0" />
        )}

        {/* Icon */}
        {isSelectable ? (
          <Tag className="size-3 text-tertiary shrink-0" strokeWidth={2} />
        ) : (
          <span className="text-[10px] text-tertiary shrink-0">&#9679;</span>
        )}

        {/* Checkbox + Label */}
        {isSelectable ? (
          <label className="flex items-center gap-1.5 min-w-0 cursor-pointer">
            <Checkbox
              checked={selectedIds.has(node.id)}
              onCheckedChange={() => onToggle(node.id)}
            />
            <span className="text-[12px] text-foreground truncate">
              {node.name}
            </span>
          </label>
        ) : (
          <span className="text-[12px] font-medium text-secondary truncate">
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
