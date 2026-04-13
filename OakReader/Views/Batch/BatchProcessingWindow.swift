import SwiftUI
import UniformTypeIdentifiers

struct BatchProcessingWindow: View {
    @State private var jobs: [BatchJob] = []
    @State private var selectedOperation: BatchOperationType = .compress
    @State private var isProcessing = false
    @State private var overallProgress: Double = 0
    @State private var errorMessage: String?

    // Operation-specific settings
    @State private var compressionQuality: CompressionQuality = .medium
    @State private var watermarkConfig = WatermarkConfig()
    @State private var headerFooterConfig = HeaderFooterConfig()
    @State private var ocrLanguage = "en"
    @State private var password = ""
    @State private var redactPattern = ""

    var body: some View {
        HSplitView {
            // Left: File list
            VStack(spacing: 0) {
                Text("Files")
                    .font(.headline)
                    .padding(8)

                Divider()

                BatchFileListView(jobs: $jobs)

                Divider()

                HStack {
                    Button {
                        addFiles()
                    } label: {
                        Label("Add Files", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button {
                        jobs.removeAll()
                    } label: {
                        Text("Clear All")
                    }
                    .buttonStyle(.borderless)
                    .disabled(jobs.isEmpty || isProcessing)
                }
                .padding(8)
            }
            .frame(minWidth: 280)

            // Right: Operation settings
            VStack(spacing: 0) {
                Text("Operation")
                    .font(.headline)
                    .padding(8)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Operation picker
                        BatchOperationPicker(selectedOperation: $selectedOperation)

                        Divider()

                        // Operation-specific options
                        operationOptions

                        Divider()

                        // Progress
                        if isProcessing {
                            BatchProgressView(
                                progress: overallProgress,
                                jobs: jobs
                            )
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding()
                }

                Divider()

                // Bottom bar
                HStack {
                    Text("\(jobs.count) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if isProcessing {
                        Button("Cancel") {
                            isProcessing = false
                        }
                        .keyboardShortcut(.cancelAction)
                    }

                    Button("Start Processing") {
                        startProcessing()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(jobs.isEmpty || isProcessing)
                }
                .padding(12)
            }
            .frame(minWidth: 400)
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    @ViewBuilder
    private var operationOptions: some View {
        switch selectedOperation {
        case .compress:
            VStack(alignment: .leading, spacing: 8) {
                Text("Compression Quality")
                    .font(.caption)
                    .fontWeight(.medium)
                Picker("Quality", selection: $compressionQuality) {
                    ForEach(CompressionQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                .pickerStyle(.radioGroup)
            }

        case .ocr:
            VStack(alignment: .leading, spacing: 8) {
                Text("OCR Language")
                    .font(.caption)
                    .fontWeight(.medium)
                Picker("Language", selection: $ocrLanguage) {
                    Text("English").tag("en")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Spanish").tag("es")
                    Text("Chinese (Simplified)").tag("zh-Hans")
                    Text("Japanese").tag("ja")
                }
            }

        case .passwordProtect:
            VStack(alignment: .leading, spacing: 8) {
                Text("Password")
                    .font(.caption)
                    .fontWeight(.medium)
                SecureField("Enter password", text: $password)
                    .textFieldStyle(.roundedBorder)
            }

        case .redactPattern:
            VStack(alignment: .leading, spacing: 8) {
                Text("Pattern to Redact")
                    .font(.caption)
                    .fontWeight(.medium)
                TextField("e.g., SSN pattern, email addresses", text: $redactPattern)
                    .textFieldStyle(.roundedBorder)
                Text("Use regex patterns to match content to redact.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .watermark:
            VStack(alignment: .leading, spacing: 8) {
                Text("Watermark Text")
                    .font(.caption)
                    .fontWeight(.medium)
                if case .text(let text) = watermarkConfig.type {
                    TextField("Watermark text", text: Binding(
                        get: { text },
                        set: { watermarkConfig.type = .text($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

        default:
            Text("No additional options for this operation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK {
            let newJobs = panel.urls.map { BatchJob(fileURL: $0) }
            jobs.append(contentsOf: newJobs)
        }
    }

    private func startProcessing() {
        isProcessing = true
        overallProgress = 0
        errorMessage = nil

        // Set all jobs to pending
        for i in jobs.indices {
            jobs[i].status = .pending
            jobs[i].error = nil
        }

        Task {
            for i in jobs.indices {
                guard isProcessing else { break }

                jobs[i].status = .processing(progress: 0)

                do {
                    try await processJob(at: i)
                    jobs[i].status = .completed
                } catch {
                    jobs[i].status = .failed
                    jobs[i].error = error.localizedDescription
                }

                overallProgress = Double(i + 1) / Double(jobs.count)
            }

            await MainActor.run {
                isProcessing = false
            }
        }
    }

    private func processJob(at index: Int) async throws {
        // Placeholder for actual batch processing
        // In production, this would dispatch to the appropriate service
        try await Task.sleep(for: .milliseconds(500))

        let outputDir = FileManager.default.temporaryDirectory
        let baseName = jobs[index].fileURL.deletingPathExtension().lastPathComponent
        let outputURL = outputDir.appendingPathComponent("\(baseName)_processed.pdf")

        // Copy file as placeholder
        try FileManager.default.copyItem(at: jobs[index].fileURL, to: outputURL)
        jobs[index].outputURL = outputURL
    }
}
