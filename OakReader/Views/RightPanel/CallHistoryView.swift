import SwiftUI

struct CallHistoryView: View {
    let viewModel: SpeakerListViewModel
    let speaker: Speaker

    var body: some View {
        VStack(spacing: 0) {
            header

            if viewModel.callHistory.isEmpty {
                emptyState
            } else {
                callList
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.backToList()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text("Call History")
                .font(.system(size: 16, weight: .semibold))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "phone.badge.clock")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("No calls yet")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            Text("Start a call with \(speaker.name)\nto see the history here.")
                .font(.system(size: 12))
                .foregroundStyle(.quaternary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var callList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.callHistory) { call in
                    CallHistoryRow(call: call)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                viewModel.deleteCallFromHistory(call)
                            }
                        }
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
    }
}

// MARK: - Call History Row

private struct CallHistoryRow: View {
    let call: VoiceCall

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(call.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: call.createdAt))
                    Text(call.formattedDuration)
                    Text("\(call.turnCount) turns")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
