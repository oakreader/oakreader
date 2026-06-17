import SwiftUI

/// Full-window presentation of a Studio artifact that needs room — a concept map
/// opens here as an interactive, pan/zoom canvas; a quiz as a roomy deck.
struct StudioFullScreenView: View {
    let artifact: StudioArtifact
    let onClose: () -> Void
    /// Jumps to the passage a flashcard cites — `(quote, 1-based page?)`.
    var onJumpToSource: ((String, Int?) -> Void)? = nil
    /// Deletes the flashcard at the given index from the quiz deck.
    var onDeleteCard: ((Int) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: artifact.kind.systemImage)
                .foregroundStyle(.secondary)
            Text(artifact.title.isEmpty ? artifact.kind.label : artifact.title)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch artifact.kind {
        case .quiz:
            if let deck = artifact.quizDeck {
                InlineDeckView(deck: deck, onDeleteCard: onDeleteCard, onJumpToSource: onJumpToSource, embeddedInSheet: true)
                    .frame(maxWidth: 1040, maxHeight: .infinity)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unavailableFullScreen
            }
        }
    }

    private var unavailableFullScreen: some View {
        Text("This artifact can't be displayed full-screen.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
