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
import { plaintextToMindElixir, mindElixirToPlaintext } from "mind-elixir/plaintextConverter";

// An XMind-ish theme: dark rounded root bubble, white rounded branch nodes, a
// warm multi-color branch palette, generous spacing.
const XMIND_THEME = {
  name: "OakXMind",
  type: "light",
  palette: [
    "#2EA7E0", "#F5A623", "#7ED321", "#BD10E0",
    "#E0518A", "#50B5A8", "#F8556D", "#6C7BFE",
  ],
  cssVar: {
    "--main-color": "#1f2329",
    "--main-bgcolor": "#ffffff",
    "--color": "#3a3f47",
    "--bgcolor": "#ffffff",
    "--root-color": "#ffffff",
    "--root-bgcolor": "#2b3038",
    "--root-border-color": "#2b3038",
    "--root-radius": "20px",
    "--main-radius": "14px",
    "--topic-padding": "11px",
    "--main-gap-x": "46px",
    "--main-gap-y": "18px",
    "--node-gap-x": "26px",
    "--node-gap-y": "10px",
    "--map-padding": "70px",
  },
};

let mind = null;

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
  });
}

function dataFromOutline(outline) {
  const text = String(outline || "").trim();
  if (!text) return MindElixir.new("Mind Map");
  try {
    return plaintextToMindElixir(text, "Mind Map");
  } catch (e) {
    return MindElixir.new("Mind Map");
  }
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
      theme: XMIND_THEME,
    });
    mind.init(dataFromOutline(outline));
    fit();
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
