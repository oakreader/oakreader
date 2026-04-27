import SwiftUI
import AVFoundation

/// Minimal AVPlayer wrapper for podcast audio playback.
struct AudioPlayerView: View {
    let audioURL: URL

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var timeObserver: Any?

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
        }
        .onAppear { setupPlayer() }
        .onDisappear { teardownPlayer() }
    }

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
