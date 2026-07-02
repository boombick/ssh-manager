import Foundation

final class ConfigStore {
    private let url: URL

    init(url: URL = Paths.configFile) {
        self.url = url
    }

    /// Loads config.json, migrating the pre-0.5 bare-array format in place:
    /// a legacy `[Connection]` file is wrapped into AppConfig and immediately
    /// rewritten to disk, so old configs keep working after upgrade.
    func load() throws -> AppConfig {
        if !FileManager.default.fileExists(atPath: url.path) {
            let fresh = AppConfig()
            try save(fresh)
            return fresh
        }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return AppConfig() }

        if let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return config
        }
        let legacy = try JSONDecoder().decode([Connection].self, from: data)
        let migrated = AppConfig(connections: legacy)
        try save(migrated)
        return migrated
    }

    func save(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }
}
