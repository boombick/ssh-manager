import Foundation

enum Paths {
    static var supportDirectory: URL {
        let lib = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return lib.appendingPathComponent("SSHManager", isDirectory: true)
    }

    static var configFile: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    static var logsDirectory: URL {
        supportDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    static func logFile(for id: UUID) -> URL {
        logsDirectory.appendingPathComponent("\(id.uuidString).log")
    }

    static func traceFile(for id: UUID) -> URL {
        logsDirectory.appendingPathComponent("\(id.uuidString).trace.log")
    }

    static var debugReportsDirectory: URL {
        supportDirectory.appendingPathComponent("debug-reports", isDirectory: true)
    }

    static var historyFile: URL {
        supportDirectory.appendingPathComponent("history.db")
    }

    static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(
            at: supportDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logsDirectory, withIntermediateDirectories: true
        )
    }
}
