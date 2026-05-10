import SwiftUI

struct CharacterListView: View {
    let viewModel: CharacterListViewModel
    @State private var showAddCharacter = false

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

            Divider()

            addCharacterButton
        }
        .popover(isPresented: $showAddCharacter) {
            AddCharacterPopover { name, language in
                viewModel.addCharacter(name: name, language: language)
                showAddCharacter = false
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

    private var addCharacterButton: some View {
        Button {
            showAddCharacter = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
                Text("Add a new Character")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
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

// MARK: - Add Character Popover

private struct AddCharacterPopover: View {
    let onAdd: (String, String) -> Void
    @State private var name = ""
    @State private var language = "en"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Character")
                .font(.system(size: 14, weight: .semibold))

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            Picker("Language", selection: $language) {
                ForEach(VoiceLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onAdd("", "")
                }
                Button("Add") {
                    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    onAdd(name.trimmingCharacters(in: .whitespaces), language)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}
