import SwiftUI
import PDFKit

struct AnnotationPropertyPanel: View {
    let viewModel: DocumentViewModel

    @State private var color: NSColor = .systemRed
    @State private var lineWidth: CGFloat = 1.5
    @State private var opacity: CGFloat = 1.0
    @State private var contents: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Annotation Properties")
                .font(.headline)

            if let annotation = viewModel.state.selectedAnnotation {
                // Type label
                LabeledContent("Type") {
                    Text(annotation.type ?? "Unknown")
                        .font(.caption)
                }

                Divider()

                // Color
                ColorPickerButton(title: "Color", color: $color)
                    .onChange(of: color) { _, newColor in
                        annotation.color = newColor
                        viewModel.markDocumentEdited()
                    }

                // Line width
                VStack(alignment: .leading, spacing: 4) {
                    Text("Line Width: \(String(format: "%.1f", lineWidth))")
                        .font(.caption)
                    Slider(value: $lineWidth, in: 0.5...10, step: 0.5)
                        .onChange(of: lineWidth) { _, newValue in
                            let border = PDFBorder()
                            border.lineWidth = newValue
                            annotation.border = border
                            viewModel.markDocumentEdited()
                        }
                }

                // Opacity
                VStack(alignment: .leading, spacing: 4) {
                    Text("Opacity: \(Int(opacity * 100))%")
                        .font(.caption)
                    Slider(value: $opacity, in: 0.1...1.0, step: 0.1)
                        .onChange(of: opacity) { _, newValue in
                            annotation.color = annotation.color.withAlphaComponent(newValue)
                            viewModel.markDocumentEdited()
                        }
                }

                // Contents
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Contents")
                        .font(.caption)
                        .fontWeight(.medium)

                    TextEditor(text: $contents)
                        .font(.caption)
                        .frame(minHeight: 60, maxHeight: 120)
                        .border(Color.secondary.opacity(0.3))
                        .onChange(of: contents) { _, newValue in
                            annotation.contents = newValue
                            viewModel.markDocumentEdited()
                        }
                }

                Divider()

                // Delete button
                Button(role: .destructive) {
                    deleteAnnotation(annotation)
                } label: {
                    Label("Delete Annotation", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .onAppear { loadProperties() }
        .onChange(of: viewModel.state.selectedAnnotation) { _, _ in
            loadProperties()
        }
    }

    private func loadProperties() {
        guard let annotation = viewModel.state.selectedAnnotation else { return }
        color = annotation.color
        lineWidth = annotation.border?.lineWidth ?? 1.5
        opacity = annotation.color.alphaComponent
        contents = annotation.contents ?? ""
    }

    private func deleteAnnotation(_ annotation: PDFAnnotation) {
        if let page = annotation.page {
            page.removeAnnotation(annotation)
            viewModel.state.selectedAnnotation = nil
            viewModel.markDocumentEdited()
        }
    }
}
