// Standalone entry bundled (via rollup.mindmap.config.js) into a plain IIFE the
// OakReader native app injects into a WKWebView to render / edit an AI-generated
// mind map with an XMind-like aesthetic.
//
// Renderer: Mind Elixir (offline, framework-agnostic). Math is rendered with
// KaTeX through Mind Elixir's `markdown` hook ($…$ inline, $$…$$ display).
//
// The artifact "body" we render/persist is DUAL-FORMAT:
//   • A 2-space indented bullet OUTLINE — what the generator streams; leaves may
//     carry a verbatim source quote `⟪…⟫` used for read-only jump-to-source.
//   • A Mind Elixir JSON object (getDataString) — what we persist once the map is
//     hand-edited, so per-node images / comments / math / structure survive
//     losslessly. Detected on read by a leading `{`. The `⟪…⟫` anchor migrates
//     into `node.metadata.anchor` so jump-to-source keeps working after editing.
//
// Hooks exposed on window.oakMindmap:
//   render(body, editable)   – build the map (auto-detects outline vs JSON). In
//                              editable mode every edit posts the new JSON body
//                              to native via the `oakMindmap` message handler.
//   update(outline)          – re-render from a (partial) OUTLINE; used to stream
//                              the map in live as it generates. Never JSON.
//   getData()                – serialize the current map to a JSON body string.
//   getOutline()             – legacy, lossy: serialize back to outline text.
//   setEditable(bool)        – flip read-only ↔ editable in place (keeps content).
//   openNote()               – open the comment popover for the selected node.
//   addImageToSelected(url)  – attach an image (data URL) to the selected node.
//   addChildToSelected()     – add a child to the selected node.
//   fit() / applyTheme() / setLayout(dir) / exportImage(fmt) – view controls.
import MindElixir from "mind-elixir";
import { mindElixirToPlaintext } from "mind-elixir/plaintextConverter";
import katex from "katex";

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

function theme() {
  return { ...OAK_PAPER, palette: isDark() ? OAK_PALETTE_DARK : OAK_PALETTE_LIGHT };
}

// True when native has flagged the host for dark appearance.
function isDark() {
  return document.body.classList.contains("oak-dark");
}

let mind = null;
let isEditable = false;
// id -> source anchor (a verbatim quote from the document) for the read-only
// "jump to source" affordance. Rebuilt on every body parse.
let anchorById = {};
let nodeSeq = 0;

function postNative(payload) {
  try {
    window.webkit.messageHandlers.oakMindmap.postMessage(payload);
  } catch (e) {
    /* no native bridge (e.g. preview) */
  }
}

// MARK: - Math (KaTeX via the Mind Elixir `markdown` hook)

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function renderMath(tex, display) {
  try {
    return katex.renderToString(tex, { displayMode: display, throwOnError: false, output: "html" });
  } catch (e) {
    return escapeHtml(display ? "$$" + tex + "$$" : "$" + tex + "$");
  }
}

// Render a node label to HTML: KaTeX for $…$ / $$…$$, everything else escaped.
// Deliberately minimal (no full markdown) — labels are short phrases. A lone /
// half-streamed `$` simply fails to match and renders as a literal dollar sign.
function oakMarkdown(md) {
  const src = String(md == null ? "" : md);
  const re = /\$\$([\s\S]+?)\$\$|\$([^$\n]+?)\$/g;
  let out = "";
  let last = 0;
  let m;
  while ((m = re.exec(src))) {
    out += escapeHtml(src.slice(last, m.index));
    out += m[1] != null ? renderMath(m[1], true) : renderMath(m[2], false);
    last = re.lastIndex;
  }
  out += escapeHtml(src.slice(last));
  return out;
}

// MARK: - Layout / decoration

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
// greyed text), `oak-anchored` (carries a source quote → jump-to-source dot) and
// `oak-noted` (carries a comment → note dot). Keyed off the `nodeObj` ME hangs on
// each `me-tpc`, so it's robust to depth.
function markAnchored() {
  document.querySelectorAll(".map-container me-tpc").forEach((el) => {
    const obj = el.nodeObj || (el.parentElement && el.parentElement.nodeObj);
    const id = obj && obj.id;
    const leaf = !!obj && !obj.root && !(obj.children && obj.children.length);
    el.classList.toggle("oak-leaf", leaf);
    el.classList.toggle("oak-anchored", !!(id && anchorById[id]));
    el.classList.toggle("oak-noted", !!(obj && obj.note));
  });
}

// MARK: - Body parsing (dual-format: outline OR Mind Elixir JSON)

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
// recording each node's source anchor in `anchorById` AND on `node.metadata` so
// it survives a later save to JSON.
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
    const node = { id, topic, children: [] };
    if (anchor) {
      anchorById[id] = anchor;
      node.metadata = { anchor };
    }
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

function rebuildAnchorsFromTree(node) {
  if (!node) return;
  const a = node.metadata && node.metadata.anchor;
  if (a) anchorById[node.id] = a;
  (node.children || []).forEach(rebuildAnchorsFromTree);
}

// A JSON body starts with `{`. We still require a successful parse with a
// `nodeData` root before trusting it — an outline that happens to start with `{`
// (won't, but defensively) falls back to outline parsing.
function parseBody(body) {
  anchorById = {};
  const s = String(body || "");
  if (/^\s*\{/.test(s)) {
    try {
      const data = JSON.parse(s);
      if (data && data.nodeData) {
        rebuildAnchorsFromTree(data.nodeData);
        delete data.theme; // our live theme (light/dark) wins over any saved one
        return data;
      }
    } catch (e) {
      /* fall through to outline */
    }
  }
  return dataFromOutline(s);
}

// MARK: - Comment (note) popover — an in-bundle editor positioned over a node.

let noteBox = null;
let noteArea = null;

function ensureNoteBox() {
  if (noteBox) return;
  noteBox = document.createElement("div");
  noteBox.id = "oak-note";
  noteBox.style.display = "none";
  const close = document.createElement("button");
  close.className = "oak-note-close";
  close.type = "button";
  close.textContent = "✕";
  close.addEventListener("click", hideNote);
  noteArea = document.createElement("textarea");
  noteArea.placeholder = "Add a comment…";
  noteArea.addEventListener("blur", commitNote);
  noteArea.addEventListener("keydown", (e) => {
    if (e.key === "Escape") { hideNote(); }
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); commitNote(); hideNote(); }
  });
  noteBox.appendChild(close);
  noteBox.appendChild(noteArea);
  document.body.appendChild(noteBox);
}

function commitNote() {
  if (!mind || !mind.currentNode || !noteArea) return;
  const val = noteArea.value.trim();
  const cur = mind.currentNode.nodeObj || {};
  if ((cur.note || "") === val) return;
  try { mind.reshapeNode(mind.currentNode, { note: val || undefined }); } catch (e) {}
}

function showNoteFor(tpc) {
  if (!tpc) return;
  ensureNoteBox();
  const obj = tpc.nodeObj || {};
  noteArea.value = obj.note || "";
  const r = tpc.getBoundingClientRect();
  noteBox.style.display = "block";
  const top = Math.min(r.bottom + 8, window.innerHeight - 150);
  const left = Math.min(r.left, window.innerWidth - 270);
  noteBox.style.top = Math.max(8, top) + "px";
  noteBox.style.left = Math.max(8, left) + "px";
  noteArea.focus();
}

function hideNote() {
  if (noteBox) noteBox.style.display = "none";
}

// MARK: - Images (paste + drop, recompressed to keep the JSON body small).

function fileToDataURL(file) {
  return new Promise((resolve) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => resolve(null);
    reader.readAsDataURL(file);
  });
}

// Downscale to <= maxDim and re-encode (webp, jpeg fallback) so a pasted screen
// grab doesn't bloat the persisted JSON body to hundreds of KB.
function recompress(dataURL, maxDim) {
  return new Promise((resolve) => {
    const img = new Image();
    img.onload = () => {
      const scale = Math.min(1, maxDim / Math.max(img.width, img.height));
      const width = Math.max(1, Math.round(img.width * scale));
      const height = Math.max(1, Math.round(img.height * scale));
      const canvas = document.createElement("canvas");
      canvas.width = width;
      canvas.height = height;
      canvas.getContext("2d").drawImage(img, 0, 0, width, height);
      let url = "";
      try { url = canvas.toDataURL("image/webp", 0.8); } catch (e) {}
      if (url.indexOf("data:image/webp") !== 0) url = canvas.toDataURL("image/jpeg", 0.85);
      resolve({ url, width, height });
    };
    img.onerror = () => resolve(null);
    img.src = dataURL;
  });
}

async function attachImage(tpc, dataURL) {
  if (!tpc || !dataURL) return;
  const im = await recompress(dataURL, 260);
  if (!im) return;
  try {
    mind.reshapeNode(tpc, { image: { url: im.url, width: im.width, height: im.height, fit: "contain" } });
  } catch (e) {}
}

function topicAtPoint(x, y) {
  const at = document.elementFromPoint(x, y);
  const tp = at && at.closest && at.closest("me-tpc");
  return tp && tp.nodeObj ? tp : null;
}

function wireImageDrop(el) {
  // The #map element persists across setEditable() re-renders, so guard against
  // stacking duplicate listeners (which would attach a dropped image N times).
  if (el.__oakDropWired) return;
  el.__oakDropWired = true;
  el.addEventListener("dragover", (e) => { e.preventDefault(); });
  el.addEventListener("drop", (e) => {
    const files = e.dataTransfer && e.dataTransfer.files;
    if (!files || !files.length) return;
    const file = Array.prototype.find.call(files, (f) => f.type && f.type.indexOf("image") === 0);
    if (!file) return;
    e.preventDefault();
    const tpc = topicAtPoint(e.clientX, e.clientY) || mind.currentNode;
    fileToDataURL(file).then((u) => attachImage(tpc, u));
  });
}

// MARK: - Save (editable edits round-trip to native as a JSON body).

let saveTimer = null;
function scheduleSave() {
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    saveTimer = null;
    postNative({ data: window.oakMindmap.getData() });
  }, 250);
}

// MARK: - Public API

window.oakMindmap = {
  render(body, editable) {
    const el = document.getElementById("map");
    if (!el) return false;
    el.innerHTML = "";
    hideNote();
    isEditable = !!editable;
    mind = new MindElixir({
      el,
      direction: MindElixir.RIGHT,
      editable: isEditable,
      draggable: isEditable,
      contextMenu: isEditable,
      // Mind Elixir's own floating toolbar (zoom in/out, center, layout/expand)
      // — the XMind-like control cluster, shown only when editing.
      toolBar: isEditable,
      keypress: isEditable,
      allowUndo: isEditable,
      markdown: oakMarkdown,
      pasteHandler: (e) => {
        const items = (e.clipboardData && e.clipboardData.items) || [];
        for (const it of items) {
          if (it.type && it.type.indexOf("image") === 0) {
            const file = it.getAsFile();
            if (file) {
              e.preventDefault();
              fileToDataURL(file).then((u) => attachImage(mind.currentNode, u));
              return;
            }
          }
        }
      },
      theme: theme(),
    });
    mind.init(parseBody(body));
    if (isEditable) wireImageDrop(el);
    fit();

    if (mind.bus) {
      mind.bus.addListener("selectNewNode", (nodeObj) => {
        if (isEditable) {
          // Surface an existing comment when its node is selected; adding a new
          // one is the toolbar's Note button (→ openNote).
          if (nodeObj && nodeObj.note) showNoteFor(mind.currentNode);
          else hideNote();
          return;
        }
        const anchor = nodeObj && anchorById[nodeObj.id];
        if (anchor) postNative({ action: "nodeClick", anchor });
      });
      if (isEditable) {
        mind.bus.addListener("operation", () => {
          scheduleSave();
          requestAnimationFrame(markAnchored);
        });
      }
    }
    return true;
  },

  // Stream a (partial) OUTLINE into the read-only map as it generates.
  update(outline) {
    if (!mind) return this.render(outline, false);
    try {
      mind.refresh(dataFromOutline(outline));
      fit();
    } catch (e) {
      /* keep last good render */
    }
  },

  // Lossless JSON body for persistence.
  getData() {
    if (!mind) return "";
    try { return mind.getDataString(); } catch (e) { return ""; }
  },

  // Legacy, lossy: drops images / notes / math markup. Not the editor save path.
  getOutline() {
    if (!mind) return "";
    try { return mindElixirToPlaintext(mind.getData()); } catch (e) { return ""; }
  },

  // Flip read-only ↔ editable in place, preserving the current map (incl. edits).
  setEditable(editable) {
    if (!mind) return;
    let data;
    try { data = mind.getDataString(); } catch (e) { return; }
    this.render(data, !!editable);
  },

  // Open the comment popover for the selected node (toolbar Note button).
  openNote() {
    if (mind && mind.currentNode) showNoteFor(mind.currentNode);
  },

  // Attach an image (data URL, e.g. from a native open panel) to the selection.
  addImageToSelected(dataURL) {
    if (mind && mind.currentNode) attachImage(mind.currentNode, dataURL);
  },

  // Add a child to the selected node (toolbar + node).
  addChildToSelected() {
    if (!mind) return;
    try { mind.addChild(); } catch (e) {}
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
      mind.theme = theme();
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
        postNative({ action: "export", format, dataURL: reader.result });
      };
      reader.readAsDataURL(blob);
    } catch (e) {}
  },
};
