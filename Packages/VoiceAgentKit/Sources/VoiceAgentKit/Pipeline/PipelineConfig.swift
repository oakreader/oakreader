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

    public init(
        models: VoiceModelConfig = VoiceModelConfig(),
        systemPrompt: String = "You are a helpful voice assistant. Keep your responses concise and conversational.",
        captureSampleRate: Double = 16000,
        sentenceDelimiters: Set<Character> = [".", "!", "?", ";", "\n"],
        minSentenceLength: Int = 10,
        minFirstSentenceLength: Int = 1,
        referenceAudioURL: URL? = nil,
        referenceText: String? = nil
    ) {
        self.models = models
        self.systemPrompt = systemPrompt
        self.captureSampleRate = captureSampleRate
        self.sentenceDelimiters = sentenceDelimiters
        self.minSentenceLength = minSentenceLength
        self.minFirstSentenceLength = minFirstSentenceLength
        self.referenceAudioURL = referenceAudioURL
        self.referenceText = referenceText
    }

    /// TTS voice (shorthand for `models.ttsVoice`).
    public var voice: String? {
        get { models.ttsVoice }
        set { models.ttsVoice = newValue }
    }
}
