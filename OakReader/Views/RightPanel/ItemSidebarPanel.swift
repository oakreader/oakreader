import SwiftUI
import PDFKit

struct ItemSidebarPanel: View {
    let viewModel: DocumentViewModel

    @State private var hasTriggeredAutoExtract = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("Reference")
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

    private func autoExtractIfNeeded() {
        guard !hasTriggeredAutoExtract else { return }
        hasTriggeredAutoExtract = true

        guard let item = viewModel.libraryItem,
              item.referenceMetadata == nil,
              item.documentType == .pdf,
              let refService = viewModel.referenceService,
              let store = viewModel.libraryStore else { return }

        Task {
            let pdfURL = item.fileURL
            guard let doi = DOIExtractorService.extractDOI(from: pdfURL) else { return }
            do {
                let cslItem = try await CrossRefService.fetchMetadata(doi: doi)
                try refService.saveMetadata(cslItem, forDocumentId: item.id.uuidString)
                await MainActor.run {
                    store.invalidate()
                }
            } catch {
                Log.error(Log.importer, "Auto-extract on open failed for DOI \(doi): \(error)")
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
