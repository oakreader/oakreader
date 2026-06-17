import SwiftUI

/// NotebookLM-style customization sheet shown when a Studio generator tile is
/// tapped. Collects difficulty, count, and an optional custom prompt, then hands
/// the params back to the panel to run generation.
struct StudioGenerateSheet: View {
    let kind: StudioArtifactKind
    /// True for paginated sources (PDFs) — gates the "Pages" scoping control.
    var isPaginated: Bool = false
    var pageCount: Int = 0
    /// 1-based current page, used by the "Current page" option.
    var currentPage: Int = 1
    let onGenerate: (StudioGenerationParams) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var params = StudioGenerationParams()

    private enum PageMode: Hashable { case whole, current, range }
    @State private var pageMode: PageMode = .whole
    @State private var rangeStart = 1
    @State private var rangeEnd = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 15, weight: .medium))
                Text("Generate \(kind.label)")
                    .font(.headline)
                Spacer()
            }

            if kind == .quiz {
                section("Difficulty") {
                    Picker("", selection: $params.difficulty) {
                        ForEach(StudioGenerationParams.Difficulty.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            section(kind == .quiz ? "Number of cards" : "Level of detail") {
                Picker("", selection: $params.amount) {
                    ForEach(StudioGenerationParams.Amount.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if kind == .quiz && isPaginated {
                section("Pages") {
                    Picker("", selection: $pageMode) {
                        Text("Whole document").tag(PageMode.whole)
                        Text("Current page").tag(PageMode.current)
                        Text("Range").tag(PageMode.range)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch pageMode {
                    case .whole:
                        EmptyView()
                    case .current:
                        Text("Page \(currentPage) of \(pageCount)")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    case .range:
                        if pageCount > 1 {
                            VStack(alignment: .leading, spacing: 9) {
                                Text("Pages \(rangeStart)–\(rangeEnd) of \(pageCount)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                pageSlider("Start", startBinding, value: rangeStart)
                                pageSlider("End", endBinding, value: rangeEnd)
                            }
                        } else {
                            Text("This document has a single page.")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            section("Custom instructions (optional)") {
                TextField(
                    "e.g. focus on definitions, or only chapter 3",
                    text: $params.customPrompt,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Generate") {
                    var out = params
                    out.pageRange = resolvedPageRange()
                    onGenerate(out)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { rangeEnd = max(1, pageCount) }
    }

    /// The page span to scope generation to, or `nil` for the whole document.
    private func resolvedPageRange() -> StudioGenerationParams.PageRange? {
        guard kind == .quiz, isPaginated else { return nil }
        switch pageMode {
        case .whole:   return nil
        case .current: return .init(start: currentPage, end: currentPage)
        case .range:   return StudioGenerationParams.PageRange(start: rangeStart, end: rangeEnd)
                            .clamped(to: pageCount)
        }
    }

    /// A labelled page slider with a live value badge. Native `Slider` so it drags
    /// AND responds to the scroll wheel; `step: 1` keeps it on whole pages.
    private func pageSlider(_ label: String, _ value: Binding<Double>, value current: Int) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Slider(value: value, in: 1...Double(max(2, pageCount)), step: 1)
            Text("\(current)")
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }

    /// Start thumb — never crosses past the end thumb.
    private var startBinding: Binding<Double> {
        Binding(
            get: { Double(rangeStart) },
            set: { rangeStart = min(Int($0.rounded()), rangeEnd) }
        )
    }

    /// End thumb — never crosses below the start thumb.
    private var endBinding: Binding<Double> {
        Binding(
            get: { Double(rangeEnd) },
            set: { rangeEnd = max(Int($0.rounded()), rangeStart) }
        )
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
