import SwiftUI

// Shared pieces for what the chat shows while a reply is in progress: the
// thinking block and the tool-call group. Numbers follow Cursor 3.17's agent
// panel (`ThinkingLine.js`, `StepGroupSummaryView.js`, its `shimmer` keyframes),
// read from its shipped bundle.

/// Text with a light band sweeping across it, for a label that names work in
/// progress ("Thinking", "Searching library…"). 2 s per pass, linear, as
/// Cursor's; static under Reduce Motion.
struct ShimmerText: View {
    let text: String
    var font: Font = OakStyle.ChatFont.messageBody

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        let label = Text(text).font(font).fontWeight(.medium).lineLimit(1)
        label
            .foregroundStyle(.secondary)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, Color.primary.opacity(0.75), .clear],
                            startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(40, geo.size.width * 0.5))
                            .offset(x: phase * geo.size.width)
                    }
                    .mask(label)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                phase = -1
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                    phase = 1.5
                }
            }
    }
}

/// A window onto the newest part of something still growing: capped at
/// `maxHeight`, held at the bottom as content arrives, and faded at the top
/// once older content has scrolled out of view. Cursor uses 144 px for its
/// active step group and a 32 px top mask.
struct TailWindow<Content: View>: View {
    var maxHeight: CGFloat = 144
    @ViewBuilder let content: () -> Content

    /// Measured height of the content. A ScrollView otherwise takes all the
    /// height it is offered, so a two-line step list would sit in a 144 pt box.
    @State private var contentHeight: CGFloat = 0

    private var overflows: Bool { contentHeight > maxHeight + 2 }

    var body: some View {
        ScrollView(.vertical) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        // Keep the newest line in view as the content grows. A reader who
        // scrolls up stays where they are until they return to the bottom.
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentSize.height
        } action: { _, height in
            contentHeight = height
        }
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(overflows ? 0.15 : 1), .black],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 32)
                Color.black
            }
        }
    }
}

/// Cursor's collapsible timing: 150 ms, out-cubic.
extension Animation {
    static let chatDisclosure = Animation.timingCurve(0.215, 0.61, 0.355, 1, duration: 0.15)
}
