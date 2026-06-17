# 2026-06-17 — Designing the prompt-coach skill

Debrief of the user's own prompts in the session where we built `/prompt-coach`.

### Prompt 1 — "Know aihero.dev?"
**You wrote:** "do you know aihero.dev"
**Where I had to guess:** nothing major — clear intent (recall a site).
**Lenses:** —
Fine as an opener. Open recall questions are legitimately this short. ✅

### Prompt 2 — "Check his GitHub"
**You wrote:** "check his github he has greate agent skill s repo?"
**Where I had to guess:** *which* repo, and what "check" should produce — confirm it exists? list the skills? compare to ours?
**Lenses:** Precision · English

**Sharper version:**
> Check Matt Pocock's GitHub — does he have a well-known agent-skills repo? If so, list the skills and how to install it.

**Why it lands better:**
- States the *deliverable* ("list the skills + install"), so I don't stop at "yes he does".
- Names the person, removing the "his = who?" guess.

**English upgrade:**
  "he has greate agent skills repo?" → "does he have a good agent-skills repo?"
  ("great" needs an article: *a great repo*; and "skill s" → "skills".)

### Prompt 3 — "Help me design the skill" (the important one)
**You wrote:** "could you help think a agent skill? reflect the convesation with ai? think better prompt I should type? sometime my prompt expose my weakness of not understanding in these area? you should think how I descript the promblem more accurate and ai could understand better my intention and instruction?"
**Where I had to guess:** scope (one prompt vs whole chat?), output (chat-only vs saved?), where to save, and whether you wanted English help. I had to *ask* all four — that's a sign the prompt was missing them.
**Lenses:** Intent · Precision · Success · English

**Sharper version:**
> Help me design an agent skill. Goal: after a conversation, it reflects on *my* prompts and teaches me to write better ones — rewrite each weak prompt, point out where my wording shows I don't understand the topic, and improve my English (I'm not a native speaker). Save the output somewhere so I improve over time. Ask me anything ambiguous before writing it.

**Why it lands better:**
- Leads with the **goal in one sentence**, then the specifics — instead of 5 question-fragments I have to reassemble.
- States the **output + persistence** ("save somewhere so I improve"), which is what your real intent was.
- Ends with "ask me anything ambiguous" — invites the clarifying questions instead of making me guess.

**Concept to learn:** what an "agent skill" *is* — a reusable instruction file (`SKILL.md`) the
agent loads on a trigger phrase. Knowing that, you can prompt at the right altitude:
"a skill that does X on trigger Y, saving to Z." · **Right terms:** `SKILL.md`, `trigger`, `frontmatter description`.

**English upgrades:**
  "help think a agent skill" → "help me **design** an agent skill"
  "reflect the convesation" → "that **reflects on** the conversation"
  "how I descript the promblem more accurate" → "how to **describe** the problem **more accurately**"
  "my prompt expose my weakness" → "my prompt **exposes** my weakness" (singular subject → -s verb)

---

## Top 3 habits to fix
1. **Lead with the goal, then details.** You tend to fire several question-fragments; collapse them into one "Goal: …" sentence first. (seen 1×)
2. **State the deliverable.** Say what you want *produced* (a list, a file, a fix), not just the topic. "Check his GitHub" → "list the skills". (seen 1×)
3. **Name the thing precisely.** "his", "the thing", "these area" → the actual name/path. Pronouns make me guess. (seen 1×)

## Phrasebook additions
| My instinct | Sharper version | Why |
|-------------|-----------------|-----|
| "check his github" | "check X's GitHub and list/summarize Y" | adds the deliverable |
| "help think a skill" | "help me design a skill that does X on trigger Y" | states shape + altitude |
| "I don't understand these area" | "correct my mental model of <topic>" | turns a gap into an action |

## One thing to focus on next time
**Open with a single "Goal:" sentence before the details.** If you do only one thing, do that —
it removes ~80% of the guessing.
