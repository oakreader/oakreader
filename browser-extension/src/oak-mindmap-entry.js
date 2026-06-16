// Standalone entry bundled (via rollup.mindmap.config.js) into a plain IIFE the
// OakReader native app injects into a WKWebView to render / edit an AI-generated
// mind map with an XMind-like aesthetic.
//
// Renderer: Mind Elixir (offline, framework-agnostic). We feed it the indented
// "plaintext" outline the generator streams; Mind Elixir's own converters handle
// outline <-> data both ways, so editing round-trips back to an outline that we
// persist as the artifact body.
//
// Hooks exposed on window.oakMindmap:
//   render(outline, editable)  – build the map; in editable mode, every edit
//                                posts the new outline to native via the
//                                `oakMindmap` message handler.
//   update(outline)            – re-render from a (possibly partial) outline,
//                                used to stream the map in live as it generates.
//   getOutline()               – serialize the current map back to outline text.
import MindElixir from "mind-elixir";
import { mindElixirToPlaintext } from "mind-elixir/plaintextConverter";

// "Oak Paper": quiet white paper chips on a warm canvas; color lives in the
// EDGES (Mind Elixir's `palette` colors each branch's lines, not its node fill),
// hierarchy comes from size/weight/ink — not from painting node backgrounds.
// Hue order rotates ~90–135° per sibling so adjacent branches never read as
// related. Dark variant lifts the hues ~12% so strokes glow on charcoal.
const OAK_PALETTE_LIGHT = [
  "#3B82C4", "#E08A3C", "#3FA85F", "#9B59C6",
  "#D9527E", "#2FA79B", "#C0506B", "#5B6BD6",
];
const OAK_PALETTE_DARK = [
  "#5BA3E0", "#F0A05A", "#5FC47E", "#B97AE0",
  "#EE7AA0", "#4FC7B8", "#E0708A", "#8090F0",
];

const OAK_PAPER = {
  name: "OakPaper",
  type: "light",
  palette: OAK_PALETTE_LIGHT,
  cssVar: {
    "--main-color": "#26282C",   // spine ink — dark, high contrast
    "--main-bgcolor": "#FFFFFF",  // spine chip — pure white floats on warm paper
    "--main-border": "1px solid rgba(0,0,0,0.08)", // hairline, not ME's 2px ring
    "--color": "#5B6068",         // leaf ink — greyed, recedes vs spine
    "--bgcolor": "#FBFBFA",       // leaf/canvas — leaves dissolve into text
    "--root-color": "#FBFBFA",
    "--root-bgcolor": "#2B2D31",  // charcoal anchor — the one heavy element
    "--root-border-color": "#2B2D31",
    "--root-radius": "16px",
    "--main-radius": "10px",
    "--topic-padding": "7px 13px", // text-shaped chip, roomier horizontal
    "--main-gap-x": "54px",        // long edges so bezier curvature reads
    "--main-gap-y": "16px",
    "--node-gap-x": "30px",
    "--node-gap-y": "7px",
    "--map-padding": "64px",
  },
};

// True when native has flagged the host for dark appearance.
function isDark() {
  return document.body.classList.contains("oak-dark");
}

let mind = null;
// id -> source anchor (a verbatim quote from the document) for the read-only
// "jump to source" affordance. Rebuilt on every outline parse.
let anchorById = {};
let nodeSeq = 0;

// Scale the whole map to fit the viewport (and re-center). Deferred a frame so
// Mind Elixir has finished laying out after init/refresh.
function fit() {
  if (!mind) return;
  requestAnimationFrame(() => {
    try {
      mind.scaleFit();
    } catch (e) {
      try { mind.toCenter(); } catch (e2) {}
    }
    markAnchored();
  });
}

// Tag rendered nodes so CSS can style them: `oak-leaf` (no children → quiet
// greyed text) and `oak-anchored` (carries a source quote → jump-to-source
// affordance). Keyed off `nodeObj` ME hangs on each topic wrapper, so it's
// robust to outline depth (a 2-level map still distinguishes spine vs leaf).
function markAnchored() {
  document.querySelectorAll(".map-container me-tpc").forEach((el) => {
    const obj = el.parentElement && el.parentElement.nodeObj;
    const id = obj && obj.id;
    const leaf = !!obj && !obj.root && !(obj.children && obj.children.length);
    el.classList.toggle("oak-leaf", leaf);
    el.classList.toggle("oak-anchored", !!(id && anchorById[id]));
  });
}

// Split a trailing source anchor `⟪…⟫` off a node label, returning
// { topic, anchor }. Tolerates a half-streamed `⟪…` (no closing bracket yet):
// the partial is hidden and no anchor is recorded until it finishes.
function splitAnchor(text) {
  const m = text.match(/⟪([^⟫]*)⟫\s*$/);
  if (m) return { topic: text.slice(0, m.index).trim(), anchor: m[1].trim() };
  const open = text.indexOf("⟪");
  if (open !== -1) return { topic: text.slice(0, open).trim(), anchor: "" };
  return { topic: text.trim(), anchor: "" };
}

// Parse the indented bullet outline (2-space nesting) into Mind Elixir data,
// recording each node's source anchor in `anchorById`. Replaces Mind Elixir's
// own plaintext converter so we can carry per-node anchors the generator emits.
function dataFromOutline(outline) {
  anchorById = {};
  nodeSeq = 0;
  let root = null;
  const stack = []; // [{ level, node }]
  for (const raw of String(outline || "").split("\n")) {
    const m = raw.match(/^(\s*)[-*]\s+(.*\S)\s*$/);
    if (!m) continue;
    const level = Math.floor(m[1].replace(/\t/g, "  ").length / 2);
    const { topic, anchor } = splitAnchor(m[2]);
    if (!topic) continue;
    const id = "n" + nodeSeq++;
    if (anchor) anchorById[id] = anchor;
    const node = { id, topic, children: [] };
    if (!root) {
      node.root = true;
      root = node;
      stack.length = 0;
      stack.push({ level, node });
      continue;
    }
    while (stack.length > 1 && stack[stack.length - 1].level >= level) stack.pop();
    stack[stack.length - 1].node.children.push(node);
    stack.push({ level, node });
  }
  if (!root) return MindElixir.new("Mind Map");
  return { nodeData: root };
}

window.oakMindmap = {
  render(outline, editable) {
    const el = document.getElementById("map");
    if (!el) return false;
    mind = new MindElixir({
      el,
      direction: MindElixir.RIGHT,
      editable: !!editable,
      draggable: !!editable,
      contextMenu: !!editable,
      // Mind Elixir's own floating toolbar (zoom in/out, center, layout/expand)
      // — the XMind-like control cluster, shown only in the full-screen editor.
      toolBar: !!editable,
      keypress: !!editable,
      allowUndo: !!editable,
      theme: { ...OAK_PAPER, palette: isDark() ? OAK_PALETTE_DARK : OAK_PALETTE_LIGHT },
    });
    mind.init(dataFromOutline(outline));
    fit();
    // Read-only: clicking a node jumps to the source passage it was drawn from.
    if (!editable && mind.bus) {
      mind.bus.addListener("selectNode", (node) => {
        const id = node && node.id;
        const anchor = id ? anchorById[id] : "";
        if (!anchor) return;
        try {
          window.webkit.messageHandlers.oakMindmap.postMessage({
            action: "nodeClick",
            anchor,
          });
        } catch (e) {
          /* no native bridge (e.g. preview) */
        }
      });
    }
    if (editable && mind.bus) {
      mind.bus.addListener("operation", () => {
        try {
          window.webkit.messageHandlers.oakMindmap.postMessage({
            outline: window.oakMindmap.getOutline(),
          });
        } catch (e) {
          /* no native bridge (e.g. preview) */
        }
      });
    }
    return true;
  },

  update(outline) {
    if (!mind) return this.render(outline, false);
    try {
      mind.refresh(dataFromOutline(outline));
      fit();
    } catch (e) {
      /* keep last good render */
    }
  },

  getOutline() {
    if (!mind) return "";
    try {
      return mindElixirToPlaintext(mind.getData());
    } catch (e) {
      return "";
    }
  },

  // Re-fit the whole map to the viewport.
  fit() {
    fit();
  },

  // Re-point the edge palette when native flips light/dark appearance (node
  // colors flip via CSS vars on `body.oak-dark`; palette can't be a CSS var).
  applyTheme() {
    if (!mind) return;
    try {
      mind.theme = { ...OAK_PAPER, palette: isDark() ? OAK_PALETTE_DARK : OAK_PALETTE_LIGHT };
      mind.refresh();
      fit();
    } catch (e) {}
  },

  // Switch branch layout: 'right' (all branches to the right) or 'side' (split).
  setLayout(dir) {
    if (!mind) return;
    try {
      if (dir === "side") mind.initSide();
      else mind.initRight();
      fit();
    } catch (e) {}
  },

  // Export the current map as an image and hand the data URL to native, which
  // saves it via a Save dialog. format: 'png' | 'svg'.
  async exportImage(format) {
    if (!mind) return;
    try {
      const blob = format === "svg" ? mind.exportSvg() : await mind.exportPng();
      if (!blob) return;
      const reader = new FileReader();
      reader.onload = () => {
        try {
          window.webkit.messageHandlers.oakMindmap.postMessage({
            action: "export",
            format,
            dataURL: reader.result,
          });
        } catch (e) {}
      };
      reader.readAsDataURL(blob);
    } catch (e) {}
  },
};
