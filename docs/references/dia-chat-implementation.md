# Dia's chat surface, as recovered from the binary

Extracted from `/Applications/Dia.app` 1.49.1 (agent-server commit `6dd0e8a6318`,
2026-09-18) on 2026-10-07, with `ipsw class-dump` and `ipsw macho info --swift` over
`Contents/MacOS/Dia`. Read-only research on a locally installed app, for understanding.
Nothing here is lifted code.

**What this method can and cannot give.** Swift reflection metadata survives stripping, so
*types, fields, and their types* are exact. **Numeric values are not recoverable** —
`fadeInDuration` exists as a field; whether it is 0.2 or 0.25 is a code literal that needs
disassembly of a Swift body. Colors are generated at runtime from one base color (see
§5), so there is no asset catalog to read them out of either. Every number in OakReader's
replication is therefore a judgement, not a measurement; the *structure* is the finding.

Namespaces: `SupertabFrontend` (the answer surface), `SupertabEngine` (the data side),
`AssistantUI` (reusable chat widgets), `ARCUI` (Arc's shared AppKit layer),
`ColorPalette` (theme).

---

## 1. The reveal: `AssistantUI.TextFadeAnimator`

```
class AssistantUI.TextFadeAnimator<A: TextFadeAnimatorTextLayout> {
    writingDirection: NSWritingDirection
    handlers: Handlers<A>
    maskLayer: CALayer
    textLayout: A
    textContainer: NSTextContainer
    layerReusePool: ReusePool<CAGradientLayer>
    completedContentRectLayer: CALayer
    completedContentRange: Range?
    revealingLineFragments: OrderedDictionary<UUID, RevealingLineFragment<A>>
    state: State<A>
    trailingLineRevealTask: TaskCancellable?
    shouldRevealTrailingLine: Bool
    lineDuration: Double
    lineIntervalMultiplier: CGFloat
    trailingLineRevealMaxDelay: Double?
}

struct Handlers<A> {
    onComplete: () -> Void
    shouldAnimateLineFragment: (NSAttributedString) -> Bool
}

enum State<A> { awaitingFirstValidTextLayout(pendingRevealUpToLastLine: Bool)
                revealing; completing; complete }

struct RevealingLineFragment<A> {
    id: UUID
    fragmentInfo: LineFragmentInfo<A>
    layer: CAGradientLayer
    isComplete: Bool
    nextLineTask: Task<Void, Error>?
}

struct LineFragmentInfo<A> {
    frame: CGRect
    range: A.Range
    string: NSAttributedString
    shouldAnimateReveal: Bool
}
```

Six things follow from the field list.

1. **The unit is a line fragment**, not a token and not a network chunk. Text arrives at a
   typographic rhythm rather than the provider's packet rhythm.
2. **The mechanism is a CALayer mask**: one opaque rect for everything already revealed,
   one pooled `CAGradientLayer` per line still sweeping. Layer count is O(lines in
   flight), never O(glyphs).
3. **Scheduling is chained, not a global timeline** — each fragment owns the
   `nextLineTask` that starts its successor.
4. `trailingLineRevealMaxDelay` caps how long the last line may wait. A fixed cadence
   falls behind a fast stream; this is the escape hatch.
5. `shouldAnimateLineFragment` can refuse to animate a fragment — a code block or a table
   appears at once rather than sweeping.
6. Two layout backends (`TextFadeAnimatorTextKit1Layout` / `…TextKit2Layout`), and the
   chat text view uses **TextKit 1**.

`SupertabTextView.trailingLineRevealMaxDelay` and
`MarkdownItemViewModel.State.allowFullLineAnimations` mean both knobs are per message, not
global.

## 2. Typography: `SupertabFrontend.SupertabTypography.DynamicProperties`

```
DynamicProperties {
    plainTextProperties: TextProperties
    headingsProperties: HeadingsProperties   // h1, h2, h3, h4, fallback
    tableProperties: TextProperties          // tables get their own typography
    listItemSpacing: CGFloat
    paragraphSpacing: CGFloat
    quoteLevelMinOpacity: CGFloat
    textAlignment: NSTextAlignment
}

TextProperties {
    regularFontProperties: FontProperties    // { font, textColor }
    emphasisFontProperties: FontProperties   // italic — its OWN font and color
    strongFontProperties: FontProperties     // bold — its OWN font and color
    inlineCodeProperties: InlineCodeProperties
    lineSpacing, paragraphSpacing, paragraphSpacingBefore: CGFloat
}

HeadingProperties {
    textProperties: TextProperties
    isAllCaps: Bool
    appendsDividerLine: Bool
}

InlineCodeProperties {
    font, textColor, backgroundColor, strokeColor: NSColor
    backgroundPadding: NSEdgeInsets
    cornerRadius: CGFloat
}
```

The shape of this is the lesson:

- Emphasis and strong carry a **whole font and color each**, not a trait applied to the
  body font. Bold can be a different family, or a different grey.
- Every heading level owns a **complete** `TextProperties` — its own line spacing, its own
  space above and below. Not a size ladder over one paragraph style.
- Tables are typeset separately from prose.
- Inline code is a **stroked, padded, rounded pill**, not a background colour.
- `quoteLevelMinOpacity`: nested quotes dim per level, with a floor so level 4 stays
  readable.
- `isAllCaps` and `appendsDividerLine` are per level.

## 3. What is a widget rather than text

```
enum MarkdownItemView.AttachmentID {
    documentCard(paragraphIndex:)
    codeBlock(blockIndex:)
    latex(index:)
    inlineSource(line:column:sourceID:)
    inlineLink(line:column:urlID:)
    blockQuoteSource(BlockQuoteSourcingKey)
    headerQuoteReplyButton(index:)
    table(index:)
}
```

Each is an `NSTextAttachment` inside one `SupertabTextView`. A whole message is a single
text view, so selection runs across code blocks and tables without a break, and an
attachment occupies one glyph slot — resolving a citation never reflows the paragraph.

OakReader's split-block design (one `NSTextView` per prose block, SwiftUI views for code
and tables) trades that continuous selection for simpler layout and memoized re-renders.
That is a real divergence, not an oversight; see `chat-markdown-block-splitting`.

## 4. Links and highlights: `SupertabTextView`

```
struct LinkAttributes {
    textColor: NSColor
    underlineStyle: NSUnderlineStyle
    underlineColor: NSColor
    hoveredUnderlineStyle: NSUnderlineStyle
    hoveredUnderlineColor: NSColor
}
```

A link's underline **changes style and colour on hover**, independently of its text
colour. Also on the text view: `highlightedRanges` + `focusedHighlightedRange` (search and
citation targeting), `customizesCopiedPlainText` (copying rebuilds plain text rather than
dumping the attachment characters), `isContextMenuLinkAllowed` / `onEnableBlockedLink`
(link safety gating).

## 5. Colour: generated, not authored

```
class ColorPalette.SemanticColorPalette {
    baseColor, style                           // style: brightness | tritone
    textColor, textSecondaryColor, textCursorColor
    linkColor, linkUnderlineColor, linkHoveredUnderlineColor
    themeHighlightColor, themeHoverColor, themeTextSelectionColor
    themeActionColor, themeActionForegroundColor, themeActionSecondaryColor
    secondaryHighlightColor, secondaryTextSelectionColor
    secondaryActionColor, secondaryActionForegroundColor, secondaryActionSecondaryColor
    shadowColor, borderColor
    assistantMessageBackgroundColors: [NSColor]   // a gradient, not one colour
    assistantMessageForegroundColor
    newTabBackgroundColors: [NSColor]
    controlAccentColor, invertedIconBackgroundColor
}
```

28 roles derived from **one `baseColor`** through a `brightness` ramp or a `tritone`
palette (`TriTonePalette`: assistant / complementary / primaryActions / dropShadows /
strokes / supportingContainers). This is why Dia can recolour the whole assistant surface
from a single theme swatch, and why no fixed hex values exist to copy.

## 6. Thread layout: a collection view with a column system

```
enum LayoutColumn { left, center, centerExtended, centerExtendedLeft, right, fullWidth }
enum HorizontalSizeClass { default, compact, wide }
struct ColumnSpan { x, width, sizeClass }
struct ItemLayoutSpec {
    height: CGFloat
    width: CGFloat?
    contentInsets: VerticalInsets        // top, bottom
    column: LayoutColumn
    extendedContentEdges: ExtendedEdges  // OptionSet
    isHidden: Bool
    verticalPointOfInterest: CGFloat?
}
```

The thread is an `NSCollectionView` with `SupertabThreadCollectionViewLayout`, not a stack.
Every item declares a column and its own vertical insets, so an artifact can span the full
width while prose stays in the centre column, and `verticalPointOfInterest` gives the
scroller something better to aim at than "the bottom".

## 7. Waiting and thinking states

- `ShimmeringTextView` — `gradientStripView`, `maskContainerLayer`, `shimmerStyle`,
  `gradientAnimationDuration`. Shimmer is a gradient strip **masked by the text**, not an
  overlay on top of it.
- `ShimmerBarView`, `PlaceholderBarsView` (`titleBar` + `subtitleBar`) — skeleton bars
  before the first token.
- `ThinkingOrbCoordinator` with `LogoParticleView`, `renderStyle`, `phase`, and a
  `placeholderContainer`, driven against the collection view.
- `CompactThinkingView` — the collapsed reasoning block: `topFadeMaskLayer`
  (`CAGradientLayer`) feathers the top of the scrolling text, `textScale` shrinks it,
  `isDeemphasized` dims it, and the collapse runs in two phases (`pendingPhase2`,
  `pendingFadeCollapseFinish`).
- `MarkdownItemViewModel.State` carries `isDeemphasized` and `animatesDeemphasisChange`:
  a superseded message dims **with a transition**, it does not just change colour.

## 8. Motion vocabulary

`AssistantUI.AssistantAnimationUtilities.Springs` has exactly **two** cases: `slow` and
`fast`. The whole assistant surface is animated from a two-token spring system. (ARCUI's
wider app has more: `springy`, `springyFast`, `springyExtraFast`.)

`ARCUI.FeatheredContainerView<V, O>` wraps a scroll view with `featherSize`,
`featherInset` and an `orientation`, so content fades at the container edges instead of
being cut. It is used for the thread scroll view, the pills row, and the code streaming
view (`CodeStreamingView.FeatheredEdges`, an `OptionSet`).

`CodeStreamingView` drives its own scroll with a `CADisplayLink` and a `scrollTargetY` —
code streams in with its own smooth-scroll loop rather than jumping.

---

## What OakReader took, and what it did not

| Dia | OakReader | Status |
|---|---|---|
| line-fragment reveal, chained schedule | `MarkdownTextView` line-fragment sweep, backlog-adaptive interval | done, 2026-10-07 |
| delta coalescing before the UI | `DeltaCoalescer`, ~30/s | done |
| native render, no webview | `OakMarkdownUI` | done |
| payload-free citation handles | `oak:N` + `CitationSourceRegistry` | done |
| inline code as a stroked pill | background + padding, **no stroke** | partial |
| per-heading-level `TextProperties` | one size ladder, one spacing | partial |
| `listItemSpacing` token | derived (`paragraphSpacing * 0.3`) | partial |
| `quoteLevelMinOpacity` ladder | single quote style | missing |
| `appendsDividerLine`, `isAllCaps` per heading | — | missing |
| separate `tableProperties` typography | shared with prose | missing |
| `isDeemphasized` + animated change | — | missing |
| `FeatheredContainerView` edges | hard-clipped scroll edges | missing |
| column layout + `verticalPointOfInterest` | `VStack` + near-bottom follow | divergent by design |
| one text view per message, attachments | one text view per prose block | divergent by design |
| palette generated from one base colour | semantic `NSColor` tokens | divergent by design |
