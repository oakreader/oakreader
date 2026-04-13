import SwiftUI

struct CollectionEditorSheet: View {
    let store: LibraryStore
    let collection: PDFCollection?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var icon: String = "folder"

    private let iconOptions = [
        "folder", "folder.fill", "tray.full", "books.vertical",
        "star", "bookmark", "tag", "archivebox",
        "graduationcap", "briefcase", "heart", "flag"
    ]

    var isEditing: Bool { collection != nil }

    var body: some View {
        VStack(spacing: 16) {
            Text(isEditing ? "Edit Collection" : "New Collection")
                .font(.headline)

            TextField("Collection Name", text: $name)
                .textFieldStyle(.roundedBorder)

            // Icon picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Icon")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 36))], spacing: 8) {
                    ForEach(iconOptions, id: \.self) { iconName in
                        Button {
                            icon = iconName
                        } label: {
                            Image(systemName: iconName)
                                .font(.system(size: 16))
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(icon == iconName ? Color.accentColor.opacity(0.2) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(icon == iconName ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isEditing ? "Save" : "Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }

                    if let collection {
                        store.renameCollection(collection, to: trimmed)
                    } else {
                        store.createCollection(name: trimmed, icon: icon)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear {
            if let collection {
                name = collection.name
                icon = collection.icon
            }
        }
    }
}
