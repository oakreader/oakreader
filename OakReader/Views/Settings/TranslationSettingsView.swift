import SwiftUI
import OakAgent
import UniformTypeIdentifiers

struct TranslationSettingsView: View {
    let store: LibraryStore

    @State private var sourceLang: TranslationLanguage
    @State private var targetLang: TranslationLanguage

    // Translation LLM
    @State private var translationUseChatDefault: Bool
    @State private var translationProviderId: String
    @State private var translationModel: String

    // Export
    @State private var exportStatus: String?
    @State private var exportRange: ExportRange = .all
    @State private var sinceDate: Date = Calendar.current.startOfDay(for: Date())

    private let providerStore = ConfiguredProviderStore.shared

    init(store: LibraryStore) {
        self.store = store
        let prefs = Preferences.shared
        let defaults = UserDefaults.standard

        _sourceLang = State(initialValue: prefs.translationSourceLang)
        _targetLang = State(initialValue: prefs.translationTargetLang)

        // Translation LLM – nil raw key means "use chat default"
        let translationRaw = defaults.string(forKey: "translationAIProvider")
        _translationUseChatDefault = State(initialValue: translationRaw == nil)
        _translationProviderId = State(initialValue: prefs.translationAIProviderId)
        let tm = prefs.translationAIModel
        _translationModel = State(initialValue: tm.isEmpty
            ? (ProviderRegistry.shared.provider(for: prefs.translationAIProviderId)?.defaultModelId ?? "") : tm)
    }

    var body: some View {
        Form {
            languageSection
            llmSection
            exportSection
        }
        .formStyle(.grouped)
        .onDisappear { saveLLM() }
    }

    // MARK: - Default Languages Section

    private var languageSection: some View {
        Section {
            Picker("Source Language", selection: $sourceLang) {
                ForEach(TranslationLanguage.allCases) { language in
                    Text(language.nativeName).tag(language)
                }
            }
            .onChange(of: sourceLang) { _, newValue in
                Preferences.shared.translationSourceLang = newValue
            }

            Picker("Target Language", selection: $targetLang) {
                ForEach(TranslationLanguage.targetCases) { language in
                    Text(language.nativeName).tag(language)
                }
            }
            .onChange(of: targetLang) { _, newValue in
                Preferences.shared.translationTargetLang = newValue
            }
        } header: {
            Text("Default Languages")
        } footer: {
            Text("Used by the translation panel when selected text is sent for translation.")
        }
    }

    // MARK: - LLM Section

    private var llmSection: some View {
        Section("Translation LLM") {
            Toggle("Use Chat default", isOn: $translationUseChatDefault)

            if translationUseChatDefault {
                chatDefaultLabel
            } else {
                llmPickers
            }
        }
    }

    @ViewBuilder
    private var llmPickers: some View {
        if providerStore.configuredLLMProviders.isEmpty {
            Text("Configure a provider in AI Providers first.")
                .foregroundStyle(.secondary)
        } else {
            Picker("Provider", selection: $translationProviderId) {
                ForEach(providerStore.configuredLLMProviders) { p in
                    Text(p.displayName).tag(p.id)
                }
            }
            .onChange(of: translationProviderId) { _, newValue in
                translationModel = ProviderRegistry.shared.provider(for: newValue)?.defaultModelId ?? ""
            }

            if let provider = ProviderRegistry.shared.provider(for: translationProviderId) {
                Picker("Model", selection: $translationModel) {
                    ForEach(provider.models) { m in
                        Text(m.name).tag(m.id)
                    }
                }
            }
        }
    }

    private var chatDefaultLabel: some View {
        let prefs = Preferences.shared
        let pid = prefs.aiProviderId
        let model = prefs.aiModel
        let providerName = ProviderRegistry.shared.provider(for: pid)?.displayName ?? pid
        let modelName = ProviderRegistry.shared.provider(for: pid)?.models.first(where: { $0.id == model })?.name ?? model
        return LabeledContent("Using", value: "\(providerName) / \(modelName)")
            .foregroundStyle(.secondary)
    }

    // MARK: - Export Section

    private var exportSection: some View {
        Section {
            Picker("Range", selection: $exportRange) {
                ForEach(ExportRange.allCases) { Text($0.label).tag($0) }
            }
            if exportRange == .since {
                DatePicker("Since", selection: $sinceDate, displayedComponents: .date)
            }
            Menu("Export Word Lookups…") {
                Button("As CSV (.csv)") { export(format: .csv) }
                Button("As JSON (.json)") { export(format: .json) }
            }
            if let exportStatus {
                Text(exportStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("History")
        } footer: {
            Text("Export the words you've looked up while reading (newest first), the same data as the `oak words` command.")
        }
    }

    private enum ExportFormat { case csv, json }

    private enum ExportRange: String, CaseIterable, Identifiable {
        case all, today, since
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All Time"
            case .today: return "Today"
            case .since: return "Since…"
            }
        }
    }

    /// Inclusive lower bound for the selected range, or nil for "all time".
    private var rangeLowerBound: Date? {
        switch exportRange {
        case .all: return nil
        case .today: return Calendar.current.startOfDay(for: Date())
        case .since: return Calendar.current.startOfDay(for: sinceDate)
        }
    }

    private func export(format: ExportFormat) {
        var lookups = WordLookupStore(database: store.database).fetchAll()
        if let lowerBound = rangeLowerBound {
            lookups = lookups.filter { $0.createdAt >= lowerBound }
        }
        guard !lookups.isEmpty else {
            exportStatus = exportRange == .all
                ? "No word lookups to export."
                : "No word lookups in the selected range."
            return
        }

        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        let ext = format == .csv ? "csv" : "json"
        panel.nameFieldStringValue = "OakReader-Words-\(stamp.string(from: Date())).\(ext)"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let content = format == .csv ? csvString(lookups) : try jsonString(lookups)
            try content.write(to: url, atomically: true, encoding: .utf8)
            exportStatus = "Exported \(lookups.count) word\(lookups.count == 1 ? "" : "s")."
        } catch {
            exportStatus = "Export failed: \(error.localizedDescription)"
        }
    }

    private func csvString(_ lookups: [WordLookup]) -> String {
        func escape(_ field: String) -> String {
            "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var rows = ["Word,Sentence,Explanation,Document,Created At"]
        let iso = ISO8601DateFormatter()
        for l in lookups {
            rows.append([l.word, l.sentence, l.explanation, l.itemTitle, iso.string(from: l.createdAt)]
                .map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func jsonString(_ lookups: [WordLookup]) throws -> String {
        struct Row: Encodable {
            let word, sentence, explanation, itemTitle, createdAt: String
        }
        let iso = ISO8601DateFormatter()
        let rows = lookups.map {
            Row(word: $0.word, sentence: $0.sentence, explanation: $0.explanation,
                itemTitle: $0.itemTitle, createdAt: iso.string(from: $0.createdAt))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(rows)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // MARK: - Save

    private func saveLLM() {
        let prefs = Preferences.shared
        let defaults = UserDefaults.standard

        if translationUseChatDefault {
            defaults.removeObject(forKey: "translationAIProvider")
            defaults.removeObject(forKey: "translationAIModel")
        } else {
            prefs.translationAIProviderId = translationProviderId
            prefs.translationAIModel = translationModel
        }
    }
}
