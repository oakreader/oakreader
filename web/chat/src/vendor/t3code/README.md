# Vendored from pingdotgg/t3code (MIT)

Copied rather than reimplemented. See `LICENSE`; the copyright notice must
travel with these files. The directory mirrors t3code's own layout
(`components/`, `lib/`, `shared/`, `styles/`) and `tsconfig`/`vite` map `~` here,
so copied files resolve **unmodified** and can be re-synced by overwriting.

## What is here

| path | from | notes |
|---|---|---|
| `components/ui/*` (22 files) | `apps/web/src/components/ui/` | Base UI + Tailwind primitives. Unmodified. |
| `components/composerFooterLayout.ts` | same path | resting/compact layout decisions |
| `components/composerInlineChip.ts` | same path | inline chip class names |
| `components/chat/composerScrollGesture.ts` | same path | scroll-to-collapse gesture accumulator |
| `shared/composerTrigger.ts` | `packages/shared/src/` | `/`, `@`, `$skill` trigger detection |
| `styles/chat-markdown.css` | extracted from `apps/web/src/index.css` | all 56 `.chat-markdown` rules |
| `lib/utils.ts` | `apps/web/src/lib/` | **trimmed**: id factories dropped (they needed `@t3tools/contracts` + `effect`) |

## What was deliberately not copied

`ChatComposer.tsx` (7,011 lines, 62 relative imports) and `ChatMarkdown.tsx`
(3,363 lines, ~80 imports) are not liftable. They reach into
`@t3tools/client-runtime` (27,605 lines), `@t3tools/contracts` (20,204) and
`@t3tools/shared` (15,771) -- all workspace-internal, none published to npm --
plus Effect atoms, TanStack Router, their state stores, syntax highlighting,
diff rendering and pull-request previews. Copying either means adopting
t3code's application architecture, not a widget.

`MessagesTimeline.tsx` (5,092) is the same story.

Dropped from `components/ui/`: `toast` (needs TanStack Router + contracts),
`sidebar`, `wizard`, `color-picker`, `qr-code`, `calendar` and the rest that
nothing here imports.

## The rule

Keep these byte-identical so an upstream diff is meaningful. Adaptations go in
the calling code, not here. `lib/utils.ts` is the one exception and says so.
