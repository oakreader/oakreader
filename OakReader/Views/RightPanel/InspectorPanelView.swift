import SwiftUI
import PDFKit

struct InspectorPanelView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("Info")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, OakStyle.Spacing.sm)
            .padding(.vertical, OakStyle.Spacing.sm)

            ScrollView {
                VStack(spacing: 16) {
                    switch viewModel.state.editorMode {
                    case .annotate:
                        if viewModel.state.selectedAnnotation != nil {
                            AnnotationPropertyPanel(viewModel: viewModel)
                        } else {
                            emptyAnnotationState
                        }
                    default:
                        documentInfoCard
                        pageInfoCard
                    }
                }
                .padding(.horizontal, OakStyle.Spacing.sm)
                .padding(.top, OakStyle.Spacing.xs)
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

    // MARK: - Document Info Card

    private var documentInfoCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Document", icon: "doc.fill")

            Divider().padding(.horizontal, 12)

            VStack(spacing: 0) {
                infoRow(label: "File Name", value: viewModel.fileName)
                Divider().padding(.leading, 12)
                infoRow(label: "Pages", value: "\(viewModel.pageCount)")

                if let url = viewModel.document?.fileURL,
                   let size = FileCoordination.fileSizeString(for: url) {
                    Divider().padding(.leading, 12)
                    infoRow(label: "File Size", value: size)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Page Info Card

    @ViewBuilder
    private var pageInfoCard: some View {
        if let doc = viewModel.pdfDocument,
           let page = doc.page(at: viewModel.state.currentPageIndex) {
            let bounds = page.bounds(for: .mediaBox)

            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Current Page", icon: "doc.richtext")

                Divider().padding(.horizontal, 12)

                VStack(spacing: 0) {
                    infoRow(label: "Page", value: "\(viewModel.state.currentPageIndex + 1) of \(viewModel.pageCount)")
                    Divider().padding(.leading, 12)
                    infoRow(label: "Size", value: "\(Int(bounds.width)) × \(Int(bounds.height)) pts")
                    Divider().padding(.leading, 12)
                    infoRow(label: "Orientation", value: bounds.width > bounds.height ? "Landscape" : "Portrait")
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Reusable Components

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
