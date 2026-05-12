import Foundation
import OakAgent

// MARK: - Help Text

let helpText = """
oak — OakReader CLI

USAGE:
    oak                                          Show library stats
    oak items [list] [--collection <n>] [--tag <n>] [--type pdf|web|video|note]
              [--search <q>] [--sort title|author|date] [--limit N]
    oak items show <item>                        Item detail
    oak items open <item>                        Open in OakReader.app

    oak collections [list]                       List collections (tree)
    oak collections create <name> [--parent <n>] Create collection
    oak collections rename <name|id> <new-name>  Rename collection
    oak collections delete <name|id>             Delete collection
    oak collections add <collection> <item>      Add item to collection
    oak collections remove <collection> <item>   Remove item from collection

    oak tags [list]                              List tags with counts
    oak tags create <name> [--color <hex>]       Create tag
    oak tags rename <name|id> <new-name>         Rename tag
    oak tags delete <name|id>                    Delete tag
    oak tags add <tag> <item>                    Tag an item
    oak tags remove <tag> <item>                 Untag an item

    oak import <file|url>                       Import PDF, HTML, Markdown, or URL
        [--title <title>]                        Override title
        [--collection <name>]                    Add to collection after import
        [--tag <name>]                           Tag after import

    oak search <query>                           Search library
        [--mode keyword|semantic|hybrid]          Search mode (default: keyword)
        [--limit N]                               Max results (default: 20)

    oak status <item>                            Show item status
    oak status <item> <value>                    Set status (unread/reading/completed/archived)

    oak chat [--file <path>] [--ask "question"]  AI chat with PDF

    oak plugins [list]                           List all plugins and status
    oak plugins show <name>                      Show plugin detail
    oak plugins check                            Verify all plugin dependencies
    oak plugins install-tools <name>             Install tools for a plugin
    oak plugins enable <name>                    Enable a plugin
    oak plugins disable <name>                   Disable a plugin

    oak tools [list]                             List all tools across plugins
    oak tools check                              Verify all tools are installed
    oak tools install <name>                     Install a specific tool
    oak tools path <name>                        Print resolved tool path

    oak credentials [list]                       List API keys (masked)
    oak credentials set <provider>               Set API key (Keychain)
    oak credentials remove <provider>            Remove API key

OPTIONS:
    --db <path>     Path to database (default: ~/OakReader/library.sqlite)
    --help, -h      Show this help
    --version       Show version
"""

let version = "oak 1.0.0"

// MARK: - Argument Parsing

var allArgs = Array(CommandLine.arguments.dropFirst()) // drop executable name

// Check for global flags first
if allArgs.contains("--help") || allArgs.contains("-h") {
    if allArgs.first == "chat" {
        // Delegate to chat help
    } else {
        print(helpText)
        exit(0)
    }
}

if allArgs.contains("--version") {
    print(version)
    exit(0)
}

// Extract --db flag
var dbPath: String? = nil
if let idx = allArgs.firstIndex(of: "--db"), idx + 1 < allArgs.count {
    dbPath = allArgs[idx + 1]
    allArgs.removeSubrange(idx...idx + 1)
}

// MARK: - Command Dispatch

let command = allArgs.isEmpty ? nil : allArgs.removeFirst()

switch command {
case nil:
    // `oak` with no arguments: show stats + help hint
    do {
        let db = try CLIDatabase(path: dbPath)
        let commands = CLICommands(db: db)
        try commands.runStats()
        print("")
        print("Run 'oak --help' for available commands.")
    } catch {
        printError(error.localizedDescription)
        exit(1)
    }

case "items", "list":
    do {
        let db = try CLIDatabase(path: dbPath)
        let commands = CLICommands(db: db)
        let subcommand = (command == "list") ? "list" : (allArgs.isEmpty ? "list" : allArgs.removeFirst())

        switch subcommand {
        case "list":
            var remaining = allArgs
            let flags = parseFlags(&remaining)
            try commands.runItemsList(args: remaining, flags: flags)
        case "show":
            try commands.runItemsShow(args: allArgs)
        case "open":
            try commands.runItemsOpen(args: allArgs)
        default:
            // Treat as `list` with the subcommand as a potential flag
            allArgs.insert(subcommand, at: 0)
            var remaining = allArgs
            let flags = parseFlags(&remaining)
            try commands.runItemsList(args: remaining, flags: flags)
        }
    } catch {
        printError(error.localizedDescription)
        exit(1)
    }

case "collections":
    do {
        let db = try CLIDatabase(path: dbPath)
        let commands = CLICommands(db: db)
        let subcommand = allArgs.isEmpty ? "list" : allArgs.removeFirst()

        switch subcommand {
        case "list":
            try commands.runCollectionsList()
        case "create":
            var remaining = allArgs
            let flags = parseFlags(&remaining)
            try commands.runCollectionsCreate(args: remaining, flags: flags)
        case "rename":
            try commands.runCollectionsRename(args: allArgs)
        case "delete":
            try commands.runCollectionsDelete(args: allArgs)
        case "add":
            try commands.runCollectionsAdd(args: allArgs)
        case "remove":
            try commands.runCollectionsRemove(args: allArgs)
        default:
            printError("Unknown collections subcommand '\(subcommand)'. Run 'oak --help' for usage.")
            exit(1)
        }
    } catch {
        printError(error.localizedDescription)
        exit(1)
    }

case "tags":
    do {
        let db = try CLIDatabase(path: dbPath)
        let commands = CLICommands(db: db)
        let subcommand = allArgs.isEmpty ? "list" : allArgs.removeFirst()

        switch subcommand {
        case "list":
            try commands.runTagsList()
        case "create":
            var remaining = allArgs
            let flags = parseFlags(&remaining)
            try commands.runTagsCreate(args: remaining, flags: flags)
        case "rename":
            try commands.runTagsRename(args: allArgs)
        case "delete":
            try commands.runTagsDelete(args: allArgs)
        case "add":
            try commands.runTagsAdd(args: allArgs)
        case "remove":
            try commands.runTagsRemove(args: allArgs)
        default:
            printError("Unknown tags subcommand '\(subcommand)'. Run 'oak --help' for usage.")
            exit(1)
        }
    } catch {
        printError(error.localizedDescription)
        exit(1)
    }

case "status":
    do {
        let db = try CLIDatabase(path: dbPath)
        let commands = CLICommands(db: db)
        try commands.runStatus(args: allArgs)
    } catch {
        printError(error.localizedDescription)
        exit(1)
    }

case "import":
    do {
        let db = try CLIDatabase(path: dbPath)
        let commands = CLICommands(db: db)
        var remaining = allArgs
        let flags = parseFlags(&remaining)

        // Check if this is a URL import (needs async)
        let input = remaining.first ?? ""
        if input.hasPrefix("http://") || input.hasPrefix("https://") {
            _ = Task {
                do {
                    try await commands.runImportAsync(args: remaining, flags: flags)
                } catch {
                    printError(error.localizedDescription)
                    exit(1)
                }
                exit(0)
            }
            RunLoop.main.run()
        } else {
            let handled = try commands.runImport(args: remaining, flags: flags)
            if !handled {
                printError("Unexpected import error.")
                exit(1)
            }
        }
    } catch {
        printError(error.localizedDescription)
        exit(1)
    }

case "search":
    do {
        let db = try CLIDatabase(path: dbPath)
        let commands = CLICommands(db: db)
        var remaining = allArgs
        let flags = parseFlags(&remaining)
        let mode = flags["mode"] ?? "keyword"

        if mode == "semantic" || mode == "hybrid" {
            // Semantic/hybrid search requires async
            _ = Task {
                do {
                    try await commands.runSearchAsync(args: remaining, flags: flags)
                } catch {
                    printError(error.localizedDescription)
                    exit(1)
                }
                exit(0)
            }
            RunLoop.main.run()
        } else {
            try commands.runSearch(args: remaining, flags: flags)
        }
    } catch {
        printError(error.localizedDescription)
        exit(1)
    }

case "plugins":
    PluginCommands.runPlugins(args: allArgs)

case "tools":
    PluginCommands.runTools(args: allArgs)

case "credentials":
    PluginCommands.runCredentials(args: allArgs)

case "chat":
    // Preserve existing chat functionality
    var filePath: String?
    var question: String?

    var i = 0
    while i < allArgs.count {
        switch allArgs[i] {
        case "--file", "-f":
            i += 1
            if i < allArgs.count { filePath = allArgs[i] }
        case "--ask", "-a":
            i += 1
            if i < allArgs.count { question = allArgs[i] }
        case "--help", "-h":
            let usage = """
            oak chat — AI chat companion for PDF documents

            USAGE:
                oak chat --file <path>                    Interactive mode
                oak chat --file <path> --ask "question"   One-shot mode

            OPTIONS:
                -f, --file <path>      Path to PDF file
                -a, --ask <question>   Ask a question (one-shot mode)
                -h, --help             Show help
            """
            print(usage)
            exit(0)
        default:
            if filePath == nil && FileManager.default.fileExists(atPath: allArgs[i]) {
                filePath = allArgs[i]
            }
        }
        i += 1
    }

    let runner = CLIChatRunner()

    _ = Task {
        do {
            if let question {
                try await runner.oneShot(filePath: filePath, question: question)
            } else {
                try await runner.interactive(filePath: filePath)
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        exit(0)
    }

    RunLoop.main.run()

default:
    printError("Unknown command '\(command!)'. Run 'oak --help' for usage.")
    exit(1)
}
