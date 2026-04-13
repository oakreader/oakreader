import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    let supportedTypes: [UTType]
    let label: String
    var icon: String = "arrow.down.doc"
    let onDrop: ([URL]) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)

            Text(label)
                .font(.headline)
                .foregroundStyle(isTargeted ? .primary : .secondary)

            Text("or click to browse")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isTargeted ? Color.accentColor.opacity(0.05) : Color.clear)
                )
        )
        .onDrop(of: supportedTypes, isTargeted: $isTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .onTapGesture {
            openFilePicker()
        }
        .animation(.easeInOut(duration: 0.2), value: isTargeted)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            for type in supportedTypes {
                if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                        if let url = item as? URL {
                            urls.append(url)
                        } else if let data = item as? Data,
                                  let url = URL(dataRepresentation: data, relativeTo: nil) {
                            urls.append(url)
                        }
                        group.leave()
                    }
                    break
                }
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty {
                onDrop(urls)
            }
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = supportedTypes
        if panel.runModal() == .OK {
            onDrop(panel.urls)
        }
    }
}
