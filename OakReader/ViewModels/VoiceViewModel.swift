import Foundation
import os
import VoiceAgentKit
import OakReaderAI

private let voiceLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.oakreader.OakReader", category: "voice")

@Observable
class VoiceViewModel {
    var agentState: AgentState = .idle
    var userTranscript: String = ""
    var assistantText: String = ""
    var turns: [VoiceTurn] = []
    var error: String?

    /// Smoothed audio level for UI visualization (0.0–1.0).
    var audioLevel: Float = 0

    /// Whether standalone TTS playback is active (separate from full voice pipeline).
    var isSpeaking: Bool = false

    private var pipeline: VoicePipeline?
    private var eventTask: Task<Void, Never>?

    // MARK: - Audio level smoothing state

    /// Raw EMA-smoothed RMS value (before normalization).
    private var rawSmoothedLevel: Float = 0
    /// Counter for throttling audio level updates (~15Hz from ~45Hz input).
    private var levelUpdateCounter: Int = 0

    // MARK: - Standalone TTS state
    private var ttsProvider: MLXTTSProvider?
    private var ttsProviderRepo: String?
    private var speakerOutput: SpeakerOutput?
    private var ttsPlaybackTask: Task<Void, Never>?

    // MARK: - Lifecycle

    @MainActor
    func start() async {
        guard pipeline == nil else { return }
        error = nil
        userTranscript = ""
        assistantText = ""

        let prefs = Preferences.shared
        let defaultSTT = KnownModels.stt.first?.repo ?? ""
        let defaultTTS = KnownModels.tts.first?.repo ?? ""
        let defaultVAD = KnownModels.vad.first?.repo ?? ""

        let sttRepo = prefs.voiceSTTModel.isEmpty ? defaultSTT : prefs.voiceSTTModel
        let ttsRepo = prefs.voiceTTSModel.isEmpty ? defaultTTS : prefs.voiceTTSModel
        let vadRepo = prefs.voiceVADModel.isEmpty ? defaultVAD : prefs.voiceVADModel
        let voice = prefs.voiceTTSVoice.isEmpty ? nil : prefs.voiceTTSVoice

        let modelManager = ModelManager.shared

        // Pre-flight: verify required models are downloaded
        let requiredModels = [
            ("STT", sttRepo),
            ("TTS", ttsRepo),
            ("VAD", vadRepo),
        ]
        for (label, repo) in requiredModels {
            let downloaded = await modelManager.isDownloaded(repo)
            if !downloaded {
                self.error = "\(label) model not downloaded: \(repo). Please download it from Settings → Voice first."
                return
            }
        }

        // Build LLM bridge using shared ChatEngine + provider config.
        // Use the voice-specific LLM model if set, otherwise fall back to AI Chat model.
        let chatEngine = ChatEngine()
        let pid = prefs.aiProviderId
        let defaultModel = ProviderRegistry.shared.provider(for: pid)?.defaultModelId ?? ""
        let chatModel = prefs.aiModel.isEmpty ? defaultModel : prefs.aiModel
        let voiceModel = prefs.voiceLLMModel.isEmpty ? chatModel : prefs.voiceLLMModel
        let config = ProviderConfig(
            providerId: pid,
            model: voiceModel
        )
        let llm = ChatEngineBridge(chatEngine: chatEngine, config: config)

        let language = prefs.voiceLanguage

        var pipelineConfig = PipelineConfig()
        pipelineConfig.models = VoiceModelConfig(
            sttModel: sttRepo,
            ttsModel: ttsRepo,
            vadModel: vadRepo,
            ttsVoice: voice
        )
        let languageInstruction: String
        if language == "en" {
            languageInstruction = "Respond in English."
        } else {
            let displayName = VoiceLanguage(rawValue: language)?.displayName ?? language
            languageInstruction = "Respond in \(displayName). The user is speaking \(displayName)."
        }
        pipelineConfig.systemPrompt = """
        You are a friendly voice assistant for a reading app called OakReader. \
        Talk like a close friend — casual, warm, and natural. Use short sentences. \
        Avoid formal language or lists. React naturally to what the user says.

        \(languageInstruction)

        Your response will be read aloud by a text-to-speech engine. Follow these rules strictly:
        - Never use emojis, emoticons, or special symbols.
        - Never use markdown formatting (no **, *, #, -, bullet points, or numbered lists).
        - Write plain, speakable text only. Avoid abbreviations that sound unnatural when spoken aloud.
        - Keep responses concise — one to three short sentences is ideal.
        - When the response covers multiple points or is longer than two sentences, \
        insert a blank line between logical groups so the listener gets a natural pause.

        The user's messages come from automatic speech recognition (ASR), which may contain \
        transcription errors, misheard words, or missing punctuation. Interpret the user's intent \
        from context rather than taking every word literally. If something seems like a transcription \
        mistake, infer the most likely meaning and respond accordingly. Do not point out ASR errors \
        unless the meaning is truly ambiguous.
        """
        pipelineConfig.language = language
        pipelineConfig.referenceAudioURL = prefs.voiceReferenceAudioURL
        pipelineConfig.referenceText = prefs.voiceReferenceText.isEmpty ? nil : prefs.voiceReferenceText

        let stt = MLXSTTProvider(repoId: sttRepo, manager: modelManager)
        let tts = MLXTTSProvider(repoId: ttsRepo, language: language, manager: modelManager)
        let vad = MLXVADProvider(repoId: vadRepo, threshold: pipelineConfig.vadThreshold, manager: modelManager)

        // Audio device selection — empty UID means system default
        let inputUID = prefs.voiceInputDeviceUID.isEmpty ? nil : prefs.voiceInputDeviceUID
        let outputUID = prefs.voiceOutputDeviceUID.isEmpty ? nil : prefs.voiceOutputDeviceUID
        let mic = MicrophoneCapture(deviceUID: inputUID)
        let speaker = SpeakerOutput(deviceUID: outputUID)

        let newPipeline = VoicePipeline(
            stt: stt,
            tts: tts,
            vad: vad,
            llm: llm,
            capture: mic,
            playback: speaker,
            config: pipelineConfig,
            session: VoiceSession()
        )
        pipeline = newPipeline

        // Subscribe to events — access actor-isolated `events` with await
        let events = await newPipeline.events
        eventTask = Task { [weak self] in
            for await event in events {
                await MainActor.run {
                    self?.handleEvent(event)
                }
            }
            // Event stream ended — pipeline has stopped (crashed or finished)
            await MainActor.run {
                self?.handlePipelineEnded()
            }
        }

        do {
            try await newPipeline.start()
            agentState = .listening
        } catch {
            self.error = error.localizedDescription
            pipeline = nil
            eventTask?.cancel()
            eventTask = nil
        }
    }

    @MainActor
    func stop() {
        guard let pipeline else { return }
        let p = pipeline
        self.pipeline = nil
        eventTask?.cancel()
        eventTask = nil
        agentState = .idle
        error = nil
        audioLevel = 0
        rawSmoothedLevel = 0
        levelUpdateCounter = 0
        Task { await p.stop() }
    }

    var isRunning: Bool {
        pipeline != nil
    }

    // MARK: - Standalone TTS Playback

    @MainActor
    func speakText(_ text: String) {
        guard !isRunning else { return }
        stopSpeaking()
        isSpeaking = true

        let prefs = Preferences.shared
        let defaultTTS = KnownModels.tts.first?.repo ?? ""
        let ttsRepo = prefs.voiceTTSModel.isEmpty ? defaultTTS : prefs.voiceTTSModel
        let voice = prefs.voiceTTSVoice.isEmpty ? nil : prefs.voiceTTSVoice
        let language = prefs.voiceLanguage
        let refAudioURL = prefs.voiceReferenceAudioURL
        let refText = prefs.voiceReferenceText.isEmpty ? nil : prefs.voiceReferenceText
        let outputUID = prefs.voiceOutputDeviceUID.isEmpty ? nil : prefs.voiceOutputDeviceUID

        // Reuse TTS provider if same repo, otherwise create new one
        if ttsProvider == nil || ttsProviderRepo != ttsRepo {
            ttsProvider = MLXTTSProvider(repoId: ttsRepo, language: language, manager: ModelManager.shared)
            ttsProviderRepo = ttsRepo
        }

        let provider = ttsProvider!
        let speaker = SpeakerOutput(deviceUID: outputUID)
        speakerOutput = speaker

        let stream = provider.synthesizeStream(
            text: text,
            voice: voice,
            referenceAudioURL: refAudioURL,
            referenceText: refText
        )

        ttsPlaybackTask = Task { [weak self] in
            do {
                try await speaker.play(buffers: stream)
            } catch {
                if !Task.isCancelled {
                    voiceLog.error("TTS playback failed: \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                self?.isSpeaking = false
                self?.speakerOutput = nil
            }
        }
    }

    @MainActor
    func stopSpeaking() {
        ttsPlaybackTask?.cancel()
        ttsPlaybackTask = nil
        speakerOutput?.stop()
        speakerOutput = nil
        isSpeaking = false
    }

    // MARK: - Event Handling

    @MainActor
    private func handleEvent(_ event: PipelineEvent) {
        switch event {
        case .stateChanged(let state):
            agentState = state
            // Clear stale live transcript when returning to listening — the
            // speculative STT emits .userTranscript before .turnCompleted,
            // so any late or missed cleanup leaves a duplicate bubble.
            if state == .listening {
                userTranscript = ""
                assistantText = ""
            }

        case .userSpeechStarted:
            userTranscript = ""

        case .userSpeechEnded:
            break

        case .userTranscript(let text, _):
            userTranscript = text

        case .agentThinking:
            assistantText = ""

        case .agentResponseText(let delta):
            assistantText += delta

        case .agentResponseComplete:
            break

        case .agentSpeechStarted:
            break

        case .agentSpeechEnded:
            break

        case .agentInterrupted:
            // Save the interrupted turn so conversation history is preserved.
            // When the user interrupts during thinking/speaking, the in-flight
            // response task is cancelled before .turnCompleted fires — the turn
            // data would otherwise be lost when .userSpeechStarted clears the
            // live transcript fields.
            if !userTranscript.isEmpty {
                let partialTurn = VoiceTurn(
                    userText: userTranscript,
                    assistantText: assistantText,
                    startedAt: Date(),
                    completedAt: Date()
                )
                turns.append(partialTurn)
                userTranscript = ""
                assistantText = ""
            }

        case .turnCompleted(let turn):
            turns.append(turn)
            userTranscript = ""
            assistantText = ""

        case .audioLevel(let rms):
            updateAudioLevel(rms: rms)

        case .latencyMetrics(let metrics):
            let fmt = { (s: Double) in String(format: "%.0f", s * 1000) }
            voiceLog.info(
                "[VoicePipeline] Latency: STT=\(fmt(metrics.sttLatency))ms LLM=\(fmt(metrics.llmLatency))ms TTS=\(fmt(metrics.ttsLatency))ms Total=\(fmt(metrics.totalLatency))ms"
            )

        case .error(let voiceError):
            error = voiceError.localizedDescription
        }
    }

    /// Asymmetric EMA smoothing + power-curve normalization, throttled to ~15Hz.
    @MainActor
    private func updateAudioLevel(rms: Float) {
        // During thinking, no meaningful audio — decay toward 0
        if agentState == .thinking {
            rawSmoothedLevel *= 0.9
            audioLevel = rawSmoothedLevel < 0.001 ? 0 : audioLevel * 0.9
            return
        }

        // Asymmetric EMA: fast attack (α=0.4), slow decay (α=0.15)
        let alpha: Float = rms > rawSmoothedLevel ? 0.4 : 0.15
        rawSmoothedLevel += alpha * (rms - rawSmoothedLevel)

        // Throttle UI updates: publish every 3rd sample (~15Hz from ~45Hz)
        levelUpdateCounter += 1
        guard levelUpdateCounter >= 3 else { return }
        levelUpdateCounter = 0

        // Power-curve normalization: map [0, 0.25] → [0, 1] with toe compression
        let normalized = min(rawSmoothedLevel / 0.25, 1.0)
        audioLevel = pow(normalized, 0.6)
    }

    /// Called when the event stream ends — pipeline has stopped or crashed.
    @MainActor
    private func handlePipelineEnded() {
        pipeline = nil
        eventTask = nil
        agentState = .idle
        audioLevel = 0
        rawSmoothedLevel = 0
        levelUpdateCounter = 0
    }
}
