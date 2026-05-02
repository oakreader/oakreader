/** Lightweight metadata returned instantly by content script (no SingleFile). */
export interface PageMeta {
  type: "html" | "embed" | "pdf";
  url: string;
  title: string | null;
  favicon: string | null;
}

/** Full page capture including HTML content. */
export interface PageCapture {
  type: "html" | "embed";
  url: string;
  title: string | null;
  html?: string | null;
  author?: string | null;
  videoId?: string | null;
  duration?: number | null;
  thumbnailURL?: string | null;
  transcript?: string | null;
  description?: string | null;
}

/** Payload for saving a PDF by URL (no HTML capture needed). */
export interface PDFSavePayload {
  type: "pdf";
  url: string;
  title: string | null;
  cookies?: string;
  collectionId?: string;
  tagOptionIds?: string[];
}

/** @deprecated Use PageCapture for full data or PageMeta for lightweight detection. */
export type PageData = PageCapture;

export interface CollectionInfo {
  id: string;
  name: string;
  icon: string;
  parentId: string | null;
}

export interface TagNodeInfo {
  id: string;
  name: string;
  fullPath: string;
  count: number;
  isTag?: boolean;
  children?: TagNodeInfo[];
}
