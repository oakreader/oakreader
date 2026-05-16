import Foundation
import GRDB

// MARK: - Command Handlers (legacy support for shared logic)

struct CLICommands {
    let db: CLIDatabase
    let resolver: CLIResolver

    init(db: CLIDatabase) {
        self.db = db
        self.resolver = CLIResolver(db: db)
    }
}
