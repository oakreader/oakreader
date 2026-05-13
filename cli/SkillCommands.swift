import Foundation
import OakAgent

// MARK: - Skill Commands

enum SkillCommands {

    /// Installed skills directory: `~/OakReader/agent/skills/`.
    private static let installedDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader/agent/skills", isDirectory: true)
    }()

    // MARK: - oak skills

    static func run(args: [String]) {
        let subcommand = args.first ?? "list"

        switch subcommand {
        case "list":
            listSkills()
        case "show":
            let name = args.dropFirst().first
            showSkill(name: name)
        case "check":
            checkSkills()
        case "install":
            let name = args.dropFirst().first
            installSkill(name: name)
        case "uninstall":
            let name = args.dropFirst().first
            uninstallSkill(name: name)
        default:
            printError("Unknown skills subcommand '\(subcommand)'. Run 'oak --help' for usage.")
            exit(1)
        }
    }

    // MARK: - List

    private static func listSkills() {
        let catalog = loadCatalogSkills()
        let installed = scanInstalledNames()

        if catalog.isEmpty && installed.isEmpty {
            print("No skills found.")
            return
        }

        print("SKILLS")
        print(String(repeating: "\u{2500}", count: 80))
        print("\(pad("NAME", 20))\(pad("STATUS", 12))\(pad("DESCRIPTION", 32))BINS")
        print(String(repeating: "\u{2500}", count: 80))

        for skill in catalog {
            let isInstalled = installed.contains(skill.name)
            let desc = String(skill.description.prefix(30))
            let status = isInstalled ? "installed" : "available"
            let binSummary: String
            if let bins = skill.requirements?.bins, !bins.isEmpty {
                let missing = bins.filter { ToolResolver.resolve(name: $0.name, searchPaths: $0.searchPaths) == nil }
                if missing.isEmpty {
                    binSummary = "\(bins.count) ok"
                } else {
                    binSummary = "\(missing.count)/\(bins.count) missing"
                }
            } else {
                binSummary = "\u{2014}"
            }
            print("\(pad(skill.name, 20))\(pad(status, 12))\(pad(desc, 32))\(binSummary)")
        }
    }

    // MARK: - Show

    private static func showSkill(name: String?) {
        guard let name else {
            printError("Usage: oak skills show <name>")
            exit(1)
        }

        let catalog = loadCatalogSkills()
        guard let skill = catalog.first(where: { $0.name == name }) else {
            printError("Skill '\(name)' not found. Run 'oak skills' to see available skills.")
            exit(1)
        }

        let installed = scanInstalledNames().contains(name)
        print("\(skill.name) (\(installed ? "installed" : "not installed"))")
        if !skill.description.isEmpty {
            print(skill.description)
        }
        if let author = skill.author {
            print("Author: \(author.name)")
        }
        print("")

        // Bins
        if let bins = skill.requirements?.bins, !bins.isEmpty {
            print("DEPENDENCIES")
            print(String(repeating: "\u{2500}", count: 60))
            for bin in bins {
                let path = ToolResolver.resolve(name: bin.name, searchPaths: bin.searchPaths)
                let ver = path.flatMap { ToolResolver.version(at: $0, versionArgs: bin.versionArgs ?? []) }
                let icon = path != nil ? "\u{2713}" : "\u{2717}"
                let pathStr = path ?? "not found"
                let verStr = ver.map { " [\($0)]" } ?? ""
                print("  \(icon) \(bin.name)")
                if let desc = bin.description {
                    print("    \(desc)")
                }
                print("    \(pathStr)\(verStr)")
            }
            print("")
        }

        print("Location: \(skill.baseDir)")
        if installed {
            print("Installed: \(installedDir.appendingPathComponent(name).path)")
        }
    }

    // MARK: - Check

    private static func checkSkills() {
        let installed = loadInstalledSkills()
        var allOk = true

        if installed.isEmpty {
            print("No skills installed. Run 'oak skills install <name>' to install one.")
            return
        }

        for skill in installed {
            guard let bins = skill.requirements?.bins else { continue }
            for bin in bins {
                if ToolResolver.resolve(name: bin.name, searchPaths: bin.searchPaths) == nil {
                    print("WARNING: \(skill.name) \u{2014} \(bin.name) not found")
                    allOk = false
                }
            }
        }

        if allOk {
            print("All installed skill dependencies are satisfied.")
        }
    }

    // MARK: - Install

    private static func installSkill(name: String?) {
        guard let name else {
            printError("Usage: oak skills install <name>")
            exit(1)
        }

        let catalog = loadCatalogSkills()
        guard let skill = catalog.first(where: { $0.name == name }) else {
            printError("Skill '\(name)' not found. Run 'oak skills' to see available skills.")
            exit(1)
        }

        let fm = FileManager.default
        let destDir = installedDir.appendingPathComponent(name)

        do {
            try fm.createDirectory(at: installedDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destDir.path) {
                try fm.removeItem(at: destDir)
            }
            try fm.copyItem(at: URL(fileURLWithPath: skill.baseDir), to: destDir)
            print("Installed '\(name)' to \(destDir.path)")
        } catch {
            printError("Failed to install '\(name)': \(error.localizedDescription)")
            exit(1)
        }
    }

    // MARK: - Uninstall

    private static func uninstallSkill(name: String?) {
        guard let name else {
            printError("Usage: oak skills uninstall <name>")
            exit(1)
        }

        let destDir = installedDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: destDir.path) else {
            printError("Skill '\(name)' is not installed.")
            exit(1)
        }

        do {
            try FileManager.default.removeItem(at: destDir)
            print("Uninstalled '\(name)'.")
        } catch {
            printError("Failed to uninstall '\(name)': \(error.localizedDescription)")
            exit(1)
        }
    }

    // MARK: - Helpers

    /// Load the skill catalog (bundled skills from the repo).
    private static func loadCatalogSkills() -> [AgentSkill] {
        var dirs: [URL] = []

        // Look for bundled skills relative to the CLI binary
        let cliDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let repoSkills = cliDir.deletingLastPathComponent().appendingPathComponent("skills")
        if FileManager.default.fileExists(atPath: repoSkills.path) {
            dirs.append(repoSkills)
        }

        var skills = SkillLoader.loadSkills(from: dirs).skills

        // Also include installed skills that aren't in the catalog
        let installed = loadInstalledSkills()
        let catalogNames = Set(skills.map(\.name))
        skills.append(contentsOf: installed.filter { !catalogNames.contains($0.name) })

        return skills
    }

    /// Load only installed skills from ~/OakReader/agent/skills/.
    private static func loadInstalledSkills() -> [AgentSkill] {
        SkillLoader.loadSkills(from: [installedDir]).skills
    }

    /// Scan installed directory for skill names.
    private static func scanInstalledNames() -> Set<String> {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: installedDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var names: Set<String> = []
        for entry in entries {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            if isDir.boolValue {
                names.insert(entry.lastPathComponent)
            }
        }
        return names
    }

    private static func pad(_ str: String, _ width: Int) -> String {
        if str.count >= width { return str }
        return str + String(repeating: " ", count: width - str.count)
    }
}
