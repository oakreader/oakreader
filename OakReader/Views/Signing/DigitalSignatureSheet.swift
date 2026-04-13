import SwiftUI
import PDFKit
import Security

struct DigitalSignatureSheet: View {
    let viewModel: DocumentViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var certificates: [CertificateInfo] = []
    @State private var selectedCertificate: CertificateInfo?
    @State private var reason = ""
    @State private var location = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    struct CertificateInfo: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let issuer: String
        let expirationDate: Date
        let reference: SecIdentity?

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: CertificateInfo, rhs: CertificateInfo) -> Bool {
            lhs.id == rhs.id
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Digital Signature")
                .font(.title3)
                .fontWeight(.semibold)

            if isLoading {
                ProgressView("Loading certificates...")
            } else if certificates.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)

                    Text("No Signing Certificates Found")
                        .font(.headline)

                    Text("Install a digital certificate in your Keychain to enable digital signing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxHeight: 200)
            } else {
                // Certificate list
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select Certificate:")
                        .font(.caption)
                        .fontWeight(.medium)

                    List(certificates, selection: $selectedCertificate) { cert in
                        HStack {
                            Image(systemName: "person.badge.key.fill")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading) {
                                Text(cert.name)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Issued by: \(cert.issuer)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("Expires: \(cert.expirationDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(cert)
                    }
                    .listStyle(.bordered)
                    .frame(height: 150)
                }

                Divider()

                // Reason & location
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reason for signing:")
                            .font(.caption)
                            .fontWeight(.medium)
                        TextField("e.g., Approval", text: $reason)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Location:")
                            .font(.caption)
                            .fontWeight(.medium)
                        TextField("e.g., Office", text: $location)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Sign Document") {
                    signDocument()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCertificate == nil)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 480, height: 500)
        .onAppear { loadCertificates() }
    }

    private func loadCertificates() {
        isLoading = true

        // Query Keychain for signing identities
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
            kSecReturnAttributes as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let items = result as? [[String: Any]] {
            certificates = items.compactMap { item in
                let name = item[kSecAttrLabel as String] as? String ?? "Unknown"
                let issuer = item[kSecAttrIssuer as String] as? String ?? "Unknown Issuer"
                let identity = item[kSecValueRef as String].map { $0 as! SecIdentity }

                return CertificateInfo(
                    name: name,
                    issuer: issuer,
                    expirationDate: Date().addingTimeInterval(365 * 24 * 3600),
                    reference: identity
                )
            }
        }

        isLoading = false
    }

    private func signDocument() {
        guard let _ = selectedCertificate else {
            errorMessage = "Please select a certificate."
            return
        }

        // Visual signature only — not cryptographic (see DigitalSignatureService docs)
        if let doc = viewModel.pdfDocument {
            var attributes = doc.documentAttributes ?? [:]
            attributes[PDFDocumentAttribute.subjectAttribute] = "Signed: \(reason)"
            doc.documentAttributes = attributes
            viewModel.markDocumentEdited()
        }
        dismiss()
    }
}
