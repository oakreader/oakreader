import SwiftUI
import OakReaderAI

struct SidebarView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Tab-style mode picker
            HStack(spacing: 2) {
                ForEach(SidebarMode.allCases) { mode in
                    let selected = viewModel.state.sidebarMode == mode
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.state.sidebarMode = mode
                        }
                    } label: {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                            .foregroundStyle(selected ? .primary : .secondary)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selected ? Color(nsColor: .textBackgroundColor) : .clear)
                                    .shadow(color: selected ? .black.opacity(0.12) : .clear, radius: 2, y: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(mode.label)
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, OakStyle.Spacing.sm)
            .padding(.vertical, OakStyle.Spacing.xs)

            // Content
            switch viewModel.state.sidebarMode {
            case .thumbnails:
                ThumbnailSidebarView(viewModel: viewModel)
            case .outline:
                BookmarkSidebarView(viewModel: viewModel)
            case .annotations:
                AnnotationListView(viewModel: viewModel)
            case .search:
                SearchSidebarView(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MediaSidebarView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        VStack(spacing: 0) {
            modePicker

            if let media = viewModel.mediaDocument {
                switch viewModel.state.mediaSidebarMode {
                case .transcript:
                    MediaTranscriptSidebarContent(model: viewModel.media, media: media)
                case .outline:
                    MediaOutlineSidebarContent(model: viewModel.media, media: media)
                }
            } else {
                MediaSidebarEmptyView(
                    systemImage: "play.rectangle",
                    title: "No Video",
                    message: "Open a YouTube item to view transcript and highlights."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: viewModel.mediaDocument?.storageDirectory) {
            guard let media = viewModel.mediaDocument else { return }
            viewModel.media.prepareForMedia(media)
            await viewModel.media.loadOrFetchTranscript(media: media)
            await viewModel.media.loadChapters(media: media)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(MediaSidebarMode.allCases) { mode in
                let selected = viewModel.state.mediaSidebarMode == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.state.mediaSidebarMode = mode
                    }
                } label: {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .foregroundStyle(selected ? .primary : .secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected ? Color(nsColor: .textBackgroundColor) : .clear)
                                .shadow(color: selected ? .black.opacity(0.12) : .clear, radius: 2, y: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(mode.label)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.xs)
    }
}

private struct MediaTranscriptSidebarContent: View {
    let model: MediaViewModel
    let media: MediaDocument

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !model.transcriptEntries.isEmpty {
                        transcriptRows
                    } else if let transcript = model.transcriptText, !transcript.isEmpty {
                        Text(transcript)
                            .font(.callout)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else if model.isLoadingTranscript {
                        MediaSidebarStatusView(message: "Fetching transcript...")
                            .padding(12)
                    } else if let message = model.transcriptErrorMessage {
                        MediaSidebarErrorView(message: message) {
                            model.retryTranscript(media: media)
                        }
                        .padding(12)
                    } else {
                        MediaSidebarEmptyView(
                            systemImage: "text.bubble",
                            title: "No Transcript",
                            message: "No timestamped transcript is available yet."
                        )
                    }
                }
                .padding(.bottom, 12)
            }
            .onChange(of: model.activeEntryID) { _, newID in
                guard let id = newID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var transcriptRows: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(model.transcriptEntries) { entry in
                let active = model.activeEntryID == entry.id
                Button {
                    model.requestSeek(seconds: entry.offset)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(MediaViewModel.formatTimestamp(seconds: entry.offset, bracketed: false))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(active ? Color.accentColor : .secondary)
                            .frame(width: 44, alignment: .trailing)

                        Text(entry.text)
                            .font(.callout)
                            .foregroundStyle(active ? Color.accentColor : .primary)
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, 2)
                    .padding(.trailing, 6)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(active ? Color.accentColor.opacity(0.10) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .id(entry.id)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }
}

private struct MediaOutlineSidebarContent: View {
    let model: MediaViewModel
    let media: MediaDocument

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch model.chapterStatus {
                    case .completed(let source):
                        if model.chapters.isEmpty {
                            idleContent(message: "No chapters are available for this video.")
                        } else {
                            outlineHeader(source: source)
                            chapterRows
                        }

                    case .extractingChapters:
                        MediaSidebarStatusView(message: "Checking for chapters...")
                            .padding(12)

                    case .fetchingTranscript:
                        MediaSidebarStatusView(message: "Fetching transcript...")
                            .padding(12)

                    case .generatingChapters:
                        MediaSidebarStatusView(message: "Generating chapters...")
                            .padding(12)

                    case .failed(let message):
                        MediaSidebarErrorView(message: message) {
                            Task { await model.generateChaptersManually(media: media) }
                        }
                        .padding(12)

                    case .skipped(let reason):
                        idleContent(message: reason)

                    case .idle:
                        idleContent(message: "No chapters yet.")
                    }
                }
                .padding(.bottom, 12)
            }
            .onChange(of: model.activeChapterID) { _, newID in
                guard let id = newID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func outlineHeader(source: ChapterSource) -> some View {
        HStack {
            Text("Chapters")
                .font(.headline)

            Spacer()

            Text(source == .ai ? "AI" : "YouTube")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var chapterRows: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.chapters.enumerated()), id: \.element.id) { index, chapter in
                let active = model.activeChapterID == chapter.id
                Button {
                    model.requestSeek(seconds: chapter.startTime)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(active ? Color.accentColor : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(chapter.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            if let summary = chapter.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(active ? Color.accentColor.opacity(0.1) : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .id(chapter.id)
            }
        }
        .padding(.horizontal, 10)
    }

    private func idleContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MediaSidebarEmptyView(
                systemImage: "list.bullet.rectangle",
                title: "Chapters",
                message: message
            )

            if KeychainService.apiKey(for: Preferences.shared.youtubeAIProvider) != nil {
                Button {
                    Task { await model.generateChaptersManually(media: media) }
                } label: {
                    Label("Generate Chapters", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.horizontal, 12)
            } else {
                Text("Configure an AI provider in Settings > YouTube to generate chapters.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct MediaSidebarStatusView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct MediaSidebarErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Retry", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

private struct MediaSidebarEmptyView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}
