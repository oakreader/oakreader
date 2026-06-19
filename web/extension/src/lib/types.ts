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
  thumbnailURL?: string | null;
  /** Base64 og:image bytes fetched in-page (cookies + referer beat anti-bot hosts like
   *  X, Instagram, 小红书). The app stores this cover directly instead of re-fetching the URL. */
  thumbnailData?: string | null;
  description?: string | null;
  embedType?: "link";
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

/** Payload for a full-page HTML snapshot captured by SingleFile (sent by background). */
export interface HTMLSnapshotPayload {
  type: "html";
  url: string;
  title: string | null;
  html: string;
  markdown?: string | null;
  /** og:image read from the live, rendered page — the app uses it as the cover directly,
   *  bypassing a server-side re-fetch that anti-bot sites (X, Instagram, Dribbble, 知乎…) block. */
  thumbnailURL?: string | null;
}

/** Payload for a base64 PDF generated via the debugger (sent by background). */
export interface PDFCapturePayload {
  type: "pdf";
  url: string;
  title: string | null;
  pdfData: string;
  markdown?: string | null;
}
