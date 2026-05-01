import SwiftUI

struct CollectionEditorSheet: View {
    let store: LibraryStore
    let collection: PDFCollection?
    let parent: PDFCollection?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = "Untitled"
    @State private var selectedParentId: UUID?

    private var isEditing: Bool { collection != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing ? "Edit Collection" : "New Collection")
                .font(.headline)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name:")
                    .font(.system(size: 13))

                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            if !isEditing {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Create in:")
                        .font(.system(size: 13))

                    CollectionPopUpButton(
                        rootCollections: store.rootCollections,
                        selectedParentId: $selectedParentId
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isEditing ? "Save" : "Create Collection") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }

                    if let collection {
                        store.renameCollection(collection, to: trimmed)
                    } else if let parentId = selectedParentId,
                              let target = findCollection(parentId) {
                        store.createSubcollection(name: trimmed, icon: "folder.fill", parent: target)
                    } else {
                        store.createCollection(name: trimmed, icon: "folder.fill")
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            if let collection {
                name = collection.name
            } else {
                selectedParentId = parent?.id
            }
        }
    }

    private func findCollection(_ id: UUID) -> PDFCollection? {
        func search(_ collections: [PDFCollection]) -> PDFCollection? {
            for c in collections {
                if c.id == id { return c }
                if let found = search(c.subcollections) { return found }
            }
            return nil
        }
        return search(store.rootCollections)
    }
}

// MARK: - Hierarchical Collection Picker (NSPopUpButton)

private struct CollectionPopUpButton: NSViewRepresentable {
    let rootCollections: [PDFCollection]
    @Binding var selectedParentId: UUID?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtCenter
        context.coordinator.button = button
        rebuildMenu(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        rebuildMenu(button, coordinator: context.coordinator)
    }

    private func rebuildMenu(_ button: NSPopUpButton, coordinator: Coordinator) {
        let menu = NSMenu()
        let libraryImage = NSImage(systemSymbolName: "building.columns", accessibilityDescription: nil)

        // First item = displayed title (pull-down mode uses item 0 as the button face)
        let titleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(titleItem)

        // "Library" option in the dropdown
        let libraryItem = NSMenuItem(
            title: "Library", action: #selector(Coordinator.itemSelected(_:)), keyEquivalent: ""
        )
        libraryItem.target = coordinator
        libraryItem.image = libraryImage
        menu.addItem(libraryItem)
        menu.addItem(.separator())

        // Build hierarchical tree with submenus
        for collection in rootCollections.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            addItem(for: collection, to: menu, coordinator: coordinator)
        }

        button.menu = menu

        // Set the displayed title to match current selection
        if let parentId = selectedParentId,
           let item = findItem(in: menu, matching: parentId.uuidString) {
            titleItem.title = item.title
            titleItem.image = item.image
        } else {
            titleItem.title = "Library"
            titleItem.image = libraryImage
        }
    }

    private func addItem(for collection: PDFCollection, to menu: NSMenu, coordinator: Coordinator) {
        let children = collection.subcollections.sorted(by: { $0.sortOrder < $1.sortOrder })
        let folderImage = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)

        if children.isEmpty {
            let item = NSMenuItem(
                title: collection.name, action: #selector(Coordinator.itemSelected(_:)), keyEquivalent: ""
            )
            item.target = coordinator
            item.image = folderImage
            item.representedObject = collection.id.uuidString
            menu.addItem(item)
        } else {
            // Parent with children — opens submenu
            let item = NSMenuItem(title: collection.name, action: nil, keyEquivalent: "")
            item.image = folderImage

            let submenu = NSMenu()

            // The parent itself as first selectable item in the submenu
            let selfItem = NSMenuItem(
                title: collection.name, action: #selector(Coordinator.itemSelected(_:)), keyEquivalent: ""
            )
            selfItem.target = coordinator
            selfItem.image = folderImage
            selfItem.representedObject = collection.id.uuidString
            submenu.addItem(selfItem)
            submenu.addItem(.separator())

            for child in children {
                addItem(for: child, to: submenu, coordinator: coordinator)
            }

            item.submenu = submenu
            menu.addItem(item)
        }
    }

    private func findItem(in menu: NSMenu, matching uuidString: String) -> NSMenuItem? {
        for item in menu.items {
            if item.representedObject as? String == uuidString {
                return item
            }
            if let submenu = item.submenu, let found = findItem(in: submenu, matching: uuidString) {
                return found
            }
        }
        return nil
    }

    class Coordinator: NSObject {
        var parent: CollectionPopUpButton
        weak var button: NSPopUpButton?

        init(_ parent: CollectionPopUpButton) {
            self.parent = parent
        }

        @objc func itemSelected(_ sender: NSMenuItem) {
            if let uuidString = sender.representedObject as? String {
                parent.selectedParentId = UUID(uuidString: uuidString)
            } else {
                parent.selectedParentId = nil
            }

            // Update the pull-down title item (item at index 0) to reflect the selection
            if let titleItem = button?.menu?.items.first {
                titleItem.title = sender.title
                titleItem.image = sender.image
            }
        }
    }
}
