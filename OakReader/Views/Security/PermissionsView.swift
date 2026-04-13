import SwiftUI

struct PermissionsView: View {
    let viewModel: DocumentViewModel

    @State private var allowPrinting = true
    @State private var allowCopying = true
    @State private var allowEditing = true
    @State private var allowAnnotations = true
    @State private var encryptionKeyLength: SecuritySettings.EncryptionKeyLength = .aes_256

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Allow Printing", isOn: $allowPrinting)
                    .onChange(of: allowPrinting) { _, newValue in
                        viewModel.security.settings.allowPrinting = newValue
                    }

                Toggle("Allow Copying Text & Images", isOn: $allowCopying)
                    .onChange(of: allowCopying) { _, newValue in
                        viewModel.security.settings.allowCopying = newValue
                    }

                Toggle("Allow Editing", isOn: $allowEditing)
                    .onChange(of: allowEditing) { _, newValue in
                        viewModel.security.settings.allowEditing = newValue
                    }

                Toggle("Allow Annotations", isOn: $allowAnnotations)
                    .onChange(of: allowAnnotations) { _, newValue in
                        viewModel.security.settings.allowAnnotations = newValue
                    }

                Divider()

                Picker("Encryption:", selection: $encryptionKeyLength) {
                    ForEach(SecuritySettings.EncryptionKeyLength.allCases) { length in
                        Text(length.label).tag(length)
                    }
                }
                .onChange(of: encryptionKeyLength) { _, newValue in
                    viewModel.security.settings.encryptionKeyLength = newValue
                }
            }
        } label: {
            Label("Permissions", systemImage: "shield.checkered")
        }
        .onAppear { loadSettings() }
    }

    private func loadSettings() {
        let settings = viewModel.security.settings
        allowPrinting = settings.allowPrinting
        allowCopying = settings.allowCopying
        allowEditing = settings.allowEditing
        allowAnnotations = settings.allowAnnotations
        encryptionKeyLength = settings.encryptionKeyLength
    }
}
