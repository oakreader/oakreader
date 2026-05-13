# CharacterAgent as User-Role Input

## Summary

Add `CharacterAgent` mentions to chat as a new kind of user input source. A `CharacterAgent` is a real historical thinker / practitioner inspired reasoning agent (for example Feynman, Socrates, Arendt, Shannon, Kahneman), invoked from the chat input with `@`.

Important distinction: a CharacterAgent is **not** an assistant reply in the main chat. It produces user-role input for the main LLM. In the main chat UI, CharacterAgent output is rendered as a left-side agent input card, but when building LLM history it is sent as `role: user`.

## Core Design Intent

LLM chat history only has two semantic roles that matter here:

- `user`
- `assistant`

A CharacterAgent output should be modeled as `user`, because it represents context/material delegated by the user, not a response from the main assistant.

Example LLM messages:

```json
{
  "role": "user",
  "content": "Explain section 2"
}
{
  "role": "user",
  "content": "<character-agent-input agent_id=\"feynman\" agent_name=\"Richard Feynman\" thread_id=\"...\">\nFirst-principles analysis...\n</character-agent-input>"
}
{
  "role": "assistant",
  "content": "...main assistant synthesis..."
}
```

## UI Behavior

### Main chat display

- Normal user message: right-aligned user bubble.
- Assistant message: left-aligned assistant bubble.
- CharacterAgent input: left-aligned card, even though its data role is `user`.

Reason: the source is an agent invoked by the user, not the user typing directly.

Example UI:

```text
Left side:
⚛ Feynman
First-principles view:
This section is mainly saying...
```

### Do not show subagent chat UI in main AI chat

The main chat should not expand a full subagent conversation. It should only show the CharacterAgent-produced input card / digest that becomes user-role input to the main LLM.

## Input Syntax

User can type:

```text
@Feynman explain Section 2
```

Internal stored representation may become:

```xml
<character-agent-input
  agent_id="feynman"
  agent_name="Richard Feynman"
  icon="atom"
  thread_id="..."
  jsonl_path=".../agent-threads/....jsonl"
>
First-principles analysis...
</character-agent-input>
```

then later appended/expanded into the XML-style block used for LLM context.

## CharacterAgent Catalog

Use real thinkers / practitioners across fields. Prompts should not impersonate the person; they should be phrased as inspired by their intellectual style and methods.

Example catalog item:

```json
{
  "id": "feynman",
  "handle": "Feynman",
  "name": "Richard Feynman",
  "domain": "Physics / Explanation",
  "icon": "atom",
  "description": "Explain from first principles with concrete analogies.",
  "prompt": "You are a CharacterAgent inspired by Richard Feynman's teaching style. Do not claim to be Feynman. Use first-principles reasoning, concrete examples, and simple language."
}
```

Candidate agents:

- Richard Feynman — first principles / physics explanation
- Socrates — questioning assumptions
- Hannah Arendt — politics, responsibility, public action
- Claude Shannon — information theory, signal/noise
- Alan Kay — computing systems, interfaces, education
- Daniel Kahneman — cognitive bias / decision making
- Marshall McLuhan — media theory
- Charles Darwin — evolutionary reasoning
- Jorge Luis Borges — literary/metaphorical analysis
- Marvin Minsky — AI / society of mind
- Edward Tufte — visualization / evidence display
- Norbert Wiener — cybernetics / feedback systems
- Susan Sontag — culture / interpretation / aesthetics

## Thread Storage

CharacterAgent can have an independent JSONL thread for full provenance and follow-ups:

```text
~/OakReader/chats/threads/{threadId}.jsonl
```

Main chat should store only the thread reference and current digest/result needed for the main LLM.

Suggested reference:

```swift
struct CharacterAgentThreadRef: Codable, Identifiable {
    let id: UUID
    let agentId: String
    let agentName: String
    let icon: String?
    let jsonlPath: String
    var status: Status
    var title: String
    var summary: String
    var latestUserFollowUp: String?
    let createdAt: Date
    var updatedAt: Date
}
```

## Follow-up Behavior

If the user asks follow-up questions inside the CharacterAgent thread:

1. Append follow-up to the CharacterAgent JSONL.
2. Append CharacterAgent response to the same JSONL.
3. Update the thread digest/summary.
4. Update or append a new `character-agent-input` user-role block in the main chat history.

The follow-up content should be available to the main LLM as user-role context, not assistant-role context.

## `@` Mention Integration

The `@` popup should include a CharacterAgent section in addition to context mentions:

```text
Context
@Document
@Current Page
@Selection
@Notes

CharacterAgents
@Feynman    Physics · First principles
@Socrates   Philosophy · Question assumptions
@Kahneman   Psychology · Bias and decisions
```

Selecting a CharacterAgent inserts an inline chip in the input.

## Rendering Rule

Pseudo-code:

```swift
if turn.role == .user && turn.content.containsCharacterAgentInput {
    renderCharacterAgentInputCardLeft(turn)
} else if turn.role == .user {
    renderUserBubbleRight(turn)
} else {
    renderAssistantBubbleLeft(turn)
}
```

## MVP Plan

1. Add `CharacterAgent` model and bundled catalog.
2. Extend `ChatCompletionItem` with `.characterAgent(CharacterAgent)`.
3. Add CharacterAgent section to `@` completion list.
4. Insert inline token and serialize marker/tag into user turn.
5. Render CharacterAgent input as a left-side card in main chat.
6. Ensure LLM history sends CharacterAgent blocks as `role: user`.
7. Add JSONL thread storage and thread reference metadata.

## Non-goals for MVP

- Do not show full subagent chat UI inside the main AI chat.
- Do not treat CharacterAgent output as main assistant content.
- Do not impersonate historical figures directly.
