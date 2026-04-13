import SwiftUI

// Zotero-style tag manager: 9-color swatch picker with exact Zotero palette
struct TagManagerSheet: View {
    let store: LibraryStore

    @Environment(\.dismiss) private var dismiss
    @State private var newTagName = ""
    @State private var selectedColor: TagColor = .red
    @State private var editingTag: PDFTag?

    var body: some View {
        VStack(spacing: 16) {
            Text("Manage Tags")
                .font(.system(size: 16, weight: .semibold))

            // New tag creation
            HStack(spacing: 8) {
                TextField("Tag name", text: $newTagName)
                    .font(.system(size: 13))
                    .textFieldStyle(.roundedBorder)

                Button("Add") {
                    let name = newTagName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    store.createTag(name: name, color: selectedColor)
                    newTagName = ""
                }
                .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Color picker — Zotero's 9 colors as squares
            HStack(spacing: 6) {
                ForEach(TagColor.allCases) { color in
                    Button {
                        selectedColor = color
                    } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hex: color.hex))
                            .frame(width: 22, height: 22)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(
                                        selectedColor == color ? Color.primary.opacity(0.8) : Color.clear,
                                        lineWidth: 2
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Rectangle()
                .fill(Color.primary.opacity(0.05))
                .frame(height: 1)

            // Existing tags
            if store.tags.isEmpty {
                Text("No tags yet")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                List {
                    ForEach(store.tags, id: \.id) { tag in
                        HStack {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: tag.colorHex))
                                .frame(width: 12, height: 12)

                            if editingTag?.id == tag.id {
                                TextField("Name", text: Binding(
                                    get: { editingTag?.name ?? "" },
                                    set: { editingTag?.name = $0 }
                                ))
                                .font(.system(size: 13))
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    if let editing = editingTag {
                                        store.renameTag(editing, to: editing.name)
                                    }
                                    editingTag = nil
                                }
                            } else {
                                Text(tag.name)
                                    .font(.system(size: 13))
                                Spacer()

                                // Color picker for existing tag
                                Menu {
                                    ForEach(TagColor.allCases) { color in
                                        Button {
                                            store.updateTagColor(tag, to: color)
                                        } label: {
                                            Label(color.rawValue.capitalized, systemImage: "square.fill")
                                        }
                                    }
                                } label: {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color(hex: tag.colorHex))
                                        .frame(width: 14, height: 14)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()

                                Button {
                                    editingTag = tag
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.primary.opacity(0.55))

                                Button {
                                    store.deleteTag(tag)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color(hex: "DB2C3A"))
                            }
                        }
                    }
                }
                .frame(height: 200)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 380)
    }
}
