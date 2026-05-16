import SwiftUI
import AVFoundation

/// Minimal AVPlayer wrapper for podcast audio playback.
struct AudioPlayerView: View {
    let audioURL: URL
    var itemStorageKey: String?
    var attachmentStorageKey: String?

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var timeObserver: Any?
    @State private var transcript: String?
    @State private var transcriptionService = RecordingTranscriptionService()
    @State private var isTranscribing = false

    var body: some View {
        VStack(spacing: 8) {
            // Seek slider
            Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                if !editing {
                    player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
                }
            }

            HStack {
                Text(formatTime(currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                // Playback controls
                Button(action: skipBackward) {
                    Image(systemName: "gobackward.15")
                        .font(.title3)
                }
                .buttonStyle(.plain)

                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                }
                .buttonStyle(.plain)

                Button(action: skipForward) {
                    Image(systemName: "goforward.30")
                        .font(.title3)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(formatTime(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Transcription section
            if let itemKey = itemStorageKey, let attKey = attachmentStorageKey {
                Divider()

                if let transcript {
                    transcriptView(transcript)
                } else if isTranscribing {
                    transcriptionProgressView
                } else {
                    transcribeButton(itemKey: itemKey, attKey: attKey)
                }
            }
        }
        .onAppear {
            setupPlayer()
            loadTranscript()
        }
        .onDisappear { teardownPlayer() }
    }

    // MARK: - Transcript Views

    @ViewBuilder
    private func transcriptView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Transcript", systemImage: "text.quote")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Copy transcript")
            }

            ScrollView {
                Text(text)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)

            // Summary section
            if let itemKey = itemStorageKey, let attKey = attachmentStorageKey {
                Divider()
                RecordingSummaryView(
                    itemStorageKey: itemKey,
                    attachmentStorageKey: attKey,
                    transcript: text
                )
            }
        }
    }

    private var transcriptionProgressView: some View {
        VStack(spacing: 4) {
            if case .transcribing(let progress) = transcriptionService.status {
                ProgressView(value: progress)
                Text("Transcribing... \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .loading = transcriptionService.status {
                ProgressView()
                    .controlSize(.small)
                Text("Loading STT model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func transcribeButton(itemKey: String, attKey: String) -> some View {
        Button {
            startTranscription(itemKey: itemKey, attKey: attKey)
        } label: {
            Label("Transcribe", systemImage: "captions.bubble")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(Preferences.shared.voiceSTTModel.isEmpty)
    }

    // MARK: - Transcription Logic

    private func loadTranscript() {
        guard let itemKey = itemStorageKey, let attKey = attachmentStorageKey else { return }
        let url = CatalogDatabase.attachmentTranscriptURL(
            itemStorageKey: itemKey,
            attachmentStorageKey: attKey
        )
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            transcript = text
        }
    }

    private func startTranscription(itemKey: String, attKey: String) {
        let sttModel = Preferences.shared.voiceSTTModel
        guard !sttModel.isEmpty else { return }

        isTranscribing = true
        Task {
            do {
                let text = try await transcriptionService.transcribe(audioURL: audioURL, sttModel: sttModel)
                let url = CatalogDatabase.attachmentTranscriptURL(
                    itemStorageKey: itemKey,
                    attachmentStorageKey: attKey
                )
                try text.write(to: url, atomically: true, encoding: .utf8)
                transcript = text
            } catch {
                Log.error(Log.audio, "Transcription failed: \(error)")
            }
            isTranscribing = false
        }
    }

    // MARK: - Player

    private func setupPlayer() {
        let p = AVPlayer(url: audioURL)
        self.player = p

        // Observe time
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentTime = time.seconds
        }

        // Get duration
        Task {
            if let d = try? await p.currentItem?.asset.load(.duration) {
                await MainActor.run {
                    duration = d.seconds.isFinite ? d.seconds : 0
                }
            }
        }
    }

    private func teardownPlayer() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        player?.pause()
        player = nil
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    private func skipBackward() {
        guard let player else { return }
        let newTime = max(currentTime - 15, 0)
        player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
    }

    private func skipForward() {
        guard let player else { return }
        let newTime = min(currentTime + 30, duration)
        player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
