import SwiftUI
import Textual
import OakVoiceAI

struct VoiceChatView: View {
    let voiceVM: VoiceViewModel
    var onBack: (() -> Void)?
    var characterName: String?

    private var orbColor: Color {
        guard voiceVM.isRunning else { return .accentColor }
        switch voiceVM.agentState {
        case .idle: return .accentColor
        case .listening: return .green
        case .userSpeaking: return .blue
        case .thinking: return .purple
        case .speaking: return .orange
        case .interrupted: return .red
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if voiceVM.turns.isEmpty && !voiceVM.isRunning {
                emptyState
            } else {
                turnList
            }

            if let error = voiceVM.error {
                errorBanner(error)
            }

            voiceControls
        }
        .background {
            if voiceVM.isRunning {
                AmbientGlow(color: orbColor, audioLevel: CGFloat(voiceVM.audioLevel))
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(characterName ?? "Voice AI")
                .font(.system(size: 16, weight: .semibold))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("Tap the microphone to start\na voice conversation")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Turn List

    private var turnList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(voiceVM.turns) { turn in
                        VoiceTurnRow(turn: turn)
                            .id(turn.id)
                    }

                    // Live transcript / response
                    if voiceVM.isRunning {
                        if !voiceVM.userTranscript.isEmpty {
                            VoiceBubble(
                                text: voiceVM.userTranscript,
                                role: .user,
                                isLive: true
                            )
                            .id("live-user")
                        }
                        if !voiceVM.assistantText.isEmpty {
                            VoiceBubble(
                                text: voiceVM.assistantText,
                                role: .assistant,
                                isLive: true
                            )
                            .id("live-assistant")
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: voiceVM.turns.count) { _, _ in
                if let last = voiceVM.turns.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: voiceVM.userTranscript) { _, _ in
                withAnimation {
                    proxy.scrollTo("live-user", anchor: .bottom)
                }
            }
            .onChange(of: voiceVM.assistantText) { _, _ in
                withAnimation {
                    proxy.scrollTo("live-assistant", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Voice Controls

    private var voiceControls: some View {
        VStack(spacing: 4) {
            Button {
                if voiceVM.isRunning {
                    voiceVM.stop()
                } else {
                    Task { await voiceVM.start() }
                }
            } label: {
                VoiceOrb(agentState: voiceVM.agentState, isRunning: voiceVM.isRunning, audioLevel: CGFloat(voiceVM.audioLevel))
            }
            .buttonStyle(.plain)
            .help(voiceVM.isRunning ? "Stop voice conversation" : "Start voice conversation")

            Text(statusLabel)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: voiceVM.agentState)
        }
        .padding(.bottom, 12)
    }

    private var statusLabel: String {
        guard voiceVM.isRunning else { return "Tap to start" }
        switch voiceVM.agentState {
        case .idle: return "Idle"
        case .listening: return "Listening..."
        case .userSpeaking: return "Hearing you..."
        case .thinking: return "Thinking..."
        case .speaking: return "Speaking..."
        case .interrupted: return "Interrupted"
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
    }
}

// MARK: - Voice Orb Animation

private struct VoiceOrb: View {
    let agentState: AgentState
    let isRunning: Bool
    var audioLevel: CGFloat = 0

    private let coreSize: CGFloat = 56

    private var color: Color {
        guard isRunning else { return .accentColor }
        switch agentState {
        case .idle: return .accentColor
        case .listening: return .green
        case .userSpeaking: return .blue
        case .thinking: return .purple
        case .speaking: return .orange
        case .interrupted: return .red
        }
    }

    private var speed: Double {
        guard isRunning else { return 1.0 }
        switch agentState {
        case .idle: return 1.5
        case .listening: return 2.0
        case .userSpeaking: return 4.0
        case .thinking: return 2.5
        case .speaking: return 3.0
        case .interrupted: return 1.5
        }
    }

    private var intensity: Double {
        guard isRunning else { return 0.025 }
        switch agentState {
        case .idle: return 0.03
        case .listening: return 0.04
        case .userSpeaking: return 0.09
        case .thinking: return 0.05
        case .speaking: return 0.07
        case .interrupted: return 0.03
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate

            ZStack {
                // Ring 2 (outermost glow)
                ring(index: 2, time: t)
                // Ring 1 (middle glow)
                ring(index: 1, time: t)
                // Ring 0 (inner glow)
                ring(index: 0, time: t)
                // Core circle
                core(time: t)
                // Icon
                icon
            }
        }
        .frame(width: 130, height: 130)
    }

    private func ring(index i: Int, time t: Double) -> some View {
        let phase = Double(i) * 0.7
        let multiplier = 1.5 + Double(i) * 0.5
        let audioBoost = Double(audioLevel) * (0.08 + Double(i) * 0.04)
        let scale = 1.0 + sin(t * speed + phase) * intensity * multiplier + audioBoost
        let ringSize = coreSize + CGFloat(i + 1) * 14
        let baseOpacity = isRunning ? max(0.06 - Double(i) * 0.015, 0.02) : (i == 0 ? 0.04 : 0.0)
        let opacityBoost = Double(audioLevel) * 0.04
        let blurRadius = CGFloat(i + 1) * 3.5 + audioLevel * CGFloat(i) * 1.0

        return Circle()
            .fill(color.opacity(baseOpacity + opacityBoost))
            .frame(width: ringSize, height: ringSize)
            .scaleEffect(scale)
            .blur(radius: blurRadius)
    }

    private func core(time t: Double) -> some View {
        let audioBoost = Double(audioLevel) * 0.06
        let coreScale = 1.0 + sin(t * speed) * intensity * 0.5 + audioBoost
        let innerOpacityBoost = Double(audioLevel) * 0.1

        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        color.opacity((isRunning ? 0.3 : 0.18) + innerOpacityBoost),
                        color.opacity((isRunning ? 0.1 : 0.06) + innerOpacityBoost * 0.5),
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: coreSize / 2
                )
            )
            .frame(width: coreSize, height: coreSize)
            .scaleEffect(coreScale)
    }

    private var icon: some View {
        Image(systemName: isRunning ? "stop.fill" : "mic.fill")
            .font(.system(size: 22))
            .foregroundStyle(isRunning ? .red : .accentColor)
    }
}

// MARK: - Bubble Role

private enum VoiceBubbleRole {
    case user, assistant
}

// MARK: - Voice Bubble

private struct VoiceBubble: View {
    let text: String
    let role: VoiceBubbleRole
    var isLive: Bool = false

    var body: some View {
        let bgColor: Color = role == .user
            ? Color.accentColor.opacity(0.15)
            : Color(nsColor: .controlBackgroundColor)

        HStack(alignment: .top) {
            if role == .user { Spacer(minLength: 4) }

            StructuredText(markdown: text, syntaxExtensions: [.math])
                .textual.headingStyle(VoiceHeadingStyle())
                .textual.textSelection(.enabled)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: role == .user ? .trailing : .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(bgColor)
                )
                .opacity(isLive ? 0.85 : 1.0)

            if role == .assistant { Spacer(minLength: 4) }
        }
    }
}

// MARK: - Turn Row

private struct VoiceTurnRow: View {
    let turn: VoiceTurn

    var body: some View {
        VStack(spacing: 8) {
            VoiceBubble(text: turn.userText, role: .user)
            VoiceBubble(text: turn.assistantText, role: .assistant)
        }
    }
}

// MARK: - Ambient Glow

private struct AmbientGlow: View {
    let color: Color
    let audioLevel: CGFloat

    var body: some View {
        ZStack {
            // Bottom edge — strongest glow
            LinearGradient(
                colors: [color.opacity(0.08 * audioLevel), .clear],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: 120)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            // Left edge
            LinearGradient(
                colors: [color.opacity(0.04 * audioLevel), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            // Right edge
            LinearGradient(
                colors: [color.opacity(0.04 * audioLevel), .clear],
                startPoint: .trailing,
                endPoint: .leading
            )
            .frame(width: 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

// MARK: - Compact heading style for voice bubbles

private struct VoiceHeadingStyle: StructuredText.HeadingStyle {
    private static let fontScales: [CGFloat] = [1.3, 1.15, 1.05, 1.0, 0.9, 0.85]

    func makeBody(configuration: Configuration) -> some View {
        let level = min(configuration.headingLevel, 6)
        let scale = Self.fontScales[level - 1]

        configuration.label
            .textual.fontScale(scale)
            .textual.lineSpacing(.fontScaled(0.1))
            .textual.blockSpacing(.fontScaled(top: 0.6, bottom: 0.3))
            .fontWeight(.semibold)
    }
}
