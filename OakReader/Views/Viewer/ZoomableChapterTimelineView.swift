import SwiftUI

struct ZoomableChapterTimelineView: View {
    let chapters: [VideoChapter]
    let duration: Double
    let currentTime: Double
    let activeChapterID: UUID?
    let onSeek: (Double) -> Void

    @State private var zoomLevel: CGFloat = 1.0
    @State private var hoveredChapter: VideoChapter?
    @State private var hoverLocation: CGPoint = .zero
    @State private var showZoomIndicator = false
    @State private var userIsScrolling = false
    @State private var scrollDebounceTask: Task<Void, Never>?

    private var timelineDuration: Double {
        let chapterMax = chapters.compactMap(\.endTime).max()
            ?? chapters.last.map { $0.startTime + 1 } ?? 0
        return max(duration, chapterMax, 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let containerWidth = geometry.size.width
                let contentWidth = containerWidth * zoomLevel

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: zoomLevel > 1.2) {
                        ZStack(alignment: .topLeading) {
                            // Track background
                            Capsule()
                                .fill(Color.primary.opacity(0.04))
                                .frame(width: contentWidth, height: 28)
                                .padding(.top, 2)

                            // Chapter segments
                            chapterSegments(contentWidth: contentWidth)

                            // Playhead
                            playhead(contentWidth: contentWidth)
                                .id("playhead")

                            // Time axis ticks
                            timeAxis(contentWidth: contentWidth)
                        }
                        .frame(width: contentWidth, height: 50)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            let ratio = location.x / contentWidth
                            let seconds = ratio * timelineDuration
                            onSeek(max(0, min(seconds, timelineDuration)))
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: currentTime) { _, _ in
                        guard !userIsScrolling else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo("playhead", anchor: .center)
                        }
                    }
                    .onScrollPhaseChange { _, newPhase in
                        if newPhase == .interacting || newPhase == .decelerating {
                            userIsScrolling = true
                            scrollDebounceTask?.cancel()
                        } else if newPhase == .idle {
                            scrollDebounceTask?.cancel()
                            scrollDebounceTask = Task { @MainActor in
                                try? await Task.sleep(for: .seconds(2))
                                guard !Task.isCancelled else { return }
                                userIsScrolling = false
                            }
                        }
                    }
                }

                // Tooltip overlay
                if let chapter = hoveredChapter {
                    tooltipCard(for: chapter)
                        .position(x: min(max(hoverLocation.x, 120), containerWidth - 120),
                                  y: -36)
                        .allowsHitTesting(false)
                }

                // Zoom gesture capture (behind everything)
                TimelineZoomGestureView(zoomLevel: $zoomLevel)
                    .frame(width: containerWidth, height: 50)
                    .allowsHitTesting(true)
            }
            .frame(height: 50)
            .onChange(of: zoomLevel) { _, _ in
                showZoomIndicator = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.easeOut(duration: 0.3)) {
                        showZoomIndicator = false
                    }
                }
            }

            // Zoom indicator
            if showZoomIndicator {
                Text("\(Int(zoomLevel * 100))%")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Chapter Segments

    @ViewBuilder
    private func chapterSegments(contentWidth: CGFloat) -> some View {
        ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
            let startX = (chapter.startTime / timelineDuration) * contentWidth
            let endTime = chapterEndTime(for: index)
            let chapterDur = endTime - chapter.startTime
            let segWidth = max((chapterDur / timelineDuration) * contentWidth, 6)
            let isActive = activeChapterID == chapter.id

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.accentColor.opacity(isActive ? 0.25 : 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(isActive ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
                )
                .frame(width: segWidth, height: 22)
                .offset(x: startX, y: 5)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoveredChapter = chapter
                        hoverLocation = CGPoint(x: startX + location.x, y: location.y)
                    case .ended:
                        if hoveredChapter?.id == chapter.id {
                            hoveredChapter = nil
                        }
                    }
                }
                .onTapGesture {
                    onSeek(chapter.startTime)
                }
        }
    }

    // MARK: - Playhead

    private func playhead(contentWidth: CGFloat) -> some View {
        let playheadX = (currentTime / timelineDuration) * contentWidth
        return RoundedRectangle(cornerRadius: 1)
            .fill(Color.red)
            .frame(width: 2, height: 30)
            .offset(x: max(0, min(playheadX - 1, contentWidth - 2)), y: 1)
    }

    // MARK: - Time Axis

    @ViewBuilder
    private func timeAxis(contentWidth: CGFloat) -> some View {
        let tickInterval = adaptiveTickInterval()
        let tickCount = Int(timelineDuration / tickInterval) + 1

        ForEach(0..<tickCount, id: \.self) { i in
            let seconds = Double(i) * tickInterval
            let x = (seconds / timelineDuration) * contentWidth

            VStack(spacing: 1) {
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: 5)

                Text(MediaViewModel.formatTimestamp(seconds: seconds, bracketed: false))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
            .offset(x: x - 12, y: 32)
        }
    }

    // MARK: - Tooltip

    private func tooltipCard(for chapter: VideoChapter) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chapter.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)

            if let summary = chapter.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(MediaViewModel.formatTimestamp(seconds: chapter.startTime, bracketed: false))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(maxWidth: 220, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }

    // MARK: - Helpers

    private func chapterEndTime(for index: Int) -> Double {
        let chapter = chapters[index]
        if let endTime = chapter.endTime, endTime > chapter.startTime {
            return endTime
        }
        if chapters.indices.contains(index + 1) {
            return max(chapters[index + 1].startTime, chapter.startTime + 1)
        }
        return max(duration, chapter.startTime + 1)
    }

    private func adaptiveTickInterval() -> Double {
        let visibleDuration = timelineDuration / Double(zoomLevel)

        switch visibleDuration {
        case ..<15:
            return 5
        case 15..<45:
            return 15
        case 45..<120:
            return 30
        case 120..<600:
            return 60
        case 600..<1800:
            return 300
        default:
            return 600
        }
    }
}
