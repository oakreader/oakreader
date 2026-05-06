import SwiftUI

struct GraphMapSettingsView: View {
    var body: some View {
        Form {
            Section("Graph Map") {
                Text("Graph maps are generated using the AI provider configured in AI settings.")
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                Text("Generate concept maps and mind maps from your documents using AI. Graphs are rendered natively using SwiftUI Canvas.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
