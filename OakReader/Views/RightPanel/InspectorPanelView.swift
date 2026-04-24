import SwiftUI
import PDFKit

struct InspectorPanelView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspector")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, OakStyle.Spacing.sm)
            .padding(.vertical, OakStyle.Spacing.xs)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch viewModel.state.editorMode {
                    case .annotate:
                        if viewModel.state.selectedAnnotation != nil {
                            AnnotationPropertyPanel(viewModel: viewModel)
                        } else {
                            Text("Select an annotation to edit its properties.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                    default:
                        documentInfoInspector
                    }
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private var documentInfoInspector: some View {
        Group {
            LabeledContent("File Name") {
                Text(viewModel.fileName)
                    .font(.caption)
            }
            LabeledContent("Pages") {
                Text("\(viewModel.pageCount)")
                    .font(.caption)
            }

            if let doc = viewModel.pdfDocument,
               let page = doc.page(at: viewModel.state.currentPageIndex) {
                let bounds = page.bounds(for: .mediaBox)
                LabeledContent("Page Size") {
                    Text("\(Int(bounds.width)) x \(Int(bounds.height)) pts")
                        .font(.caption)
                }
            }

            if let url = viewModel.document?.fileURL,
               let size = FileCoordination.fileSizeString(for: url) {
                LabeledContent("File Size") {
                    Text(size)
                        .font(.caption)
                }
            }
        }
    }
}
