// OakReader note editor — Milkdown Crepe WYSIWYG, hosted in a WKWebView.
//
// This is the production entry (the AI-proofread demo lives in git history).
// It mirrors the bridge pattern of NotePreviewView.swift / MilkdownEditorView.swift:
//   JS -> Swift : window.webkit.messageHandlers.<name>.postMessage(body)
//   Swift -> JS : evaluateJavaScript("window.oakEditor.<fn>(...)")
//
// Source of truth is Markdown. Crepe edits WYSIWYG and emits clean Markdown on
// every change; Swift persists it through NotesViewModel's debounced autosave.

import { Crepe } from '@milkdown/crepe'
import { editorViewCtx, commandsCtx } from '@milkdown/kit/core'
import { replaceAll, $prose } from '@milkdown/kit/utils'
import { Plugin, PluginKey } from '@milkdown/kit/prose/state'
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view'

import '@milkdown/crepe/theme/common/style.css'
import './type-theme.css'

// --- Swift bridge --------------------------------------------------------
type WK = { messageHandlers?: Record<string, { postMessage: (b: unknown) => void }> }
const webkit = (window as unknown as { webkit?: WK }).webkit
function post(name: string, body: unknown) {
  webkit?.messageHandlers?.[name]?.postMessage(body)
}
function log(msg: string) {
  post('log', msg)
}

// Notes directory injected by Swift before the bundle loads, e.g.
//   window.__OAK_NOTES_BASE__ = "file:///Users/.../OakReader/notes/"
function notesBase(): string {
  return (window as unknown as { __OAK_NOTES_BASE__?: string }).__OAK_NOTES_BASE__ ?? ''
}

// Body font (a CSS font-family stack) injected by Swift; empty = theme default.
function noteFont(): string {
  return (window as unknown as { __OAK_NOTE_FONT__?: string }).__OAK_NOTE_FONT__ ?? ''
}

// Override the theme's --type-font-main on the .milkdown element (inline style
// beats the theme rule + [data-font] presets). Empty restores the theme serif.
function applyFont(css: string) {
  const el = document.querySelector('.milkdown') as HTMLElement | null
  if (!el) return
  if (css) el.style.setProperty('--type-font-main', css)
  else el.style.removeProperty('--type-font-main')
}

// --- AI provider: stream chunks from OakAI through Swift -----------------
// Crepe's AIProvider is `(ctx, signal) => AsyncIterable<string>`. We turn the
// Swift push-based stream (aiChunk/aiDone/aiError callbacks) into that pull-based
// async generator using a tiny queue + wake latch.
interface AIStream {
  push: (s: string) => void
  done: () => void
  error: (m: string) => void
}
let aiSeq = 0
const aiStreams = new Map<number, AIStream>()

const aiProvider = async function* (
  ctx: { document: string; selection: string; instruction: string },
  signal: AbortSignal
): AsyncIterable<string> {
  const id = ++aiSeq
  const queue: string[] = []
  let finished = false
  let err: string | null = null
  let wake: (() => void) | null = null
  const nudge = () => {
    const w = wake
    wake = null
    w?.()
  }

  aiStreams.set(id, {
    push: (s) => { queue.push(s); nudge() },
    done: () => { finished = true; nudge() },
    error: (m) => { err = m; finished = true; nudge() },
  })

  signal.addEventListener('abort', () => {
    post('aiCancel', { id })
    finished = true
    nudge()
  })

  post('aiRequest', {
    id,
    document: ctx.document,
    selection: ctx.selection,
    instruction: ctx.instruction,
  })

  try {
    for (;;) {
      if (queue.length) { yield queue.shift() as string; continue }
      if (err) throw new Error(err)
      if (finished) return
      await new Promise<void>((r) => { wake = r })
    }
  } finally {
    aiStreams.delete(id)
  }
}

// Notion-style preset actions surfaced in the native AI tooltip.
const PRESETS: Array<{ id: string; icon: string; label: string; prompt: string }> = [
  { id: 'grammar', icon: '✓', label: 'Fix spelling & grammar', prompt: 'Fix spelling and grammar' },
  { id: 'improve', icon: '✦', label: 'Improve writing', prompt: 'Improve writing' },
  { id: 'shorter', icon: '⊟', label: 'Make it more concise', prompt: 'Make it more concise' },
  { id: 'continue', icon: '⤳', label: 'Continue writing', prompt: 'Continue writing from here' },
  { id: 'translate', icon: '⇄', label: 'Translate to Chinese', prompt: 'Translate to Chinese' },
]

// --- Image upload: hand bytes to Swift, get back a relative path ---------
let imgSeq = 0
const imgResolvers = new Map<number, (path: string) => void>()

function fileToBase64(file: File): Promise<{ base64: string; ext: string }> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onerror = () => reject(reader.error)
    reader.onload = () => {
      const result = String(reader.result)
      const comma = result.indexOf(',')
      const base64 = comma >= 0 ? result.slice(comma + 1) : result
      const ext = (file.name.split('.').pop() || file.type.split('/').pop() || 'png').toLowerCase()
      resolve({ base64, ext })
    }
    reader.readAsDataURL(file)
  })
}

async function uploadImage(file: File): Promise<string> {
  const { base64, ext } = await fileToBase64(file)
  return new Promise<string>((resolve) => {
    const id = ++imgSeq
    imgResolvers.set(id, resolve)
    post('imageUpload', { id, base64, ext })
  })
}

// Stored markdown keeps a relative path ("attachments/<id>/x.png"); convert it
// to a file:// URL under the notes directory so the in-editor <img> resolves.
function proxyImageURL(url: string): string {
  if (/^(https?:|data:|file:|blob:)/.test(url)) return url
  const base = notesBase()
  if (!base) return url
  return base.replace(/\/?$/, '/') + url.replace(/^\.?\//, '')
}

// --- [[reference]] and #tag decorations ----------------------------------
// References and tags stay literal Markdown text; we only style them and make
// them clickable via a ProseMirror decoration plugin (no custom node types, so
// round-tripping to Markdown is lossless).
const REF_RE = /\[\[([^\]]+?)\]\]/g
const TAG_RE = /(^|[\s(（【])(#[\p{L}\p{N}_/-]+)/gu
const refPluginKey = new PluginKey('oak-ref-decorations')

function buildDecorations(doc: any): DecorationSet {
  const decos: Decoration[] = []
  doc.descendants((node: any, pos: number) => {
    if (!node.isText || !node.text) return
    const text: string = node.text
    let m: RegExpExecArray | null
    REF_RE.lastIndex = 0
    while ((m = REF_RE.exec(text))) {
      const from = pos + m.index
      const to = from + m[0].length
      decos.push(
        Decoration.inline(from, to, { class: 'oak-ref', 'data-oak-ref': m[1].trim() })
      )
    }
    TAG_RE.lastIndex = 0
    while ((m = TAG_RE.exec(text))) {
      const tag = m[2]
      const from = pos + m.index + m[1].length
      const to = from + tag.length
      decos.push(
        Decoration.inline(from, to, { class: 'oak-tag', 'data-oak-tag': tag.slice(1) })
      )
    }
  })
  return DecorationSet.create(doc, decos)
}

const referenceDecorationPlugin = $prose(
  () =>
    new Plugin({
      key: refPluginKey,
      state: {
        init: (_, state) => buildDecorations(state.doc),
        apply: (tr, old) => (tr.docChanged ? buildDecorations(tr.doc) : old),
      },
      props: {
        decorations(state) {
          return this.getState(state)
        },
        handleClick(_view, _pos, event) {
          const target = (event.target as HTMLElement | null)?.closest?.(
            '[data-oak-ref],[data-oak-tag]'
          ) as HTMLElement | null
          if (!target) return false
          const ref = target.getAttribute('data-oak-ref')
          if (ref) { post('refClick', ref); return true }
          const tag = target.getAttribute('data-oak-tag')
          if (tag) { post('tagClick', tag); return true }
          return false
        },
      },
    })
)

// --- Editor bootstrap ----------------------------------------------------
let crepe: Crepe | null = null
// Markdown we last pushed in via setMarkdown — used to swallow the echo so a
// programmatic load doesn't look like a user edit.
let lastPushed: string | null = null

async function main() {
  crepe = new Crepe({
    root: '#editor',
    defaultValue: '',
    features: {
      [Crepe.Feature.CodeMirror]: true,
      [Crepe.Feature.ListItem]: true,
      [Crepe.Feature.LinkTooltip]: true,
      [Crepe.Feature.Cursor]: true,
      [Crepe.Feature.ImageBlock]: true,
      // Slash menu + block drag handle are OFF — markdown input rules
      // (#, -, 1., >, ---, ```, $$) cover block creation, so the `/` menu was
      // redundant. (Disabling BlockEdit removes both the menu and the handle.)
      [Crepe.Feature.BlockEdit]: false,
      // Crepe's built-in selection toolbar is OFF — the host shows its own
      // native glass popup (matching the rest of the app) and triggers AI via
      // window.oakEditor.runAI(), which still runs Crepe's RunAI + diff-review.
      [Crepe.Feature.Toolbar]: false,
      [Crepe.Feature.Placeholder]: true,
      [Crepe.Feature.Table]: true,
      [Crepe.Feature.Latex]: true,
      [Crepe.Feature.AI]: true,
    },
    featureConfigs: {
      [Crepe.Feature.Placeholder]: {
        text: 'Start writing…  type / for commands, select text to call AI',
      },
      [Crepe.Feature.ImageBlock]: {
        onUpload: uploadImage,
        inlineOnUpload: uploadImage,
        blockOnUpload: uploadImage,
        proxyDomURL: proxyImageURL,
      },
      [Crepe.Feature.AI]: {
        provider: aiProvider,
        diffReviewOnEnd: true,
        instructionPlaceholder: 'Ask AI to edit… (e.g. improve writing)',
        diffActions: {
          acceptAllLabel: 'Accept all',
          rejectAllLabel: 'Reject all',
          retryLabel: 'Retry',
        },
        buildAISuggestions: (builder) => {
          for (const p of PRESETS) {
            builder.addItem(p.id, { icon: p.icon, label: p.label, prompt: p.prompt })
          }
        },
      },
    },
  })

  // Register the reference/tag decoration plugin before create().
  crepe.editor.use(referenceDecorationPlugin)

  await crepe.create()

  // Apply the host-injected body font now that .milkdown exists.
  applyFont(noteFont())

  crepe.on((listener) => {
    listener.markdownUpdated((_ctx, markdown) => {
      // Swallow the echo of a programmatic load.
      if (lastPushed !== null && markdown === lastPushed) {
        lastPushed = null
        return
      }
      lastPushed = null
      post('markdown', markdown)
    })
  })

  // --- Report text selection so the host can show its native popup ---
  // Posts the selection's viewport rect; the host converts it to screen coords
  // and positions the glass popup, mirroring the HTML document viewer.
  function reportSelection() {
    const sel = window.getSelection()
    const editorEl = document.querySelector('#editor .ProseMirror')
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed || !editorEl) {
      post('selectionCleared', true)
      return
    }
    const range = sel.getRangeAt(0)
    if (!editorEl.contains(range.commonAncestorContainer)) {
      post('selectionCleared', true)
      return
    }
    const text = sel.toString()
    const r = range.getBoundingClientRect()
    if (!text.trim() || (r.width === 0 && r.height === 0)) {
      post('selectionCleared', true)
      return
    }
    post('textSelected', {
      text,
      x: r.left + r.width / 2,
      y: r.top,
      bottomY: r.bottom,
      vpWidth: window.innerWidth,
      vpHeight: window.innerHeight,
    })
  }

  let selTimer: number | undefined
  const scheduleSel = () => {
    clearTimeout(selTimer)
    selTimer = window.setTimeout(reportSelection, 180)
  }
  document.addEventListener('selectionchange', scheduleSel)
  document.addEventListener('mouseup', scheduleSel)
  document.addEventListener('keyup', scheduleSel)
  // Dismiss while scrolling — the popup is anchored to a now-moving rect.
  document.getElementById('editor')?.addEventListener('scroll', () => post('selectionCleared', true), true)

  post('ready', true)
  log('crepe ready')
}

// --- API exposed to Swift (window.oakEditor.*) ---------------------------
const oakEditor = {
  setMarkdown(md: string) {
    if (!crepe) return
    lastPushed = md
    crepe.editor.action(replaceAll(md))
  },
  getMarkdown(): string {
    return crepe ? crepe.getMarkdown() : ''
  },
  setTheme(theme: 'light' | 'dark') {
    document.documentElement.setAttribute('data-theme', theme)
  },
  setFont(css: string) {
    applyFont(css)
  },
  focus() {
    crepe?.editor.action((c) => {
      try { c.get(editorViewCtx).focus() } catch { /* not ready */ }
    })
  },
  // Run Crepe's AI over the current selection (host's native popup calls this).
  // Reuses the AI provider + diff-review even though the built-in toolbar is off.
  runAI(instruction: string) {
    crepe?.editor.action((c) => {
      try {
        c.get(editorViewCtx).focus()
        c.get(commandsCtx).call('RunAI', { instruction })
      } catch (e) {
        log('runAI error: ' + ((e as Error)?.message ?? String(e)))
      }
    })
  },
  // AI stream callbacks (Swift -> JS)
  __aiChunk(id: number, text: string) { aiStreams.get(id)?.push(text) },
  __aiDone(id: number) { aiStreams.get(id)?.done() },
  __aiError(id: number, message: string) { aiStreams.get(id)?.error(message) },
  // Image upload callback (Swift -> JS)
  __imageUploaded(id: number, relativePath: string) {
    const resolve = imgResolvers.get(id)
    if (resolve) {
      imgResolvers.delete(id)
      resolve(proxyImageURL(relativePath))
    }
  },
}
;(window as unknown as { oakEditor: typeof oakEditor }).oakEditor = oakEditor

main().catch((e) => {
  log('boot error: ' + (e?.message ?? String(e)))
  console.error(e)
})
