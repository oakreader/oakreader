import SwiftUI

/// NotebookLM-style customization sheet shown when a Studio generator tile is
/// tapped. Collects difficulty, count, and an optional custom prompt, then hands
/// the params back to the panel to run generation.
struct StudioGenerateSheet: View {
    let kind: StudioArtifactKind
    let onGenerate: (StudioGenerationParams) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var params = StudioGenerationParams()

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
                    onGenerate(params)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
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
