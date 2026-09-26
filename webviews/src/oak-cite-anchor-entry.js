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

// Candidate roots to anchor within, narrowest-first. Scoping to the readable
// article (when one exists) matters for two reasons: (1) on a live page like a
// GitHub repo, `document.body` also holds nav / sidebar / comment chrome whose
// text dilutes diff-match-patch's Bitap match and invites false hits; (2) the
// library sizes its fuzzy search distance to the root's text length, so a tighter
// root means a tighter, more accurate match. We still fall through to body so a
// quote outside any recognized container can be found.
function candidateRoots() {
  const roots = [];
  const heti = document.querySelector(".heti"); // OakReader's reader-mode clip
  if (heti) roots.push(heti);
  // Common readable-article containers across the live web.
  const sel =
    "article, main, [role='main'], .markdown-body, #readme, .post, .entry-content, #content";
  document.querySelectorAll(sel).forEach((el) => {
    // Skip tiny decorative <article> tags (cards, asides); keep substantial prose.
    if (el.textContent && el.textContent.length > 200 && !roots.includes(el)) {
      roots.push(el);
    }
  });
  roots.push(document.body);
  return roots;
}

// Progressively shorter leading spans of the quote, longest first. The model
// sometimes appends a synthesized tail to a real sentence (e.g. it flattens a
// results table into prose: a true leading clause followed by stitched-together
// numbers that appear nowhere contiguously). Anchoring the leading clause still
// lands the reader on the right passage. Bounded to a few candidates so this
// stays cheap even on large pages.
function leadingSubSpans(exact) {
  const out = [];
  const push = (s) => {
    const t = s && s.trim();
    if (t && t.length >= 20 && !out.includes(t)) out.push(t);
  };
  const sentence = exact.match(/^[^.!?]{20,}[.!?]/); // up to first sentence end
  if (sentence) push(sentence[0]);
  const clause = exact.match(/^[^,;:—(]{20,}/); // up to first clause break
  if (clause) push(clause[0]);
  const words = exact.split(/\s+/).filter(Boolean);
  if (words.length > 12) push(words.slice(0, 12).join(" "));
  return out.sort((a, b) => b.length - a.length);
}

function anchorIn(root, sel) {
  try {
    return toRange(root, sel);
  } catch (e) {
    return null;
  }
}

// payload: JSON-encoded W3C TextQuoteSelector — { exact, prefix?, suffix? }.
// Returns true when a passage was located and flashed, false otherwise (so the
// native caller can fall back). prefix/suffix are optional context that disambiguate
// when `exact` occurs more than once; `exact` alone still fuzzy-matches.
window.oakHighlightCitation = function (payload) {
  try {
    const sel = typeof payload === "string" ? JSON.parse(payload) : payload;
    if (!sel || !sel.exact) return false;
    const roots = candidateRoots();

    // Pass 1 — the full quote, narrowest root first.
    for (const root of roots) {
      const range = anchorIn(root, {
        exact: sel.exact,
        prefix: sel.prefix,
        suffix: sel.suffix,
      });
      if (range) return flashRange(range);
    }

    // Pass 2 — longest leading sub-span (handles synthesized/table-flattened tails).
    for (const sub of leadingSubSpans(sel.exact)) {
      for (const root of roots) {
        const range = anchorIn(root, { exact: sub, prefix: sel.prefix });
        if (range) return flashRange(range);
      }
    }
    return false;
  } catch (e) {
    return false;
  }
};
