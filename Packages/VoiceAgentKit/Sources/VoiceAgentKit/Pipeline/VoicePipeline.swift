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
    private let audioRecorder: AudioRecorder?

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

    /// Detached SmartTurn endpoint detection task — cancelled (bounced) when
    /// the user resumes speaking before inference completes.
    private var endpointTask: Task<Void, Never>?

    /// Counts consecutive high-energy speech chunks during agent speaking (echo filtering).
    private var interruptSpeechFrames: Int = 0

    /// Counts consecutive silence chunks while in `.userSpeaking` state.
    /// If this exceeds the timeout threshold, force the turn to complete
    /// (prevents getting stuck when SmartTurn incorrectly says "not done").
    private var userSpeakingSilenceFrames: Int = 0
    /// ~1 second of silence in `.userSpeaking` triggers forced turn completion.
    /// The VAD already debounces 500ms of silence before firing speechEnd,
    /// so this 1s fallback is on top of that (total ~1.5s from actual silence).
    private static let userSpeakingSilenceTimeout = 45

    /// Energy-based fallback: counts consecutive low-energy chunks during
    /// `.userSpeaking`. If the VAD fails to fire `.speechEnd` (e.g. background
    /// noise keeps probability above threshold), this catches actual silence
    /// by checking RMS energy directly.
    private var lowEnergyFrames: Int = 0
    /// RMS energy below which a chunk is considered silence for the fallback.
    private static let speechEnergyFloor: Float = 0.01
    /// ~1 second of low-energy audio forces speech end.
    private static let lowEnergyTimeout = 45

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

    // MARK: - Latency instrumentation

    /// Timestamp when speech ended (VAD speechEnd, energy timeout, or silence timeout).
    private var speechEndTimestamp: CFAbsoluteTime = 0
    /// Timestamp when STT transcript became available.
    private var sttCompleteTimestamp: CFAbsoluteTime = 0
    /// Timestamp of the first LLM token received.
    private var llmFirstTokenTimestamp: CFAbsoluteTime = 0
    /// Timestamp of the first TTS audio buffer yielded to playback.
    private var ttsFirstBufferTimestamp: CFAbsoluteTime = 0

    /// Whether the agent has started speaking in the current response turn.
    /// Shared between LLM and TTS tasks via actor serialization.
    private var didStartSpeech = false

    /// Zero-based counter tracking the current turn number within the call.
    /// Incremented after each `.turnCompleted` event. Used to name per-turn
    /// audio files (`turn-0-user.caf`, `turn-1-agent.caf`, etc.).
    private var turnIndex: Int = 0

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
        session: VoiceSession = VoiceSession(),
        audioRecorder: AudioRecorder? = nil
    ) {
        self.stt = stt
        self.tts = tts
        self.vad = vad
        self.llm = llm
        self.capture = capture
        self.playback = playback
        self.config = config
        self.session = session
        self.audioRecorder = audioRecorder
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
    public func stop() async {
        pipelineTask?.cancel()
        pipelineTask = nil
        responseTask?.cancel()
        responseTask = nil
        endpointTask?.cancel()
        endpointTask = nil
        playback.stop()
        capture.stopCapture()
        await audioRecorder?.finalize()
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

                // Compute RMS once per chunk — reused by echo calibration,
                // energy fallback, and emitted for UI audio level visualization.
                let chunkEnergy = Self.rms(of: chunk)
                emit(.audioLevel(chunkEnergy))

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
                    if echoBaselineCount < Self.echoCalibrationChunks {
                        // Still calibrating — accumulate baseline, ignore all VAD
                        echoBaseline = (echoBaseline * Float(echoBaselineCount) + chunkEnergy)
                            / Float(echoBaselineCount + 1)
                        echoBaselineCount += 1
                        continue // skip VAD event processing entirely
                    }
                }

                // Energy-based fallback: force end-of-speech when actual audio
                // energy is low but the VAD is confused by background noise.
                if state == .userSpeaking {
                    if chunkEnergy < Self.speechEnergyFloor {
                        lowEnergyFrames += 1
                    } else {
                        lowEnergyFrames = 0
                    }

                    if lowEnergyFrames >= Self.lowEnergyTimeout {
                        lowEnergyFrames = 0
                        endpointTask?.cancel()
                        endpointTask = nil
                        speechEndTimestamp = CFAbsoluteTimeGetCurrent()

                        // Accumulate remaining speech
                        turnBuffers.append(contentsOf: speechBuffers)
                        speechBuffers = []

                        let totalFrames = turnBuffers.reduce(0) { $0 + Int($1.frameLength) }
                        let minFrames = Int(config.captureSampleRate * 0.5)
                        if totalFrames >= minFrames {
                            // Reset VAD — its LSTM state is confused
                            await vad.reset()
                            userSpeakingSilenceFrames = 0
                            emit(.userSpeechEnded)
                            let capturedBuffers = turnBuffers
                            turnBuffers = []
                            await startResponse(speechBuffers: capturedBuffers)
                        } else {
                            turnBuffers = []
                            userSpeakingSilenceFrames = 0
                            transition(to: .listening)
                        }
                        continue
                    }
                }

                switch vadEvent {
                case .speechStart:
                    lowEnergyFrames = 0
                    // Only reset for a new turn; brief noise during .userSpeaking
                    // must not restart the silence timeout counter.
                    if state != .userSpeaking {
                        userSpeakingSilenceFrames = 0
                    }
                    endpointTask?.cancel()
                    endpointTask = nil
                    if state == .speaking {
                        // Energy must exceed echo baseline significantly to count
                        let threshold = max(echoBaseline * 3.0, 0.02)
                        if chunkEnergy > threshold {
                            interruptSpeechFrames = 1
                            speechBuffers = [chunk]
                        }
                    } else if state == .thinking {
                        // Continuation, not interruption — cancel the premature
                        // response but keep turnBuffers so previous + new audio
                        // are transcribed together. No .userSpeechStarted event.
                        cancelPendingResponse()
                        interruptSpeechFrames = 0
                        speechBuffers = preRoll + [chunk]
                        preRoll = []
                        transition(to: .userSpeaking)
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
                    // Require ≥5 buffered frames (~100ms) before resetting the
                    // silence counter — filters out brief noise blips that would
                    // otherwise prevent the timeout from ever firing.
                    if state == .userSpeaking {
                        if speechBuffers.count >= 5 {
                            userSpeakingSilenceFrames = 0
                        }
                    } else {
                        userSpeakingSilenceFrames = 0
                    }
                    if state == .speaking {
                        // Only count frames with energy above echo baseline
                        if interruptSpeechFrames > 0 {
                            let threshold = max(echoBaseline * 3.0, 0.02)
                            if chunkEnergy > threshold {
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

                    // Only process speech end when actually capturing speech.
                    // Spurious speechEnd from echo/noise after playback would
                    // otherwise re-transcribe stale turnBuffers.
                    guard state == .userSpeaking else { continue }

                    speechBuffers.append(chunk)

                    // Accumulate this phrase into the turn-level buffer
                    turnBuffers.append(contentsOf: speechBuffers)
                    speechBuffers = []

                    // Require minimum speech duration (0.5s) to avoid ASR hallucination
                    let totalFrames = turnBuffers.reduce(0) { $0 + Int($1.frameLength) }
                    let minFrames = Int(config.captureSampleRate * 0.5)
                    guard totalFrames >= minFrames else {
                        turnBuffers = []
                        transition(to: .listening)
                        continue
                    }

                    speechEndTimestamp = CFAbsoluteTimeGetCurrent()

                    // Run SmartTurn and STT in parallel. By the time SmartTurn
                    // confirms the endpoint, the transcript is already ready —
                    // saving 1-3s of sequential STT processing from the critical path.
                    // If the user resumes speaking, both are cancelled (bounced).
                    let buffersForEndpoint = turnBuffers
                    endpointTask?.cancel()
                    endpointTask = Task { [weak self] in
                        guard let self else { return }
                        async let smartTurnResult = self.checkEndpoint(speechBuffers: buffersForEndpoint)
                        async let sttResult = self.transcribeSpeech(buffersForEndpoint)
                        let (endpointResult, transcript) = await (smartTurnResult, sttResult)
                        guard !Task.isCancelled else { return }
                        await self.completeEndpoint(
                            result: endpointResult,
                            transcript: transcript,
                            speechBuffers: buffersForEndpoint
                        )
                    }

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
                            // Cancel pending SmartTurn — silence timeout takes over
                            endpointTask?.cancel()
                            endpointTask = nil
                            speechEndTimestamp = CFAbsoluteTimeGetCurrent()
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

        // Cancel any in-flight response and pending endpoint check
        responseTask?.cancel()
        responseTask = nil
        endpointTask?.cancel()
        endpointTask = nil

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
            // Pass referenceAudioURL + referenceText so the voice conditioning
            // is prepared and cached during warmup, not on the first real sentence.
            group.addTask {
                _ = try? await self.tts.synthesize(
                    text: ".",
                    voice: self.config.voice,
                    referenceAudioURL: self.config.referenceAudioURL,
                    referenceText: self.config.referenceText
                )
            }
            // VAD is NOT warmed up here. The silent buffer would race with
            // live audio in the LSTM, corrupting the streaming state at an
            // unpredictable time. The VAD loads lazily on the first real
            // audio chunk via ensureModel() — adds ~100ms to the first
            // call but eliminates the race condition.
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

    /// Speculatively transcribe speech audio. Runs in parallel with SmartTurn
    /// so the transcript is ready by the time the endpoint is confirmed.
    /// Emits `.userTranscript` events for live UI updates.
    /// Returns the final transcript text, or nil if STT failed/was cancelled.
    private func transcribeSpeech(_ buffers: [AVAudioPCMBuffer]) async -> String? {
        let audioStream = AsyncStream<AVAudioPCMBuffer> { continuation in
            for buffer in buffers { continuation.yield(buffer) }
            continuation.finish()
        }

        var finalText: String?
        var lastPartialText: String?
        do {
            let transcriptStream = stt.transcribeStream(audioStream: audioStream)
            for try await partial in transcriptStream {
                guard !Task.isCancelled else { return nil }
                if partial.isFinal {
                    finalText = partial.text
                    emit(.userTranscript(text: partial.text, isFinal: true))
                } else {
                    lastPartialText = partial.text
                    emit(.userTranscript(text: partial.text, isFinal: false))
                }
            }
        } catch {
            // STT failed — caller will fall back to normal STT in runFullResponse
            return nil
        }
        return finalText ?? lastPartialText
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

    /// Handle the result of an async SmartTurn endpoint check.
    /// Guards against double-fire if the silence timeout already handled the turn.
    private func completeEndpoint(
        result: Bool?,
        transcript: String? = nil,
        speechBuffers: [AVAudioPCMBuffer]
    ) async {
        // Another path (silence timeout, bounce, or interruption) may have
        // already handled this turn — only proceed if still in userSpeaking.
        guard state == .userSpeaking else { return }
        if let endpointResult = result, !endpointResult {
            // SmartTurn says user is just pausing — do nothing,
            // wait for more speech or silence timeout.
            return
        }
        // Endpoint confirmed (or SmartTurn unavailable) — respond
        emit(.userSpeechEnded)
        await startResponse(speechBuffers: speechBuffers, transcript: transcript)
    }

    // MARK: - Response lifecycle

    /// Kick off transcription → LLM → TTS entirely in a background task.
    /// The audio loop returns immediately so VAD keeps processing for interruption.
    /// - Parameter transcript: Pre-computed STT transcript (from parallel speculative STT).
    ///   When provided, `runFullResponse` skips the STT phase entirely.
    private func startResponse(speechBuffers: [AVAudioPCMBuffer], transcript: String? = nil) async {
        // Cancel any prior response still running
        responseTask?.cancel()
        responseTask = nil

        transition(to: .thinking)
        emit(.agentThinking)

        // Do NOT reset VAD here. The LSTM hidden state needs to stay warm
        // across turns — resetting it creates a ~0.5s cold-start window
        // where speechStart never fires. LiveKit agents never reset VAD
        // during the audio loop, only on session shutdown.

        // Everything runs in the response task — audio loop stays free
        let capturedTranscript = transcript
        responseTask = Task {
            await self.runFullResponse(speechBuffers: speechBuffers, precomputedTranscript: capturedTranscript)
        }
    }

    /// Full STT → LLM → TTS pipeline, running concurrently with the audio loop.
    /// - Parameter precomputedTranscript: If provided (from speculative STT that ran
    ///   in parallel with SmartTurn), the STT phase is skipped entirely — saving
    ///   1-3 seconds of sequential processing.
    private func runFullResponse(speechBuffers: [AVAudioPCMBuffer], precomputedTranscript: String? = nil) async {
        let turnStarted = Date()
        let currentTurnIndex = turnIndex

        // Record user audio for this turn (non-blocking — errors are ignored)
        if let recorder = audioRecorder {
            try? await recorder.writeUserAudio(turnIndex: currentTurnIndex, buffers: speechBuffers)
        }

        // --- STT phase ---
        let transcriptionText: String?

        if let precomputed = precomputedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
           !precomputed.isEmpty {
            // Transcript was computed in parallel with SmartTurn — skip STT.
            // Transcript events were already emitted during speculative STT.
            transcriptionText = precomputed
            sttCompleteTimestamp = CFAbsoluteTimeGetCurrent()
        } else {
            // No pre-computed transcript — run STT normally
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
            transcriptionText = finalText ?? lastPartialText
            sttCompleteTimestamp = CFAbsoluteTimeGetCurrent()
        }

        guard let transcriptionText else {
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
            let fullResponse = try await processLLMResponse(userText: userText, currentTurnIndex: currentTurnIndex)

            guard !Task.isCancelled else { return }

            let assistantMessage = VoiceMessage(role: .assistant, content: fullResponse)
            session.addMessage(assistantMessage)

            // Emit latency metrics before turn completion
            if speechEndTimestamp > 0, ttsFirstBufferTimestamp > 0 {
                let metrics = TurnLatencyMetrics(
                    sttLatency: sttCompleteTimestamp - speechEndTimestamp,
                    llmLatency: llmFirstTokenTimestamp > 0 ? llmFirstTokenTimestamp - sttCompleteTimestamp : 0,
                    ttsLatency: llmFirstTokenTimestamp > 0 ? ttsFirstBufferTimestamp - llmFirstTokenTimestamp : 0,
                    totalLatency: ttsFirstBufferTimestamp - speechEndTimestamp
                )
                emit(.latencyMetrics(metrics))
            }
            resetLatencyTimestamps()

            let turn = VoiceTurn(
                userText: userText,
                assistantText: fullResponse,
                startedAt: turnStarted,
                completedAt: Date()
            )
            session.addTurn(turn)
            emit(.turnCompleted(turn))
            turnIndex += 1
            transition(to: .listening)
        } catch {
            if !Task.isCancelled {
                emit(.error(VoiceAgentError.llmFailed(error.localizedDescription)))
                transition(to: .listening)
            }
        }
    }

    /// Cancel pending response/endpoint tasks without emitting interruption events.
    /// Used when the user resumes speaking during `.thinking` (continuation, not interruption).
    private func cancelPendingResponse() {
        responseTask?.cancel()
        responseTask = nil
        endpointTask?.cancel()
        endpointTask = nil
    }

    /// Interrupt an in-flight response (user started speaking during playback).
    private func interruptResponse() {
        cancelPendingResponse()
        playback.stop()
        transition(to: .interrupted)
        emit(.agentInterrupted)
    }

    // MARK: - LLM + TTS processing

    /// Process the LLM response with concurrent sentence-level TTS.
    ///
    /// LLM token streaming and TTS synthesis are decoupled via an `AsyncStream<String>`
    /// sentence channel. The LLM loop yields complete sentences without blocking on TTS,
    /// and a separate TTS task synthesizes them in order — so while TTS renders sentence N,
    /// the LLM can accumulate sentence N+1.
    ///
    /// Returns the full response text.
    private func processLLMResponse(userText: String, currentTurnIndex: Int) async throws -> String {
        let llmStream = llm.respond(
            userMessage: userText,
            history: session.messages,
            systemPrompt: config.systemPrompt
        )

        var fullText = ""
        var sentenceBuffer = ""
        var sentenceIndex = 0
        didStartSpeech = false

        // Create a passthrough stream for TTS buffers that we can feed into playback
        var ttsContinuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation!
        let ttsBufferStream = AsyncThrowingStream<AVAudioPCMBuffer, Error> { ttsContinuation = $0 }

        // Create sentence channel between LLM and TTS
        var sentenceContinuation: AsyncStream<String>.Continuation!
        let sentenceStream = AsyncStream<String> { sentenceContinuation = $0 }

        // Start playback concurrently
        let playbackTask = Task {
            try await playback.play(buffers: ttsBufferStream)
        }

        // TTS task: consumes sentences from the channel, synthesizes, yields audio buffers.
        // Runs on the same actor — interleaves with the LLM loop at suspension points.
        let ttsTask = Task {
            for await sentence in sentenceStream {
                try Task.checkCancellation()
                let ttsStream = tts.synthesizeStream(
                    text: sentence,
                    voice: config.voice,
                    referenceAudioURL: config.referenceAudioURL,
                    referenceText: config.referenceText
                )
                for try await buffer in ttsStream {
                    try Task.checkCancellation()
                    if !didStartSpeech {
                        ttsFirstBufferTimestamp = CFAbsoluteTimeGetCurrent()
                        transition(to: .speaking)
                        emit(.agentSpeechStarted)
                        didStartSpeech = true
                    }
                    ttsContinuation.yield(buffer)

                    // Record agent TTS audio (non-blocking — errors are ignored)
                    if let recorder = self.audioRecorder {
                        try? await recorder.appendAgentAudio(turnIndex: currentTurnIndex, buffer: buffer)
                    }
                }
            }
        }

        // Always clean up, even on error or cancellation
        defer {
            ttsTask.cancel()
            if Task.isCancelled {
                playback.stop()
            }
            playbackTask.cancel()
        }

        do {
            for try await delta in llmStream {
                try Task.checkCancellation()

                // Record first LLM token timestamp
                if llmFirstTokenTimestamp == 0 {
                    llmFirstTokenTimestamp = CFAbsoluteTimeGetCurrent()
                }

                fullText += delta
                sentenceBuffer += delta
                emit(.agentResponseText(delta: delta))

                // Progressive sentence length: all sentences split at natural
                // boundaries (period, !, ?, newline). First sentence uses a lower
                // minimum to reduce time-to-first-audio; later sentences are longer
                // so TTS has enough context for natural prosody.
                let delimiters = sentenceIndex == 0 ? config.firstSentenceDelimiters : config.sentenceDelimiters
                let threshold: Int
                switch sentenceIndex {
                case 0:  threshold = config.minFirstSentenceLength   // 1 — first natural sentence
                case 1:  threshold = 40
                default: threshold = min(40 + sentenceIndex * 30, 200) // grow up to ~200 chars
                }
                if let lastChar = sentenceBuffer.last,
                   delimiters.contains(lastChar),
                   sentenceBuffer.count >= threshold {
                    let sentence = sentenceBuffer
                    sentenceBuffer = ""
                    sentenceIndex += 1

                    // Yield sentence to TTS task (non-blocking)
                    sentenceContinuation.yield(sentence)
                }
            }

            // Flush remaining text (skip if cancelled — user interrupted)
            try Task.checkCancellation()
            if !sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentenceContinuation.yield(sentenceBuffer)
            }

            // Signal no more sentences
            sentenceContinuation.finish()

            // Wait for TTS to finish all queued sentences
            try await ttsTask.value

            try Task.checkCancellation()
            ttsContinuation.finish()
            emit(.agentResponseComplete(fullText: fullText))
        } catch {
            sentenceContinuation.finish()
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

    private func resetLatencyTimestamps() {
        speechEndTimestamp = 0
        sttCompleteTimestamp = 0
        llmFirstTokenTimestamp = 0
        ttsFirstBufferTimestamp = 0
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
