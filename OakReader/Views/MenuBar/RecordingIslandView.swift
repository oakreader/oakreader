import SwiftUI

struct RecordingIslandView: View {
    @Bindable var model: RecordingIslandModel
    var onStop: () -> Void

    private let expandedWidth: CGFloat = 320
    private let expandedHeight: CGFloat = 160
    private let darkBackground = Color(red: 0.051, green: 0.051, blue: 0.059) // #0d0d0f

    var body: some View {
        let isExpanded = model.isExpanded
        let width = isExpanded ? expandedWidth : model.collapsedWidth
        let height = isExpanded ? expandedHeight : model.collapsedHeight
        let cornerRadius: CGFloat = isExpanded ? 20 : (model.isNotchedDisplay ? 16 : height / 2)

        VStack(spacing: 0) {
            ZStack {
                // Background shape
                Group {
                    if model.isNotchedDisplay {
                        NotchPillShape(cornerRadius: cornerRadius)
                            .fill(darkBackground)
                    } else {
                        FloatingPillShape(cornerRadius: cornerRadius)
                            .fill(darkBackground)
                    }
                }

                // Content
                VStack(spacing: 12) {
                    collapsedContent
                    if isExpanded {
                        expandedContent
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, isExpanded ? 14 : 0)
            }
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            .animation(.spring(duration: 0.42, bounce: 0.2), value: isExpanded)
            .animation(.spring(duration: 0.42, bounce: 0.2), value: width)
            .animation(.spring(duration: 0.42, bounce: 0.2), value: height)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Collapsed Content

    private var collapsedContent: some View {
        HStack(spacing: 8) {
            // Pulsing red dot
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .modifier(PulseModifier())

            Text(model.elapsedTime)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)

            if model.isExpanded {
                Spacer()

                // Recording mode icon
                Image(systemName: model.recordingMode == "micAndSystem" ? "mic.and.signal.meter" : "mic.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(spacing: 10) {
            Divider()
                .background(.white.opacity(0.15))

            // Device info
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                Text(model.inputDeviceName)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer()

                // Mode badge
                Text(model.recordingMode == "micAndSystem" ? "Mic + System" : "Mic Only")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.1), in: Capsule())
            }

            // Stop button
            Button(action: onStop) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12))
                    Text("Stop Recording")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(.red, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Pulse Animation Modifier

private struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}
