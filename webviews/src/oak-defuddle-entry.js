// Standalone entry bundled (via rollup.defuddle.config.js) into a plain IIFE that
// the OakReader native browser injects into its live WKWebView. Exposes
// window.oakExtractReadableMarkdown(), which LivePageBridge calls to extract the
// current page as readable markdown — the SAME defuddle path the web-clip extension
// uses (entrypoints/content.ts), so live-browse markdown matches saved-clip markdown.
import Defuddle, { createMarkdownContent } from "defuddle/full";

window.oakExtractReadableMarkdown = function () {
  try {
    const result = new Defuddle(document).parse();
    const markdown = createMarkdownContent(result.content, location.href) || "";
    return JSON.stringify({
      title: result.title || document.title || "",
      url: location.href,
      markdown,
    });
  } catch (e) {
    const body = document.body ? document.body.innerText : "";
    return JSON.stringify({
      title: document.title || "",
      url: location.href,
      markdown: body,
    });
  }
};
