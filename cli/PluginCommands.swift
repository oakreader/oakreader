import Foundation
import OakAgent // re-exports OakAI (KeychainService)

// MARK: - Plugin Commands

enum PluginCommands {

    // MARK: - oak plugins

    static func runPlugins(args: [String]) {
        let subcommand = args.first ?? "list"

        switch subcommand {
        case "list":
            listPlugins()
        case "show":
            let name = args.dropFirst().first
            showPlugin(name: name)
        case "check":
            checkPlugins()
        case "install-tools":
            let name = args.dropFirst().first
            installPluginTools(name: name)
        case "enable":
            let name = args.dropFirst().first
            enablePlugin(name: name, enable: true)
        case "disable":
            let name = args.dropFirst().first
            enablePlugin(name: name, enable: false)
        default:
            printError("Unknown plugins subcommand '\(subcommand)'. Run 'oak --help' for usage.")
            exit(1)
        }
    }

    private static func listPlugins() {
        let registry = PluginRegistry.shared
        let disabled = loadDisabledPlugins()

        print("PLUGINS")
        print(String(repeating: "─", count: 80))
        print("\(pad("NAME", 16))\(pad("VERSION", 10))\(pad("TYPE", 10))\(pad("STATUS", 10))\(pad("DESCRIPTION", 26))TOOLS")
        print(String(repeating: "─", count: 80))

        for plugin in registry.plugins {
            let isBundled = registry.isBundled(plugin.name)
            let isEnabled = !disabled.contains(plugin.name)

            let statuses = registry.checkTools(for: plugin)
            let toolSummary: String
            if statuses.isEmpty {
                toolSummary = "—"
            } else {
                let missing = statuses.filter { $0.path == nil }
                if missing.isEmpty {
                    toolSummary = "\(statuses.count) ok"
                } else {
                    toolSummary = "\(missing.count)/\(statuses.count) missing"
                }
            }

            let typeStr = isBundled ? "bundled" : "user"
            let statusStr = isEnabled ? "enabled" : "disabled"
            let desc = String(plugin.description.prefix(26))
            print("\(pad(plugin.name, 16))\(pad(plugin.version, 10))\(pad(typeStr, 10))\(pad(statusStr, 10))\(pad(desc, 26))\(toolSummary)")
        }
    }

    private static func showPlugin(name: String?) {
        guard let name else {
            printError("Usage: oak plugins show <name>")
            exit(1)
        }
        let registry = PluginRegistry.shared
        guard let plugin = registry.plugins.first(where: { $0.name == name }) else {
            printError("Plugin '\(name)' not found. Run 'oak plugins' to see available plugins.")
            exit(1)
        }

        print("\(plugin.name) v\(plugin.version)")
        print(plugin.description)
        print("")

        // Tools
        if !plugin.tools.isEmpty {
            print("TOOLS")
            print(String(repeating: "─", count: 60))
            let statuses = registry.checkTools(for: plugin)
            for status in statuses {
                let icon = status.path != nil ? "✓" : "✗"
                let req = status.tool.required ? "(required)" : "(optional)"
                let pathStr = status.path ?? "not found"
                let verStr = status.version.map { " [\($0)]" } ?? ""
                print("  \(icon) \(status.tool.name) \(req)")
                print("    \(status.tool.description)")
                print("    \(pathStr)\(verStr)")
            }
            print("")
        }

        // Credentials
        if !plugin.credentials.isEmpty {
            print("CREDENTIALS")
            print(String(repeating: "─", count: 60))
            for cred in plugin.credentials {
                let key = KeychainService.apiKey(forProviderId: cred.providerId)
                let envVal = cred.envVar.flatMap { ProcessInfo.processInfo.environment[$0] }
                let status: String
                if key != nil {
                    status = "set (keychain)"
                } else if envVal != nil {
                    status = "set (env: \(cred.envVar!))"
                } else {
                    status = "not set"
                }
                print("  \(cred.displayName): \(status)")
            }
            print("")
        }

        // Commands
        if !plugin.commands.isEmpty {
            print("COMMANDS: \(plugin.commands.joined(separator: ", "))")
        }
    }

    private static func checkPlugins() {
        let registry = PluginRegistry.shared
        var allOk = true

        for plugin in registry.plugins {
            let statuses = registry.checkTools(for: plugin)
            for status in statuses where status.path == nil {
                let severity = status.tool.required ? "ERROR" : "WARNING"
                print("\(severity): \(plugin.name) — \(status.tool.name) not found")
                if status.tool.required { allOk = false }
            }
        }

        if allOk {
            print("All required plugin dependencies are satisfied.")
        } else {
            exit(1)
        }
    }

    private static func installPluginTools(name: String?) {
        guard let name else {
            printError("Usage: oak plugins install-tools <name>")
            exit(1)
        }
        let registry = PluginRegistry.shared
        guard let plugin = registry.plugins.first(where: { $0.name == name }) else {
            printError("Plugin '\(name)' not found.")
            exit(1)
        }

        let statuses = registry.checkTools(for: plugin)
        let missing = statuses.filter { $0.path == nil }

        if missing.isEmpty {
            print("All tools for '\(name)' are already installed.")
            return
        }

        for status in missing {
            do {
                try registry.install(tool: status.tool.name)
            } catch {
                printError("\(status.tool.name): \(error.localizedDescription)")
            }
        }
    }

    private static func enablePlugin(name: String?, enable: Bool) {
        guard let name else {
            printError("Usage: oak plugins \(enable ? "enable" : "disable") <name>")
            exit(1)
        }
        let registry = PluginRegistry.shared
        guard registry.plugins.contains(where: { $0.name == name }) else {
            printError("Plugin '\(name)' not found. Run 'oak plugins' to see available plugins.")
            exit(1)
        }

        var disabled = loadDisabledPlugins()
        if enable {
            disabled.remove(name)
        } else {
            disabled.insert(name)
        }
        saveDisabledPlugins(disabled)
        print("Plugin '\(name)' \(enable ? "enabled" : "disabled").")
    }

    // MARK: - Disabled Plugins Persistence

    private static let configURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".oak/config.json")
    }()

    static func loadDisabledPlugins() -> Set<String> {
        guard let data = FileManager.default.contents(atPath: configURL.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["disabledPlugins"] as? [String] else {
            return []
        }
        return Set(arr)
    }

    private static func saveDisabledPlugins(_ disabled: Set<String>) {
        let fm = FileManager.default
        let dir = configURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var json: [String: Any] = [:]
        if let data = fm.contents(atPath: configURL.path),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        json["disabledPlugins"] = Array(disabled).sorted()

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configURL)
        }
    }

    static func isPluginEnabled(_ name: String) -> Bool {
        !loadDisabledPlugins().contains(name)
    }

    // MARK: - oak tools

    static func runTools(args: [String]) {
        let subcommand = args.first ?? "list"

        switch subcommand {
        case "list":
            listTools()
        case "check":
            checkTools()
        case "install":
            let name = args.dropFirst().first
            installTool(name: name)
        case "path":
            let name = args.dropFirst().first
            toolPath(name: name)
        default:
            printError("Unknown tools subcommand '\(subcommand)'. Run 'oak --help' for usage.")
            exit(1)
        }
    }

    private static func listTools() {
        let registry = PluginRegistry.shared
        let statuses = registry.checkAll()

        print("TOOLS")
        print(String(repeating: "─", count: 80))
        print("\(pad("TOOL", 14))\(pad("PLUGIN", 14))\(pad("ST", 4))\(pad("PATH", 32))VERSION")
        print(String(repeating: "─", count: 80))

        for status in statuses {
            let icon = status.path != nil ? "✓" : "✗"
            let pathStr = status.path ?? "—"
            let verStr = status.version ?? "—"
            let displayPath = pathStr.count > 30 ? "..." + String(pathStr.suffix(27)) : pathStr
            print("\(pad(status.tool.name, 14))\(pad(status.pluginName, 14))\(pad(icon, 4))\(pad(displayPath, 32))\(verStr)")
        }
    }

    private static func checkTools() {
        let registry = PluginRegistry.shared
        let statuses = registry.checkAll()

        listTools()
        print("")

        let missing = statuses.filter { $0.path == nil }
        if missing.isEmpty {
            print("All tools found.")
        } else {
            let required = missing.filter { $0.tool.required }
            let optional = missing.filter { !$0.tool.required }
            if !optional.isEmpty {
                print("\(optional.count) optional tool(s) not found: \(optional.map(\.tool.name).joined(separator: ", "))")
            }
            if !required.isEmpty {
                print("\(required.count) required tool(s) missing: \(required.map(\.tool.name).joined(separator: ", "))")
                exit(1)
            }
        }
    }

    private static func installTool(name: String?) {
        guard let name else {
            printError("Usage: oak tools install <name>")
            exit(1)
        }
        do {
            try PluginRegistry.shared.install(tool: name)
            print("Done.")
        } catch {
            printError(error.localizedDescription)
            exit(1)
        }
    }

    private static func toolPath(name: String?) {
        guard let name else {
            printError("Usage: oak tools path <name>")
            exit(1)
        }
        guard let path = PluginRegistry.shared.resolve(tool: name) else {
            printError("\(name) not found.")
            exit(1)
        }
        print(path)
    }

    // MARK: - oak credentials

    static func runCredentials(args: [String]) {
        let subcommand = args.first ?? "list"

        switch subcommand {
        case "list":
            listCredentials()
        case "set":
            let provider = args.dropFirst().first
            setCredential(provider: provider)
        case "remove":
            let provider = args.dropFirst().first
            removeCredential(provider: provider)
        default:
            printError("Unknown credentials subcommand '\(subcommand)'. Run 'oak --help' for usage.")
            exit(1)
        }
    }

    private static func listCredentials() {
        let registry = PluginRegistry.shared
        let creds = registry.allCredentials

        if creds.isEmpty {
            print("No credential declarations found.")
            return
        }

        print("CREDENTIALS")
        print(String(repeating: "─", count: 64))
        print("\(pad("PROVIDER", 12))\(pad("NAME", 22))\(pad("STATUS", 10))SOURCE")
        print(String(repeating: "─", count: 64))

        for cred in creds {
            let keychainKey = KeychainService.apiKey(forProviderId: cred.providerId)
            let envVal = cred.envVar.flatMap { ProcessInfo.processInfo.environment[$0] }

            let status: String
            let source: String
            if let key = keychainKey {
                status = "set"
                source = "keychain (\(maskKey(key)))"
            } else if let val = envVal {
                status = "set"
                source = "env:\(cred.envVar!) (\(maskKey(val)))"
            } else {
                status = "not set"
                source = "—"
            }
            print("\(pad(cred.providerId, 12))\(pad(cred.displayName, 22))\(pad(status, 10))\(source)")
        }
    }

    private static func maskKey(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "*", count: key.count) }
        return String(key.prefix(4)) + "..." + String(key.suffix(4))
    }

    private static func setCredential(provider: String?) {
        guard let provider else {
            printError("Usage: oak credentials set <provider>")
            let ids = PluginRegistry.shared.allCredentials.map(\.providerId).joined(separator: ", ")
            printError("Available providers: \(ids)")
            exit(1)
        }

        guard PluginRegistry.shared.allCredentials.contains(where: { $0.providerId == provider }) else {
            printError("Unknown provider '\(provider)'.")
            let ids = PluginRegistry.shared.allCredentials.map(\.providerId).joined(separator: ", ")
            printError("Available providers: \(ids)")
            exit(1)
        }

        print("Enter API key for \(provider): ", terminator: "")
        fflush(stdout)

        let key = readSecure()

        guard !key.isEmpty else {
            printError("No key provided.")
            exit(1)
        }

        if KeychainService.setAPIKey(key, forProviderId: provider) {
            print("API key for '\(provider)' saved to Keychain.")
        } else {
            printError("Failed to save API key to Keychain.")
            exit(1)
        }
    }

    private static func removeCredential(provider: String?) {
        guard let provider else {
            printError("Usage: oak credentials remove <provider>")
            exit(1)
        }

        KeychainService.deleteAPIKey(forProviderId: provider)
        print("Removed API key for '\(provider)' from Keychain.")
    }

    /// Read a line from stdin with terminal echo disabled.
    private static func readSecure() -> String {
        var oldTermios = termios()
        tcgetattr(STDIN_FILENO, &oldTermios)

        var newTermios = oldTermios
        newTermios.c_lflag &= ~UInt(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &newTermios)

        let line = readLine(strippingNewline: true) ?? ""

        tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios)
        print("") // newline after hidden input
        return line
    }

    // MARK: - Helpers

    /// Pad a string to a fixed width with trailing spaces.
    private static func pad(_ str: String, _ width: Int) -> String {
        if str.count >= width {
            return str
        }
        return str + String(repeating: " ", count: width - str.count)
    }
}
