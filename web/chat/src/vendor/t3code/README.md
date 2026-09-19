# Vendored from pingdotgg/t3code (MIT)

Verbatim copies of the dependency-free modules from t3code's chat composer.
See LICENSE; the copyright notice must travel with these files.

Only files with no imports at all are vendored. The components themselves are
not liftable: `ChatComposer.tsx` is 7,011 lines with 62 relative imports, and
it pulls `@t3tools/client-runtime`, `@t3tools/contracts` and `@t3tools/shared`,
which are workspace-internal and not published to npm. Copying the composer
would mean adopting t3code's Effect runtime, Zustand stores, keybinding
registry, model selection and terminal integration -- the application, not a
widget.

What is worth taking is the *reasoning*, which lives in these files as encoded
decisions rather than pixels. `shouldUseRestingComposerLayout` is the example
that earned this directory: it documents that losing focus must NOT collapse
the composer, because a user clicking into a message to copy or select text
would otherwise watch the input shrink under them.

| file | from |
|---|---|
| `composerFooterLayout.ts` | `apps/web/src/components/composerFooterLayout.ts` |
| `composerScrollGesture.ts` | `apps/web/src/components/chat/composerScrollGesture.ts` |

Keep these byte-identical so they can be re-synced. Adaptations belong in the
calling code.
