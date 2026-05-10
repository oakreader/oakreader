import SwiftUI

struct CharacterListView: View {
    let viewModel: CharacterListViewModel
    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.characters) { character in
                        CharacterRow(
                            character: character,
                            onCall: { viewModel.startCall(character: character) },
                            onHistory: { viewModel.showCallHistory(character: character) },
                            onDelete: { viewModel.deleteCharacter(character) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Voice AI")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

}

// MARK: - Character Row

private struct CharacterRow: View {
    let character: Character
    let onCall: () -> Void
    let onHistory: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CharacterAvatarView(avatar: character.avatar, initials: character.initials, size: 40)

            // Name + subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(character.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let lastCall = character.lastCall {
                    Text("\(lastCall.displayTitle) \u{2022} \(lastCall.formattedDuration)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("No calls yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Call button
            Button(action: onCall) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.green))
            }
            .buttonStyle(.plain)
            .help("Start call")

            // History button
            Button(action: onHistory) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
            }
            .buttonStyle(.plain)
            .help("Call history")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .contextMenu {
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

