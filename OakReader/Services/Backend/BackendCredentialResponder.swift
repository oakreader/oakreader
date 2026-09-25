import Foundation
import OakAgent
import OSLog

/// Answers the sidecar's `credential_request` events out of the Keychain.
///
/// The sidecar needs provider credentials to make requests, but it should not
/// be the thing that *stores* them: its own file-backed store wrote a 0600
/// `auth.json` into the data dir, which is readable by anything running as the
/// user and lands in every backup. Keeping the secrets here preserves the
/// data-protection keychain and its team-stable access group (see
/// `KeychainConfig`), and leaves the sidecar holding a credential only for as
/// long as a request needs one.
///
/// A credential is opaque JSON on this side. The sidecar's provider layer keys
/// one per provider and the shape varies — an api-key entry can carry provider
/// env, an OAuth entry carries refresh/access/expiry — so the shell stores what
/// it is handed rather than modelling it. The one exception is the legacy
/// plain-key item written before the sidecar existed: a read with no blob falls
/// back to it and synthesizes `{"type":"api_key","key":…}`, so a user who saved
/// a key under the old scheme keeps it without a migration pass.
enum BackendCredentialResponder {
    private static let log = Logger(subsystem: "com.oakreader.OakReader", category: "NodeBackend")

    /// Build the reply to one `credential_request`. Never throws: a keystore
    /// failure comes back as `ok: false`, which the sidecar surfaces as an auth
    /// error rather than as "no credential configured".
    static func reply(to event: BackendEvent) -> BackendCommand {
        var command = BackendCommand(id: event.id, type: "credential_result")
        command.ok = true

        switch event.op {
        case "read":
            guard let providerId = event.providerId else {
                return failure(&command, "read without a providerId")
            }
            command.credential = readCredential(providerId: providerId)

        case "list":
            command.credentials = KeychainService.credentialProviderIds().compactMap { providerId in
                guard let credential = readCredential(providerId: providerId) else { return nil }
                let type = credential.object["type"] as? String ?? "api_key"
                return BackendCredentialInfo(providerId: providerId, type: type)
            }

        case "write":
            guard let providerId = event.providerId else {
                return failure(&command, "write without a providerId")
            }
            guard let credential = event.credential,
                  let data = try? JSONEncoder().encode(credential),
                  let json = String(data: data, encoding: .utf8) else {
                return failure(&command, "write without a credential")
            }
            guard KeychainService.setCredentialJSON(json, forProviderId: providerId) else {
                return failure(&command, "keychain write failed for \(providerId)")
            }

        case "delete":
            guard let providerId = event.providerId else {
                return failure(&command, "delete without a providerId")
            }
            KeychainService.deleteCredential(forProviderId: providerId)

        default:
            return failure(&command, "unknown credential op \(event.op ?? "nil")")
        }

        return command
    }

    private static func failure(_ command: inout BackendCommand, _ message: String) -> BackendCommand {
        command.ok = false
        command.error = message
        log.error("credential_request: \(message)")
        return command
    }

    private static func readCredential(providerId: String) -> AnyJSONObject? {
        if let json = KeychainService.credentialJSON(forProviderId: providerId),
           let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return AnyJSONObject(object)
        }
        // Legacy plain-key item from before the sidecar owned provider auth.
        if let key = KeychainService.apiKey(forProviderId: providerId), !key.isEmpty {
            return AnyJSONObject(["type": "api_key", "key": key])
        }
        return nil
    }
}
