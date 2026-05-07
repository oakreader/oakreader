import AVFoundation
import MLX
import MLXAudioVAD

/// Main orchestrator for the STT → LLM → TTS voice pipeline.
///
/// The pipeline captures microphone audio, detects speech via VAD,
/// transcribes with STT, generates a response via LLM (with sentence-level streaming),
/// synthesizes speech via TTS, and plays it back — all while supporting interruption.
///
/// Uses a hybrid VAD approach:
/// - **Silero VAD**: real-time frame-level speech detection (streaming)
/// - **SmartTurn**: end-of-turn verification after speech ends (non-streaming)
public actor VoicePipeline {
    // MARK: - Services

    private let stt: any STTService
    private let tts: any TTSService
    private let vad: any VADService
    private let llm: any LLMService
    private let capture: any AudioCaptureService
    private let playback: any AudioPlaybackService

    // MARK: - Configuration

    private let config: PipelineConfig
    private let session: VoiceSession

    // MARK: - SmartTurn endpoint detection

    private var smartTurnModel: SmartTurnModel?
    private let smartTurnRepo: String?

    // MARK: - State

    private var state: AgentState = .idle
    private var eventContinuation: AsyncStream<PipelineEvent>.Continuation?
    private var pipelineTask: Task<Void, Never>?

    /// Active LLM+TTS response task — cancelled on interruption.
    private var responseTask: Task<Void, Never>?

    /// Counts consecutive high-energy speech chunks during agent speaking (echo filtering).
    private var interruptSpeechFrames: Int = 0

    /// Counts consecutive silence chunks while in `.userSpeaking` state.
    /// If this exceeds the timeout threshold, force the turn to complete
    /// (prevents getting stuck when SmartTurn incorrectly says "not done").
    private var userSpeakingSilenceFrames: Int = 0
    /// ~2 seconds of silence in `.userSpeaking` triggers forced turn completion.
    private static let userSpeakingSilenceTimeout = 90

    // MARK: - Echo filtering state

    /// Running average of audio RMS during TTS playback (echo baseline).
    private var echoBaseline: Float = 0
    /// Number of chunks used to build the echo baseline.
    private var echoBaselineCount: Int = 0
    /// Chunks needed to calibrate echo level (~0.5s at 16kHz / 341-sample chunks).
    private static let echoCalibrationChunks = 22

    /// Number of recent audio chunks to keep as pre-roll. When the VAD fires
    /// `speechStart`, the onset is already partially consumed by the VAD's
    /// internal 512-sample window. Prepending pre-roll chunks avoids clipping.
    private static let preRollChunks = 2

    /// Stream of pipeline events for UI observation.
    public let events: AsyncStream<PipelineEvent>

    // MARK: - Init

    public init(
        stt: any STTService,
        tts: any TTSService,
        vad: any VADService,
        llm: any LLMService,
        capture: any AudioCaptureService = MicrophoneCapture(),
        playback: any AudioPlaybackService = SpeakerOutput(),
        config: PipelineConfig = PipelineConfig(),
        session: VoiceSession = VoiceSession()
    ) {
        self.stt = stt
        self.tts = tts
        self.vad = vad
        self.llm = llm
        self.capture = capture
        self.playback = playback
        self.config = config
        self.session = session
        self.smartTurnRepo = config.models.turnDetectorModel

        var continuation: AsyncStream<PipelineEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    // MARK: - Lifecycle

    /// Start the voice pipeline. Begins listening for speech.
    public func start() throws {
        guard state == .idle else { return }

        pipelineTask = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline()
        }
    }

    /// Stop the voice pipeline and release resources.
    public func stop() {
        pipelineTask?.cancel()
        pipelineTask = nil
        responseTask?.cancel()
        responseTask = nil
        playback.stop()
        capture.stopCapture()
        transition(to: .idle)
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: - Main loop

    /// Minimum consecutive *high-energy* speech frames required to trigger
    /// interruption during agent speaking. At 16 kHz with ~341-frame chunks,
    /// ~22 chunks ≈ 0.5 seconds of sustained loud speech.
    private static let interruptMinFrames = 22

    private func runPipeline() async {
        // Pre-warm models in the background — don't block capture startup.
        // The first turn may be slightly slower, but the mic starts immediately.
        let warmupTask = Task { await preWarmModels() }
        defer { warmupTask.cancel() }

        do {
            let audioStream = try capture.startCapture(sampleRate: config.captureSampleRate)
            transition(to: .listening)

            // `speechBuffers` holds the current speech phrase (reset per phrase).
            // `turnBuffers` accumulates across pauses within a single turn when
            // SmartTurn says "not done", so earlier phrases are preserved.
            // `preRoll` is a small ring buffer of recent chunks so we can
            // recover audio consumed by the VAD before it fires speechStart.
            var speechBuffers: [AVAudioPCMBuffer] = []
            var turnBuffers: [AVAudioPCMBuffer] = []
            var preRoll: [AVAudioPCMBuffer] = []

            for await chunk in audioStream {
                guard !Task.isCancelled else { break }

                let vadEvent = try await vad.process(chunk: chunk)

                // Maintain pre-roll ring buffer while not capturing speech
                if state == .listening || state == .idle {
                    preRoll.append(chunk)
                    if preRoll.count > Self.preRollChunks {
                        preRoll.removeFirst()
                    }
                }

                // During TTS playback, build an echo energy baseline from the
                // first ~0.5s of chunks, then only count interrupt frames when
                // the chunk energy significantly exceeds the baseline.
                if state == .speaking {
                    let energy = Self.rms(of: chunk)
                    if echoBaselineCount < Self.echoCalibrationChunks {
                        // Still calibrating — accumulate baseline, ignore all VAD
                        echoBaseline = (echoBaseline * Float(echoBaselineCount) + energy)
                            / Float(echoBaselineCount + 1)
                        echoBaselineCount += 1
                        continue // skip VAD event processing entirely
                    }
                }

                switch vadEvent {
                case .speechStart:
                    userSpeakingSilenceFrames = 0
                    if state == .speaking {
                        // Energy must exceed echo baseline significantly to count
                        let energy = Self.rms(of: chunk)
                        let threshold = max(echoBaseline * 3.0, 0.02)
                        if energy > threshold {
                            interruptSpeechFrames = 1
                            speechBuffers = [chunk]
                        }
                    } else if state == .thinking {
                        // No speaker echo while thinking — interrupt immediately
                        interruptResponse()
                        interruptSpeechFrames = 0
                        // Prepend pre-roll to recover clipped onset
                        speechBuffers = preRoll + [chunk]
                        preRoll = []
                        turnBuffers = []
                        transition(to: .userSpeaking)
                        emit(.userSpeechStarted)
                    } else {
                        // Prepend pre-roll to recover audio consumed by VAD
                        speechBuffers = preRoll + [chunk]
                        preRoll = []
                        if state != .userSpeaking {
                            // New turn — first phrase
                            turnBuffers = []
                            transition(to: .userSpeaking)
                            emit(.userSpeechStarted)
                        }
                        // If already .userSpeaking (resuming after SmartTurn pause),
                        // just start a new phrase within the same turn.
                    }

                case .speechContinuing:
                    userSpeakingSilenceFrames = 0
                    if state == .speaking {
                        // Only count frames with energy above echo baseline
                        if interruptSpeechFrames > 0 {
                            let energy = Self.rms(of: chunk)
                            let threshold = max(echoBaseline * 3.0, 0.02)
                            if energy > threshold {
                                interruptSpeechFrames += 1
                                speechBuffers.append(chunk)
                            } else {
                                // Energy dropped — was echo, not real speech
                                interruptSpeechFrames = 0
                                speechBuffers = []
                            }

                            if interruptSpeechFrames >= Self.interruptMinFrames {
                                // Confirmed real interruption (sustained loud speech)
                                interruptResponse()
                                interruptSpeechFrames = 0
                                turnBuffers = speechBuffers
                                speechBuffers = []
                                transition(to: .userSpeaking)
                                emit(.userSpeechStarted)
                            }
                        }
                    } else if state == .userSpeaking {
                        speechBuffers.append(chunk)
                    }

                case .speechEnd:
                    if interruptSpeechFrames > 0 {
                        // Speech ended before reaching interrupt threshold — echo, discard
                        interruptSpeechFrames = 0
                        speechBuffers = []
                        continue
                    }

                    if state == .userSpeaking {
                        speechBuffers.append(chunk)
                    }

                    // Accumulate this phrase into the turn-level buffer
                    turnBuffers.append(contentsOf: speechBuffers)
                    speechBuffers = []

                    // Require minimum speech duration (0.5s) to avoid ASR hallucination
                    let totalFrames = turnBuffers.reduce(0) { $0 + Int($1.frameLength) }
                    let minFrames = Int(config.captureSampleRate * 0.5)
                    guard totalFrames >= minFrames else {
                        turnBuffers = []
                        if state == .userSpeaking {
                            transition(to: .listening)
                        }
                        continue
                    }

                    // SmartTurn endpoint verification: is the user done speaking?
                    if let endpointResult = await checkEndpoint(speechBuffers: turnBuffers) {
                        if !endpointResult {
                            // SmartTurn says user is just pausing — stay in
                            // .userSpeaking and keep turnBuffers for next phrase.
                            continue
                        }
                    }

                    emit(.userSpeechEnded)

                    // Transcribe and respond with the full turn audio
                    let capturedBuffers = turnBuffers
                    turnBuffers = []
                    await startResponse(speechBuffers: capturedBuffers)

                case .silence:
                    if interruptSpeechFrames > 0 {
                        // Speech stopped during echo detection — reset
                        interruptSpeechFrames = 0
                        speechBuffers = []
                    }

                    // Timeout: if stuck in .userSpeaking with sustained silence
                    // (e.g., SmartTurn said "not done" but user actually stopped),
                    // force the turn to complete.
                    if state == .userSpeaking {
                        userSpeakingSilenceFrames += 1
                        if userSpeakingSilenceFrames >= Self.userSpeakingSilenceTimeout,
                           !turnBuffers.isEmpty {
                            userSpeakingSilenceFrames = 0
                            emit(.userSpeechEnded)
                            let capturedBuffers = turnBuffers
                            turnBuffers = []
                            await startResponse(speechBuffers: capturedBuffers)
                        }
                    } else {
                        userSpeakingSilenceFrames = 0
                    }
                }
            }
        } catch {
            if !Task.isCancelled {
                emit(.error(VoiceAgentError.audioCaptureError(error.localizedDescription)))
            }
        }

        // Cancel any in-flight response
        responseTask?.cancel()
        responseTask = nil

        transition(to: .idle)
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: - Model pre-warming

    /// Pre-load all models in parallel so the first turn has no cold-start delay.
    private func preWarmModels() async {
        await withTaskGroup(of: Void.self) { group in
            // SmartTurn (optional)
            if let repo = smartTurnRepo {
                group.addTask {
                    do {
                        let model = try await SmartTurnModel.fromPretrained(repo)
                        await self.setSmartTurnModel(model)
                    } catch {
                        // SmartTurn is optional — continue without it
                    }
                }
            }
            // STT — trigger ensureModel via a no-op protocol method
            group.addTask { _ = try? await self.stt.transcribe(audio: self.makeSilentBuffer()) }
            // TTS — use a short real word; empty string triggers a precondition
            // failure inside Qwen3TTSModel.prepareGenerationInputs.
            group.addTask { _ = try? await self.tts.synthesize(text: ".", voice: self.config.voice, referenceAudioURL: nil) }
            // VAD
            group.addTask { _ = try? await self.vad.process(chunk: self.makeSilentBuffer()); await self.vad.reset() }
        }
    }

    private func setSmartTurnModel(_ model: SmartTurnModel) {
        self.smartTurnModel = model
    }

    /// Create a minimal silent buffer for model pre-warming.
    private nonisolated func makeSilentBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512
        // Zero-filled by default
        return buffer
    }

    /// Check if the user has finished their turn using SmartTurn.
    /// Returns true if endpoint confirmed, false if just a pause, nil if SmartTurn unavailable.
    private func checkEndpoint(speechBuffers: [AVAudioPCMBuffer]) async -> Bool? {
        guard let model = smartTurnModel else { return nil }

        // Extract raw samples from buffers
        var allSamples: [Float] = []
        for buffer in speechBuffers {
            guard let floatData = buffer.floatChannelData else { continue }
            let count = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: floatData[0], count: count))
            allSamples.append(contentsOf: samples)
        }

        guard !allSamples.isEmpty else { return nil }

        do {
            let audio = MLXArray(allSamples)
            let result = try model.predictEndpoint(audio, sampleRate: Int(config.captureSampleRate))
            return result.prediction == 1
        } catch {
            // SmartTurn failed — fall through to proceed without it
            return nil
        }
    }

    // MARK: - Response lifecycle

    /// Kick off transcription → LLM → TTS entirely in a background task.
    /// The audio loop returns immediately so VAD keeps processing for interruption.
    private func startResponse(speechBuffers: [AVAudioPCMBuffer]) async {
        // Cancel any prior response still running
        responseTask?.cancel()
        responseTask = nil

        transition(to: .thinking)
        emit(.agentThinking)

        // Reset VAD state so Silero streaming context doesn't leak across turns
        await vad.reset()

        // Everything runs in the response task — audio loop stays free
        responseTask = Task {
            await self.runFullResponse(speechBuffers: speechBuffers)
        }
    }

    /// Full STT → LLM → TTS pipeline, running concurrently with the audio loop.
    private func runFullResponse(speechBuffers: [AVAudioPCMBuffer]) async {
        let turnStarted = Date()

        // --- STT phase ---
        let audioStream = AsyncStream<AVAudioPCMBuffer> { continuation in
            for buffer in speechBuffers { continuation.yield(buffer) }
            continuation.finish()
        }

        var finalText: String?
        var lastPartialText: String?
        do {
            let transcriptStream = stt.transcribeStream(audioStream: audioStream)
            for try await partial in transcriptStream {
                guard !Task.isCancelled else { return }
                if partial.isFinal {
                    finalText = partial.text
                    emit(.userTranscript(text: partial.text, isFinal: true))
                } else {
                    lastPartialText = partial.text
                    emit(.userTranscript(text: partial.text, isFinal: false))
                }
            }
        } catch {
            if !Task.isCancelled {
                emit(.error(VoiceAgentError.sttFailed(error.localizedDescription)))
                transition(to: .listening)
            }
            return
        }

        guard !Task.isCancelled else { return }

        guard let transcriptionText = finalText ?? lastPartialText else {
            transition(to: .listening)
            return
        }

        let userText = transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty else {
            transition(to: .listening)
            return
        }

        // Record user message
        let userMessage = VoiceMessage(role: .user, content: userText)
        session.addMessage(userMessage)

        // --- LLM + TTS phase ---
        do {
            let fullResponse = try await processLLMResponse(userText: userText)

            guard !Task.isCancelled else { return }

            let assistantMessage = VoiceMessage(role: .assistant, content: fullResponse)
            session.addMessage(assistantMessage)

            let turn = VoiceTurn(
                userText: userText,
                assistantText: fullResponse,
                startedAt: turnStarted,
                completedAt: Date()
            )
            session.addTurn(turn)
            emit(.turnCompleted(turn))
            transition(to: .listening)
        } catch {
            if !Task.isCancelled {
                emit(.error(VoiceAgentError.llmFailed(error.localizedDescription)))
                transition(to: .listening)
            }
        }
    }

    /// Interrupt an in-flight response (user started speaking).
    private func interruptResponse() {
        responseTask?.cancel()
        responseTask = nil
        playback.stop()
        transition(to: .interrupted)
        emit(.agentInterrupted)
    }

    // MARK: - LLM + TTS processing

    /// Process the LLM response with sentence-level buffering and streaming TTS.
    /// Returns the full response text.
    private func processLLMResponse(userText: String) async throws -> String {
        let llmStream = llm.respond(
            userMessage: userText,
            history: session.messages,
            systemPrompt: config.systemPrompt
        )

        var fullText = ""
        var sentenceBuffer = ""
        var isFirstSentence = true
        var didStartSpeech = false

        // Create a passthrough stream for TTS buffers that we can feed into playback
        var ttsContinuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation!
        let ttsBufferStream = AsyncThrowingStream<AVAudioPCMBuffer, Error> { ttsContinuation = $0 }

        // Start playback concurrently
        let playbackTask = Task {
            try await playback.play(buffers: ttsBufferStream)
        }

        // Always clean up the playback task, even on error or cancellation
        defer {
            if Task.isCancelled {
                playback.stop()
            }
            playbackTask.cancel()
        }

        do {
            for try await delta in llmStream {
                try Task.checkCancellation()

                fullText += delta
                sentenceBuffer += delta
                emit(.agentResponseText(delta: delta))

                // Check for sentence boundary — use a lower threshold for the
                // first sentence to reduce time-to-first-audio.
                let threshold = isFirstSentence ? config.minFirstSentenceLength : config.minSentenceLength
                if let lastChar = sentenceBuffer.last,
                   config.sentenceDelimiters.contains(lastChar),
                   sentenceBuffer.count >= threshold {
                    let sentence = sentenceBuffer
                    sentenceBuffer = ""
                    isFirstSentence = false

                    // Stream TTS for this sentence
                    let ttsStream = tts.synthesizeStream(text: sentence, voice: config.voice, referenceAudioURL: config.referenceAudioURL, referenceText: config.referenceText)
                    for try await buffer in ttsStream {
                        try Task.checkCancellation()
                        if !didStartSpeech {
                            transition(to: .speaking)
                            emit(.agentSpeechStarted)
                            didStartSpeech = true
                        }
                        ttsContinuation.yield(buffer)
                    }
                }
            }

            // Flush remaining text (skip if cancelled — user interrupted)
            try Task.checkCancellation()
            if !sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let ttsStream = tts.synthesizeStream(text: sentenceBuffer, voice: config.voice, referenceAudioURL: config.referenceAudioURL, referenceText: config.referenceText)
                for try await buffer in ttsStream {
                    try Task.checkCancellation()
                    if !didStartSpeech {
                        transition(to: .speaking)
                        emit(.agentSpeechStarted)
                        didStartSpeech = true
                    }
                    ttsContinuation.yield(buffer)
                }
            }

            try Task.checkCancellation()
            ttsContinuation.finish()
            emit(.agentResponseComplete(fullText: fullText))
        } catch {
            ttsContinuation.finish(throwing: error)
            throw error
        }

        // Wait for playback to complete
        try await playbackTask.value
        if didStartSpeech {
            emit(.agentSpeechEnded)
        }

        return fullText
    }

    // MARK: - State management

    private func transition(to newState: AgentState) {
        guard state != newState else { return }
        // Reset echo calibration when entering speaking state
        if newState == .speaking {
            echoBaseline = 0
            echoBaselineCount = 0
            interruptSpeechFrames = 0
        }
        // Allow forced transitions (the state machine validates the happy path,
        // but stop/interruption can happen from any state)
        state = newState
        emit(.stateChanged(newState))
    }

    private func emit(_ event: PipelineEvent) {
        eventContinuation?.yield(event)
    }

    /// Compute RMS (root-mean-square) energy of a PCM buffer.
    /// Used to distinguish real speech (high energy) from echo (low energy).
    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sumSq: Float = 0
        for i in 0..<count {
            sumSq += data[i] * data[i]
        }
        return sqrt(sumSq / Float(count))
    }
}

// MARK: - Audio buffer utilities

/// Combine multiple PCM buffers into a single buffer.
private func combineBuffers(_ buffers: [AVAudioPCMBuffer], sampleRate: Double) throws -> AVAudioPCMBuffer {
    guard !buffers.isEmpty else {
        throw VoiceAgentError.sttFailed("No audio buffers to combine")
    }

    let totalFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }

    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ) else {
        throw VoiceAgentError.sttFailed("Failed to create audio format")
    }

    guard let combined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
        throw VoiceAgentError.sttFailed("Failed to create combined buffer")
    }

    var offset = 0
    for buffer in buffers {
        guard let srcData = buffer.floatChannelData?[0],
              let dstData = combined.floatChannelData?[0] else { continue }
        let count = Int(buffer.frameLength)
        dstData.advanced(by: offset).update(from: srcData, count: count)
        offset += count
    }
    combined.frameLength = AVAudioFrameCount(totalFrames)

    return combined
}
