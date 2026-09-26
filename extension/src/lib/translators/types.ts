export type ContentKind = "webpage" | "scholarly" | "link";

export interface BiblioMetadata {
  doi?: string | null;
  issn?: string | null;
  isbn?: string | null;
  journal?: string | null;
  volume?: string | null;
  issue?: string | null;
  pages?: string | null;
  publisher?: string | null;
  year?: number | null;
  authors?: Array<{ given?: string; family?: string }>;
  cslType?: string | null;
}

export interface TranslatorResult {
  kind: ContentKind;
  url: string;
  title: string;
  author?: string | null;
  thumbnailURL?: string | null;
  description?: string | null;
  html?: string;
  markdown?: string | null;
  // Scholarly-specific
  biblio?: BiblioMetadata;
}

export interface Translator {
  id: string;
  label: string;
  contentKind: ContentKind;
  priority: number;
  detect(url: string): boolean;
  extract(doc: Document, url: string): Promise<TranslatorResult>;
}
