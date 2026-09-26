/**
 * Extract readable markdown from a saved HTML page.
 *
 * Mirrors what the browser extension does in-page (Defuddle → markdown, see
 * `extension/entrypoints/content.ts`) so an archive saved before that
 * pipeline existed — or on a platform without a WebView — yields the same
 * `content.md` that search and the AI tools read.
 *
 * SingleFile/monolith archives inline every asset as a `data:` URI, so a real
 * archive is mostly base64 and can reach well over 100 MB. Handing that to a
 * DOM parser is both slow and pointless, so strip the payloads first: it is a
 * pure size reduction, since no readable text ever lives inside a data URI.
 */
import { parseHTML } from "linkedom";
import { Defuddle } from "defuddle/node";
import TurndownService from "turndown";

/**
 * Replace `data:` URI payloads with a bare `data:,`.
 *
 * Done with a linear scan rather than a regex: a real archive can be 138 MB of
 * mostly base64, and `String.replace` with a `{200,}` quantifier over that
 * blows the call stack ("Maximum call stack size exceeded") before it finishes.
 * No readable text ever lives inside a data URI, so this is pure size removal.
 */
export function stripDataURIs(html: string): string {
  const out: string[] = [];
  let i = 0;
  for (;;) {
    const at = html.indexOf("data:", i);
    if (at === -1) { out.push(html.slice(i)); break; }
    // Only a payload that is actually long is worth cutting; short data: URIs
    // (e.g. `data:,`) are already harmless and may be meaningful markup.
    let end = at + 5;
    while (end < html.length) {
      const c = html.charCodeAt(end);
      // stop at quote, paren, whitespace or '>' -- the delimiters an attribute
      // or a CSS url() can legally end on
      if (c === 34 || c === 39 || c === 41 || c === 62 || c <= 32) break;
      end++;
    }
    if (end - at >= 200) { out.push(html.slice(i, at), "data:,"); }
    else { out.push(html.slice(i, end)); }
    i = end;
  }
  return out.join("");
}

const turndown = new TurndownService({ headingStyle: "atx", codeBlockStyle: "fenced" });
// Archives carry the page chrome too; these never belong in extracted text.
turndown.remove(["script", "style", "noscript", "iframe", "svg", "form"]);

export interface ExtractResult {
  markdown: string;
  title?: string;
  /** Bytes of HTML actually parsed, after data-URI stripping. */
  parsedBytes: number;
  /** True when Defuddle could not classify the page and the raw body was used. */
  usedFallback: boolean;
}

export async function htmlToMarkdown(html: string, url?: string): Promise<ExtractResult> {
  const stripped = stripDataURIs(html);
  const { document } = parseHTML(stripped);
  if (url) {
    // Defuddle resolves relative links against the document URL when present.
    try {
      const base = document.createElement("base");
      base.setAttribute("href", url);
      document.head?.appendChild(base);
    } catch { /* best effort */ }
  }

  let contentHTML: string | undefined;
  let title: string | undefined;
  try {
    const parsed = await Defuddle(document as never, url);
    contentHTML = parsed?.content;
    title = parsed?.title;
  } catch { /* fall through to the body */ }

  // Defuddle returns nothing on pages it cannot classify (SPAs, link dumps).
  // The body is a worse but non-empty answer, and still beats losing the page.
  let usedFallback = false;
  if (!contentHTML || contentHTML.trim().length < 200) {
    usedFallback = true;
    contentHTML = document.body?.innerHTML ?? "";
  }

  const markdown = turndown
    .turndown(contentHTML)
    .replace(/\n{3,}/g, "\n\n")
    .trim();

  return { markdown, title: title ?? document.title ?? undefined, parsedBytes: stripped.length, usedFallback };
}
