import SwiftUI
import PDFKit

struct AnnotationListView: View {
    let viewModel: DocumentViewModel

    @State private var annotationsByPage: [Int: [AnnotationModel]] = [:]

    var body: some View {
        VStack(spacing: 0) {
            if annotationsByPage.isEmpty {
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
                .listStyle(.sidebar)
            }

            Divider()

            HStack {
                Button {
                    loadAnnotations()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Spacer()

                Text("\(totalAnnotationCount) annotations")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .onAppear { loadAnnotations() }
    }

    private var totalAnnotationCount: Int {
        annotationsByPage.values.reduce(0) { $0 + $1.count }
    }

    private func loadAnnotations() {
        guard let doc = viewModel.pdfDocument else { return }
        var result: [Int: [AnnotationModel]] = [:]

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let annotations = page.annotations.filter { annotation in
                // Filter out link and widget annotations from the list
                let type = annotation.type ?? ""
                return type != "Link" && type != "Widget"
            }.map { AnnotationModel(from: $0, pageIndex: i) }

            if !annotations.isEmpty {
                result[i] = annotations
            }
        }
        annotationsByPage = result
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
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: annotation.color))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(annotation.type.rawValue.isEmpty ? "Annotation" : annotation.type.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)

                if let contents = annotation.contents, !contents.isEmpty {
                    Text(contents)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}
