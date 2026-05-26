import type { BiblioMetadata, ContentKind } from "./translators/types";

/** Lightweight metadata returned instantly by content script. */
export interface PageMeta {
  type: "html" | "embed" | "pdf";
  url: string;
  title: string | null;
  favicon: string | null;
  contentKind?: ContentKind;
}

/** Full page capture including content data. */
export interface PageCapture {
  type: "html" | "embed" | "pdf";
  url: string;
  title: string | null;
  author?: string | null;
  videoId?: string | null;
  duration?: number | null;
  thumbnailURL?: string | null;
  transcript?: string | null;
  description?: string | null;
  embedType?: "youtube" | "twitter" | "link";
  biblio?: BiblioMetadata;
  markdown?: string | null;
}

/** Payload for saving a PDF by URL (no HTML capture needed). */
export interface PDFSavePayload {
  type: "pdf";
  url: string;
  title: string | null;
  cookies?: string;
}

/** Payload for saving an HTML snapshot (SingleFile capture). */
export interface HTMLSnapshotPayload {
  type: "html";
  url: string;
  title: string | null;
  html: string;
  markdown?: string | null;
}

/** @deprecated Use PageCapture for full data or PageMeta for lightweight detection. */
export type PageData = PageCapture;
