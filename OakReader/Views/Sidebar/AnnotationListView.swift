import SwiftUI
import PDFKit

struct AnnotationListView: View {
    let viewModel: DocumentViewModel

    /// Only true notes — annotations that carry a written comment. Plain
    /// highlights, native PDF links, shapes and form widgets are intentionally
    /// excluded so the list stays a focused list of what the reader wrote.
    private var notes: [AnnotationModel] {
        viewModel.annotation.annotationModels.filter {
            ($0.contents?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
    }

    private var annotationsByPage: [Int: [AnnotationModel]] {
        Dictionary(grouping: notes, by: \.pageIndex)
    }

    var body: some View {
        VStack(spacing: 0) {
            if notes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Comments")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Comments you add to highlights will appear here.")
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

                Text("\(notes.count) comments")
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color(nsColor: annotation.color))
                .frame(width: 10, height: 10)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                // A note: show the comment prominently, with the quoted source
                // text as muted context beneath it.
                Text(annotation.contents ?? "")
                    .font(.caption)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let quoted = annotation.markedUpText, !quoted.isEmpty {
                    Text(quoted)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 6)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color(nsColor: annotation.color))
                                .frame(width: 2)
                        }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
