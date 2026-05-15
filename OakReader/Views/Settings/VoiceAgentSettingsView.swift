import SwiftUI
import OakVoiceAI

struct VoiceAgentSettingsView: View {
    private let prefs = Preferences.shared

    @State private var language: String
    @State private var llmModel: String
    @State private var ttsProvider: String
    @State private var ttsVoice: String
    @State private var ttsModel: String
    @State private var sttProvider: String
    @State private var sttModel: String
    @State private var referenceAudioPath: String
    @State private var referenceText: String
    @State private var systemPrompt: String

    init() {
        let p = Preferences.shared
        _language = State(initialValue: p.voiceLanguage)
        _llmModel = State(initialValue: p.voiceLLMModel)
        _ttsProvider = State(initialValue: p.voiceTTSProvider)
        _ttsVoice = State(initialValue: p.voiceTTSVoice)
        _ttsModel = State(initialValue: p.voiceTTSModel)
        _sttProvider = State(initialValue: p.voiceSTTProvider)
        _sttModel = State(initialValue: p.voiceSTTModel)
        _referenceAudioPath = State(initialValue: p.voiceReferenceAudioPath)
        _referenceText = State(initialValue: p.voiceReferenceText)
        _systemPrompt = State(initialValue: p.voiceAgentSystemPrompt)
    }

    var body: some View {
        Form {
            languageAndModelSection
            ttsSection
            sttSection
            referenceAudioSection
            systemPromptSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Language & Model

    private var languageAndModelSection: some View {
        Section("Language & Model") {
            Picker("Language", selection: $language) {
                ForEach(VoiceLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }
            .onChange(of: language) { _, newValue in
                prefs.voiceLanguage = newValue
            }

            TextField("LLM Model", text: $llmModel, prompt: Text("Default (same as AI Chat)"))
                .onChange(of: llmModel) { _, newValue in
                    prefs.voiceLLMModel = newValue
                }
        }
    }

    // MARK: - Text-to-Speech

    private var ttsSection: some View {
        Section("Text-to-Speech") {
            Picker("Provider", selection: $ttsProvider) {
                Text("On-Device").tag("on_device")
                Text("ElevenLabs").tag("elevenlabs")
            }
            .onChange(of: ttsProvider) { _, newValue in
                prefs.voiceTTSProvider = newValue
            }

            TextField("Voice", text: $ttsVoice, prompt: Text("Default"))
                .onChange(of: ttsVoice) { _, newValue in
                    prefs.voiceTTSVoice = newValue
                }

            TextField("Model", text: $ttsModel, prompt: Text("Default"))
                .onChange(of: ttsModel) { _, newValue in
                    prefs.voiceTTSModel = newValue
                }
        }
    }

    // MARK: - Speech-to-Text

    private var sttSection: some View {
        Section("Speech-to-Text") {
            Picker("Provider", selection: $sttProvider) {
                Text("On-Device").tag("on_device")
                Text("ElevenLabs").tag("elevenlabs")
            }
            .onChange(of: sttProvider) { _, newValue in
                prefs.voiceSTTProvider = newValue
            }

            TextField("Model", text: $sttModel, prompt: Text("Default"))
                .onChange(of: sttModel) { _, newValue in
                    prefs.voiceSTTModel = newValue
                }
        }
    }

    // MARK: - Reference Audio

    private var referenceAudioSection: some View {
        Section("Reference Audio") {
            HStack {
                TextField("Audio File", text: $referenceAudioPath, prompt: Text("Path to reference audio"))
                    .onChange(of: referenceAudioPath) { _, newValue in
                        prefs.voiceReferenceAudioPath = newValue
                    }

                Button("Browse...") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.audio]
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        referenceAudioPath = url.path
                        prefs.voiceReferenceAudioPath = url.path
                    }
                }
            }

            TextField("Reference Text", text: $referenceText, prompt: Text("Transcript of the reference audio"))
                .onChange(of: referenceText) { _, newValue in
                    prefs.voiceReferenceText = newValue
                }
        }
    }

    // MARK: - System Prompt

    private var systemPromptSection: some View {
        Section("System Prompt") {
            TextEditor(text: $systemPrompt)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 120)
                .onChange(of: systemPrompt) { _, newValue in
                    prefs.voiceAgentSystemPrompt = newValue
                }

            Text("Custom instructions for the voice agent. Leave empty for the default behavior.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
