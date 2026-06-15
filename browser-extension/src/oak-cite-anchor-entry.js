// Standalone entry bundled (via rollup.cite-anchor.config.js) into a plain IIFE the
// OakReader native browser injects into its WKWebView (live pages + saved HTML clips).
//
// Exposes a single hook — window.oakHighlightCitation(selectorJSON) — that the native
// WebViewCoordinator calls when the user clicks an AI-chat citation. The hard part,
// locating a possibly-paraphrased quote inside the rendered DOM, is delegated to a
// mature library: Hypothes.is's dom-anchor-text-quote, which anchors a W3C
// TextQuoteSelector {exact, prefix, suffix} to a DOM Range using Google's
// diff-match-patch (Bitap approximate string matching). We only own the thin glue:
// JSON in, flash + scroll out.
import { toRange } from "dom-anchor-text-quote";

const HL_NAME = "oak-cite";
let clearTimer = null;

function ensureStyle() {
  if (document.getElementById("oak-cite-style")) return;
  const st = document.createElement("style");
  st.id = "oak-cite-style";
  // Both the CSS Custom Highlight pseudo (preferred, no DOM mutation) and a class
  // (block-element fallback) share one amber wash.
  st.textContent =
    "::highlight(" + HL_NAME + "){background-color:rgba(255,214,10,0.45);border-radius:2px;}" +
    ".oak-cite-hl{background-color:rgba(255,214,10,0.45)!important;border-radius:2px;}";
  (document.head || document.documentElement).appendChild(st);
}

function clearHighlight() {
  try {
    if (window.CSS && CSS.highlights) CSS.highlights.delete(HL_NAME);
  } catch (e) {
    /* no-op */
  }
  document.querySelectorAll(".oak-cite-hl").forEach((n) => n.classList.remove("oak-cite-hl"));
}

function scrollToRange(range) {
  const rect = range.getBoundingClientRect();
  if (rect && rect.height > 0) {
    window.scrollTo({
      top: window.scrollY + rect.top - window.innerHeight / 2,
      behavior: "smooth",
    });
    return;
  }
  const el =
    range.startContainer.nodeType === 1
      ? range.startContainer
      : range.startContainer.parentElement;
  if (el) el.scrollIntoView({ behavior: "smooth", block: "center" });
}

function flashRange(range) {
  ensureStyle();
  clearHighlight();

  let painted = false;
  // Preferred: CSS Custom Highlight API paints arbitrary (cross-node) ranges with no
  // DOM surgery. Available in the modern WebKit that backs WKWebView on macOS.
  if (window.CSS && CSS.highlights && window.Highlight) {
    try {
      CSS.highlights.set(HL_NAME, new Highlight(range));
      painted = true;
    } catch (e) {
      painted = false;
    }
  }
  // Fallback: tint the containing block element.
  if (!painted) {
    const node =
      range.startContainer.nodeType === 1
        ? range.startContainer
        : range.startContainer.parentElement;
    const block =
      node &&
      node.closest("p,li,blockquote,h1,h2,h3,h4,h5,h6,td,th,dd,dt,figcaption,pre,div");
    if (block) block.classList.add("oak-cite-hl");
  }

  scrollToRange(range);
  if (clearTimer) clearTimeout(clearTimer);
  clearTimer = setTimeout(clearHighlight, 3000);
  return true;
}

// payload: JSON-encoded W3C TextQuoteSelector — { exact, prefix?, suffix? }.
// Returns true when a passage was located and flashed, false otherwise (so the
// native caller can fall back). prefix/suffix are optional context that disambiguate
// when `exact` occurs more than once; `exact` alone still fuzzy-matches.
window.oakHighlightCitation = function (payload) {
  try {
    const sel = typeof payload === "string" ? JSON.parse(payload) : payload;
    if (!sel || !sel.exact) return false;
    const root = document.querySelector(".heti") || document.body;
    const range = toRange(root, {
      exact: sel.exact,
      prefix: sel.prefix,
      suffix: sel.suffix,
    });
    if (!range) return false;
    return flashRange(range);
  } catch (e) {
    return false;
  }
};
