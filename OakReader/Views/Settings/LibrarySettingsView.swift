import SwiftUI

struct LibrarySettingsView: View {
    let store: LibraryStore

    private let systemCollections: [(id: UUID, name: String, icon: String)] = [
        (SystemCollectionID.allItems, "All Items", "books.vertical"),
        (SystemCollectionID.recentlyRead, "Recently Read", "book"),
        (SystemCollectionID.pdfs, "PDFs", "doc.fill"),
        (SystemCollectionID.webSnapshots, "Web", "globe"),
        (SystemCollectionID.videos, "Videos", "play.rectangle"),
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
        }
        .formStyle(.grouped)
        .padding()
    }
}
