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
// and inlined alongside this bundle by the Swift host — so this JS carries no
// CSS itself.
import { Crepe, CrepeFeature } from "@milkdown/crepe";
import { editorViewCtx } from "@milkdown/kit/core";
import { callCommand, $prose } from "@milkdown/kit/utils";
import { Plugin, PluginKey } from "@milkdown/kit/prose/state";
import { Decoration, DecorationSet } from "@milkdown/kit/prose/view";
import { Fragment } from "@milkdown/kit/prose/model";
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

// Highlight `#tags` inline (flomo-style accent text) as you type — a ProseMirror
// *decoration* only, so the serialized markdown stays plain `#welcome/guide` and
// round-trips untouched. Pattern mirrors the native `NoteTags` regex (token
// boundary, CJK, nested `a/b`). The `.oak-tag` color is themed by the Swift host.
const TAG_RE = /(?<!\S)#[\p{L}\p{N}_][\p{L}\p{N}_/-]*/gu;

function tagDecorations(doc) {
  const decos = [];
  doc.descendants((node, pos) => {
    if (!node.isText || !node.text) return;
    TAG_RE.lastIndex = 0;
    let m;
    while ((m = TAG_RE.exec(node.text)) !== null) {
      const from = pos + m.index;
      decos.push(Decoration.inline(from, from + m[0].length, { class: "oak-tag" }));
    }
  });
  return DecorationSet.create(doc, decos);
}

const tagHighlight = $prose(
  () =>
    new Plugin({
      key: new PluginKey("oak-tag-highlight"),
      state: {
        init: (_, { doc }) => tagDecorations(doc),
        apply: (tr, set) =>
          tr.docChanged ? tagDecorations(tr.doc) : set.map(tr.mapping, tr.doc),
      },
      props: {
        decorations(state) {
          return this.getState(state);
        },
      },
    })
);

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
  // Measure the editor's *content* element (auto-height), not `pm.scrollHeight`.
  // scrollHeight can't report smaller than its container, so when the page is
  // pinned to the native frame it only ever grows (a ratchet). The bounding box
  // of `.milkdown` tracks the real content height up and down.
  const el = document.querySelector(".milkdown") || document.querySelector(".ProseMirror");
  if (el) post({ type: "height", value: Math.ceil(el.getBoundingClientRect().height) });
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

// Tell native to open the memo-reference picker, anchored at the caret's viewport
// coords (so the dropdown sits next to the cursor, not the toolbar button).
function postMentionAnchor() {
  withEditor((ctx) => {
    const view = ctx.get(editorViewCtx);
    const payload = { type: "mention" };
    try {
      const c = view.coordsAtPos(view.state.selection.from);
      payload.left = c.left;
      payload.top = c.top;
      payload.bottom = c.bottom;
    } catch (e) {
      /* no coords — native falls back to a default anchor */
    }
    post(payload);
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

  crepe.editor.use(tagHighlight);
  await crepe.create();
  if (!editable) crepe.setReadonly(true);

  // ⌘↩ / Ctrl+↩ submits, matching the native send button.
  root.addEventListener(
    "keydown",
    (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault();
        post({ type: "submit" });
        return;
      }
      // Typing `@` opens the native memo-reference picker (flomo-style). The `@`
      // is left in place and consumed by insertReference when a memo is picked.
      // Defer one tick so the `@` is in the doc and the caret has advanced before
      // we measure its coords (so the dropdown anchors next to the cursor).
      if (e.key === "@") {
        setTimeout(postMentionAnchor, 0);
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

  // Reveal once layout has settled — avoids the blank→content flash/resize the
  // Notes tab showed on first appearance.
  requestAnimationFrame(() =>
    requestAnimationFrame(() => {
      document.body.classList.add("ready");
      reportHeight();
    })
  );
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

  // Open the memo-reference picker from the toolbar button (focus + report caret).
  requestMention() {
    focusEditor();
    postMentionAnchor();
  },

  // Insert a memo reference (a link + trailing space) at the caret, consuming a
  // just-typed trigger `@` immediately before the caret if present. Used by the
  // `@` picker for both the toolbar button and the typed-`@` trigger.
  insertReference(label, href) {
    if (!href) return;
    withEditor((ctx) => {
      const view = ctx.get(editorViewCtx);
      const { state } = view;
      const linkMark = state.schema.marks.link;
      const sel = state.selection;
      let from = sel.from;
      const to = sel.to;
      if (sel.empty && sel.$from.parentOffset > 0) {
        const ch = sel.$from.parent.textBetween(sel.$from.parentOffset - 1, sel.$from.parentOffset);
        if (ch === "@") from = sel.from - 1;
      }
      const text = label || href;
      const linkNode = state.schema.text(text, linkMark ? [linkMark.create({ href })] : null);
      const space = state.schema.text(" ");
      const tr = state.tr.replaceWith(from, to, Fragment.fromArray([linkNode, space]));
      view.dispatch(tr.scrollIntoView());
      view.focus();
    });
  },

  // Insert a (native-persisted) inline image at the caret.
  insertImage(src) {
    if (!src) return;
    run(insertImageCommand.key, { src });
  },
};
