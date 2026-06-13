import SwiftUI
import PDFKit

struct AnnotationListView: View {
    let viewModel: DocumentViewModel

    private var annotationsByPage: [Int: [AnnotationModel]] {
        Dictionary(grouping: viewModel.annotation.annotationModels, by: \.pageIndex)
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.annotation.annotationModels.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Annotations")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Annotations added to the document will appear here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(annotationsByPage.keys.sorted(), id: \.self) { pageIndex in
                        Section("Page \(pageIndex + 1)") {
                            if let annotations = annotationsByPage[pageIndex] {
                                ForEach(annotations) { annotation in
                                    AnnotationRowView(annotation: annotation)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            viewModel.viewer.goToPage(annotation.pageIndex)
                                            selectAnnotation(annotation)
                                        }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .listRowSeparator(.hidden)
            }

            Divider()

            HStack {
                Spacer()

                Text("\(viewModel.annotation.annotationModels.count) annotations")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { viewModel.annotation.refreshAnnotationModels() }
    }

    private func selectAnnotation(_ model: AnnotationModel) {
        guard let doc = viewModel.pdfDocument,
              let page = doc.page(at: model.pageIndex) else { return }

        let matching = page.annotations.first { annotation in
            annotation.bounds == model.bounds && annotation.type == model.type.rawValue
        }
        viewModel.state.selectedAnnotation = matching
    }
}

private struct AnnotationRowView: View {
    let annotation: AnnotationModel

    /// A human-readable label for the annotation type.
    private var typeLabel: String {
        let raw = annotation.type.rawValue
        switch raw {
        case "Highlight": return "Highlight"
        case "Underline": return "Underline"
        case "StrikeOut": return "Strikethrough"
        case "FreeText": return "Text"
        case "Text": return "Note"
        case "Ink": return "Drawing"
        case "Square": return "Rectangle"
        case "Circle": return "Oval"
        default: return raw.isEmpty ? "Annotation" : raw
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color(nsColor: annotation.color))
                .frame(width: 10, height: 10)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                // A note: show the comment prominently, with the quoted text as
                // muted context beneath it.
                if let comment = annotation.contents, !comment.isEmpty {
                    Text(comment)
                        .font(.caption)
                        .lineLimit(4)
                    if let quoted = annotation.markedUpText, !quoted.isEmpty {
                        Text(quoted)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.leading, 6)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(Color(nsColor: annotation.color))
                                    .frame(width: 2)
                            }
                    }
                } else if let text = annotation.markedUpText, !text.isEmpty {
                    Text(text)
                        .font(.caption)
                        .lineLimit(3)
                    Text(typeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(typeLabel)
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}
