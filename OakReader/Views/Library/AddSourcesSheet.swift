import SwiftUI
import UniformTypeIdentifiers

struct AddSourcesSheet: View {
    let appState: AppState

    @Environment(\.dismiss) private var dismiss
    @State private var linkText = ""
    @State private var rows: [AddSourceProgressRow] = []
    @State private var isImporting = false
    @State private var isDropTargeted = false

    private var store: LibraryStore { appState.libraryStore }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 18) {
                dropZone
                linkBox
                if !rows.isEmpty {
                    progressList
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 26)
        }
        .frame(width: 640)
        .frame(minHeight: rows.isEmpty ? 420 : 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("Add sources")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var dropZone: some View {
        Button {
            chooseFiles()
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.04))
                        .frame(width: 40, height: 40)
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.primary)
                }
                VStack(spacing: 6) {
                    Text("Drop or click to upload your files")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("PDF, HTML snapshots, and Markdown")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.015))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isDropTargeted ? Color.accentColor : Color.primary.opacity(0.18),
                        style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isImporting)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            loadDroppedFiles(providers)
            return true
        }
    }

    private var linkBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                PlainMultilineTextView(text: $linkText, isEditable: !isImporting)
                    .frame(height: 118)

                if linkText.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Or paste links here to add webpages or PDFs")
                        Text("To add multiple links, separate with spaces or new lines")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary.opacity(0.65))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                    .allowsHitTesting(false)
                }
            }

            HStack(spacing: 14) {
                Text("\(parsedURLs.count)/50")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await importLinks() }
                } label: {
                    Text(isImporting ? "Adding…" : "Add links")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill((isImporting || parsedURLs.isEmpty) ? Color.accentColor.opacity(0.45) : Color.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isImporting || parsedURLs.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var progressList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Imports")
                .font(.headline)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            statusIcon(row.status)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .lineLimit(1)
                                    .font(.system(size: 13, weight: .medium))
                                if let detail = row.detail {
                                    Text(detail)
                                        .lineLimit(1)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 170)
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: AddSourceProgressRow.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var parsedURLs: [URL] {
        Self.parseURLs(from: linkText).prefix(50).map { $0 }
    }

    private func chooseFiles() {
        var contentTypes: [UTType] = [.pdf, .html]
        if let mdType = UTType(filenameExtension: "md") { contentTypes.append(mdType) }
        if let markdownType = UTType(filenameExtension: "markdown") { contentTypes.append(markdownType) }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = true
        panel.message = "Select PDF, HTML, or Markdown files to add to your library"
        panel.begin { response in
            guard response == .OK else { return }
            Task { await importFiles(panel.urls) }
        }
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let directURL = item as? URL {
                    url = directURL
                } else if let data = item as? Data,
                          let string = String(data: data, encoding: .utf8) {
                    url = URL(string: string)
                } else {
                    url = nil
                }
                guard let url else { return }
                Task { await importFiles([url]) }
            }
        }
    }

    @MainActor
    private func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImporting = true
        let ids = urls.map { url -> UUID in
            let id = UUID()
            rows.insert(.init(id: id, title: url.lastPathComponent, detail: url.path, status: .pending), at: 0)
            return id
        }

        for (index, url) in urls.enumerated() {
            updateRow(ids[index], status: .running, detail: url.path)
            let item = appState.importService.importFile(from: url)
            if let item {
                assignToSelectedCollection(item)
                updateRow(ids[index], title: item.title, status: .success, detail: item.itemType.label)
            } else {
                updateRow(ids[index], status: .failure, detail: "Unsupported or failed file")
            }
        }
        isImporting = false
    }

    @MainActor
    private func importLinks() async {
        let urls = parsedURLs
        guard !urls.isEmpty else { return }
        isImporting = true

        let ids = urls.map { url -> UUID in
            let id = UUID()
            rows.insert(.init(id: id, title: url.absoluteString, detail: nil, status: .pending), at: 0)
            return id
        }

        for (index, url) in urls.enumerated() {
            updateRow(ids[index], status: .running, detail: "Fetching…")
            do {
                let item = try await appState.importService.importURL(url)
                if let item {
                    assignToSelectedCollection(item)
                    updateRow(ids[index], title: item.title, status: .success, detail: item.itemType.label)
                } else {
                    updateRow(ids[index], status: .failure, detail: "Import failed")
                }
            } catch {
                updateRow(ids[index], status: .failure, detail: error.localizedDescription)
            }
        }

        linkText = ""
        isImporting = false
    }

    @MainActor
    private func assignToSelectedCollection(_ item: LibraryItem) {
        if let collection = store.selectedCollection, !collection.isSmart {
            store.addItem(item, to: collection)
        }
    }

    private func updateRow(_ id: UUID, title: String? = nil, status: AddSourceProgressRow.Status, detail: String?) {
        guard let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        if let title { rows[idx].title = title }
        rows[idx].status = status
        rows[idx].detail = detail
    }

    private static func parseURLs(from text: String) -> [URL] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        var seen = Set<String>()
        return text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>[](){}\"'")) }
            .filter { !$0.isEmpty }
            .compactMap { token -> URL? in
                var string = token
                if !string.contains("://"), string.contains(".") {
                    string = "https://" + string
                }
                guard let url = URL(string: string), url.scheme?.hasPrefix("http") == true else { return nil }
                let key = url.absoluteString
                guard !seen.contains(key) else { return nil }
                seen.insert(key)
                return url
            }
    }
}

private struct PlainMultilineTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEditable
        textView.font = .systemFont(ofSize: 13)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

private struct AddSourceProgressRow: Identifiable {
    enum Status {
        case pending
        case running
        case success
        case failure
    }

    let id: UUID
    var title: String
    var detail: String?
    var status: Status
}
