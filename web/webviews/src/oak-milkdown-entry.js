// Standalone entry bundled (via rollup.milkdown.config.js) into a plain IIFE the
// OakReader native app injects into a WKWebView to edit a Markdown note with a
// WYSIWYG ("what you see is what you get") surface — the flomo-style capture box
// in the right-panel Notes stream.
//
// Editor: Milkdown Crepe (offline, framework-agnostic). The note's markdown is
// seeded as the default value; every edit posts the serialized markdown (and the
// content height, for native auto-grow) back through the `oakMilkdown` message
// handler. Storage stays plain markdown — Crepe round-trips it.
//
// The native panel renders the flomo toolbar (#, image, Aa, lists, @) below the
// webview and drives the editor through `window.oakMilkdown.cmd(name)` /
// `insertImage(url)`, so the toolbar matches the reference while the editing
// surface stays true WYSIWYG.
//
// Crepe's stylesheet is built separately into oak-milkdown.css (build:milkdown)
// and inlined alongside this bundle by the Swift host, exactly as oak-mindmap.css
// is — so this JS carries no CSS itself.
import { Crepe, CrepeFeature } from "@milkdown/crepe";
import { editorViewCtx } from "@milkdown/kit/core";
import { callCommand } from "@milkdown/kit/utils";
import {
  toggleStrongCommand,
  toggleEmphasisCommand,
  toggleInlineCodeCommand,
  wrapInBulletListCommand,
  wrapInOrderedListCommand,
  wrapInHeadingCommand,
  insertImageCommand,
} from "@milkdown/kit/preset/commonmark";

let crepe = null;

function post(payload) {
  try {
    window.webkit.messageHandlers.oakMilkdown.postMessage(payload);
  } catch (e) {
    /* no native bridge (e.g. a plain browser preview) */
  }
}

function isEmptyMarkdown(md) {
  return !md || md.trim().length === 0;
}

function reportState(md) {
  // Char count mirrors flomo's footer — count the *visible* text (the doc's
  // textContent), not the markdown syntax.
  let count = md ? md.length : 0;
  withEditor((ctx) => {
    try {
      count = ctx.get(editorViewCtx).state.doc.textContent.length;
    } catch (e) {
      /* ignore */
    }
  });
  post({ type: "markdown", empty: isEmptyMarkdown(md), count });
  reportHeight();
}

function reportHeight() {
  const pm = document.querySelector(".ProseMirror");
  if (pm) post({ type: "height", value: Math.ceil(pm.scrollHeight) });
}

function withEditor(fn) {
  if (!crepe) return;
  try {
    crepe.editor.action(fn);
  } catch (e) {
    /* editor not ready */
  }
}

function focusEditor() {
  withEditor((ctx) => {
    try {
      ctx.get(editorViewCtx).focus();
    } catch (e) {
      /* ignore */
    }
  });
}

function run(commandKey, payload) {
  withEditor(callCommand(commandKey, payload));
  focusEditor();
}

function insertText(text) {
  withEditor((ctx) => {
    const view = ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.insertText(text));
    view.focus();
  });
}

// Toolbar verbs the native flomo bar dispatches through cmd(name).
const COMMANDS = {
  bold: () => run(toggleStrongCommand.key),
  italic: () => run(toggleEmphasisCommand.key),
  code: () => run(toggleInlineCodeCommand.key),
  heading: () => run(wrapInHeadingCommand.key, 2),
  bulletList: () => run(wrapInBulletListCommand.key),
  orderedList: () => run(wrapInOrderedListCommand.key),
  tag: () => insertText("#"),
  mention: () => insertText("@"),
};

async function build(markdown, editable) {
  const root = document.getElementById("editor");
  if (!root) return false;

  crepe = new Crepe({
    root,
    defaultValue: markdown || "",
    // A focused note surface: keep inline formatting, lists, links and the slash
    // menu; drop the heavier blocks (code editor, tables, block images, LaTeX,
    // AI, the document top bar) a short note never needs. Also drop the floating
    // selection toolbar — formatting lives in the native bottom bar (Slack-style),
    // so the popover would just duplicate it. Inline images still work via the
    // commonmark preset + the bottom bar's insertImage bridge.
    features: {
      [CrepeFeature.AI]: false,
      [CrepeFeature.Latex]: false,
      [CrepeFeature.Table]: false,
      [CrepeFeature.ImageBlock]: false,
      [CrepeFeature.CodeMirror]: false,
      [CrepeFeature.TopBar]: false,
      [CrepeFeature.Toolbar]: false,
    },
    featureConfigs: {
      [CrepeFeature.Placeholder]: { text: "Jot a thought…", mode: "doc" },
    },
  });

  crepe.on((api) => {
    api.markdownUpdated((_ctx, md) => reportState(md));
  });

  await crepe.create();
  if (!editable) crepe.setReadonly(true);

  // ⌘↩ / Ctrl+↩ submits, matching the native send button.
  root.addEventListener(
    "keydown",
    (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault();
        post({ type: "submit" });
      }
    },
    true
  );

  try {
    root.querySelector(".ProseMirror")?.focus();
  } catch (e) {
    /* ignore */
  }
  reportState(crepe.getMarkdown());
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

  // Reset to an empty editor (after a note is sent).
  clear() {
    return this.init("", true);
  },

  focus() {
    focusEditor();
  },

  // Dispatch a flomo-toolbar verb (see COMMANDS).
  cmd(name) {
    const fn = COMMANDS[name];
    if (fn) fn();
  },

  // Insert a (native-persisted) inline image at the caret.
  insertImage(src) {
    if (!src) return;
    run(insertImageCommand.key, { src });
  },
};
