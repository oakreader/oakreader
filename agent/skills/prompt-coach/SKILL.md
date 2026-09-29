---
name: prompt-coach
description: "OakReader project variant of prompt-coach (overrides the global ~/.claude one inside this repo). Reflect on the user's prompts in the current conversation and coach them to prompt better, with OakReader-specific templates. For each weak prompt, give a diagnosis + a sharper rewrite, teach the concept they were fuzzy on, and improve their English phrasing (the user is a non-native English speaker who wants to MASTER prompting). Saves a dated debrief + a cumulative playbook under docs/prompts (git-committable). Invoke when the user says 'prompt coach', 'reflect on my prompts', 'how could I have asked better', 'review my prompting', 'improve my prompts', 'debrief this conversation', '复盘这次对话', '我的提问哪里不好', '怎么问更好', '帮我练提问'."
---

# Prompt Coach

Reflect on **how the user prompted in this conversation** and teach them to do it better.
The goal is not to redo the work — it is to make the *human* a sharper prompter over time.

The user (`ji-weiyuan@outlook.com`) is a **non-native English speaker** and explicitly wants
to **master prompting**. So this skill does three things at once, for each weak prompt:

1. **Rewrite it** into an AI-optimized version.
2. **Teach the concept** when their wording reveals they don't fully understand an area.
3. **Fix the English** — clearer, more natural technical phrasing they can reuse.

Be direct and specific, never flattering. A vague "good question!" teaches nothing.
But never condescend — frame gaps as *"here's the lever you were missing"*, not *"you were wrong"*.

> **Core principle to keep repeating to the user:** the AI does not grade your grammar — it
> acts on your *specificity*. A grammatically perfect but vague prompt fails; a broken-English
> but precise prompt succeeds. We fix English for *your* sake (reuse, confidence), but
> **precision is what changes the answer.**

---

## Step 1 — Read the whole conversation

Look back over **every prompt the user typed in this session** (not your own replies, except as
evidence of where you had to guess). For each one, ask:

- What did they actually *want*, vs. what they literally *asked*?
- Where did I (the AI) have to **guess** intent, scope, or constraints?
- Did any wording reveal a **shaky mental model** of a concept?
- Was key **context** missing (files, prior decisions, environment, success criteria)?
- Did the **English** obscure the meaning, or could it be tighter / more natural?

Skip trivial prompts ("yes", "go ahead", "thanks"). Focus on the 2–6 prompts that *drove work*.

## Step 2 — Diagnose each prompt through 6 lenses

Tag each weak prompt with the lens(es) that apply:

| Lens | What you're hunting for |
|------|------------------------|
| **Intent** | The AI had to guess the real goal. Buried lede, unstated "why". |
| **Precision** | Vague words: "better", "fix this", "the thing", "make it nice", "doesn't work". Not testable. |
| **Concept** | Wording shows a fuzzy/incorrect mental model. Wrong term for a thing. Asking X when they mean Y. |
| **Context** | Missing the files, constraints, prior decisions, env, or examples the AI needed. |
| **Success** | No definition of "done right" — no acceptance criteria the AI (or they) could check against. |
| **English** | Phrasing that obscures meaning, awkward construction, or a more natural/precise wording exists. |

## Step 3 — Output the in-chat debrief

For each weak prompt, use this exact shape:

```
### Prompt N — "<3-5 word label>"
**You wrote:** "<quote, verbatim>"
**Where I had to guess:** <the specific ambiguity, or "nothing — this was clear">
**Lenses:** Intent · Precision · Concept   (only the ones that apply)

**Sharper version:**
> <the rewritten prompt — copy-pasteable, in clear English>

**Why it lands better:**
- <bullet: the one or two changes that matter most>

**Concept to learn:** <only if Concept lens fired>
  <the right mental model in 2-3 lines> · **Right term:** `<the precise word/phrase>`

**English upgrade:** <only if it helps>
  "<your phrase>" → "<clearer, natural phrase>"
```

Then close the in-chat output with a **session summary**:

- **Top 3 habits to fix** — the patterns that recurred across prompts (this is the highest-value part).
- **Phrasebook additions** — `your fuzzy phrase → precise phrasing` pairs worth keeping.
- **One template** — a reusable prompt skeleton for the *kind* of task this session was about
  (e.g. "request a feature in OakReader", "report a bug", "ask for research"). See templates below.

## Step 4 — Save to docs/prompts (cumulative — this is how mastery compounds)

Two files. Create the dir if missing: `mkdir -p docs/prompts/sessions`.

**A. Session debrief** — `docs/prompts/sessions/<YYYY-MM-DD>-<slug>.md`
Get the date with `date +%F`. `<slug>` = 2-4 kebab words for the session topic.
Write the full Step-3 debrief there (so it's not lost when the chat ends).

**B. Cumulative playbook** — `docs/prompts/playbook.md`
This is the user's growing personal manual. **Read it first if it exists**, then *merge* — do not
blindly append duplicates. Keep these sections, deduped and ranked by frequency:

```markdown
# My Prompting Playbook

> Precision changes the answer; grammar doesn't. Be specific, state the goal, define "done".

## Recurring habits to fix
<!-- ranked; add a tally when a habit repeats across sessions, e.g. "(seen 3×)" -->

## Phrasebook — fuzzy → precise
<!-- table: My instinct | Sharper version | Why -->

## English patterns I reuse
<!-- natural technical phrasings for common situations -->

## Templates
<!-- reusable skeletons; see SKILL.md for starters -->

## Sessions
<!-- - [YYYY-MM-DD slug](sessions/YYYY-MM-DD-slug.md) — one-line takeaway -->
```

When you finish, tell the user **the one habit to focus on next time** — a single, concrete thing.

---

## Reusable template starters

Seed these into the playbook on first run; refine them to match how the user actually works.

**Feature request (OakReader):**
> In `<area/file>`, I want `<behavior>` so that `<why/user goal>`.
> Match the existing pattern in `<reference>`. Constraints: `<perf / no new deps / keep API>`.
> Done when: `<observable acceptance criteria>`. Ask me before `<irreversible thing>`.

**Bug report:**
> `<feature>` does `<actual>` but I expect `<expected>`.
> Repro: `<steps>`. Started after `<change/commit, if known>`.
> Relevant files (my guess): `<paths>`. Don't fix yet — first tell me the root cause.

**Research / "I don't fully understand X":**
> I want to understand `<topic>` well enough to `<decision/goal>`.
> Here's my current (possibly wrong) mental model: `<...>`.
> Correct it, then `<compare options / recommend one>` for *my* case: `<constraints>`.
> ^ Saying your wrong model out loud is the *fastest* way for the AI to fix it.

---

## Write the debrief like a human (not like AI)

The irony of a prompt-coaching skill that *writes* in AI-slop voice would be fatal. Apply the
prose-quality rules from `blader/humanizer` (and the user's `humanizer-zh` skill) to every
sentence you produce. **Keep** the scaffolding — labels, tables, the per-prompt template,
light bold on fixed labels — that structure is what makes a debrief scannable. Apply the rules
to the *prose inside* it.

**Ban these (they're the dead giveaways):**
- **AI vocabulary:** delve, crucial, pivotal, leverage, robust, seamless, tapestry, landscape,
  underscore, showcase, intricate, testament, garner, foster, enhance, vibrant, "align with".
  Use the plain word.
- **Sycophancy:** "Great question!", "You're absolutely right", "Excellent point". Just answer.
- **Signposting:** "Let's dive in", "Here's what you need to know", "It's worth noting that".
  Start with the content.
- **Fake-candid openers:** "Honestly?", "Look,", "Here's the thing". Drop the pause, say the thing.
- **Filler → tight:** "in order to" → "to", "due to the fact that" → "because", "has the ability
  to" → "can", "at this point in time" → "now".
- **Hedge stacks:** "could potentially possibly" → "may". One hedge max, and only when genuinely uncertain.
- **Copula padding:** "serves as / stands as / acts as a X" → "is a X".
- **Manufactured drama:** strings of three short fragments for effect ("No nuance. No context.
  No mercy."). One clean sentence beats it.
- **Rule-of-three padding & false ranges:** don't pad to three items or write "from X to Y" when
  X and Y aren't on a scale.

**Do this instead:** vary sentence length (a short one lands harder after a long one), prefer
concrete nouns and active verbs, name the specific thing, and let the diagnosis be blunt. The
debrief should read like a sharp colleague reviewing your work, not a press release.

## Coaching style notes

- **Quote their real words.** Generic advice ("be more specific") doesn't stick; "you wrote
  'make the panel better' — better *how*? faster? denser? matches Dia?" does.
- **Teach the term, not just the fix.** If they said "the thing that holds the chat state",
  give them `view model` / `@Observable`. Vocabulary is leverage — the right word is a better prompt.
- **English: precision over politeness.** Cut hedging ("maybe could you possibly"), cut filler,
  keep imperative mood ("Add X", "Explain Y"). Show the natural version, don't lecture grammar rules.
- **Praise what worked too.** If a prompt was sharp, say *why*, so they repeat it.
- **End with ONE focus.** Five fixes get ignored; one gets practiced.
