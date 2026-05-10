import SwiftUI

/// Floating indicator shown at the top of the editor while dictation is active.
///
/// Displays a pulsing red dot and "Dictating..." label.
/// Tap to stop dictation.
struct DictationOverlayView: View {
    let onStop: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: onStop) {
            HStack(spacing: 8) {
                // Pulsing red recording dot
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 1.3 : 1.0)
                    .opacity(pulse ? 0.7 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: pulse
                    )

                Text("Dictating...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)

                Image(systemName: "stop.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .help("Stop dictation (Option+Space)")
        .onAppear { pulse = true }
    }
}
