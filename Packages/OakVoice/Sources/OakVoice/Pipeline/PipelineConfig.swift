import Foundation

/// Configuration for the voice pipeline.
public struct PipelineConfig: Sendable {
    /// Which models to use for STT, TTS, and VAD.
    public var models: VoiceModelConfig

    /// System prompt provided to the LLM.
    public var systemPrompt: String

    /// Sample rate for audio capture (VAD and STT typically require 16kHz).
    public var captureSampleRate: Double

    /// Characters that delimit sentence boundaries for streaming TTS.
    public var sentenceDelimiters: Set<Character>

    /// Delimiters used for the *first* sentence of each response.
    /// Includes comma and colon so phrases like "Sure, I can help." trigger
    /// TTS at "Sure," instead of waiting for the period — reducing perceived latency.
    public var firstSentenceDelimiters: Set<Character>

    /// Minimum number of characters to buffer before sending to TTS.
    public var minSentenceLength: Int

    /// Minimum character count for the *first* sentence of each response.
    /// A lower value (default 1) lets the first sentence reach TTS immediately
    /// on any delimiter, reducing perceived latency. Subsequent sentences use
    /// `minSentenceLength` for better prosody.
    public var minFirstSentenceLength: Int

    /// Reference audio URL for voice cloning. When set, TTS will clone this voice.
    public var referenceAudioURL: URL?

    /// Transcript of the reference audio clip. Required by Qwen3-TTS for voice cloning.
    public var referenceText: String?

    /// Language code for STT/TTS (e.g. "en", "zh", "ja", "ko").
    /// Defaults to English. Passed to TTS for correct pronunciation and prosody.
    public var language: String

    /// Enable live (streaming) transcription during speech using Parakeet.
    /// When true and a liveSTT model is configured, partial transcripts appear
    /// in real-time while the user speaks. Qwen3-ASR still produces the final transcript.
    public var enableLiveTranscription: Bool

    /// VAD speech activation threshold (0.0–1.0). Speech starts when probability
    /// exceeds this value. Silero/LiveKit/OpenAI all default to 0.5. A hysteresis
    /// gap of 0.15 is applied internally (deactivation at threshold − 0.15) to
    /// prevent rapid toggling near the boundary.
    public var vadThreshold: Float

    public init(
        models: VoiceModelConfig = VoiceModelConfig(),
        systemPrompt: String = "You are a helpful voice assistant. Keep your responses concise and conversational.",
        captureSampleRate: Double = 16000,
        sentenceDelimiters: Set<Character> = [".", "!", "?", ";", "\n"],
        firstSentenceDelimiters: Set<Character> = [".", "!", "?", ";", ",", ":", "\n"],
        minSentenceLength: Int = 10,
        minFirstSentenceLength: Int = 1,
        referenceAudioURL: URL? = nil,
        referenceText: String? = nil,
        language: String = "en",
        enableLiveTranscription: Bool = true,
        vadThreshold: Float = 0.5
    ) {
        self.models = models
        self.systemPrompt = systemPrompt
        self.captureSampleRate = captureSampleRate
        self.sentenceDelimiters = sentenceDelimiters
        self.firstSentenceDelimiters = firstSentenceDelimiters
        self.minSentenceLength = minSentenceLength
        self.minFirstSentenceLength = minFirstSentenceLength
        self.referenceAudioURL = referenceAudioURL
        self.referenceText = referenceText
        self.language = language
        self.enableLiveTranscription = enableLiveTranscription
        self.vadThreshold = vadThreshold
    }

    /// TTS voice (shorthand for `models.ttsVoice`).
    public var voice: String? {
        get { models.ttsVoice }
        set { models.ttsVoice = newValue }
    }
}
