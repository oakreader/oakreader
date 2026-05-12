import { useMemo } from "react";
import { Menu } from "@base-ui/react/menu";
import { ChevronRight, ChevronDown, BookOpen, Folder, Check } from "lucide-react";
import type { CollectionInfo } from "@/src/lib/types";

interface CollectionPickerProps {
  collections: CollectionInfo[];
  value: string;
  onChange: (value: string) => void;
}

/** Find the display name for the selected collection. */
function findName(collections: CollectionInfo[], id: string): string | null {
  for (const c of collections) {
    if (c.id === id) return c.name;
    if (c.children) {
      const found = findName(c.children, id);
      if (found) return found;
    }
  }
  return null;
}

// Shared styles
const itemClass =
  "flex w-full items-center gap-2 px-2.5 h-8 rounded-[var(--radius-control)] text-left text-[12px] text-foreground outline-none select-none transition-colors duration-150 data-highlighted:bg-fill-hover";

const submenuTriggerClass =
  "flex w-full items-center gap-2 px-2.5 h-8 rounded-[var(--radius-control)] text-left text-[12px] text-foreground outline-none select-none transition-colors duration-150 data-highlighted:bg-fill-hover data-popup-open:bg-fill-hover";

const popupClass =
  "max-h-60 overflow-y-auto rounded-[var(--radius-outer)] bg-grouped p-1 origin-[var(--transform-origin)] transition-[transform,scale,opacity] data-open:animate-in data-open:fade-in-0 data-open:zoom-in-95 data-closed:animate-out data-closed:fade-out-0 data-closed:zoom-out-95";

const popupShadow =
  "0 0 0 0.5px rgba(0,0,0,0.06), 0 8px 24px rgba(0,0,0,0.12)";

/** Recursive collection menu item — mirrors Mac app's collectionMenuItem. */
function CollectionMenuItem({
  collection,
  value,
  onChange,
}: {
  collection: CollectionInfo;
  value: string;
  onChange: (id: string) => void;
}) {
  const children = collection.children ?? [];
  const isSelected = collection.id === value;

  if (children.length === 0) {
    // Leaf collection — simple menu item
    return (
      <Menu.Item
        className={itemClass}
        onClick={() => onChange(collection.id)}
      >
        <Folder className="size-[14px] text-secondary shrink-0" strokeWidth={1.8} />
        <span className="flex-1 truncate">{collection.name}</span>
        {isSelected && (
          <Check className="size-3.5 text-primary shrink-0" strokeWidth={2.5} />
        )}
      </Menu.Item>
    );
  }

  // Collection with children — submenu
  return (
    <Menu.SubmenuRoot>
      <Menu.SubmenuTrigger className={submenuTriggerClass}>
        <Folder className="size-[14px] text-secondary shrink-0" strokeWidth={1.8} />
        <span className="flex-1 truncate">{collection.name}</span>
        {isSelected && (
          <Check className="size-3.5 text-primary shrink-0" strokeWidth={2.5} />
        )}
        <ChevronRight className="size-3 text-tertiary shrink-0" strokeWidth={2} />
      </Menu.SubmenuTrigger>
      <Menu.Portal>
        <Menu.Positioner side="right" sideOffset={-4} align="start">
          <Menu.Popup
            className={popupClass}
            style={{ boxShadow: popupShadow }}
          >
            {/* Select this collection itself */}
            <Menu.Item
              className={itemClass}
              onClick={() => onChange(collection.id)}
            >
              <Folder className="size-[14px] text-secondary shrink-0" strokeWidth={1.8} />
              <span className="flex-1 truncate">{collection.name}</span>
              {isSelected && (
                <Check className="size-3.5 text-primary shrink-0" strokeWidth={2.5} />
              )}
            </Menu.Item>
            <Menu.Separator className="mx-2 my-1 h-px bg-separator" />
            {/* Child collections */}
            {children.map((child) => (
              <CollectionMenuItem
                key={child.id}
                collection={child}
                value={value}
                onChange={onChange}
              />
            ))}
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.SubmenuRoot>
  );
}

export function CollectionPicker({
  collections,
  value,
  onChange,
}: CollectionPickerProps) {
  const selectedName = useMemo(() => {
    if (value === "__all__") return "All Items";
    return findName(collections, value) ?? "All Items";
  }, [collections, value]);

  return (
    <div>
      <p className="text-[11px] font-semibold text-secondary mb-1">Collection</p>

      <Menu.Root>
        {/* Trigger button — shows current selection */}
        <Menu.Trigger
          className="flex w-full items-center gap-2 rounded-[var(--radius-outer)] bg-grouped px-3 h-9 text-left transition-colors duration-200 hover:bg-fill-hover"
          style={{ boxShadow: "0 0 0 0.5px rgba(0,0,0,0.06)" }}
        >
          {value === "__all__" ? (
            <BookOpen className="size-[15px] text-secondary shrink-0" strokeWidth={1.8} />
          ) : (
            <Folder className="size-[15px] text-secondary shrink-0" strokeWidth={1.8} />
          )}
          <span className="flex-1 text-[13px] font-medium text-foreground truncate">
            {selectedName}
          </span>
          <ChevronDown
            className="size-3 text-tertiary shrink-0"
            strokeWidth={2.5}
          />
        </Menu.Trigger>

        {/* Dropdown with cascading submenus */}
        <Menu.Portal>
          <Menu.Positioner sideOffset={4} align="start">
            <Menu.Popup
              className={popupClass}
              style={{ boxShadow: popupShadow, minWidth: "var(--anchor-width)" }}
            >
              {/* All Items */}
              <Menu.Item
                className={itemClass}
                onClick={() => onChange("__all__")}
              >
                <BookOpen className="size-[14px] text-secondary shrink-0" strokeWidth={1.8} />
                <span className="flex-1 truncate">All Items</span>
                {value === "__all__" && (
                  <Check className="size-3.5 text-primary shrink-0" strokeWidth={2.5} />
                )}
              </Menu.Item>

              {collections.length > 0 && (
                <Menu.Separator className="mx-2 my-1 h-px bg-separator" />
              )}

              {/* Collection tree — recursive submenus */}
              {collections.map((collection) => (
                <CollectionMenuItem
                  key={collection.id}
                  collection={collection}
                  value={value}
                  onChange={onChange}
                />
              ))}
            </Menu.Popup>
          </Menu.Positioner>
        </Menu.Portal>
      </Menu.Root>
    </div>
  );
}
