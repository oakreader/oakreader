import SwiftUI

struct PasswordSheet: View {
    let viewModel: DocumentViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var openPassword = ""
    @State private var confirmOpenPassword = ""
    @State private var permissionsPassword = ""
    @State private var confirmPermissionsPassword = ""
    @State private var useOpenPassword = false
    @State private var usePermissionsPassword = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Password & Security")
                .font(.title3)
                .fontWeight(.semibold)

            // Open password
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Require password to open document", isOn: $useOpenPassword)

                    if useOpenPassword {
                        SecureField("Open Password", text: $openPassword)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Confirm Open Password", text: $confirmOpenPassword)
                            .textFieldStyle(.roundedBorder)

                        if !openPassword.isEmpty && !confirmOpenPassword.isEmpty && openPassword != confirmOpenPassword {
                            Text("Passwords do not match")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            } label: {
                Label("Document Open Password", systemImage: "lock")
            }

            // Permissions password
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Require password to change permissions", isOn: $usePermissionsPassword)

                    if usePermissionsPassword {
                        SecureField("Permissions Password", text: $permissionsPassword)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Confirm Permissions Password", text: $confirmPermissionsPassword)
                            .textFieldStyle(.roundedBorder)

                        if !permissionsPassword.isEmpty && !confirmPermissionsPassword.isEmpty && permissionsPassword != confirmPermissionsPassword {
                            Text("Passwords do not match")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            } label: {
                Label("Permissions Password", systemImage: "lock.shield")
            }

            // Permissions
            if usePermissionsPassword {
                PermissionsView(viewModel: viewModel)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                if viewModel.security.settings.isEncrypted {
                    Button("Remove Security") {
                        removeSecuritySettings()
                    }
                    .foregroundStyle(.red)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Apply") {
                    applySecuritySettings()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 480)
        .onAppear { loadSettings() }
    }

    private func loadSettings() {
        let settings = viewModel.security.settings
        useOpenPassword = settings.hasOpenPassword
        usePermissionsPassword = settings.hasPermissionsPassword
        openPassword = settings.openPassword ?? ""
        confirmOpenPassword = settings.openPassword ?? ""
        permissionsPassword = settings.permissionsPassword ?? ""
        confirmPermissionsPassword = settings.permissionsPassword ?? ""
    }

    private func applySecuritySettings() {
        // Validate
        if useOpenPassword {
            guard openPassword == confirmOpenPassword else {
                errorMessage = "Open passwords do not match."
                return
            }
        }
        if usePermissionsPassword {
            guard permissionsPassword == confirmPermissionsPassword else {
                errorMessage = "Permissions passwords do not match."
                return
            }
        }

        var settings = viewModel.security.settings
        settings.openPassword = useOpenPassword ? openPassword : nil
        settings.permissionsPassword = usePermissionsPassword ? permissionsPassword : nil
        settings.isEncrypted = useOpenPassword || usePermissionsPassword
        viewModel.security.settings = settings
        viewModel.markDocumentEdited()
        dismiss()
    }

    private func removeSecuritySettings() {
        viewModel.security.settings = SecuritySettings()
        viewModel.markDocumentEdited()
        dismiss()
    }
}
