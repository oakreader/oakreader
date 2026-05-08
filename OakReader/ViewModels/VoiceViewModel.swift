import Foundation
import VoiceAgentKit
import OakReaderAI

@Observable
class VoiceViewModel {
    var agentState: AgentState = .idle
    var userTranscript: String = ""
    var assistantText: String = ""
    var turns: [VoiceTurn] = []
    var error: String?

    private var pipeline: VoicePipeline?
    private var eventTask: Task<Void, Never>?

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

        let turnDetectorRepo: String? = prefs.voiceTurnDetectorEnabled
            ? KnownModels.turnDetector.first?.repo
            : nil

        let language = prefs.voiceLanguage

        var pipelineConfig = PipelineConfig()
        pipelineConfig.models = VoiceModelConfig(
            sttModel: sttRepo,
            ttsModel: ttsRepo,
            vadModel: vadRepo,
            turnDetectorModel: turnDetectorRepo,
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

        IMPORTANT: The user's messages come from automatic speech recognition (ASR), \
        which may contain transcription errors, misheard words, or missing punctuation. \
        Interpret the user's intent from context rather than taking every word literally. \
        If something seems like a transcription mistake, infer the most likely meaning \
        and respond accordingly. Do not point out ASR errors unless the meaning is truly ambiguous.
        """
        pipelineConfig.language = language
        pipelineConfig.referenceAudioURL = prefs.voiceReferenceAudioURL
        pipelineConfig.referenceText = prefs.voiceReferenceText.isEmpty ? nil : prefs.voiceReferenceText

        let stt = MLXSTTProvider(repoId: sttRepo, manager: modelManager)
        let tts = MLXTTSProvider(repoId: ttsRepo, language: language, manager: modelManager)
        let vad = MLXVADProvider(repoId: vadRepo, threshold: pipelineConfig.vadThreshold, manager: modelManager)

        let newPipeline = VoicePipeline(
            stt: stt,
            tts: tts,
            vad: vad,
            llm: llm,
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
        Task { await p.stop() }
    }

    var isRunning: Bool {
        pipeline != nil
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

        case .error(let voiceError):
            error = voiceError.localizedDescription
        }
    }

    /// Called when the event stream ends — pipeline has stopped or crashed.
    @MainActor
    private func handlePipelineEnded() {
        pipeline = nil
        eventTask = nil
        agentState = .idle
    }
}
