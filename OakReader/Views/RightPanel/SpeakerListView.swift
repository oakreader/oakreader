import SwiftUI

struct SpeakerListView: View {
    let viewModel: SpeakerListViewModel
    @State private var showAddSpeaker = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.speakers) { speaker in
                        SpeakerRow(
                            speaker: speaker,
                            onCall: { viewModel.startCall(speaker: speaker) },
                            onHistory: { viewModel.showCallHistory(speaker: speaker) },
                            onDelete: { viewModel.deleteSpeaker(speaker) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()

            addSpeakerButton
        }
        .popover(isPresented: $showAddSpeaker) {
            AddSpeakerPopover { name, language in
                viewModel.addSpeaker(name: name, language: language)
                showAddSpeaker = false
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

    private var addSpeakerButton: some View {
        Button {
            showAddSpeaker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
                Text("Add a new Speaker")
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

// MARK: - Speaker Row

private struct SpeakerRow: View {
    let speaker: Speaker
    let onCall: () -> Void
    let onHistory: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Avatar circle
            ZStack {
                Circle()
                    .fill(Color(hex: speaker.avatarColorHex))
                Text(speaker.initials)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            // Name + subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(speaker.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let lastCall = speaker.lastCall {
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
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}

// MARK: - Add Speaker Popover

private struct AddSpeakerPopover: View {
    let onAdd: (String, String) -> Void
    @State private var name = ""
    @State private var language = "en"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Speaker")
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
                    // Popover will be dismissed by parent
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

