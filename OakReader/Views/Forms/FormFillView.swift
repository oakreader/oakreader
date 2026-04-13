import SwiftUI
import PDFKit

struct FormFillView: View {
    let viewModel: DocumentViewModel

    @State private var formFields: [FormFieldInfo] = []

    struct FormFieldInfo: Identifiable {
        let id = UUID()
        let annotation: PDFAnnotation
        let pageIndex: Int
        var value: String
        var isChecked: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            if formFields.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.and.pencil.and.ellipsis")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Form Fields")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("This document does not contain fillable form fields.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(
                            Dictionary(grouping: formFields) { $0.pageIndex }.sorted(by: { $0.key < $1.key }),
                            id: \.key
                        ) { pageIndex, fields in
                            Section {
                                ForEach(fields) { field in
                                    FormFieldRow(field: field) { newValue in
                                        updateFieldValue(field: field, value: newValue)
                                    } onToggle: { isChecked in
                                        updateFieldChecked(field: field, isChecked: isChecked)
                                    }
                                }
                            } header: {
                                Text("Page \(pageIndex + 1)")
                                    .font(.headline)
                                    .padding(.top, 8)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .onAppear { scanFormFields() }
    }

    private func scanFormFields() {
        guard let doc = viewModel.pdfDocument else { return }
        var fields: [FormFieldInfo] = []

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" {
                let info = FormFieldInfo(
                    annotation: annotation,
                    pageIndex: i,
                    value: annotation.widgetStringValue ?? "",
                    isChecked: annotation.buttonWidgetState == .onState
                )
                fields.append(info)
            }
        }
        formFields = fields
    }

    private func updateFieldValue(field: FormFieldInfo, value: String) {
        field.annotation.widgetStringValue = value
        viewModel.markDocumentEdited()
    }

    private func updateFieldChecked(field: FormFieldInfo, isChecked: Bool) {
        field.annotation.buttonWidgetState = isChecked ? .onState : .offState
        viewModel.markDocumentEdited()
    }
}

private struct FormFieldRow: View {
    let field: FormFillView.FormFieldInfo
    let onValueChange: (String) -> Void
    let onToggle: (Bool) -> Void

    @State private var textValue: String = ""
    @State private var isChecked: Bool = false

    var body: some View {
        HStack(alignment: .top) {
            Text(field.annotation.fieldName ?? "Field")
                .font(.caption)
                .fontWeight(.medium)
                .frame(width: 120, alignment: .trailing)

            fieldInput
        }
        .onAppear {
            textValue = field.value
            isChecked = field.isChecked
        }
    }

    @ViewBuilder
    private var fieldInput: some View {
        switch field.annotation.widgetFieldType {
        case .text:
            TextField("Enter text", text: $textValue)
                .textFieldStyle(.roundedBorder)
                .onChange(of: textValue) { _, newValue in
                    onValueChange(newValue)
                }

        case .button:
            Toggle("", isOn: $isChecked)
                .labelsHidden()
                .onChange(of: isChecked) { _, newValue in
                    onToggle(newValue)
                }

        case .choice:
            if let choices = field.annotation.choices, !choices.isEmpty {
                Picker("", selection: $textValue) {
                    ForEach(choices, id: \.self) { choice in
                        Text(choice).tag(choice)
                    }
                }
                .labelsHidden()
                .onChange(of: textValue) { _, newValue in
                    onValueChange(newValue)
                }
            } else {
                TextField("Enter value", text: $textValue)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: textValue) { _, newValue in
                        onValueChange(newValue)
                    }
            }

        case .signature:
            Text("Signature field")
                .font(.caption)
                .foregroundStyle(.secondary)

        default:
            TextField("Value", text: $textValue)
                .textFieldStyle(.roundedBorder)
        }
    }
}
