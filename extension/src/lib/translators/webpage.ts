import type { Translator, TranslatorResult } from "./types";

export const genericWebpageTranslator: Translator = {
  id: "webpage",
  label: "Web Page",
  contentKind: "webpage",
  priority: -100, // catch-all, always matches last

  detect(): boolean {
    return true;
  },

  async extract(doc: Document, url: string): Promise<TranslatorResult> {
    const title = doc.title || url;

    const author =
      doc.querySelector<HTMLMetaElement>('meta[name="author"]')?.content ??
      doc.querySelector<HTMLMetaElement>('meta[property="og:site_name"]')?.content ??
      null;

    const description =
      doc.querySelector<HTMLMetaElement>('meta[property="og:description"]')?.content ??
      doc.querySelector<HTMLMetaElement>('meta[name="description"]')?.content ??
      null;

    const thumbnailURL =
      doc.querySelector<HTMLMetaElement>('meta[property="og:image"]')?.content ?? null;

    return {
      kind: "webpage",
      url,
      title,
      author,
      description,
      thumbnailURL,
      html: "",
      markdown: null,
    };
  },
};
