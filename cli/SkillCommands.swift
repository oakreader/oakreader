import Foundation
import OakAgent

// MARK: - Skill Commands

enum SkillCommands {

    /// Installed skills directory: `~/OakReader/agent/skills/`.
    static let installedDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader/agent/skills", isDirectory: true)
    }()

    // MARK: - Public API (called from ArgumentParser commands)

    /// Load the skill catalog (bundled + installed).
    static func loadCatalog() -> [AgentSkill] {
        loadCatalogSkills()
    }

    /// Get names of installed skills.
    static func installedNames() -> Set<String> {
        scanInstalledNames()
    }

    // MARK: - Human-readable Output

    static func listSkillsHuman() {
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

    static func showSkillHuman(name: String) {
        let catalog = loadCatalogSkills()
        guard let skill = catalog.first(where: { $0.name == name }) else {
            fputs("Error: Skill '\(name)' not found. Run 'oak skills' to see available skills.\n", stderr)
            Darwin.exit(1)
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

    // MARK: - Actions

    static func installSkillAction(name: String, json: Bool, quiet: Bool) {
        let catalog = loadCatalogSkills()
        guard let skill = catalog.first(where: { $0.name == name }) else {
            if json {
                let output = CLIOutput(json: true, quiet: quiet)
                output.error(operation: "skills.install", message: "Skill '\(name)' not found.", code: "not_found")
            } else {
                fputs("Error: Skill '\(name)' not found. Run 'oak skills' to see available skills.\n", stderr)
            }
            Darwin.exit(1)
        }

        let fm = FileManager.default
        let destDir = installedDir.appendingPathComponent(name)

        do {
            try fm.createDirectory(at: installedDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destDir.path) {
                try fm.removeItem(at: destDir)
            }
            try fm.copyItem(at: URL(fileURLWithPath: skill.baseDir), to: destDir)

            if json {
                let output = CLIOutput(json: true, quiet: quiet)
                output.success(operation: "skills.install", result: CLIOperationResult(
                    id: nil, message: "Installed '\(name)' to \(destDir.path)"
                ))
            } else {
                print("Installed '\(name)' to \(destDir.path)")
            }
        } catch {
            if json {
                let output = CLIOutput(json: true, quiet: quiet)
                output.error(operation: "skills.install", message: error.localizedDescription, code: "install_failed")
            } else {
                fputs("Error: Failed to install '\(name)': \(error.localizedDescription)\n", stderr)
            }
            Darwin.exit(1)
        }
    }

    static func uninstallSkillAction(name: String, json: Bool, quiet: Bool) {
        let destDir = installedDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: destDir.path) else {
            if json {
                let output = CLIOutput(json: true, quiet: quiet)
                output.error(operation: "skills.uninstall", message: "Skill '\(name)' is not installed.", code: "not_found")
            } else {
                fputs("Error: Skill '\(name)' is not installed.\n", stderr)
            }
            Darwin.exit(1)
        }

        do {
            try FileManager.default.removeItem(at: destDir)
            if json {
                let output = CLIOutput(json: true, quiet: quiet)
                output.success(operation: "skills.uninstall", result: CLIOperationResult(
                    id: nil, message: "Uninstalled '\(name)'."
                ))
            } else {
                print("Uninstalled '\(name)'.")
            }
        } catch {
            if json {
                let output = CLIOutput(json: true, quiet: quiet)
                output.error(operation: "skills.uninstall", message: error.localizedDescription, code: "uninstall_failed")
            } else {
                fputs("Error: Failed to uninstall '\(name)': \(error.localizedDescription)\n", stderr)
            }
            Darwin.exit(1)
        }
    }

    static func checkSkillsAction(json: Bool, quiet: Bool) {
        let installed = loadInstalledSkills()

        if installed.isEmpty {
            if json {
                let output = CLIOutput(json: true, quiet: quiet)
                output.success(operation: "skills.check", result: CLIOperationResult(
                    id: nil, message: "No skills installed."
                ))
            } else {
                print("No skills installed. Run 'oak skills install <name>' to install one.")
            }
            return
        }

        var issues: [String] = []
        for skill in installed {
            guard let bins = skill.requirements?.bins else { continue }
            for bin in bins {
                if ToolResolver.resolve(name: bin.name, searchPaths: bin.searchPaths) == nil {
                    issues.append("\(skill.name): \(bin.name) not found")
                }
            }
        }

        if json {
            let output = CLIOutput(json: true, quiet: quiet)
            if issues.isEmpty {
                output.success(operation: "skills.check", result: CLIOperationResult(
                    id: nil, message: "All installed skill dependencies are satisfied."
                ))
            } else {
                output.error(operation: "skills.check", message: issues.joined(separator: "; "), code: "missing_deps")
            }
        } else {
            if issues.isEmpty {
                print("All installed skill dependencies are satisfied.")
            } else {
                for issue in issues {
                    print("WARNING: \(issue)")
                }
            }
        }
    }

    // MARK: - Internal Helpers

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
