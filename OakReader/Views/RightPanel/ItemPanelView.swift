import SwiftUI
import PDFKit

struct ItemPanelView: View {
    let viewModel: DocumentViewModel

    @State private var hasTriggeredAutoExtract = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Metadata")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, OakStyle.Spacing.sm)
            .padding(.vertical, OakStyle.Spacing.sm)

            ScrollView {
                VStack(spacing: 12) {
                    switch viewModel.state.editorMode {
                    case .annotate:
                        if viewModel.state.selectedAnnotation != nil {
                            AnnotationPropertyPanel(viewModel: viewModel)
                        } else {
                            emptyAnnotationState
                        }
                    default:
                        referenceContent
                    }
                }
                .padding(.horizontal, OakStyle.Spacing.sm)
                .padding(.top, OakStyle.Spacing.xs)
                .padding(.bottom, OakStyle.Spacing.sm)
            }
        }
        .onAppear {
            autoExtractIfNeeded()
        }
    }

    // MARK: - Reference Content

    @ViewBuilder
    private var referenceContent: some View {
        if let item = viewModel.libraryItem,
           let store = viewModel.libraryStore,
           let refService = viewModel.referenceService {
            ReferenceMetadataView(
                item: item,
                store: store,
                referenceService: refService
            )
        } else {
            notInLibraryState
        }
    }

    // MARK: - Not In Library

    private var notInLibraryState: some View {
        VStack(spacing: 12) {
            Image(systemName: "quote.opening")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Not in Library")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Import this document to your library to manage reference metadata.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Auto-Extract

    /// Auto-extract reference metadata when opening a document that has none.
    /// Tries DOI + CrossRef first, falls back to basic document info.
    private func autoExtractIfNeeded() {
        guard !hasTriggeredAutoExtract else { return }
        hasTriggeredAutoExtract = true

        guard let item = viewModel.libraryItem,
              item.referenceMetadata == nil,
              let refService = viewModel.referenceService,
              let store = viewModel.libraryStore else { return }

        Task {
            // Try DOI extraction for PDFs
            if item.contentType == .pdf {
                if let doi = DOIExtractorService.extractDOI(from: item.fileURL) {
                    do {
                        let cslItem = try await CrossRefService.fetchMetadata(doi: doi)
                        try refService.saveMetadata(cslItem, forItemId: item.id.uuidString)
                        await MainActor.run { store.invalidate() }
                        return
                    } catch {
                        Log.error(Log.importer, "Auto-extract on open failed for DOI \(doi): \(error)")
                    }
                }
            }

            // Fallback: create metadata from document info
            var csl = CSLItem(type: "document")
            csl.title = item.title.isEmpty ? nil : item.title
            if !item.author.isEmpty {
                csl.author = [CSLName(family: item.author, given: nil)]
            }
            do {
                try refService.saveMetadata(csl, forItemId: item.id.uuidString)
                await MainActor.run { store.invalidate() }
            } catch {
                Log.error(Log.importer, "Failed to create fallback reference metadata: \(error)")
            }
        }
    }

    // MARK: - Empty Annotation State

    private var emptyAnnotationState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "square.and.pencil")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Select an annotation to edit")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
