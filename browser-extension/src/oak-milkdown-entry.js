// Standalone entry bundled (via rollup.milkdown.config.js) into a plain IIFE the
// OakReader native app injects into a WKWebView to edit a Markdown note with a
// WYSIWYG ("what you see is what you get") surface.
//
// Editor: Milkdown Crepe (offline, framework-agnostic). The note's markdown is
// seeded as the default value; every edit posts the serialized markdown back to
// native via the `oakMilkdown` message handler, mirroring how oak-mindmap pushes
// its outline. Storage stays plain markdown — Crepe round-trips it.
//
// Crepe's stylesheet is built separately into oak-milkdown.css (see the
// build:milkdown script) and inlined alongside this bundle by MilkdownEditorView,
// exactly as oak-mindmap.css is — so this JS carries no CSS itself.
//
// Hooks exposed on window.oakMilkdown:
//   init(markdown, editable)  – build the editor seeded with `markdown`; in
//                               editable mode every change posts { markdown } to
//                               native. Returns a Promise<boolean>.
//   getMarkdown()             – serialize the current document back to markdown.
//   setMarkdown(markdown)     – rebuild the editor with new content (parity with
//                               oak-mindmap; the popup seeds via init instead).
import { Crepe, CrepeFeature } from "@milkdown/crepe";

let crepe = null;

function postMarkdown(md) {
  try {
    window.webkit.messageHandlers.oakMilkdown.postMessage({ markdown: md });
  } catch (e) {
    /* no native bridge (e.g. a plain browser preview) */
  }
}

async function build(markdown, editable) {
  const root = document.getElementById("editor");
  if (!root) return false;

  crepe = new Crepe({
    root,
    defaultValue: markdown || "",
    // A focused note surface: keep inline formatting, lists, links, the slash
    // menu and the selection toolbar; drop the heavier blocks (code editor,
    // tables, images, LaTeX, AI, the document top bar) a short note never needs.
    features: {
      [CrepeFeature.AI]: false,
      [CrepeFeature.Latex]: false,
      [CrepeFeature.Table]: false,
      [CrepeFeature.ImageBlock]: false,
      [CrepeFeature.CodeMirror]: false,
      [CrepeFeature.TopBar]: false,
    },
    featureConfigs: {
      [CrepeFeature.Placeholder]: { text: "Write a comment…", mode: "doc" },
    },
  });

  crepe.on((api) => {
    api.markdownUpdated((_ctx, md) => postMarkdown(md));
  });

  await crepe.create();
  if (!editable) crepe.setReadonly(true);

  // Take focus so the user can type immediately when the popup opens.
  try {
    root.querySelector(".ProseMirror")?.focus();
  } catch (e) {
    /* ignore */
  }
  return true;
}

window.oakMilkdown = {
  async init(markdown, editable) {
    if (crepe) {
      try {
        await crepe.destroy();
      } catch (e) {
        /* ignore */
      }
      crepe = null;
    }
    return build(markdown, editable);
  },

  getMarkdown() {
    if (!crepe) return "";
    try {
      return crepe.getMarkdown();
    } catch (e) {
      return "";
    }
  },

  setMarkdown(markdown) {
    return this.init(markdown, true);
  },
};
