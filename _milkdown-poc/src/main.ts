import { Crepe } from '@milkdown/crepe'
import { commandsCtx, editorViewCtx } from '@milkdown/kit/core'
import { AllSelection, TextSelection } from '@milkdown/kit/prose/state'

import '@milkdown/crepe/theme/common/style.css'
// MiaoYan theme, aliased in vite.config.ts to our local Milkdown source build.
import '@milkdown/crepe/theme/miaoyan.css'

// --- Bridge helpers (no-op when not running inside WKWebView) ---
type WK = { messageHandlers?: Record<string, { postMessage: (b: unknown) => void }> }
const webkit = (window as unknown as { webkit?: WK }).webkit
function postToSwift(name: string, body: unknown) {
  webkit?.messageHandlers?.[name]?.postMessage(body)
}
const statusEl = document.getElementById('status')!
function setStatus(s: string) {
  statusEl.textContent = s
  postToSwift('status', s)
}

// --- Seed document with deliberate errors + clunky prose ---
const SEED = `# 会议笔记

teh project is on track. i think we will recieve the final report soon. The team dont have alot of  time but we can still finish it

## 下一步

- 联系 [供应商](https://example.com)
- review teh budget
`

// --- Mock "AI": Notion-style actions, branched on the instruction ---
function fixGrammar(text: string): string {
  const fixes: Array<[RegExp, string]> = [
    [/\bteh\b/g, 'the'],
    [/\brecieve\b/g, 'receive'],
    [/\bdont\b/g, "don't"],
    [/\bcant\b/g, "can't"],
    [/\balot\b/g, 'a lot'],
    [/\bi\b/g, 'I'],
    [/ {2,}/g, ' '],
  ]
  let out = text
  for (const [re, rep] of fixes) out = out.replace(re, rep)
  return out.replace(/finish it(\n|$)/, 'finish it.$1')
}

function improveWriting(text: string): string {
  let out = fixGrammar(text)
  out = out.replace(
    /The team don't have a lot of time but we can still finish it\.?/,
    'Although the team is short on time, we are confident we can still deliver.'
  )
  out = out.replace(/I think we will receive/, 'We expect to receive')
  out = out.replace(/review the budget/i, 'Review and approve the budget')
  return out
}

function makeShorter(text: string): string {
  const out = fixGrammar(text)
  return out
    .replace(
      /the project is on track\. We expect to receive the final report soon\. Although[^]*?finish it\.?/i,
      'On track; final report expected soon. Tight timeline, but on course.'
    )
    .replace(
      /the project is on track\. I think we will receive the final report soon\. The team don't have a lot of time but we can still finish it\.?/i,
      'On track; final report expected soon. Tight timeline, but on course.'
    )
}

function transformFor(instruction: string, source: string): string {
  const i = instruction.toLowerCase()
  if (i.includes('shorter') || instruction.includes('简洁')) return makeShorter(source)
  if (i.includes('improve') || instruction.includes('改善') || instruction.includes('润色'))
    return improveWriting(source)
  return fixGrammar(source) // default: fix spelling & grammar
}

function* chunk(s: string, size = 6): Generator<string> {
  for (let i = 0; i < s.length; i += size) yield s.slice(i, i + size)
}

const mockProvider = async function* (
  ctx: { document: string; selection: string; instruction: string },
  signal: AbortSignal
): AsyncIterable<string> {
  const source = ctx.selection?.trim() ? ctx.selection : ctx.document
  const result = transformFor(ctx.instruction, source)
  setStatus('AI 处理中… (' + ctx.instruction + ')')
  for (const c of chunk(result)) {
    if (signal.aborted) return
    await new Promise((r) => setTimeout(r, 16))
    yield c
  }
  setStatus('完成 — 请审阅 diff')
}

// Notion-style action presets (label + the instruction sent to the provider)
const PRESETS: Array<{ id: string; icon: string; label: string; prompt: string }> = [
  { id: 'grammar', icon: '✓', label: '修正拼写和语法', prompt: 'Fix spelling and grammar' },
  { id: 'improve', icon: '✦', label: '改善写作', prompt: 'Improve writing' },
  { id: 'shorter', icon: '⊟', label: '更简洁', prompt: 'Make shorter' },
]

async function main() {
  const crepe = new Crepe({
    root: '#editor',
    defaultValue: SEED,
    features: {
      [Crepe.Feature.AI]: true,
      [Crepe.Feature.ImageBlock]: true,
      [Crepe.Feature.LinkTooltip]: true,
      [Crepe.Feature.Toolbar]: true,
      [Crepe.Feature.BlockEdit]: true,
      [Crepe.Feature.Placeholder]: true,
    },
    featureConfigs: {
      [Crepe.Feature.AI]: {
        provider: mockProvider,
        diffReviewOnEnd: true,
        instructionPlaceholder: '让 AI 帮你修改…（如：改善写作）',
        diffActions: {
          acceptAllLabel: '全部接受',
          rejectAllLabel: '全部拒绝',
          retryLabel: '重试',
        },
        // Notion-style preset menu in the native AI tooltip
        buildAISuggestions: (builder) => {
          for (const p of PRESETS) {
            builder.addItem(p.id, { icon: p.icon, label: p.label, prompt: p.prompt })
          }
        },
      },
    },
  })

  await crepe.create()
  setStatus('ready')

  crepe.on((listener) => {
    listener.markdownUpdated((_ctx, markdown) => {
      postToSwift('markdown', markdown)
    })
  })

  // Run an AI action over the whole document, then diff-review the result.
  function runAction(instruction: string) {
    crepe.editor.action((c) => {
      try {
        const view = c.get(editorViewCtx)
        view.dispatch(view.state.tr.setSelection(new AllSelection(view.state.doc)))
        view.focus()
        // Look up the command by NAME ("RunAI") to dodge duplicate-module key mismatch.
        const ok = c.get(commandsCtx).call('RunAI', { instruction })
        postToSwift('log', `RunAI("${instruction}") -> ${ok}`)
      } catch (e) {
        postToSwift('log', 'runAction error: ' + ((e as Error)?.message ?? String(e)))
      }
    })
  }

  // Wire the external toolbar preset buttons
  for (const p of PRESETS) {
    document.getElementById('preset-' + p.id)?.addEventListener('click', () => runAction(p.prompt))
  }

  // Select a text range so the native selection toolbar pops up over it.
  function selectRange(from: number, to: number) {
    crepe.editor.action((c) => {
      const view = c.get(editorViewCtx)
      const size = view.state.doc.content.size
      const f = Math.max(1, Math.min(from, size - 1))
      const t = Math.max(f + 1, Math.min(to, size - 1))
      view.focus()
      view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, f, t)))
    })
  }

  // Insert an empty paragraph and type "/" to open the Notion-style slash menu.
  function openSlash() {
    crepe.editor.action((c) => {
      const view = c.get(editorViewCtx)
      view.focus()
      const end = view.state.doc.content.size
      const para = view.state.schema.nodes.paragraph.create()
      let tr = view.state.tr.insert(end, para)
      tr = tr.setSelection(TextSelection.near(tr.doc.resolve(end + 1)))
      view.dispatch(tr)
      view.dispatch(view.state.tr.insertText('/', view.state.selection.from))
    })
  }

  ;(window as unknown as { oak: unknown }).oak = {
    runAction,
    openSlash,
    fixGrammar: () => runAction('Fix spelling and grammar'),
    improve: () => runAction('Improve writing'),
    shorter: () => runAction('Make shorter'),
    selectRange,
    getMarkdown: () => crepe.getMarkdown(),
  }
  postToSwift('ready', true)
}

main().catch((e) => {
  setStatus('error: ' + (e?.message ?? String(e)))
  console.error(e)
})
