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
  linkSchema,
} from "@milkdown/kit/preset/commonmark";

// Make the link mark non-inclusive. ProseMirror marks are inclusive by default,
// so typing at the end of an autolinked URL keeps extending the link — type a URL
// then a space and a word, and the space + word stay underlined as part of the
// link. Non-inclusive ends the mark at the URL boundary, so anything you type
// after it is plain text (matching what a space visibly implies).
const nonInclusiveLink = linkSchema.extendSchema((prev) => (ctx) => ({
  ...prev(ctx),
  inclusive: false,
}));

let crepe = null;
// Observes the editor's content box so the native frame follows the real height
// the moment the browser commits layout — see attachHeightObserver.
let heightObserver = null;

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

// --- Active-format reporting -------------------------------------------------
// The native flomo toolbar fires *toggle* commands (bold, inline code, heading,
// lists). Without telling native which of those are currently ON at the caret,
// the user has no way to know that the same button will toggle the style back
// OFF — they'd press "code", land inside an inline-code span, and feel stuck.
// So on every selection/doc change we report which formats are active; native
// highlights the matching toolbar buttons (accent), making the toggle obvious.

function markActive(state, type) {
  if (!type) return false;
  const { from, to, empty, $from } = state.selection;
  if (empty) return !!type.isInSet(state.storedMarks || $from.marks());
  return state.doc.rangeHasMark(from, to, type);
}

// True when any ancestor of the caret is of `nodeType` (used for block-level
// styles: heading, bullet / ordered list).
function ancestorActive(state, nodeType) {
  if (!nodeType) return false;
  const { $from } = state.selection;
  for (let d = $from.depth; d >= 0; d--) {
    if ($from.node(d).type === nodeType) return true;
  }
  return false;
}

function reportFormat(state) {
  const m = state.schema.marks;
  const n = state.schema.nodes;
  post({
    type: "format",
    bold: markActive(state, m.strong),
    italic: markActive(state, m.emphasis),
    code: markActive(state, m.inlineCode || m.code),
    heading: ancestorActive(state, n.heading),
    bulletList: ancestorActive(state, n.bullet_list || n.bulletList),
    orderedList: ancestorActive(state, n.ordered_list || n.orderedList),
  });
}

// Re-report the active formats whenever the selection or document changes, so
// the native toolbar's highlight tracks the caret in real time.
const formatReporter = $prose(
  () =>
    new Plugin({
      key: new PluginKey("oak-format-reporter"),
      view() {
        return {
          update(view, prev) {
            if (
              view.state.selection.eq(prev.selection) &&
              view.state.doc.eq(prev.doc)
            )
              return;
            reportFormat(view.state);
          },
        };
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

// Drive auto-grow off the editor's actual layout, not the doc-edit signal. A
// ResizeObserver fires exactly when the browser commits a new content height —
// race-free (no stale pre-layout read) and for *every* cause: typing, wrapping,
// list/heading changes, a pasted image, a late font load. Measuring only on
// markdownUpdated missed the non-edit reflows and could double-bump; this owns
// height end-to-end so the native frame catches up once, smoothly.
function attachHeightObserver() {
  if (typeof ResizeObserver === "undefined") return;
  const el = document.querySelector(".milkdown") || document.querySelector(".ProseMirror");
  if (!el) return;
  if (heightObserver) heightObserver.disconnect();
  heightObserver = new ResizeObserver(() => reportHeight());
  heightObserver.observe(el);
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

// Tell native to open the tag picker, anchored at the caret (mirrors the `@`
// mention flow). Used by the `#` toolbar button and the typed-`#` trigger, so a
// tag is reused from the existing set instead of retyped (kills tag sprawl).
function postTagAnchor() {
  withEditor((ctx) => {
    const view = ctx.get(editorViewCtx);
    const payload = { type: "tag" };
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

// True when the caret is at a token boundary (start of block, or after
// whitespace) — so a typed `#` mid-word ("C#", "F#") doesn't open the picker.
function atTokenBoundary() {
  let boundary = true;
  withEditor((ctx) => {
    const sel = ctx.get(editorViewCtx).state.selection;
    if (sel.empty && sel.$from.parentOffset > 0) {
      const ch = sel.$from.parent.textBetween(sel.$from.parentOffset - 1, sel.$from.parentOffset);
      if (ch && !/\s/.test(ch)) boundary = false;
    }
  });
  return boundary;
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
  tag: () => {
    focusEditor();
    postTagAnchor();
  },
  mention: () => insertText("@"),
};

async function build(markdown, editable) {
  const root = document.getElementById("editor");
  if (!root) return false;

  crepe = new Crepe({
    root,
    defaultValue: markdown || "",
    // A focused note surface: keep inline formatting, lists and links; drop the
    // heavier blocks (code editor, tables, block images, LaTeX, AI, the document
    // top bar) a short note never needs. Also drop the floating selection toolbar —
    // formatting lives in the native bottom bar (Slack-style), so the popover would
    // just duplicate it. Inline images still work via the commonmark preset + the
    // bottom bar's insertImage bridge.
    //
    // BlockEdit is OFF: its `/` slash menu (and left block handle) popped an empty,
    // clipped panel inside this short auto-grow webview — ugly and pointless for a
    // capture box. Formatting/lists/tag/mention all live on the native toolbar.
    //
    // LinkTooltip is OFF: its copy/edit/delete popover is absolutely positioned
    // inside the webview, but this composer is a short auto-grow surface, so the
    // popover can't escape the painted bounds and clipped to an ugly sliver under
    // the link. Links still autolink (paste/type a URL) and round-trip as markdown
    // — a capture box doesn't need an in-place link editor.
    features: {
      [CrepeFeature.AI]: false,
      [CrepeFeature.Latex]: false,
      [CrepeFeature.Table]: false,
      [CrepeFeature.ImageBlock]: false,
      [CrepeFeature.CodeMirror]: false,
      [CrepeFeature.TopBar]: false,
      [CrepeFeature.Toolbar]: false,
      [CrepeFeature.LinkTooltip]: false,
      [CrepeFeature.BlockEdit]: false,
    },
    featureConfigs: {
      [CrepeFeature.Placeholder]: { text: "Jot a thought…", mode: "doc" },
    },
  });

  crepe.on((api) => {
    api.markdownUpdated((_ctx, md) => reportState(md));
  });

  crepe.editor.use(tagHighlight);
  crepe.editor.use(formatReporter);
  crepe.editor.use(nonInclusiveLink);
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
      // Typing `#` at a token boundary opens the tag picker (reuse an existing
      // tag → no sprawl). Mid-word `#` ("C#") is left alone. The `#` is consumed
      // by insertTag when a tag is picked.
      if (e.key === "#" && atTokenBoundary()) {
        setTimeout(postTagAnchor, 0);
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
  withEditor((ctx) => reportFormat(ctx.get(editorViewCtx).state));
  attachHeightObserver();

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
    if (heightObserver) {
      heightObserver.disconnect();
      heightObserver = null;
    }
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

  // Re-report the live content + height WITHOUT rebuilding the editor. Used when a
  // cached WKWebView is rebound to a freshly-created native composer (re-entering
  // the Notes tab): the editor is already booted, so we only resync the native
  // @State (empty / char count / height) instead of reloading — which is what
  // caused the visible boot+fade "flick" on every tab switch.
  resync() {
    if (!crepe) return false;
    reportState(this.getMarkdown());
    withEditor((ctx) => reportFormat(ctx.get(editorViewCtx).state));
    return true;
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

  // Open the tag picker from the toolbar button (focus + report caret).
  requestTag() {
    focusEditor();
    postTagAnchor();
  },

  // Insert a `#tag ` at the caret, consuming a just-typed `#` immediately before
  // the caret if present. Plain text (no space after `#`) so the tagHighlight
  // plugin colours it and NoteTags.extract picks it up; round-trips as markdown.
  insertTag(tag) {
    const clean = (tag || "").trim().replace(/^#+/, "");
    if (!clean) return;
    withEditor((ctx) => {
      const view = ctx.get(editorViewCtx);
      const { state } = view;
      const sel = state.selection;
      let from = sel.from;
      const to = sel.to;
      if (sel.empty && sel.$from.parentOffset > 0) {
        const ch = sel.$from.parent.textBetween(sel.$from.parentOffset - 1, sel.$from.parentOffset);
        if (ch === "#") from = sel.from - 1;
      }
      const node = state.schema.text(`#${clean} `);
      const tr = state.tr.replaceWith(from, to, node);
      view.dispatch(tr.scrollIntoView());
      view.focus();
    });
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
