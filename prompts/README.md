# Prompts

The static half of the system prompt, as data.

Everything here is plain Markdown loaded at runtime by the core, so changing
what the assistant is told does not need a Swift rebuild or a notarized
release — and it carries to any other shell unchanged, which is the point.

What does **not** live here: anything assembled from live application state —
the open document, the active collection, the tab list, the citation registry.
That is built in the shell, because only the shell knows it, and appended
after the composed text below.

## Layout

    base.md          Always first. Who the assistant is and what it refuses to do.
    mixins/*.md      Composable fragments, included by name.

Each mixin wraps itself in a semantic tag (`<math-formatting>`, …) so the model
sees where one concern ends and the next begins, and so a fragment can be
dropped without leaving dangling prose. The convention is borrowed from Dia,
which ships ~12 mixins beside its prompts and composes them per agent.

## Adding one

Drop a `.md` file in `mixins/`, wrap it in a tag named after the file, and
request it by filename. There is no template language and no front matter on
purpose: a prompt is prose, and the moment it needs branching it belongs in
code instead.
