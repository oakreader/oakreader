import SwiftUI

struct LibrarySettingsView: View {
    let store: LibraryStore

    @State private var archiveWebPages = Preferences.shared.archiveWebPages

    private let systemCollections: [(id: UUID, name: String, icon: String)] = [
        (SystemCollectionID.allItems, "All Items", "books.vertical"),
        (SystemCollectionID.recentlyRead, "Recently Read", "book"),
        (SystemCollectionID.pdfs, "PDFs", "doc.fill"),
        (SystemCollectionID.html, "Web", "globe"),
    ]

    var body: some View {
        Form {
            Section("Sidebar Collections") {
                Text("Choose which system collections appear in the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(systemCollections, id: \.id) { item in
                    Toggle(isOn: Binding(
                        get: { !store.hiddenSystemCollectionIds.contains(item.id) },
                        set: { visible in
                            if visible {
                                store.hiddenSystemCollectionIds.remove(item.id)
                            } else {
                                store.hiddenSystemCollectionIds.insert(item.id)
                            }
                        }
                    )) {
                        Label(item.name, systemImage: item.icon)
                    }
                }
            }

            Section("Web Pages") {
                Toggle("Save an offline snapshot", isOn: $archiveWebPages)
                    .onChange(of: archiveWebPages) { _, newValue in
                        Preferences.shared.archiveWebPages = newValue
                    }
                Text("Off: a saved page stores its link plus the extracted text, "
                     + "and reopens live. On: a full offline copy is archived too — "
                     + "typically a few megabytes per page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
